import AppKit
import AVFoundation
import Carbon
import Foundation

// MARK: - Pipeline (integration worker)
//
// Wires hotkey -> mic capture -> transcription -> intent parse -> contact
// resolution -> confirm card -> WhatsApp send into one end-to-end loop, and
// enforces the progressive-permission model from CLAUDE.md:
//
//   Tier 1 (required, asked on launch): Microphone, Contacts.
//     Hotkey: Ctrl+Space via Carbon (RegisterEventHotKey) — needs NO permission.
//     Send:   open WhatsApp pre-filled; the user presses Enter themselves.
//   Tier 2 (optional, checked at call time):
//     "Hold a key to talk"  (Right-Option) only if Input Monitoring is granted.
//     "Send without Enter"  (synthetic Return) only if Accessibility is granted.
//
// Every Tier-2 path checks its permission at call time and degrades gracefully
// to the Tier-1 behaviour. Nothing here ever shells out to osascript.

/// Ctrl+Space global hotkey via Carbon `RegisterEventHotKey`.
///
/// Carbon hotkeys are process-global and fire without any macOS privacy grant,
/// which is what makes Ctrl+Space the permission-free Tier-1 default.
@MainActor
private final class CarbonHotkey {
    typealias Action = () -> Void
    var onDown: Action?
    var onUp: Action?

    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) var handlerRef: EventHandlerRef?
    private nonisolated(unsafe) var installed = false

    /// 'Voiy' FourCharCode (bytes V O I Y) for this app's hotkey ID space.
    private static let signature: OSType = OSType(0x564F4959)
    private static let spaceKeycode: UInt32 = 49 // kVK_Space

    /// Installs the event handler and registers the hotkey for `keyCode` +
    /// `modifiers` (Carbon modifier mask, e.g. `controlKey`). Returns false if
    /// registration failed (e.g. the hotkey is already taken).
    func register(keyCode: UInt32 = CarbonHotkey.spaceKeycode, modifiers: OptionBits) -> Bool {
        guard !installed else { return true }
        installHandler()

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, OptionBits(modifiers), id,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr else {
            print("[voicy] carbon hotkey register failed: \(status)")
            return false
        }
        hotKeyRef = ref
        installed = true
        return true
    }

    nonisolated func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
        installed = false
    }

    private func installHandler() {
        var down = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        var up = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                               eventKind: UInt32(kEventHotKeyReleased))
        var types = [down, up]

        // Non-capturing @convention(c) callback; routing happens via userData.
        let handler: @convention(c) (EventHandlerCallRef?, EventRef?, UnsafeMutableRawPointer?) -> OSStatus = { _, event, userData in
            guard let event, let userData else { return noErr }
            let hotkey = Unmanaged<CarbonHotkey>.fromOpaque(userData).takeUnretainedValue()
            hotkey.receive(event: event)
            return noErr
        }

        let status = InstallEventHandler(GetEventDispatcherTarget(), handler,
                                         types.count, &types,
                                         Unmanaged.passUnretained(self).toOpaque(),
                                         &handlerRef)
        if status != noErr {
            print("[voicy] carbon handler install failed: \(status)")
        }
    }

    /// Called from the Carbon callback (main thread, not actor-isolated).
    private nonisolated func receive(event: EventRef) {
        let kind = GetEventKind(event)
        let pressed = UInt32(kEventHotKeyPressed)
        let released = UInt32(kEventHotKeyReleased)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if kind == pressed {
                self.onDown?()
            } else if kind == released {
                self.onUp?()
            }
        }
    }

    deinit { unregister() }
}
/// The end-to-end pipeline. Owned by AppDelegate; `start()` is the only entry.
@MainActor
final class Pipeline {
    private let recorder = MicrophoneRecorder()
    private let transcriber: Transcriber = TranscriberFactory.make()
    private let intentParser = IntentParser()
    private let contactIndex = ContactIndex()
    private let resolver = ContactResolver()
    private let aliasStore = AliasStore()
    private let recordingIndicator = RecordingIndicatorController()
    private let confirmPanel = ConfirmPanelController()
    private let whatsAppSender = WhatsAppSender()

    private var carbonHotkey: CarbonHotkey?
    private let modifierHotkey = PushToTalkHotkey()
    private var levelTimer: Timer?

    /// In-memory mirror of the persisted aliases (normalized spoken -> contact
    /// identifier). Loaded from disk at startup so learned names survive a
    /// restart, since AliasStore exposes no enumeration API. Writes still go
    /// through AliasStore (the single durable writer).
    private var aliasLookup: [String: String] = [:]

    // MARK: - Lifecycle

    func start() {
        print("[voicy] Voicy starting")
        loadAliases()
        registerHotkeys()

        // Tier-1 permissions (Microphone + Contacts) are requested on launch but
        // never block startup. Everything works once they are granted.
        Task { @MainActor [weak self] in
            await self?.requestTier1Permissions()
        }

        // Load the on-device speech model NOW, not on the user's first sentence.
        // Measured with the audio-injection harness: the first transcribe call
        // in a process costs ~920 ms and every later call ~160 ms. Warming here
        // is what keeps the first utterance inside the 800 ms budget.
        // Detached from the permission task so neither can delay the other.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await TranscriberWarmup.warm(self.transcriber)
        }

        // Same idea for the audio graph. A cold AVAudioEngine start costs ~296 ms
        // against a 100 ms budget, and that delay does not just look slow, it
        // eats the beginning of the sentence. Prewarming allocates the graph
        // without opening the microphone, so the recording indicator stays off
        // until the user actually holds the key.
        recorder.prewarm()
    }

    // MARK: - Hotkeys (progressive permission)

    private func registerHotkeys() {
        // Tier 1 default: Ctrl+Space via Carbon. Needs no permission at all.
        let carbon = CarbonHotkey()
        carbon.onDown = { [weak self] in self?.startRecording() }
        carbon.onUp = { [weak self] in self?.stopRecording() }
        if carbon.register(modifiers: OptionBits(controlKey)) {
            print("[voicy] hotkey: Ctrl+Space via Carbon (no permission required)")
        } else {
            print("[voicy] ERROR: could not register Ctrl+Space hotkey")
        }
        carbonHotkey = carbon

        // Tier 2 ("hold a key to talk"): Right-Option push-to-talk ONLY if Input
        // Monitoring is already granted. Never ask for it at launch.
        if modifierHotkey.hasInputMonitoring {
            modifierHotkey.onKeyDown = { [weak self] in self?.startRecording() }
            modifierHotkey.onKeyUp = { [weak self] in self?.stopRecording() }
            do {
                try modifierHotkey.start()
                print("[voicy] hotkey: Right-Option hold-to-talk (Input Monitoring already granted)")
            } catch {
                print("[voicy] hotkey: Right-Option unavailable: \(error)")
            }
        } else {
            print("[voicy] hotkey: Input Monitoring not granted; using Ctrl+Space only")
        }
    }

    // MARK: - Recording

    private func startRecording() {
        guard !recorder.isRunning else { return }
        let t0 = Date()
        recordingIndicator.show()          // reveal first (respects the 100 ms budget)
        recordingIndicator.updateLevel(0)
        startLevelMeter()
        do {
            try recorder.start()
            let ms = Date().timeIntervalSince(t0) * 1000
            print("[voicy] recording: started in \(String(format: "%.1f", ms)) ms")
        } catch {
            print("[voicy] ERROR: could not start mic: \(error)")
            recordingIndicator.hide()
            stopLevelMeter()
        }
    }

    private func stopRecording() {
        guard recorder.isRunning else { return }
        stopLevelMeter()
        let pcm = recorder.stop()
        recordingIndicator.hide()
        guard !pcm.isEmpty else {
            print("[voicy] capture: empty; ignoring")
            return
        }
        print("[voicy] capture: \(pcm.count) samples (\(String(format: "%.2f", Double(pcm.count) / 16_000)) s)")
        transcribe(pcm)
    }

    // MARK: - Transcription

    private func transcribe(_ pcm: [Float]) {
        // Accuracy feature: bias the recognizer toward real contact names.
        let hints = contactNames()
        let transcribeStart = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let text = try await self.transcriber.transcribe(pcm: pcm, hints: hints)
                let ms = Date().timeIntervalSince(transcribeStart) * 1000
                // NEVER log the transcript. It is the user's message content, and
                // when Voicy runs as a bundle its stdout is routinely redirected to
                // a file, which would put private messages on disk. Length only.
                // To inspect real transcripts, use the audio-injection harness
                // (`--test-audio`), which runs on synthetic audio by design.
                print("[voicy] transcription: \(String(format: "%.1f", ms)) ms, \(text.count) chars")
                self.present(transcript: text, transcribeStart: transcribeStart)
            } catch {
                print("[voicy] ERROR: transcription failed: \(error)")
            }
        }
    }

    // MARK: - Intent + resolution

    private func present(transcript: String, transcribeStart: Date) {
        let parseStart = Date()
        switch intentParser.parse(transcript) {
        case .notParsed(let reason):
            let parseMs = Date().timeIntervalSince(parseStart) * 1000
            print("[voicy] intent: not parsed (\(reason)) in \(String(format: "%.1f", parseMs)) ms")
            confirmPanel.show(
                payload: VoicyConfirmPayload(recipients: [], message: "", transcript: transcript),
                onSend: { _, _ in },
                onCancel: { print("[voicy] confirm: cancelled (not found)") },
                onDismiss: {}
            )
        case .parsed(let intent):
            // Recipient name is operational metadata and stays; the body never
            // appears in a log, only its length.
            print("[voicy] intent: parsed recipient=\"\(intent.recipientText)\" "
                  + "body=\(intent.body.count) chars app=\(appName(intent.app))")
            let resolveStart = Date()
            let resolution = resolver.resolve(spoken: intent.recipientText,
                                              contacts: contactIndex.contacts,
                                              aliases: aliasLookup)
            showConfirm(intent: intent, resolution: resolution, transcript: transcript,
                        parseMs: Date().timeIntervalSince(parseStart) * 1000,
                        resolveMs: Date().timeIntervalSince(resolveStart) * 1000)
        }
        _ = transcribeStart
    }

    private func showConfirm(intent: ParsedIntent, resolution: Resolution, transcript: String,
                             parseMs: Double, resolveMs: Double) {
        let recipients: [VoicyRecipient]
        switch resolution {
        case .resolved(let contact):
            recipients = [toRecipient(contact, app: intent.app)]
            if let p = contact.preferredE164 {
                // Last 4 digits only. A full phone number in a log file is PII we
                // have no reason to write down.
                print("[voicy] resolve: resolved -> \(contact.displayName) +…\(p.suffix(4))")
            } else {
                print("[voicy] resolve: resolved (no number) -> \(contact.displayName)")
            }
        case .ambiguous(let contacts):
            recipients = contacts.map { toRecipient($0, app: intent.app) }
            print("[voicy] resolve: ambiguous -> \(recipients.count) candidates")
        case .notFound:
            recipients = []
            print("[voicy] resolve: notFound")
        }

        // Disfluency cleanup. Deletion only, and double-checked.
        //
        // `rulesOnly` drops standalone fillers ("um", "uh") and immediately
        // repeated words. It is deterministic, so it can be reasoned about and
        // tested, unlike a model. Even so its output is verified to be a
        // deletion of the original before it is used: if anything at all was
        // added, altered or reordered, the untouched body is kept instead.
        //
        // This is the one place the body legitimately differs from the raw
        // transcript slice, and CLAUDE.md permits exactly this: "Removing filler
        // is allowed; rewording is not." The user still sees the result on the
        // confirm card and can edit it before anything is sent.
        //
        // `LLMCleaner` (FoundationModels) exists and works, but is deliberately
        // NOT wired in here: it is free to add punctuation the user never spoke,
        // which the deletion-only check tolerates by design since it compares
        // bare words. Deterministic beats clever for the text of someone's
        // message.
        let cleanedBody = TranscriptCleaner.rulesOnly(intent.body)
        let body = TranscriptCleaner.isDeletionOnly(original: intent.body, cleaned: cleanedBody)
            ? cleanedBody
            : intent.body
        if body != intent.body {
            print("[voicy] cleanup: removed \(intent.body.count - body.count) char(s) of disfluency")
        }

        // The transcript is shown only when nothing matched, so the user can see
        // exactly what was heard. For resolved/ambiguous the editable message body
        // is what matters.
        let payload = VoicyConfirmPayload(recipients: recipients,
                                          message: body,
                                          transcript: recipients.isEmpty ? transcript : nil)

        // The panel dismisses (clearing instance state) BEFORE firing onSend, so
        // capture everything we need for the send here, at show time.
        let app = intent.app
        let spoken = intent.recipientText
        // "Correct once and it remembers" must cover EVERY path where the user's
        // final choice is authoritative, not just the ambiguous list:
        //   .ambiguous -> they picked one of several candidates
        //   .notFound  -> they picked from the contact picker
        //   .resolved  -> they may have overridden a WRONG confident match
        // The last two were previously not learned, which is where the feature
        // failed in practice: correcting a wrong name taught it nothing.
        // Persisting on every confirmed send is idempotent — re-storing a mapping
        // that was already correct changes nothing — and it makes the promise true.
        let rememberAlias = true
        _ = resolution

        confirmPanel.show(
            payload: payload,
            onSend: { [weak self] recipient, body in
                self?.handleSend(recipient: recipient, body: body,
                                 app: app, spoken: spoken, rememberAlias: rememberAlias)
            },
            onCancel: { print("[voicy] confirm: cancelled") },
            onDismiss: {}
        )
        print("[voicy] confirm: parse=\(String(format: "%.1f", parseMs))ms resolve=\(String(format: "%.1f", resolveMs))ms ready")
    }
// MARK: - Send (progressive permission)

    private func handleSend(recipient: VoicyRecipient, body: String,
                            app: MessagingApp, spoken: String, rememberAlias: Bool) {
        guard let e164 = recipient.phoneE164, !e164.isEmpty else {
            print("[voicy] send: \(recipient.displayName) has no phone number; cannot send")
            return
        }

        // Only WhatsApp is wired. Do not fake a send to another app.
        if app != .whatsapp {
            print("[voicy] send: \(appName(app)) is not wired; not faking a send to \(recipient.displayName)")
            return
        }

        // "Correct once and it remembers": if the user corrected an ambiguous
        // recipient at confirm time, persist the spoken name -> this contact.
        if rememberAlias {
            persistAlias(spoken: spoken, recipient: recipient)
        }

        // Tier 2 ("send without pressing Enter"): auto-send with a synthetic Return
        // ONLY if Accessibility is already granted.
        if WhatsAppAccessibility.isTrusted(prompt: false) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let t0 = Date()
                let outcome = await self.whatsAppSender.send(phone: e164, body: body,
                                                             contactName: recipient.displayName,
                                                             dryRun: false)
                let ms = Date().timeIntervalSince(t0) * 1000
                print("[voicy] send: \(String(format: "%.1f", ms)) ms -> \(outcome)")
            }
        } else {
            // Tier 1 default: open WhatsApp pre-filled; the user presses Enter.
            openPrefilledInWhatsApp(phone: e164, body: body)
        }
    }

    private func openPrefilledInWhatsApp(phone: String, body: String) {
        do {
            let url = try WhatsAppDeepLink.sendURL(phone: phone, text: body)
            guard NSWorkspace.shared.open(url) else {
                print("[voicy] send: NSWorkspace.open returned false")
                return
            }
            print("[voicy] send (Tier-1): WhatsApp opened pre-filled; user presses Enter")
            tellUserToPressEnter()
        } catch {
            print("[voicy] send: could not build deep link: \(error)")
        }
    }

    /// Permission-free, on-demand notice (after WhatsApp is open), not a launch-time
    /// permission dialog — consistent with the progressive-permission model.
    ///
    /// Says WHY it did not send by itself. The old wording just told the user to
    /// press Enter, which left "why didn't auto-send work?" unanswerable without
    /// reading the source. The usual cause is not a missing grant at all: it is
    /// running a differently-signed copy of the app. macOS keys Accessibility to
    /// the code signature, so a stale ad-hoc build with the same bundle id is a
    /// different identity and is not trusted, no matter what the checkbox says.
    private func tellUserToPressEnter() {
        let alert = NSAlert()
        alert.messageText = "Message ready in WhatsApp"
        alert.informativeText = """
            Press Enter in WhatsApp to send it.

            Voicy did not send it for you because it does not have Accessibility \
            permission. If you have already granted it, you are probably running a \
            different build of Voicy than the one you granted: macOS ties this \
            permission to the app's signature, not its name.

            Running from: \(Bundle.main.bundleURL.path)
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Accessibility Settings")
        if alert.runModal() == .alertSecondButtonReturn {
            let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            if let url = URL(string: pane) {
                NSWorkspace.shared.open(url)
            }
        }
    }
// MARK: - Aliases ("correct once and it remembers")

    private func loadAliases() {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let url = support.appendingPathComponent("Voicy/aliases.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: AliasStore.Entry].self, from: data)
        else { return }
        aliasLookup = decoded.mapValues { $0.contactIdentifier }
        print("[voicy] aliases: loaded \(aliasLookup.count) learned name(s)")
    }

    private func persistAlias(spoken: String, recipient: VoicyRecipient) {
        guard let e164 = recipient.phoneE164 else { return }
        aliasLookup[NameNormalizer.normalize(spoken)] = recipient.id
        do {
            try aliasStore.setAlias(spoken: spoken, contactIdentifier: recipient.id, e164: e164)
            print("[voicy] alias: remembered \"\(spoken)\" -> \(recipient.displayName)")
        } catch {
            print("[voicy] alias: failed to persist: \(error)")
        }
    }

    // MARK: - Tier-1 permissions

    private func requestTier1Permissions() async {
        let mic = await requestMicrophone()
        let contacts = await loadContacts()
        print("[voicy] permissions: mic=\(mic) contacts=\(contacts)")
    }

    private func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    private func loadContacts() async -> Bool {
        do {
            try await contactIndex.load()
            print("[voicy] contacts: \(contactIndex.contacts.count) loaded")
            return true
        } catch {
            print("[voicy] contacts: \(error)")
            return false
        }
    }

    // MARK: - Helpers

    /// Every contact name, as transcription hints. This biases the recognizer
    /// toward real names — the accuracy feature.
    private func contactNames() -> [String] {
        contactIndex.contacts.flatMap { c in
            [c.givenName, c.familyName, c.nickname, c.organizationName, c.displayName]
                .filter { !$0.isEmpty }
        }
    }

    private func toRecipient(_ contact: Contact, app: MessagingApp) -> VoicyRecipient {
        VoicyRecipient(
            id: contact.identifier,
            displayName: contact.displayName,
            givenName: contact.givenName,
            familyName: contact.familyName,
            phoneDisplay: contact.preferredE164.map { "+" + $0 } ?? "no phone number",
            phoneE164: contact.preferredE164,
            appName: appName(app),
            appSymbol: appSymbol(app)
        )
    }

    private func appName(_ app: MessagingApp) -> String {
        switch app {
        case .whatsapp: return "WhatsApp"
        case .telegram: return "Telegram"
        case .imessage: return "iMessage"
        }
    }

    private func appSymbol(_ app: MessagingApp) -> String {
        switch app {
        case .whatsapp: return "message.fill"
        case .telegram: return "paperplane.fill"
        case .imessage: return "bubble.left.fill"
        }
    }

    // MARK: - Level meter (real RMS, visually only)

    private func startLevelMeter() {
        stopLevelMeter()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let tail = self.recorder.captured.suffix(4000)
                guard !tail.isEmpty else { return }
                var sum: Float = 0
                for s in tail { sum += s * s }
                let rms = (sum / Float(tail.count)).squareRoot()
                // Normalize so a loud signal approaches the top of the meter.
                self.recordingIndicator.updateLevel(min(1, rms / 0.25))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func stopLevelMeter() {
        levelTimer?.invalidate()
        levelTimer = nil
    }
}