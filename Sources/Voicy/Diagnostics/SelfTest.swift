import ApplicationServices
import AppKit
import AVFoundation
import Contacts
import CoreAudio
import CoreGraphics
import Foundation
import Security
import Speech

// MARK: - Self-test

/// QA self-test. Checks each capability the app depends on and prints a clear
/// pass/fail line for it. Run the binary with `--selftest` to invoke it, or
/// call `runSelfTest()` directly from code.
///
/// Wiring: main.swift (owned by W1) should add the single line
///   `runSelfTestIfRequested()`
/// right after `import AppKit`. It returns immediately when `--selftest` is not
/// present and runs the whole suite then exits when it is. See the report.

/// Sync entry intended for main.swift's one-line hook. When `--selftest` is
/// present it runs the async suite, prints the results, and exits(0). Otherwise
/// it returns immediately so the app can launch normally.
///
/// Note: the suite runs on a detached task (none of the checks need the main
/// actor) so the main thread can block on the semaphore without deadlocking.
func runSelfTestIfRequested() {
    guard CommandLine.arguments.contains("--selftest") else { return }
    let sema = DispatchSemaphore(value: 0)
    Task.detached {
        await runSelfTest()
        sema.signal()
    }
    sema.wait()
    exit(0)
}

/// Runs the full self-test suite and prints one pass/fail line per capability.
func runSelfTest() async {
    print("=== Voicy self-test (\(macOSVersion())) ===")
    print()

    checkMicrophone()
    checkAudioHardware()
    checkSpeechRecognition()
    await checkContacts()
    checkAccessibilityTrust()
    checkInputMonitoring()
    checkWhatsAppInstalled()
    checkWhatsAppRunning()
    checkWhatsAppMedia()
    checkTranscriptionEngine()
    checkBundleIdentity()
    checkAliasStore()
    checkBlocklist()
    _ = runPipelineFailureTests()
    print()
    print("=== end self-test ===")
}

private func macOSVersion() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
}

private func resultLine(_ name: String, pass: Bool, detail: String) {
    print("\(pass ? "PASS" : "FAIL")  \(name): \(detail)")
}

/// Informational line for Tier-2 (optional) permissions — granted or not is a
/// user choice, not a pass/fail. Distinct prefix so a green self-test no longer
/// lies that an ungranted optional permission is a failure.
private func resultTier2(_ name: String, granted: Bool, detail: String) {
    print("\(granted ? "GRANTED" : "OPTIONAL")  \(name): \(detail)")
}

/// Warning line: the machine works but a specific behavior is degraded or
/// unverified. The detail must say what to do about it.
private func warnLine(_ name: String, detail: String) {
    print("WARN  \(name): \(detail)")
}

/// Honest "cannot determine" line: better than a wrong PASS. Always carries the
/// reason so the user can see what blocked the check.
private func unknownLine(_ name: String, detail: String) {
    print("UNKNOWN  \(name): \(detail)")
}
// MARK: Permissions

private func checkMicrophone() {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        resultLine("Microphone", pass: true, detail: "authorized")
    case .notDetermined:
        resultLine("Microphone", pass: false, detail: "not determined (prompt appears on first use)")
    case .denied:
        resultLine("Microphone", pass: false, detail: "denied in System Settings > Privacy & Security")
    case .restricted:
        resultLine("Microphone", pass: false, detail: "restricted (MDM / parental controls)")
    @unknown default:
        resultLine("Microphone", pass: false, detail: "unknown authorization state")
    }
}

/// Hardware-level check, independent of the TCC permission line above: a user
/// can grant the permission and still have no working input device.
private func checkAudioHardware() {
    // Device presence. Returns nil when the Mac has no audio input at all.
    // https://developer.apple.com/documentation/avfoundation/avcapturedevice/default(for:mediatype:)
    guard AVCaptureDevice.default(for: .audio) != nil else {
        resultLine("Audio hardware", pass: false,
                   detail: "no audio input device at all — plug in or enable a microphone (System Settings > Sound > Input), then restart Voicy")
        return
    }
    // Default-input sanity via CoreAudio (read-only property queries, no TCC
    // prompt). Deliberately NOT AVAudioEngine.inputNode.inputFormat(forBus:):
    // that API SEGFAULTS here (exit 139, macOS 26.5.1, bare binary, microphone
    // already authorized), observed with the probe and with this selftest.
    // https://developer.apple.com/documentation/coreaudio/1571952-audioobjectgetpropertydata
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
          deviceID != AudioDeviceID(kAudioObjectUnknown) else {
        resultLine("Audio hardware", pass: false,
                   detail: "an input device exists but the default input is unreachable — select it in System Settings > Sound > Input, then restart Voicy")
        return
    }
    var rateAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var rate = Float64(0)
    size = UInt32(MemoryLayout<Float64>.size)
    let rateStatus = AudioObjectGetPropertyData(deviceID, &rateAddr, 0, nil, &size, &rate)
    var streamAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    var streamSize = UInt32(0)
    var streamsStatus = AudioObjectGetPropertyDataSize(deviceID, &streamAddr, 0, nil, &streamSize)
    var channels = UInt32(0)
    if streamsStatus == noErr && streamSize >= UInt32(MemoryLayout<AudioStreamID>.size) {
        var streamIDs = [AudioStreamID](repeating: 0, count: Int(streamSize) / MemoryLayout<AudioStreamID>.size)
        streamsStatus = AudioObjectGetPropertyData(deviceID, &streamAddr, 0, nil, &streamSize, &streamIDs)
        if streamsStatus == noErr, let firstStream = streamIDs.first {
            var fmtAddr = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var asbd = AudioStreamBasicDescription()
            var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            if AudioObjectGetPropertyData(firstStream, &fmtAddr, 0, nil, &fmtSize, &asbd) == noErr {
                channels = asbd.mChannelsPerFrame
            }
        }
    }
    if rateStatus != noErr || rate <= 0 || channels == 0 {
        resultLine("Audio hardware", pass: false,
                   detail: "the default input reports no usable format (rate \(rate), \(channels) ch) — select a working input in System Settings > Sound > Input, then restart Voicy")
        return
    }
    resultLine("Audio hardware", pass: true,
               detail: "default input present: \(channels) ch / \(Int(rate)) Hz")
}

private func checkSpeechRecognition() {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized:
        resultLine("Speech recognition", pass: true, detail: "authorized")
    case .notDetermined:
        resultLine("Speech recognition", pass: false, detail: "not determined (prompt appears on first use)")
    case .denied:
        resultLine("Speech recognition", pass: false, detail: "denied in System Settings > Privacy & Security")
    case .restricted:
        resultLine("Speech recognition", pass: false, detail: "restricted (MDM / parental controls)")
    @unknown default:
        resultLine("Speech recognition", pass: false, detail: "unknown authorization state")
    }
}

private func checkContacts() async {
    let status = CNContactStore.authorizationStatus(for: .contacts)
    switch status {
    case .authorized:
        let count = countContacts()
        resultLine("Contacts", pass: true, detail: "authorized, \(count) contacts loaded")
    case .notDetermined:
        resultLine("Contacts", pass: false, detail: "not determined (prompt on first use)")
    case .denied:
        resultLine("Contacts", pass: false, detail: "denied in System Settings > Privacy & Security")
    case .restricted:
        resultLine("Contacts", pass: false, detail: "restricted (MDM / parental controls)")
    @unknown default:
        resultLine("Contacts", pass: false, detail: "unknown authorization state")
    }

    // Quality of the contact set itself (permission already reported above).
    // Counts only — names and numbers are never printed.
    guard status == .authorized else {
        unknownLine("Contacts quality", detail: "cannot enumerate contacts without permission — quality unknown")
        return
    }
    guard let stats = sampleContactQualityStats() else {
        unknownLine("Contacts quality", detail: "contacts enumeration failed — quality unknown")
        return
    }
    if stats.total == 0 {
        warnLine("Contacts quality", detail: "0 contacts — nothing to resolve or send to. Add contacts in the Contacts app.")
    } else if stats.noPhone == 0 && stats.duplicateNames == 0 {
        resultLine("Contacts quality", pass: true,
                   detail: "\(stats.total) contacts, all have at least one phone number, no duplicate display names")
    } else {
        warnLine("Contacts quality", detail: "\(stats.total) contacts; \(stats.noPhone) have NO phone number (they resolve but cannot be sent to); \(stats.duplicateNames) duplicate display names (every use of those names forces a manual choice). Clean these up in the Contacts app.")
    }
}

private func countContacts() -> Int {
    let store = CNContactStore()
    let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor]
    let request = CNContactFetchRequest(keysToFetch: keys)
    var n = 0
    do {
        try store.enumerateContacts(with: request) { _, _ in n += 1 }
    } catch {
        return -1
    }
    return n
}

// Tier-2 (optional) permissions. Under the progressive-permission model these
// are upgrades the user opts into via Settings, never required at launch. An
// ungranted Tier-2 permission is the CORRECT default — Voicy is fully
// functional with Tier 1 alone — so these report informatively, never as FAIL.

private func checkAccessibilityTrust() {
    let trusted = AXIsProcessTrustedWithOptions(
        ["AXTrustedCheckOptionPrompt": false] as CFDictionary
    )
    resultTier2("Accessibility (Tier-2, optional)", granted: trusted, detail: trusted
        ? "granted — \"Send without pressing Enter\" enabled"
        : "not granted — optional. Enables synthetic-Return send; off by default. Enable in System Settings > Privacy & Security > Accessibility")
}

private func checkInputMonitoring() {
    let allowed = CGPreflightListenEventAccess()
    resultTier2("Input Monitoring (Tier-2, optional)", granted: allowed, detail: allowed
        ? "granted — \"Hold a key to talk\" (Right-Option push-to-talk) enabled"
        : "not granted — optional. Enables push-to-talk on a bare modifier; Hotkey is Ctrl+Space without it. Enable in System Settings > Privacy & Security > Input Monitoring")
}
// MARK: WhatsApp

private var whatsAppAppPath: String? {
    let candidates = [
        "/Applications/WhatsApp.app",
        "\(NSHomeDirectory())/Applications/WhatsApp.app",
    ]
    for path in candidates where FileManager.default.fileExists(atPath: path) {
        return path
    }
    return nil
}

private func checkWhatsAppInstalled() {
    if let path = whatsAppAppPath {
        resultLine("WhatsApp installed", pass: true, detail: "found at \(path)")
    } else {
        resultLine("WhatsApp installed", pass: false, detail: "not found in /Applications")
    }
}

/// Running vs quit matters for deep-link pre-fill: the pre-fill path is verified
/// while WhatsApp is running; the cold-start path (WhatsApp quit) is UNVERIFIED,
/// so the machine state must be stated plainly.
private func checkWhatsAppRunning() {
    guard whatsAppAppPath != nil else {
        unknownLine("WhatsApp running", detail: "WhatsApp is not installed — nothing to check")
        return
    }
    // Returns the running instances matching the bundle id (empty when quit).
    // https://developer.apple.com/documentation/appkit/nsrunningapplication/runningapplications(withbundleidentifier:)
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: "net.whatsapp.WhatsApp")
    if running.isEmpty {
        warnLine("WhatsApp running", detail: "no — WhatsApp is quit. Deep-link pre-fill on cold start is UNVERIFIED: if the message does not arrive pre-filled, open WhatsApp first and say it again.")
    } else {
        resultLine("WhatsApp running", pass: true, detail: "yes — deep-link pre-fill is the verified path")
    }
}

private var whatsAppMediaDir: String {
    let base = "\(NSHomeDirectory())/Library/Group Containers"
    return "\(base)/group.net.whatsapp.WhatsApp.shared/Message/Media"
}

private func checkWhatsAppMedia() {
    let dir = whatsAppMediaDir
    guard FileManager.default.fileExists(atPath: dir) else {
        resultLine("WhatsApp media dir", pass: false, detail: "missing at \(dir)")
        return
    }
    let (summary, timedOut) = sampleWhatsAppMedia(in: dir, timeBudget: 3.0)
    // A time-boxed partial sample is expected and healthy: the tree holds
    // hundreds of chats and we deliberately never walk all of it.
    if timedOut {
        resultLine("WhatsApp media dir", pass: true,
                   detail: "exists — sampler hit its time budget (expected on large libraries)")
    } else {
        resultLine("WhatsApp media dir", pass: true, detail: "\(summary)")
    }
}

/// Lightweight, time-boxed look at the WhatsApp media tree. Counts top-level
/// chat directories (shallow, fast) and samples a bounded number of `.opus`
/// files inside a few of them with a shallow depth limit. Deliberately does NOT
/// walk the whole tree — it can contain hundreds of chat folders and a full
/// recursive walk is far too slow to run in a self-test (or at launch). Runs on
/// a background queue with a hard deadline so the self-test can never hang on it.
private func sampleWhatsAppMedia(in dir: String, timeBudget: TimeInterval) -> (summary: String, timedOut: Bool) {
    let box = MediaSampleBox()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .utility).async {
        defer { group.leave() }
        box.set(sampleWhatsAppMediaSync(in: dir, deadline: Date().addingTimeInterval(timeBudget)))
    }
    // The inner work stops at `timeBudget`; give the outer wait a grace margin so
    // the two do not race. Without this the wait expires at the same instant the
    // sampler finishes and a successful sample is misreported as a timeout.
    let timedOut = group.wait(timeout: .now() + timeBudget + 2.0) == .timedOut
    return (box.summary ?? "no data", timedOut)
}

/// Runs off the calling thread; stops the moment the deadline passes.
private func sampleWhatsAppMediaSync(in dir: String, deadline: Date) -> String {
    let fm = FileManager.default
    // 1) Top-level chat directories only — this is one fast shallow listing.
    let topLevel = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir),
                                                includingPropertiesForKeys: [.isDirectoryKey],
                                                options: .skipsHiddenFiles)) ?? []
    let chats = topLevel.filter { url in
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
    let chatCount = chats.count
    if Date() > deadline { return "\(chatCount) chats detected (sampling timed out)" }

    // 2) Sample a bounded number of chats; within each, walk a SHALLOW tree
    // counting .opus files, stopping at the budget.
    let sampleLimit = 24
    let sampleDepthLimit = 4
    var sampledChats = 0
    var sampledOpus = 0
    for chat in chats.prefix(sampleLimit) {
        if Date() > deadline { break }
        sampledChats += 1
        sampledOpus += countShallowOpus(in: chat, depthLimit: sampleDepthLimit, deadline: deadline)
    }

    if Date() > deadline {
        return "\(chatCount) chats detected, \(sampledChats) sampled"
    }
    return "\(chatCount) chats, sampled \(sampledChats) chats → \(sampledOpus) voice notes counted"
}

/// Counts `.opus` files under `root` without descending deeper than
/// `depthLimit` levels, using `.skipsHiddenFiles`. FSEvents-nested voice notes
/// live at depth ≤ 3 under a chat dir, so `depthLimit: 4` is safely shallow.
private func countShallowOpus(in root: URL, depthLimit: Int, deadline: Date) -> Int {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return 0 }
    var count = 0
    while let url = enumerator.nextObject() as? URL {
        if Date() > deadline { break }
        if enumerator.level >= depthLimit {
            enumerator.skipDescendants()
            continue
        }
        if url.pathExtension.lowercased() == "opus" {
            count += 1
        }
    }
    return count
}

/// A tiny lock-protected holder for the media-sample summary string. Used only
/// by the self-test so a background thread can publish a String to the caller
/// without racing.
private final class MediaSampleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _summary: String?
    func set(_ newValue: String) {
        lock.lock(); _summary = newValue; lock.unlock()
    }
    var summary: String? {
        lock.lock(); defer { lock.unlock() }
        return _summary
    }
}

// MARK: Transcription engine

private func checkTranscriptionEngine() {
    if #available(macOS 26.0, *) {
        // This build targets macOS 26, so the primary engine is the new
        // SpeechAnalyzer + SpeechTranscriber path (what TranscriberFactory returns).
        resultLine("Transcription engine", pass: true, detail: "SpeechAnalyzer (macOS 26) — primary engine")
    } else {
        resultLine("Transcription engine", pass: true, detail: "SFSpeechRecognizer fallback")
    }
    let fallbackAvailable = SFSpeechRecognizer(locale: Locale(identifier: "en_US"))?.isAvailable ?? false
    resultLine("SFSpeechRecognizer fallback", pass: fallbackAvailable, detail: fallbackAvailable
        ? "available as fallback"
        : "unavailable on this machine")
}

// MARK: Contacts quality

/// Counts only. No name, phone number, or identifier ever leaves this struct.
private struct ContactQualityStats {
    let total: Int
    let noPhone: Int
    let duplicateNames: Int
}

/// One enumeration pass computing the three quality counts. Duplicate detection
/// mirrors `Contact.displayName` exactly (given+family | given | organization),
/// because that is the string the resolver actually matches against. The
/// "Unknown" fallback is excluded: it is a placeholder, not a name anyone says.
private func sampleContactQualityStats() -> ContactQualityStats? {
    let store = CNContactStore()
    let keys: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        // https://developer.apple.com/documentation/contacts/cncontactphonenumberskey
        CNContactPhoneNumbersKey as CNKeyDescriptor,
    ]
    // https://developer.apple.com/documentation/contacts/cncontactfetchrequest
    let request = CNContactFetchRequest(keysToFetch: keys)
    var total = 0
    var noPhone = 0
    var nameCounts: [String: Int] = [:]
    do {
        // https://developer.apple.com/documentation/contacts/cncontactstore/enumeratecontacts(with:usingblock:)
        try store.enumerateContacts(with: request) { contact, _ in
            total += 1
            if contact.phoneNumbers.isEmpty { noPhone += 1 }
            let display: String
            if !contact.givenName.isEmpty && !contact.familyName.isEmpty {
                display = "\(contact.givenName) \(contact.familyName)"
            } else if !contact.givenName.isEmpty {
                display = contact.givenName
            } else if !contact.organizationName.isEmpty {
                display = contact.organizationName
            } else {
                display = "Unknown"
            }
            if display != "Unknown" {
                nameCounts[display, default: 0] += 1
            }
        }
    } catch {
        return nil
    }
    let duplicateNames = nameCounts.values.filter { $0 > 1 }.count
    return ContactQualityStats(total: total, noPhone: noPhone, duplicateNames: duplicateNames)
}

// MARK: Bundle identity

/// Every TCC grant (microphone, speech, contacts, accessibility, input
/// monitoring) is keyed to the requesting binary's bundle identity and its code
/// signature. Run the bare executable instead of the bundled app and macOS sees
/// a different requester: prompts reappear, or worse, previously granted
/// permissions silently do not apply. That failure looks exactly like "Voicy
/// broke", so it is worth one explicit line.
private func checkBundleIdentity() {
    let bundle = Bundle.main
    guard let identifier = bundle.bundleIdentifier, !identifier.isEmpty else {
        resultLine("Bundle identity", pass: false,
                   detail: "running as a bare executable with no bundle identifier (\(bundle.bundleURL.lastPathComponent)) — TCC grants cannot attach to it, so permissions will not stick. Run the bundled Voicy.app (see build.sh).")
        return
    }
    guard bundle.bundleURL.pathExtension == "app" else {
        resultLine("Bundle identity", pass: false,
                   detail: "bundle identifier \(identifier) is set but the bundle is not a .app (\(bundle.bundleURL.path)) — run the bundled Voicy.app so TCC grants attach to a stable identity")
        return
    }

    // Code signing identity. Ad-hoc signing is fine for local builds, but an
    // UNSIGNED binary gets a new TCC identity on every rebuild, which is the
    // usual cause of "it asked for the microphone again".
    // https://developer.apple.com/documentation/security/seccodecopyself(_:_:)
    var code: SecCode?
    let selfStatus = SecCodeCopySelf(SecCSFlags(), &code)
    guard selfStatus == errSecSuccess, let code else {
        unknownLine("Bundle identity",
                    detail: "\(identifier) at \(bundle.bundleURL.path); could not read this process's code object (OSStatus \(selfStatus)) — signing state unknown")
        return
    }
    // The Swift binding wants a SecStaticCode; a running SecCode is accepted by
    // the underlying API, and this is the documented way to hand it over.
    // https://developer.apple.com/documentation/security/seccodecopysigninginformation(_:_:_:)
    var infoRef: CFDictionary?
    let staticCode = unsafeBitCast(code, to: SecStaticCode.self)
    let infoStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)

    // errSecCSUnsigned is not an error in the "something went wrong" sense: it
    // is the answer, and it is the answer that costs the user their grants.
    if infoStatus == errSecCSUnsigned {
        warnLine("Bundle identity",
                 detail: "\(identifier) at \(bundle.bundleURL.path) is UNSIGNED — macOS gives it a new TCC identity on every rebuild, so permission prompts reappear after each build. Sign it, ad-hoc is enough (codesign --force --deep -s - Voicy.app), to keep grants.")
        return
    }
    guard infoStatus == errSecSuccess, let info = infoRef as? [String: Any] else {
        unknownLine("Bundle identity",
                    detail: "\(identifier) at \(bundle.bundleURL.path); signing information unreadable (OSStatus \(infoStatus)) — signing state unknown")
        return
    }
    guard let signingID = info[kSecCodeInfoIdentifier as String] as? String else {
        warnLine("Bundle identity",
                 detail: "\(identifier) at \(bundle.bundleURL.path) reports no signing identifier — treat its TCC grants as unstable across rebuilds")
        return
    }
    resultLine("Bundle identity", pass: true,
               detail: "\(identifier), signed as \(signingID), at \(bundle.bundleURL.path)")
}

// MARK: Learned aliases

/// Support-directory path shared by the alias store and the blocklist.
private var voicySupportDirectory: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("Voicy", isDirectory: true)
}

/// The "correct once and it remembers" store. Reported here because `AliasStore`
/// swallows a decode failure and starts empty (AliasStore.swift `load()`), so a
/// corrupt file looks to the user exactly like "Voicy forgot everything I taught
/// it" with no other signal anywhere.
///
/// Counts only. No spoken phrase, contact name, or number is ever printed.
private func checkAliasStore() {
    guard let directory = voicySupportDirectory else {
        unknownLine("Learned aliases", detail: "cannot locate the Application Support directory")
        return
    }
    let url = directory.appendingPathComponent("aliases.json")

    guard FileManager.default.fileExists(atPath: url.path) else {
        // Not an error: a fresh install has taught Voicy nothing yet. What
        // matters is whether the first correction will be able to save.
        if FileManager.default.isWritableFile(atPath: directory.path)
            || !FileManager.default.fileExists(atPath: directory.path) {
            resultLine("Learned aliases", pass: true,
                       detail: "no aliases learned yet (\(url.path) does not exist); the directory is writable, so corrections will save")
        } else {
            resultLine("Learned aliases", pass: false,
                       detail: "\(directory.path) is not writable — name corrections cannot be saved and Voicy will re-ask forever")
        }
        return
    }

    guard let data = try? Data(contentsOf: url) else {
        resultLine("Learned aliases", pass: false,
                   detail: "\(url.path) exists but cannot be read — every learned name correction is lost and Voicy will silently start from empty")
        return
    }
    guard let decoded = try? JSONDecoder().decode([String: AliasStore.Entry].self, from: data) else {
        resultLine("Learned aliases", pass: false,
                   detail: "\(url.path) is present but not decodable as the alias format — AliasStore starts EMPTY without saying so, so every taught name is silently forgotten. Move the file aside to start clean.")
        return
    }
    guard FileManager.default.isWritableFile(atPath: url.path) else {
        warnLine("Learned aliases",
                 detail: "\(decoded.count) learned name(s) load fine, but \(url.path) is not writable — new corrections will not save")
        return
    }
    resultLine("Learned aliases", pass: true,
               detail: "\(decoded.count) learned name(s), readable and writable at \(url.path)")
}

// MARK: Blocklist

/// The kill-switch. `Blocklist` fails CLOSED: a corrupt file refuses every
/// auto-send. That is the right behavior and the worst possible surprise, so the
/// self-test states it outright rather than letting the user discover it when a
/// message will not go.
private func checkBlocklist() {
    let path = voicySupportDirectory?.appendingPathComponent("blocklist.json").path
        ?? "<Application Support unavailable>"
    let blocklist = Blocklist.load()

    guard blocklist.isUsable else {
        resultLine("Blocklist", pass: false,
                   detail: "\(path) is present but unparseable, so the kill-switch has failed CLOSED: EVERY auto-send is refused until it is fixed. It must be a JSON array of strings, e.g. [\"919812345670\"]. Delete the file to disable blocking entirely.")
        return
    }
    if blocklist.count == 0 {
        resultLine("Blocklist", pass: true,
                   detail: "empty (\(path)) — nobody is blocked, and sending is not gated")
    } else {
        resultLine("Blocklist", pass: true,
                   detail: "\(blocklist.count) blocked entrie(s) loaded from \(path) — auto-send to those is refused")
    }
}
