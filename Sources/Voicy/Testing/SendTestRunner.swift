import AppKit
import Foundation

// MARK: - Live send diagnostic
//
// Drives the REAL send path (ContactIndex -> ContactResolver -> SendGuard ->
// WhatsAppSender with `dryRun: false`) from the command line, so an agent or a
// human at the terminal can exercise the full background send on demand.
//
// The confirm card is the one piece this bypasses: whoever runs this flag is
// asserting the human confirmation. It exists because the voice half of the
// pipeline needs a human at the keyboard and cannot be scripted.
//
// Usage (run via LaunchServices so TCC permissions apply):
//   open -n --stdout /tmp/send.log --stderr /tmp/send.err dist/Voicy.app \
//     --args --send-test "<spoken recipient>" "<body>"
//
// Safety: the same SendGuard rails as the UI path (kill switch, blocklist,
// phone digits) all run inside `WhatsAppSender.send`. The runner itself refuses
// to send to anything ambiguous or unknown, exactly like the UI.

/// Sync entry for main.swift, mirroring `runSelfTestIfRequested()`. Returns
/// immediately unless `--send-test` is present; otherwise runs and exits.
@MainActor
func runSendTestIfRequested() {
    let args = CommandLine.arguments
    guard let flag = args.firstIndex(of: "--send-test") else { return }
    guard flag + 2 < args.count, !args[flag + 1].hasPrefix("--"), !args[flag + 2].hasPrefix("--") else {
        print("[voicy] [send-test] usage: --send-test <spoken recipient> <body>")
        exit(2)
    }
    let spoken = args[flag + 1]
    let body = args[flag + 2]

    let done = SendTestCompletionFlag()
    var exitCode: Int32 = 1
    Task { @MainActor in
        exitCode = await SendTestRunner().run(spoken: spoken, body: body)
        done.value = true
    }
    // Pump the main run loop rather than blocking on a semaphore, same as the
    // audio harness: parts of the pipeline are main-actor isolated.
    while !done.value {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    exit(exitCode)
}

@MainActor
private final class SendTestCompletionFlag {
    var value = false
}

@MainActor
private struct SendTestRunner {
    func run(spoken: String, body: String) async -> Int32 {
        let before = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        print("[voicy] [send-test] frontmost before: \(before)")
        print("[voicy] [send-test] recipient spoken: \"\(spoken)\" body: \(body.count) chars [content redacted]")

        // Real contact load (same as Pipeline.requestTier1Permissions).
        let index = ContactIndex()
        do {
            try await index.load()
        } catch {
            print("[voicy] [send-test] FAIL: contacts: \(error)")
            return 1
        }
        print("[voicy] [send-test] contacts loaded: \(index.contacts.count)")

        // Real alias load (same store the UI uses).
        let aliases = AliasStore().lookup
        print("[voicy] [send-test] aliases loaded: \(aliases.count)")

        // Real resolution: an alias wins immediately; ambiguous or unknown is
        // refused here, never guessed.
        let contact: Contact
        switch ContactResolver().resolve(spoken: spoken, contacts: index.contacts, aliases: aliases) {
        case .resolved(let resolved):
            contact = resolved
        case .ambiguous(let candidates):
            print("[voicy] [send-test] FAIL: ambiguous (\(candidates.count) candidates); refusing to guess")
            return 1
        case .notFound:
            print("[voicy] [send-test] FAIL: no contact resolved for \"\(spoken)\"")
            return 1
        }
        guard let e164 = contact.preferredE164 else {
            print("[voicy] [send-test] FAIL: \(contact.displayName) has no phone number")
            return 1
        }
        print("[voicy] [send-test] resolved -> \(contact.displayName) +...\(e164.suffix(4))")
        print("[voicy] [send-test] SENDING LIVE: one WhatsApp message to the resolved contact (\(body.count) chars).")

        let outcome = await WhatsAppSender().send(phone: e164, body: body,
                                                  contactName: contact.displayName, dryRun: false)
        print("[voicy] [send-test] outcome: \(outcome)")

        let after = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        let focusHeld = before == after
        print("[voicy] [send-test] frontmost after: \(after) (focus held: \(focusHeld ? "YES" : "NO"))")

        switch outcome {
        case .sentVerified:
            return 0
        case .sentUnverified, .prefilled, .prefilledNotReady, .blocked, .notAllowlisted, .dryRun, .failed:
            return 1
        }
    }
}
