import AppKit
import AVFoundation
import Carbon
import Contacts
import Foundation
import Speech

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
    private var liveSession: AnyObject?
    private var liveStart: Task<Void, Never>?
    private var pendingSpeechChunks: [[Float]] = []
    private var transcriptionInFlight = false
    private var permissionRequestInFlight = false

    init() {
        recorder.onSamples = { [weak self] samples in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if #available(macOS 26.0, *), let liveSession = self.liveSession as? LiveTranscriptionSession {
                    liveSession.append(samples)
                } else {
                    self.pendingSpeechChunks.append(samples)
                }
            }
        }
    }

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

        // Tier-1 permissions (Microphone + Speech Recognition + Contacts) are requested on launch but
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

        // Pay the one-time FoundationModels load before the first dictation.
        // Cleanup itself has a hard 250 ms budget, so a slow or unavailable
        // model can never hold the user's live path open.
        Task { @MainActor in
            await LLMCleaner().warm()
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
            present(failure: .hotkeyUnavailable)
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
        guard !recorder.isRunning else {
            present(failure: .recordingAlreadyActive)
            return
        }
        guard !transcriptionInFlight else {
            present(failure: .transcriptionInProgress)
            return
        }
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if micStatus == .notDetermined || speechStatus == .notDetermined {
            guard !permissionRequestInFlight else { return }
            permissionRequestInFlight = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.permissionRequestInFlight = false }
                if let failure = await self.requestRecordingPermissions() {
                    self.present(failure: failure)
                } else {
                    self.startRecording()
                }
            }
            return
        }
        if micStatus == .denied || micStatus == .restricted {
            present(failure: .microphonePermissionDenied)
            return
        }
        if speechStatus == .denied || speechStatus == .restricted {
            present(failure: .speechRecognitionPermissionDenied)
            return
        }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            present(failure: .contactsPermissionDenied)
            return
        }
        guard recorder.hasInputDevice else {
            present(failure: .noInputDevice)
            return
        }
        let t0 = Date()
        pendingSpeechChunks = []
        if #available(macOS 26.0, *) {
            let hints = contactNames()
            let session = LiveTranscriptionSession(locale: TranscriberLocale.requestedLocale(), hints: hints) { [weak self] text in
                Task { @MainActor [weak self] in
                    self?.recordingIndicator.updateTranscript(text)
                }
            }
            liveSession = session
            liveStart = Task { [weak self] in
                do { try await session.start() }
                catch { print("[voicy] streaming: start failed") }
                _ = self
            }
        }
        recordingIndicator.show()          // reveal first (respects the 100 ms budget)
        recordingIndicator.updateLevel(0)
        startLevelMeter()
        do {
            try recorder.start()
            let ms = Date().timeIntervalSince(t0) * 1000
            print("[voicy] recording: started in \(String(format: "%.1f", ms)) ms")
        } catch MicrophoneRecorder.RecordError.noInputDevice {
            present(failure: .noInputDevice)
            recordingIndicator.hide()
            stopLevelMeter()
        } catch {
            present(failure: .microphoneStartFailed)
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
            if #available(macOS 26.0, *), let session = liveSession as? LiveTranscriptionSession {
                session.cancel()
            }
            liveSession = nil
            liveStart = nil
            present(failure: .deviceDeliveredZeroSamples)
            return
        }
        var energy: Float = 0
        for sample in pcm { energy += sample * sample }
        let rms = (energy / Float(pcm.count)).squareRoot()
        guard rms >= 0.001 else {
            if #available(macOS 26.0, *), let session = liveSession as? LiveTranscriptionSession {
                session.cancel()
            }
            liveSession = nil
            liveStart = nil
            present(failure: .noSpeechDetected)
            return
        }
        print("[voicy] capture: \(pcm.count) samples (\(String(format: "%.2f", Double(pcm.count) / 16_000)) s)")
        if #available(macOS 26.0, *), let session = liveSession as? LiveTranscriptionSession, let liveStart {
            transcriptionInFlight = true
            self.liveSession = nil
            self.liveStart = nil
            Task { @MainActor [weak self] in
                await liveStart.value
                let chunks = self?.pendingSpeechChunks ?? []
                self?.pendingSpeechChunks = []
                for chunk in chunks { session.append(chunk) }
                do {
                    let final = try await session.finish()
                    self?.transcriptionInFlight = false
                    self?.present(transcript: final.best, transcribeStart: Date())
                } catch {
                    self?.transcriptionInFlight = false
                    self?.present(failure: .transcriptionFailed)
                }
            }
        } else {
            transcriptionInFlight = true
            transcribe(pcm)
        }
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
                self.transcriptionInFlight = false
                self.present(transcript: text, transcribeStart: transcribeStart)
            } catch {
                self.transcriptionInFlight = false
                self.present(failure: .transcriptionFailed)
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
            _ = reason
            present(failure: .noRecipient)
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
            present(failure: .noRecipient)
        }

        // Disfluency cleanup. Deletion only, and double-checked.
        //
        // The LLM pass is warmed at launch but remains off the live path until
        // warmed latency is proven safe. The deterministic rules are bounded
        // and deletion-only.
        //
        // This is the one place the body legitimately differs from the raw
        // transcript slice, and CLAUDE.md permits exactly this: "Removing filler
        // is allowed; rewording is not." The user still sees the result on the
        // confirm card and can edit it before anything is sent.
        let cleaned = TranscriptCleaner.rulesOnly(intent.body)
        let deletionOnlyBody = TranscriptCleaner.isDeletionOnly(original: intent.body, cleaned: cleaned)
            ? cleaned
            : intent.body

        // Then the formatting pass, which IS allowed to rewrite.
        //
        // ORDER: deletion-only cleanup first, formatting second, kept as two
        // separate statements rather than merged into one call.
        //
        //  - The deletion-only floor above is unchanged and still verified.
        //    Nothing after it weakens that guarantee.
        //  - `TextFormatter` wants the disfluencies already gone: a filler
        //    between a number and its unit ("in five uh minutes") would hide the
        //    unit and leave the number spelled out.
        //  - Deleting this one statement restores the previous behavior exactly,
        //    which is what we want from a pass permitted to rewrite.
        //
        // The two do not fight and nothing double-strips. `TextFormatter` runs
        // its own disfluency pass over text `rulesOnly` has already cleaned,
        // which is a no-op: both only ever delete fillers and adjacent repeats,
        // and formatting is asserted idempotent on every row of the corpus in
        // TextQualityTests.swift.
        //
        // Unlike `rulesOnly` this step is NOT deletion-only, and cannot be:
        // spoken punctuation ("period"), spoken emails ("rishet at gmail dot
        // com") and self-corrections are substitutions by nature. Its safety
        // story is different and deliberate: every rule is a closed, enumerated,
        // deterministic rewrite with no model in the loop, and the user reads the
        // result on the confirm card and can edit it before anything is sent.
        let body = TextFormatter.format(deletionOnlyBody)
        if body != intent.body {
            print("[voicy] cleanup: body \(intent.body.count) -> \(body.count) char(s) (disfluency + formatting)")
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
            present(failure: .recipientHasNoPhoneNumber)
            return
        }

        // Only WhatsApp is wired. Do not fake a send to another app.
        if app != .whatsapp {
            print("[voicy] send: \(appName(app)) is not wired; not faking a send to \(recipient.displayName)")
            return
        }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp") != nil else {
            present(failure: .whatsappNotInstalled)
            return
        }

        // ONE outbound path, always: WhatsAppSender checks the kill switch and
        // the blocklist, opens the deep link without activating WhatsApp, and
        // submits in the background (AX press on the send button, with a
        // PID-targeted Return fallback). The sender still requires explicit
        // Voicy confirmation and exact AX verification before one submit, and
        // only claims a send after observing the composer clear.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.whatsAppSender.send(phone: e164, body: body,
                                                        contactName: recipient.displayName,
                                                        dryRun: false)
            print("[voicy] send: -> \(outcome)")
            switch outcome {
            case .prefilled:
                // "Correct once and it remembers": only learn the name once the
                // recipient actually cleared the kill switch. Teaching the app a
                // mapping to a blocked contact would work against the user.
                if rememberAlias {
                    self.persistAlias(spoken: spoken, recipient: recipient)
                }
                self.tellUserToPressEnter()
            case .sentVerified:
                if rememberAlias {
                    self.persistAlias(spoken: spoken, recipient: recipient)
                }
                self.tellUserMessageSent()
            case .sentUnverified:
                // Submitted, but the composer never cleared: delivery cannot be
                // confirmed, so the name is not learned and the user is told to
                // check rather than being told it sent.
                self.tellUserSendUnverified()
            case .prefilledNotReady:
                self.present(failure: .whatsappUnavailable)
            case .blocked, .failed, .dryRun, .notAllowlisted:
                self.present(failure: .whatsappUnavailable)
                break
            }
        }
    }

    private func present(failure: PipelineFailure) {
        print("[voicy] ERROR: \(failure.description)")
        let alert = NSAlert()
        alert.messageText = failure.description
        alert.alertStyle = .warning
        if let pane = settingsPane(for: failure) {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(pane)
            }
            return
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func settingsPane(for failure: PipelineFailure) -> URL? {
        switch failure {
        case .microphonePermissionDenied: return SystemSettingsPane.microphone
        case .speechRecognitionPermissionDenied: return SystemSettingsPane.speechRecognition
        case .noInputDevice, .deviceDeliveredZeroSamples, .microphoneStartFailed:
            return SystemSettingsPane.soundInput
        default: return nil
        }
    }

    /// Permission-free, on-demand notice (after WhatsApp is open), not a
    /// launch-time permission dialog — consistent with the progressive-permission
    /// model.
    ///
    /// Auto-send was not possible because Accessibility was unavailable. The
    /// message remains unsent and the user can finish it manually.
    private func tellUserToPressEnter() {
        let alert = NSAlert()
        alert.messageText = "Message remains unsent"
        alert.informativeText = """
            Press Enter in WhatsApp to send it.

            Auto-send could not be verified because Accessibility permission is \
            unavailable. Nothing has been sent yet.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func tellUserMessageSent() {
        let alert = NSAlert()
        alert.messageText = "Message sent"
        alert.informativeText = "WhatsApp confirmed the message was submitted after Voicy verified the exact composer text."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// The submit ran in the background but the composer never cleared, so
    /// delivery cannot be confirmed. Voicy never claims a send it could not
    /// verify, and it never resubmits, so nothing can be sent twice.
    private func tellUserSendUnverified() {
        let alert = NSAlert()
        alert.messageText = "Message may not have been sent"
        alert.informativeText = """
            Voicy submitted the message in the background, but WhatsApp did not confirm the composer cleared. Check WhatsApp before resending.

            The message was not resubmitted automatically, so nothing can be sent twice.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
        let speech = await requestSpeechRecognition()
        let contacts = await loadContacts()
        print("[voicy] permissions: mic=\(mic) speech=\(speech) contacts=\(contacts)")
    }

    private func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    private func requestSpeechRecognition() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    /// Explicitly resolves both recording permissions before any engine start.
    /// Request both on first run so the user gets the complete setup flow before
    /// trying to dictate, then report the specific permission still missing.
    private func requestRecordingPermissions() async -> PipelineFailure? {
        let mic = await requestMicrophone()
        let speech = await requestSpeechRecognition()
        if !mic { return .microphonePermissionDenied }
        if !speech { return .speechRecognitionPermissionDenied }
        return nil
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
