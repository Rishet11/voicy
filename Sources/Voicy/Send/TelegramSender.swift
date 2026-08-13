import AppKit
import Foundation

/// Orchestrates the confirmed Telegram send path: open, verify, then post one
/// Return. No keystroke is possible before the guard accepts confirmation.
///
/// Mirror of `WhatsAppSender` with Telegram targets. Every decision about
/// *whether* to open anything lives in `SendGuard`, which is pure and
/// unit-tested; this type only performs the effect the guard authorized.
///
/// Telegram-specific named failures, all aborting before any Return:
///  - `.telegramNotInstalled`: neither Telegram client is installed
///  - `.prefilledNotReady(reason: "Telegram is not running")`: installed but
///    not running (reported by the compose waiter, not guessed here)
///  - `.failed(...)`: no resolvable identifier, invalid username, or the
///    deep link could not be built/opened
@MainActor
final class TelegramSender {
    /// Clear, machine-checkable outcome of a send attempt.
    enum Outcome: Equatable {
        /// Deep link opened and the composer was observed ready: Telegram is
        /// frontmost with the message sitting UNSENT in the composer. Nothing
        /// has left the account.
        case prefilled
        /// The exact confirmed body was verified in the focused composer and
        /// one Return was posted.
        case sentVerified
        /// Deep link opened, but the composer never became ready within the
        /// timeout. The message may still be sitting there; the user has to
        /// look. `reason` names the specific stage that failed.
        case prefilledNotReady(reason: String)
        /// Dry-run: nothing was opened or posted; this is the log of intent.
        case dryRun
        /// Killed by the blocklist before anything happened. `contact` is
        /// already masked: numbers are reduced to their last 4 digits.
        case blocked(contact: String)
        /// Compatibility outcome for older callers.
        case notAllowlisted
        /// Telegram (neither org.telegram.desktop nor ru.keepcoder.Telegram)
        /// is installed. Distinct from "installed but not running".
        case telegramNotInstalled
        /// Something failed before we could open anything or verify anything.
        case failed(String)
    }

    private var blocklist: Blocklist

    /// Injected so the composer-readiness wait is testable without a running
    /// Telegram. Defaults to the real Accessibility tree.
    private let probe: TelegramComposeWaiter.Probe
    private let waitOptions: TelegramComposeWaiter.Options
    /// Injected so tests can exercise the open path without launching anything.
    private let openURL: (URL) -> Bool
    private let postReturn: () -> Void
    /// Injected so "not installed" is testable without uninstalling Telegram.
    private let isInstalled: () -> Bool

    init(blocklist: Blocklist = .load(),
         probe: TelegramComposeWaiter.Probe = .live,
         waitOptions: TelegramComposeWaiter.Options = TelegramComposeWaiter.Options(),
         openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         postReturn: @escaping () -> Void = { TelegramAccessibility.postReturn() },
         isInstalled: @escaping () -> Bool = { TelegramAccessibility.isInstalled() }) {
        self.blocklist = blocklist
        self.probe = probe
        self.waitOptions = waitOptions
        self.openURL = openURL
        self.postReturn = postReturn
        self.isInstalled = isInstalled
    }


    /// Primary entry point.
    ///
    /// - Parameters:
    ///   - identifier: Telegram target — a username or an E.164 phone number.
    ///     Classified by `TelegramDeepLink`; never guessed.
    ///   - body: raw message body, byte-for-byte from the user (never rewritten).
    ///   - contactName: optional display name, checked against the blocklist too.
    ///   - dryRun: **defaults to true.** Passing `false` is the caller asserting
    ///     that a human explicitly confirmed this exact recipient and body.
    func send(identifier: String, body: String, contactName: String? = nil,
              dryRun: Bool = true) async -> Outcome {
        let decision = SendGuard.decide(identifier: identifier,
                                        contactName: contactName,
                                        blocklist: blocklist,
                                        confirmed: !dryRun,
                                        requestedDryRun: dryRun)

        switch decision {
        case .refused(let refusal):
            log("REFUSED: \(refusal.reason)")
            switch refusal {
            case .blocklisted(let contact): return .blocked(contact: SendGuard.maskIdentifier(contact))
            case .notAllowlisted: return .notAllowlisted
            case .blocklistUnreadable, .neverSend, .noPhoneDigits, .noResolvableIdentifier:
                return .failed(refusal.reason)
            }

        case .dryRun, .forcedDryRun:
            if case .forcedDryRun = decision {
                log("NOT CONFIRMED: downgraded to a dry run. Nothing was opened.")
            }
            // Never log the body content (CLAUDE.md: no message bodies in logs)
            // and never the full number (last 4 only).
            log("DRY-RUN target=\(SendGuard.maskIdentifier(identifier)) body=\(body.count) char(s) [content redacted]")
            log("DRY-RUN  1. would open the tg:// deep link via NSWorkspace (pre-fills composer)")
            log("DRY-RUN  2. would verify exact composer text, then post one Return")
            log("DRY-RUN  blocklist loaded: \(self.blocklist.count) entry(ies)")
            log("DRY-RUN  NOTHING was opened or typed.")
            return .dryRun

        case .live:
            break
        }

        // Build the URL. Classification happens here, so an identifier that is
        // neither a username nor a phone is a named failure, not a guess.
        let url: URL
        do {
            url = try TelegramDeepLink.sendURL(identifier: identifier, text: body)
        } catch let error as TelegramDeepLink.BuildError {
            log("FAIL: \(error.reason)")
            return .failed(error.reason)
        } catch {
            log("FAIL: could not build Telegram deep link: \(error)")
            return .failed("could not build Telegram deep link")
        }

        // Distinct named check: installed at all, before we try to launch.
        guard isInstalled() else {
            log("ABORT: Telegram is not installed; nothing was opened")
            return .telegramNotInstalled
        }

        log("OPEN tg://resolve?target=\(SendGuard.maskIdentifier(identifier)) [body redacted]")
        guard openURL(url) else {
            log("FAIL: NSWorkspace.open returned false")
            return .failed("NSWorkspace.open failed")
        }

        // Without Accessibility we can still honestly report the deep-link
        // prefill, but we cannot authorize an automated Return. This is the
        // explicit non-auto-send outcome, not a success claim.
        guard probe.isTrusted() else {
            log("ABORT: Accessibility permission is not granted; message remains prefilled and unsent")
            return .prefilled
        }

        switch await confirmComposerReady(expectedText: body) {
        case .ready:
            log("POST Return after exact composer verification")
            postReturn()
            log("SEND: Return posted once after explicit Voicy confirmation")
            return .sentVerified
        case .notReady(let cause, let attempts, let elapsedMs, let timedOut):
            log(String(format: "NOT READY: %@ (%d poll(s), %.0f ms, %@)",
                       cause.reason, attempts, elapsedMs,
                       timedOut ? "timed out" : "attempt budget exhausted"))
            return .prefilledNotReady(reason: cause.reason)
        }
    }

    /// Waits (bounded) for the composer to actually be ready, so the user is
    /// told what went wrong instead of being left with a silent no-op.
    private func confirmComposerReady(expectedText: String) async -> TelegramComposeWaiter.Result {
        return TelegramComposeWaiter.wait(probe: probe, expectedText: expectedText, options: waitOptions)
    }

    private func log(_ message: String) {
        print("[voicy] [send] \(message)")
    }
}
