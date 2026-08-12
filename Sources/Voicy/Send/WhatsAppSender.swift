import AppKit
import Foundation

/// Orchestrates the full send path: kill-switch check, (optionally) open the
/// WhatsApp deep link, wait for the composer to be ready, post Return, then
/// verify the send actually happened.
///
/// Concurrency note: this is `@MainActor` because it drives the UI-facing flow.
/// The polling loops use `await Task.sleep`, which yields the main actor between
/// checks, so the menubar stays responsive while we wait.
@MainActor
final class WhatsAppSender {
    /// Clear, machine-checkable outcome of a send attempt.
    enum Outcome: Equatable {
        /// Composer was confirmed empty after Return (verified real send).
        case sentVerified
        /// Return was posted but we could not confirm the composer cleared.
        /// This is an UNVERIFIED success — reported honestly, never assumed.
        case sentUnverified
        /// Dry-run: nothing was opened or posted; this is the log of intent.
        case dryRun
        /// Killed by the blocklist before anything happened.
        case blocked(contact: String)
        /// Something failed before we could send.
        case failed(String)
    }

    struct Config {
        var readinessTimeout: TimeInterval = 20
        var verifyTimeout: TimeInterval = 4
        var pollInterval: TimeInterval = 0.15
    }

    private var blocklist: Blocklist
    private let config: Config

    init(blocklist: Blocklist = .load(), config: Config = Config()) {
        self.blocklist = blocklist
        self.config = config
    }

    /// Primary entry point.
    ///
    /// - Parameters:
    ///   - phone: E.164 contact number, no leading `+`.
    ///   - body: raw message body, byte-for-byte from the user (never rewritten).
    ///   - contactName: optional display name, checked against the blocklist too.
    ///   - dryRun: when true, logs the exact planned actions and touches nothing.
    func send(phone: String, body: String, contactName: String? = nil, dryRun: Bool) async -> Outcome {
        // 0. Kill-switch: refuse before doing anything, including dry-run.
        guard blocklist.isUsable else {
            log("KILL-SWITCH: blocklist is corrupt/unreadable; refusing EVERY auto-send (fail closed).")
            return .failed("blocklist unreadable; refuses to auto-send")
        }
        for identifier in [contactName, phone].compactMap({ $0 }) {
            if blocklist.contains(identifier) {
                log("KILL-SWITCH: '\(identifier)' is blocklisted; refusing to auto-send.")
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
            log("DRY-RUN  2. would poll AX until WhatsApp is frontmost with a focused text input (timeout \(self.config.readinessTimeout)s)")
            log("DRY-RUN  3. would CGEventPost Return (keycode 36)")
            log("DRY-RUN  4. would verify composer emptied (timeout \(self.config.verifyTimeout)s)")
            log("DRY-RUN  blocklist loaded: \(self.blocklist.count) entry(ies)")
            log("DRY-RUN  NOTHING was opened or typed.")
            return .dryRun
        }

        // 3. Accessibility permission — must be granted to this process.
        guard WhatsAppAccessibility.isTrusted(prompt: true) else {
            log("FAIL: no Accessibility permission. Voicy cannot post the Return key.")
            return .failed("missing Accessibility permission")
        }

        // 4. Open the deep link. Log the target, never the body (CLAUDE.md).
        log("OPEN whatsapp://send?phone=\(phone.filter(\.isNumber)) [body redacted]")
        guard NSWorkspace.shared.open(url) else {
            log("FAIL: NSWorkspace.open returned false")
            return .failed("NSWorkspace.open failed")
        }

        // 5. Wait for readiness (frontmost + focused text input).
        guard await waitForReadiness() else {
            log("FAIL: WhatsApp never became ready within \(self.config.readinessTimeout)s")
            return .failed("readiness timeout: WhatsApp window/composer not ready")
        }
        log("READY: WhatsApp frontmost with focused text input")

        // 6. Post Return.
        log("POST Return (keycode 36)")
        WhatsAppAccessibility.postReturn()

        // 7. Verify the send actually happened.
        if await verifyComposerCleared() {
            log("VERIFY: composer empty after Return -> send confirmed")
            return .sentVerified
        } else {
            log("VERIFY: could not confirm composer cleared -> UNVERIFIED success")
            return .sentUnverified
        }
    }

    // MARK: - Polling

    private func waitForReadiness() async -> Bool {
        let deadline = Date().addingTimeInterval(config.readinessTimeout)
        while Date() < deadline {
            if WhatsAppAccessibility.isWhatsAppFocusedOnTextInput() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(Int(config.pollInterval * 1000)))
        }
        return false
    }

    private func verifyComposerCleared() async -> Bool {
        let deadline = Date().addingTimeInterval(config.verifyTimeout)
        while Date() < deadline {
            if let value = WhatsAppAccessibility.focusedTextValue(), value.isEmpty {
                return true
            }
            try? await Task.sleep(for: .milliseconds(Int(config.pollInterval * 1000)))
        }
        return false
    }

    private func log(_ message: String) {
        print("[voicy] [send] \(message)")
    }
}