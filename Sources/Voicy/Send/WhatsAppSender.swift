import AppKit
import Foundation

/// How the ready composer was submitted, used for logging only.
enum WhatsAppSubmitKind: Equatable {
    case pressedButton
    case postedReturn
}

/// Orchestrates the confirmed WhatsApp send path: open, verify, then submit.
/// No keystroke or button press is possible before the guard accepts
/// confirmation.
///
/// The preferred path never brings WhatsApp to the foreground: the deep link
/// opens with `activates = false`, the composer is verified through WhatsApp's
/// own Accessibility tree (by PID, not by focus), and the message is submitted
/// by pressing the AX send button or by delivering a Return directly to
/// WhatsApp's PID.
///
/// One escape hatch exists, because WhatsApp will not materialize its chat
/// window without being activated (a cold launch or a window closed to the
/// tray leaves the composer unreachable in the background). In those two cases
/// the sender opens the deep link ONCE with activation, waits for the
/// composer, hands focus straight back to the user's app, and only then
/// submits and verifies in the background.
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
        /// Deep link opened, but auto-send is unavailable: WhatsApp has the
        /// message sitting UNSENT in the composer. Nothing has left the
        /// account. This is the only non-refusal outcome the app can produce
        /// without Accessibility.
        case prefilled
        /// The exact confirmed body was verified in the composer, the send was
        /// submitted, and WhatsApp cleared the composer afterwards.
        case sentVerified
        /// The send was submitted, but the composer never cleared within the
        /// verification window, so delivery cannot be confirmed. The message
        /// was submitted exactly once and is never retried.
        case sentUnverified
        /// Deep link opened, but the composer never became ready within the
        /// timeout. The message may still be sitting there; the user has to
        /// look. `reason` names the specific stage that failed.
        case prefilledNotReady(reason: String)
        /// Dry-run: nothing was opened or submitted; this is the log of intent.
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
    /// The default opens the deep link without activating WhatsApp, so the
    /// user's current app keeps focus.
    private let openURL: (URL) -> Bool
    /// The same open but WITH activation — the escape hatch used only when
    /// WhatsApp refuses to show its window in the background.
    private let activateOpenURL: (URL) -> Bool
    /// Injected submission primitive. The default presses WhatsApp's AX send
    /// button, falling back to a Return delivered straight to WhatsApp's PID.
    /// Neither path ever requires WhatsApp to be frontmost.
    private let submitSend: () -> WhatsAppSubmitKind?
    /// Injected post-send verification: true when the composer no longer holds
    /// the expected body. The default reads WhatsApp's AX composer by PID.
    private let composeCleared: (String) -> Bool

    init(blocklist: Blocklist = .load(),
         probe: WhatsAppComposeWaiter.Probe = .live,
         waitOptions: WhatsAppComposeWaiter.Options = WhatsAppComposeWaiter.Options(),
         openURL: @escaping (URL) -> Bool = { url in
             let configuration = NSWorkspace.OpenConfiguration()
             configuration.activates = false
             NSWorkspace.shared.open(url, configuration: configuration)
             return true
         },
         activateOpenURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         submitSend: @escaping () -> WhatsAppSubmitKind? = { WhatsAppAccessibility.submitSend() },
         composeCleared: @escaping (String) -> Bool = { WhatsAppAccessibility.composerCleared(expected: $0) }) {
        self.blocklist = blocklist
        self.probe = probe
        self.waitOptions = waitOptions
        self.openURL = openURL
        self.activateOpenURL = activateOpenURL
        self.submitSend = submitSend
        self.composeCleared = composeCleared
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
    /// - Returns: see `Outcome`. Only `.sentVerified` claims a send, and only
    ///   after the composer was observed cleared; everything else is explicit
    ///   about what did or did not happen.
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
            case .blocklistUnreadable, .neverSend, .noPhoneDigits, .noResolvableIdentifier:
                return .failed(refusal.reason)
            }

        case .dryRun, .forcedDryRun:
            if case .forcedDryRun = decision {
                log("NOT CONFIRMED: downgraded to a dry run. Nothing was opened.")
            }
            // Never log the body content (CLAUDE.md: no message bodies in logs)
            // and never the full number (last 4 only).
            log("DRY-RUN target=\(SendGuard.maskPhone(phone)) body=\(body.count) char(s) [content redacted]")
            log("DRY-RUN  1. would open the deep link via NSWorkspace without activating WhatsApp")
            log("DRY-RUN  2. would verify exact composer text, then submit via the AX send button")
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

        log("OPEN whatsapp://send?phone=\(SendGuard.maskPhone(phone)) [body redacted] (non-activating: WhatsApp stays in the background)")
        guard openURL(url) else {
            log("FAIL: NSWorkspace.open returned false")
            return .failed("NSWorkspace.open failed")
        }

        // The open is non-activating, so focus should never leave the user's
        // app. If the system brought WhatsApp forward anyway (a cold-launch
        // quirk on some macOS versions), hand focus straight back on the way
        // out.
        let previousFrontmost = NSWorkspace.shared.frontmostApplication
        defer { WhatsAppAccessibility.restoreFrontmostIfWhatsApp(previous: previousFrontmost) }

        // Without Accessibility we can still honestly report the deep-link
        // prefill, but we cannot authorize an automated submit. This is the
        // explicit non-auto-send outcome, not a success claim.
        guard probe.isTrusted() else {
            log("ABORT: Accessibility permission is not granted; message remains prefilled and unsent")
            return .prefilled
        }

        var readiness = await confirmComposerReady(expectedText: body)
        var activatedOnce = false

        // Escape hatch: WhatsApp will not show its chat window without being
        // activated (cold launch, or the window was closed to the tray), and
        // without a window there is no composer to fill or submit. Open once
        // with activation, then hand focus back the moment the composer is
        // ready — before anything is submitted.
        if case .notReady(let cause, _, _, _) = readiness,
           cause == .appNotRunning || cause == .windowNotFound {
            log("READY-WAIT: \(cause.reason); opening once with activation so WhatsApp can show the chat")
            guard activateOpenURL(url) else {
                log("FAIL: activating NSWorkspace.open returned false")
                return .failed("activating NSWorkspace.open failed")
            }
            activatedOnce = true
            var coldOptions = waitOptions
            coldOptions.timeout = 35.0
            coldOptions.maxAttempts = 700
            readiness = await WhatsAppComposeWaiter.wait(probe: probe, expectedText: body, options: coldOptions)
        }

        switch readiness {
        case .ready:
            // If the escape hatch fired, give the user their app back before
            // submitting: the AX submit does not need WhatsApp frontmost.
            if activatedOnce {
                WhatsAppAccessibility.restoreFrontmostIfWhatsApp(previous: previousFrontmost)
            }
            guard let kind = submitSend() else {
                log("FAIL: WhatsApp disappeared before the message could be submitted")
                return .failed("WhatsApp quit during send")
            }
            log("SUBMIT \(kind == .pressedButton ? "AX press on the send button" : "Return delivered to WhatsApp's PID") after exact composer verification")
            if await confirmComposerCleared(expected: body) {
                log("VERIFY: composer cleared; message submitted")
                return .sentVerified
            }
            log("VERIFY: composer still holds the message after submit; delivery cannot be confirmed")
            return .sentUnverified
        case .notReady(let cause, let attempts, let elapsedMs, let timedOut):
            log(String(format: "NOT READY: %@ (%d poll(s), %.0f ms, %@)",
                       cause.reason, attempts, elapsedMs,
                       timedOut ? "timed out" : "attempt budget exhausted"))
            return .prefilledNotReady(reason: cause.reason)
        }
    }

    /// Waits (bounded) for the composer to actually be ready, so the user is
    /// told what went wrong instead of being left with a silent no-op.
    ///
    /// Accessibility is Tier 2 and optional. Without it we cannot observe
    /// anything, so we report the prefill and stop rather than pretending to
    /// have verified something. That keeps the Tier-1-only path fully working.
    private func confirmComposerReady(expectedText: String) async -> WhatsAppComposeWaiter.Result {
        return WhatsAppComposeWaiter.wait(probe: probe, expectedText: expectedText, options: waitOptions)
    }

    /// Waits (bounded, ~2.5 s) for the composer to clear after submission, so
    /// `sentVerified` means something the app actually observed rather than a
    /// hope. The message is never resubmitted either way.
    private func confirmComposerCleared(expected: String) async -> Bool {
        let start = waitOptions.now()
        var attempts = 0
        while attempts < 50 {
            attempts += 1
            if composeCleared(expected) { return true }
            if waitOptions.now() - start > 2.5 { break }
            waitOptions.sleep(0.05)
        }
        return false
    }

    private func log(_ message: String) {
        print("[voicy] [send] \(message)")
    }
}
