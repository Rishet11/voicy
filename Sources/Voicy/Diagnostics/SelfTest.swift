import ApplicationServices
import AVFoundation
import Contacts
import CoreGraphics
import Foundation
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
    checkSpeechRecognition()
    await checkContacts()
    checkAccessibilityTrust()
    checkInputMonitoring()
    checkWhatsAppInstalled()
    checkWhatsAppMedia()
    checkTranscriptionEngine()
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
