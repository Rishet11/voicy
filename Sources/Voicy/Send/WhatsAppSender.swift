import AppKit
import Foundation

/// Orchestrates the send path: guard check, then open the WhatsApp deep link so
/// the message is pre-filled in the composer. It stops there.
///
/// It deliberately does NOT press Return for the user. Synthesizing a keystroke
/// into WhatsApp is send-path automation, and WhatsApp bans accounts for it
/// permanently. The last inch is the user's own keypress inside WhatsApp, every
/// time. `WhatsAppAccessibility` has no key-posting primitive at all, so this
/// cannot be re-added by accident here.
///
/// Every decision about *whether* to open anything lives in `SendGuard`, which
/// is pure and unit-tested. This type only performs the effect the guard
/// authorized, which is why the safety story is one file long.
///
/// Concurrency note: this is `@MainActor` because it drives the UI-facing flow.
@MainActor
final class WhatsAppSender {
    /// Clear, machine-checkable outcome of a send attempt.
    enum Outcome: Equatable {
        /// Deep link opened and the composer was observed ready: WhatsApp is
        /// frontmost with the message sitting UNSENT in the composer. Nothing
        /// has left the account. This is the only non-refusal outcome the app
        /// can produce.
        case prefilled
        /// Deep link opened, but the composer never became ready within the
        /// timeout. The message may still be sitting there; the user has to
        /// look. `reason` names the specific stage that failed.
        case prefilledNotReady(reason: String)
        /// Dry-run: nothing was opened or posted; this is the log of intent.
        case dryRun
        /// Killed by the blocklist before anything happened. `contact` is
        /// already masked: numbers are reduced to their last 4 digits, because
        /// callers log this value verbatim.
        case blocked(contact: String)
        /// Compatibility outcome for older callers. Current guard decisions do
        /// not reject contacts for their phone number alone.
        case notAllowlisted
        /// Something failed before we could open anything.
        case failed(String)
    }

    private var blocklist: Blocklist

    /// Injected so the composer-readiness wait is testable without a running
    /// WhatsApp. Defaults to the real Accessibility tree.
    private let probe: WhatsAppComposeWaiter.Probe
    private let waitOptions: WhatsAppComposeWaiter.Options
    /// Injected so tests can exercise the open path without launching anything.
    private let openURL: (URL) -> Bool

    init(blocklist: Blocklist = .load(),
         probe: WhatsAppComposeWaiter.Probe = .live,
         waitOptions: WhatsAppComposeWaiter.Options = WhatsAppComposeWaiter.Options(),
         openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.blocklist = blocklist
        self.probe = probe
        self.waitOptions = waitOptions
        self.openURL = openURL
    }

    /// Primary entry point.
    ///
    /// - Parameters:
    ///   - phone: E.164 contact number, no leading `+`.
    ///   - body: raw message body, byte-for-byte from the user (never rewritten).
    ///   - contactName: optional display name, checked against the blocklist too.
    ///   - dryRun: **defaults to true.** Passing `false` is the caller asserting
    ///     that a human explicitly confirmed this exact recipient and body. The
    ///     default is deliberate: a future call site that forgets this argument
    ///     gets a dry run, so a bug can fail to deliver a message but can never
    ///     deliver one to the wrong person.
    /// - Returns: `.prefilled` at best. Never a "sent" state, because this code
    ///   cannot send.
    func send(phone: String, body: String, contactName: String? = nil, dryRun: Bool = true) async -> Outcome {
        let decision = SendGuard.decide(phone: phone,
                                        contactName: contactName,
                                        blocklist: blocklist,
                                        confirmed: !dryRun,
                                        requestedDryRun: dryRun)

        switch decision {
        case .refused(let refusal):
            log("REFUSED: \(refusal.reason)")
            switch refusal {
            // Masked at the source: callers print this whole value (see
            // Pipeline.handleSend), so an unmasked number here would put a full
            // phone number in the log even though every log() call is careful.
            case .blocklisted(let contact): return .blocked(contact: SendGuard.maskIdentifier(contact))
            case .notAllowlisted: return .notAllowlisted
            case .blocklistUnreadable, .neverSend, .noPhoneDigits:
                return .failed(refusal.reason)
            }

        case .dryRun, .forcedDryRun:
            if case .forcedDryRun = decision {
                log("NOT CONFIRMED: downgraded to a dry run. Nothing was opened.")
            }
            // Never log the body content (CLAUDE.md: no message bodies in logs)
            // and never the full number (last 4 only).
            log("DRY-RUN target=\(SendGuard.maskPhone(phone)) body=\(body.count) char(s) [content redacted]")
            log("DRY-RUN  1. would open the deep link via NSWorkspace (pre-fills composer)")
            log("DRY-RUN  2. would stop there; the user presses Return inside WhatsApp")
            log("DRY-RUN  blocklist loaded: \(self.blocklist.count) entry(ies)")
            log("DRY-RUN  NOTHING was opened or typed.")
            return .dryRun

        case .live:
            break
        }

        // Build the URL. The guard already proved there are digits, so this can
        // only fail on encoding, but it is still checked rather than forced.
        let url: URL
        do {
            url = try WhatsAppDeepLink.sendURL(phone: phone, text: body)
        } catch {
            log("FAIL: could not build deep link: \(error)")
            return .failed("could not build deep link")
        }

        log("OPEN whatsapp://send?phone=\(SendGuard.maskPhone(phone)) [body redacted]")
        guard openURL(url) else {
            log("FAIL: NSWorkspace.open returned false")
            return .failed("NSWorkspace.open failed")
        }

        return await confirmComposerReady()
    }

    /// Waits (bounded) for the composer to actually be ready, so the user is
    /// told what went wrong instead of being left with a silent no-op.
    ///
    /// Accessibility is Tier 2 and optional. Without it we cannot observe
    /// anything, so we report the prefill and stop rather than pretending to
    /// have verified something. That keeps the Tier-1-only path fully working.
    private func confirmComposerReady() async -> Outcome {
        guard probe.isTrusted() else {
            log("PREFILLED: message is in the composer, UNSENT. (Composer readiness not verified: Accessibility not granted.)")
            return .prefilled
        }

        switch WhatsAppComposeWaiter.wait(probe: probe, options: waitOptions) {
        case .ready(let attempts, let elapsedMs):
            log(String(format: "PREFILLED: composer ready after %d poll(s), %.0f ms. UNSENT; the user presses Return.",
                       attempts, elapsedMs))
            return .prefilled
        case .notReady(let cause, let attempts, let elapsedMs, let timedOut):
            log(String(format: "NOT READY: %@ (%d poll(s), %.0f ms, %@)",
                       cause.reason, attempts, elapsedMs,
                       timedOut ? "timed out" : "attempt budget exhausted"))
            return .prefilledNotReady(reason: cause.reason)
        }
    }

    private func log(_ message: String) {
        print("[voicy] [send] \(message)")
    }
}
