import Foundation

/// Waits, with a hard ceiling, for WhatsApp to be genuinely ready to receive a
/// message the user will send themselves.
///
/// READ-ONLY. This waiter observes; it never types. It exists so the app can
/// tell the user *why* the composer is not ready instead of spinning forever or
/// failing silently — the two behaviours BUILD-STATE records as the reason the
/// send path was never trusted.
///
/// Everything it observes is read from WhatsApp's own Accessibility tree via
/// the app's PID, so the composer never has to be focused — and WhatsApp never
/// has to be frontmost — for the wait to succeed. That is what keeps the whole
/// send in the background.
///
/// Three hard guarantees:
///  - **Bounded time.** `timeout` is absolute; the loop cannot outlive it.
///  - **Bounded attempts.** `maxAttempts` caps the poll count independently, so
///    a clock that misbehaves still cannot produce an unbounded loop.
///  - **Distinct causes.** Every failure names the specific stage that was not
///    satisfied. There is no generic "not ready".
///
/// The stages are checked in dependency order, so the reported cause is the
/// first thing actually wrong: an app that is not running is reported as
/// `appNotRunning`, never as `composerNotFound`.
enum WhatsAppComposeWaiter {

    /// Why the composer never became ready. One case per real-world cause.
    enum Failure: Equatable {
        /// WhatsApp is not running at all (deep link never launched it).
        case appNotRunning
        /// Running, but it has no window we can see (still launching, or the
        /// window is closed to the menu bar).
        case windowNotFound
        /// A window is up, but no compose field is exposed in it yet (the chat
        /// is still loading — the normal cold-start state).
        case composerNotFound
        /// Composer present, but the send affordance is absent — the chat is
        /// not in a sendable state (no recipient resolved, or an error sheet).
        case sendButtonNotFound
        /// The composer does not contain the exact confirmed body.
        case composeTextMismatch
        /// The composer already holds text that is not the confirmed body, so it
        /// is someone's draft. Voicy refuses rather than overwriting it.
        case composerHasDraft
        /// The composer is exposed and empty: WhatsApp has not applied the deep
        /// link's prefill yet. Transient, and worth waiting out rather than
        /// writing over.
        case composerNotPrefilled
        /// Accessibility permission is not granted, so nothing can be observed.
        case notTrusted

        var reason: String {
            switch self {
            case .appNotRunning: return "WhatsApp is not running"
            case .windowNotFound: return "WhatsApp has no visible window yet"
            case .composerNotFound: return "no compose field was found in any WhatsApp window"
            case .sendButtonNotFound: return "the WhatsApp send button was not found"
            case .composeTextMismatch: return "the WhatsApp compose text did not match the confirmed message"
            case .composerHasDraft: return "the WhatsApp chat already has an unsent draft in the composer, and Voicy will not overwrite it"
            case .composerNotPrefilled: return "WhatsApp has not filled the composer with the message yet"
            case .notTrusted: return "Accessibility permission is not granted"
            }
        }
    }

    enum Result: Equatable {
        /// Every stage satisfied. The user can press Return.
        case ready(attempts: Int, elapsedMs: Double)
        /// Gave up. `cause` is the first unsatisfied stage on the last attempt,
        /// `timedOut` distinguishes "ran out of clock" from "ran out of tries".
        case notReady(cause: Failure, attempts: Int, elapsedMs: Double, timedOut: Bool)
    }

    /// The observations the waiter needs, injected so the polling logic is unit
    /// testable without a running WhatsApp. `live` wires the real AX tree.
    /// All probes are window-based, never frontmost-based.
    struct Probe {
        var isTrusted: () -> Bool
        var appIsRunning: () -> Bool
        var hasWindow: () -> Bool
        /// The composer's current text, or nil when no compose field is exposed
        /// in any WhatsApp window yet.
        var composeText: () -> String?
        var sendButtonExists: () -> Bool
        var replaceComposeText: (String) -> Bool

        init(isTrusted: @escaping () -> Bool,
             appIsRunning: @escaping () -> Bool,
             hasWindow: @escaping () -> Bool,
             composeText: @escaping () -> String?,
             sendButtonExists: @escaping () -> Bool,
             replaceComposeText: @escaping (String) -> Bool = { _ in false }) {
            self.isTrusted = isTrusted
            self.appIsRunning = appIsRunning
            self.hasWindow = hasWindow
            self.composeText = composeText
            self.sendButtonExists = sendButtonExists
            self.replaceComposeText = replaceComposeText
        }

        static var live: Probe {
            Probe(isTrusted: { WhatsAppAccessibility.isTrusted(prompt: false) },
                  appIsRunning: { WhatsAppAccessibility.whatsAppPID() != nil },
                  hasWindow: { WhatsAppAccessibility.whatsAppHasWindow() },
                  composeText: { WhatsAppAccessibility.composerTextValue() },
                  sendButtonExists: { WhatsAppAccessibility.whatsAppSendButtonExists() },
                  replaceComposeText: { WhatsAppAccessibility.replaceComposerText(with: $0) })
        }
    }

    /// Timing knobs. Defaults are the shipped values; there is no env var or
    /// flag behind them. Tests inject a fake clock so they run instantly.
    /// The first wait is short: a warm WhatsApp is ready within a couple of
    /// seconds, and when it is not, the sender's escape hatch (one activating
    /// open, then a longer second wait) takes over.
    struct Options {
        // 10 s, not 6 s. The two graces below mean readiness cannot be reached
        // before 4 s when the send button is absent, and a 6 s ceiling left almost
        // no margin after that: the wait was giving up two seconds after it first
        // became willing to succeed. `maxAttempts` is kept consistent with
        // timeout / pollInterval so neither bound silently shadows the other.
        var timeout: TimeInterval = 10.0
        var pollInterval: TimeInterval = 0.05
        var maxAttempts: Int = 220
        /// How long an empty composer is left alone before Voicy writes into it,
        /// so WhatsApp's own deep-link prefill gets first chance. Only the prefill
        /// leaves the chat in a state where a send button exists.
        var prefillGrace: TimeInterval = 3.0
        /// How long a missing send button keeps the wait going before Voicy
        /// proceeds without it and submits through the Return fallback. The button
        /// is observably flaky; see the note at its check.
        var sendButtonGrace: TimeInterval = 4.0
        /// Monotonic-ish source of "now", in seconds.
        var now: () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
        /// Blocking wait between polls. Pumps the main run loop instead of a
        /// plain `Thread.sleep`: a hard sleep freezes NSWorkspace's
        /// notification delivery, so a WhatsApp launched DURING the wait is
        /// never seen by `runningApplications` and the wait times out even
        /// though the composer is ready. Tests inject a fake clock instead.
        ///
        /// It is driven to a deadline in a loop, and that is load bearing. A bare
        /// `RunLoop.main.run(until:)` returns as soon as its nested invocation is
        /// unwound, which is exactly what happens here: the send runs inside a
        /// Task on the main actor, which is itself already inside a
        /// `RunLoop.main.run` call. Measured on a real cold send, the bare
        /// version delivered 700 polls in 375 ms when 700 polls at a 50 ms
        /// interval should have taken 35 s. The whole cold-start budget was
        /// therefore fiction: the attempt cap expired in a third of a second and
        /// the sender reported "WhatsApp has no visible window yet" while
        /// WhatsApp was still opening.
        ///
        /// When no input source is ready there is nothing to pump, so it naps
        /// briefly rather than spinning a core.
        var sleep: (TimeInterval) -> Void = { interval in
            let deadline = Date().addingTimeInterval(interval)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { return }
                if !RunLoop.main.run(mode: .default, before: deadline) {
                    Thread.sleep(forTimeInterval: min(remaining, 0.01))
                }
            }
        }
    }

    /// Polls until every stage is satisfied, the clock runs out, or the attempt
    /// budget runs out. Returns the outcome; never throws, never blocks past
    /// `timeout` by more than one poll interval.
    static func wait(probe: Probe = .live, expectedText: String? = nil,
                     options: Options = Options()) -> Result {
        let start = options.now()
        // A zero/negative budget still gets exactly one look, so a caller that
        // passes 0 gets a real answer instead of a vacuous timeout.
        let attemptCap = max(1, options.maxAttempts)
        var attempts = 0
        var lastCause: Failure = .appNotRunning

        while true {
            attempts += 1
            // Writing into an empty composer is held back until WhatsApp has had
            // `prefillGrace` to do it properly itself.
            let elapsedSoFar = options.now() - start
            let mayWrite = elapsedSoFar >= options.prefillGrace
            let requireSendButton = elapsedSoFar < options.sendButtonGrace
            switch firstUnsatisfied(probe, expectedText: expectedText, mayWrite: mayWrite,
                                    requireSendButton: requireSendButton) {
            case nil:
                return .ready(attempts: attempts, elapsedMs: (options.now() - start) * 1000)
            case .some(let cause):
                lastCause = cause
            }

            let elapsed = options.now() - start
            let outOfTime = elapsed + options.pollInterval > options.timeout
            let outOfTries = attempts >= attemptCap
            if outOfTime || outOfTries {
                return .notReady(cause: lastCause,
                                 attempts: attempts,
                                 elapsedMs: elapsed * 1000,
                                 timedOut: outOfTime)
            }
            options.sleep(options.pollInterval)
        }
    }

    /// The first stage that is not satisfied, in dependency order, or nil when
    /// all of them are.
    /// - Parameter mayWrite: whether Voicy is allowed to write the body into an
    ///   empty composer on this poll. False early in the wait, so WhatsApp's own
    ///   prefill gets first chance. See the note at the write site.
    /// - Parameter requireSendButton: whether a missing send affordance still
    ///   counts as not ready on this poll. False once the grace has passed, because
    ///   the button is flaky and a Return fallback exists.
    static func firstUnsatisfied(_ probe: Probe, expectedText: String? = nil,
                                 mayWrite: Bool = true,
                                 requireSendButton: Bool = true) -> Failure? {
        if !probe.isTrusted() { return .notTrusted }
        if !probe.appIsRunning() { return .appNotRunning }
        if !probe.hasWindow() { return .windowNotFound }
        guard let text = probe.composeText() else { return .composerNotFound }
        // The composer's contents are reconciled BEFORE the send affordance is
        // required, and that order matters. WhatsApp only shows a send button once
        // the composer has something in it. Checking for the button first made the
        // two conditions circular: no text meant no button, no button meant an
        // abort, and the abort happened before the step that would have put the
        // text there. A cold launch, whose composer starts empty, could therefore
        // never get past this check, and it reported "the WhatsApp send button was
        // not found" while the real problem was that nothing had been typed yet.
        if let expectedText, text != expectedText {
            // The composer holds something other than the confirmed body. There
            // are two very different reasons for that and they must not share a
            // code path:
            //
            //  * EMPTY. The deep link's prefill did not land, which is the normal
            //    cold-launch state. Nothing of the user's is in there, so writing
            //    the confirmed body is safe.
            //
            //  * NOT EMPTY. Somebody's text is in the composer. Voicy has no way
            //    to tell a half typed draft from its own stale prefill, and the
            //    two demand opposite handling. It used to overwrite either one:
            //    `replaceComposeText` selects the whole existing range and writes
            //    over it, so a draft the user was in the middle of typing was
            //    destroyed with no copy kept anywhere. If instead the prefill had
            //    landed on top of the draft, the composer held draft plus body and
            //    overwriting it silently changed which words were sent.
            //
            // Refusing is the only option that keeps all three promises at once:
            // the draft survives byte for byte, nothing is sent, and the user is
            // told exactly why. Restoring the draft after sending was considered
            // and rejected: it would leave text in the composer, which is the same
            // signal the post-send check reads as "not sent", so a restored draft
            // would turn every successful send into "delivery cannot be
            // confirmed".
            guard text.isEmpty else { return .composerHasDraft }
            // An empty composer is given time to be filled by WhatsApp ITSELF
            // before Voicy writes into it, and that patience is load bearing.
            //
            // Measured: after an AX write, WhatsApp's chat bar still offers
            // ChatBar_VoiceMessageButton and no send button, because setting
            // `AXValue` changes the value the tree reports without running the
            // text-changed handling that WhatsApp uses to decide it has a message
            // to send. The deep link's own prefill does run it, and that is the
            // path where the AX send button appears and a press actually delivers.
            //
            // So writing immediately raced WhatsApp's prefill and won, leaving a
            // composer that looked correct through Accessibility and was not in a
            // sendable state at all. Waiting first lets the working path work; the
            // write stays as a genuine last resort for when the prefill never
            // lands.
            guard mayWrite else { return .composerNotPrefilled }
            guard probe.replaceComposeText(expectedText), probe.composeText() == expectedText else {
                return .composeTextMismatch
            }
        }
        // Checked last, once the composer holds the confirmed body and WhatsApp has
        // had a reason to reveal its send affordance.
        //
        // Preferred, not required. Measured across repeated live sends into the
        // same chat, with WhatsApp's own prefill sitting in the composer, the AX
        // send button is present on some attempts and absent on others: one run
        // pressed it successfully, the next reported it missing after 6 s with the
        // identical 13 character prefill in place. Treating it as mandatory turned
        // that flakiness into a refusal to send at all.
        //
        // Dropping it after a grace period is safe against every hard rule here.
        // `submitSend()` falls back to a Return delivered straight to WhatsApp's
        // PID, and readiness has already established the app, a real window, and a
        // composer holding byte for byte the confirmed body, which is what proves
        // the right message is in the right chat. If the chat turns out not to be
        // sendable, the composer simply does not clear and the outcome is
        // `.sentUnverified`. That risks an unsent message, never a wrong one.
        if requireSendButton, !probe.sendButtonExists() { return .sendButtonNotFound }
        return nil
    }
}
