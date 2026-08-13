import AppKit
import Foundation

/// Orchestrates the send path: kill-switch check, then open the WhatsApp deep
/// link so the message is pre-filled in the composer. It stops there.
///
/// It deliberately does NOT press Return for the user. Synthesizing a keystroke
/// into WhatsApp is send-path automation, and WhatsApp bans accounts for it
/// permanently. The last inch is the user's own keypress inside WhatsApp, every
/// time. `WhatsAppAccessibility` has no key-posting primitive at all, so this
/// cannot be re-added by accident here.
///
/// Concurrency note: this is `@MainActor` because it drives the UI-facing flow.
@MainActor
final class WhatsAppSender {
    /// Clear, machine-checkable outcome of a send attempt.
    enum Outcome: Equatable {
        /// Deep link opened: WhatsApp is frontmost with the message sitting
        /// UNSENT in the composer. Nothing has left the account. This is the
        /// only non-refusal outcome the app can produce.
        case prefilled
        /// Dry-run: nothing was opened or posted; this is the log of intent.
        case dryRun
        /// Killed by the blocklist before anything happened.
        case blocked(contact: String)
        /// Something failed before we could open anything.
        case failed(String)
    }

    private var blocklist: Blocklist

    init(blocklist: Blocklist = .load()) {
        self.blocklist = blocklist
    }

    /// Primary entry point.
    ///
    /// - Parameters:
    ///   - phone: E.164 contact number, no leading `+`.
    ///   - body: raw message body, byte-for-byte from the user (never rewritten).
    ///   - contactName: optional display name, checked against the blocklist too.
    ///   - dryRun: when true, logs the exact planned actions and touches nothing.
    /// - Returns: `.prefilled` at best. Never a "sent" state, because this code
    ///   cannot send.
    func send(phone: String, body: String, contactName: String? = nil, dryRun: Bool) async -> Outcome {
        // 0. Kill-switch: refuse before doing anything, including dry-run.
        switch blocklist.state {
        case .corrupt:
            log("KILL-SWITCH: blocklist is corrupt/unreadable; refusing EVERY send (fail closed).")
            return .failed("blocklist unreadable; refuses to send")
        case .loaded:
            break
        }
        if blocklist.neverSend {
            log("KILL-SWITCH: neverSend is ON; refusing EVERY send.")
            return .failed("neverSend kill-switch is on")
        }
        for identifier in [contactName, phone].compactMap({ $0 }) {
            if blocklist.contains(identifier) {
                log("KILL-SWITCH: '\(identifier)' is blocklisted; refusing to send.")
                return .blocked(contact: identifier)
            }
        }

        // 1. Build the URL (pure, testable).
        let url: URL
        do {
            url = try WhatsAppDeepLink.sendURL(phone: phone, text: body)
        } catch {
            log("FAIL: could not build deep link: \(error)")
            return .failed("could not build deep link")
        }

        // 2. Dry run: log intent, open nothing, post nothing.
        // Never log the body content (CLAUDE.md: no message bodies in logs).
        if dryRun {
            log("DRY-RUN target phone=\(phone.filter(\.isNumber)) body=\(body.count) char(s) [content redacted]")
            log("DRY-RUN  1. would open the deep link via NSWorkspace (pre-fills composer)")
            log("DRY-RUN  2. would stop there; the user presses Return inside WhatsApp")
            log("DRY-RUN  blocklist loaded: \(self.blocklist.count) entry(ies)")
            log("DRY-RUN  NOTHING was opened or typed.")
            return .dryRun
        }

        // 3. Open the deep link. Log the target, never the body (CLAUDE.md).
        log("OPEN whatsapp://send?phone=\(phone.filter(\.isNumber)) [body redacted]")
        guard NSWorkspace.shared.open(url) else {
            log("FAIL: NSWorkspace.open returned false")
            return .failed("NSWorkspace.open failed")
        }

        log("PREFILLED: message is in the composer, UNSENT. The user presses Return.")
        return .prefilled
    }

    private func log(_ message: String) {
        print("[voicy] [send] \(message)")
    }
}
