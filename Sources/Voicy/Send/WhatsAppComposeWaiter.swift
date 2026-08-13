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
        /// Accessibility permission is not granted, so nothing can be observed.
        case notTrusted

        var reason: String {
            switch self {
            case .appNotRunning: return "WhatsApp is not running"
            case .windowNotFound: return "WhatsApp has no visible window yet"
            case .composerNotFound: return "no compose field was found in any WhatsApp window"
            case .sendButtonNotFound: return "the WhatsApp send button was not found"
            case .composeTextMismatch: return "the WhatsApp compose text did not match the confirmed message"
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
        var timeout: TimeInterval = 6.0
        var pollInterval: TimeInterval = 0.05
        var maxAttempts: Int = 120
        /// Monotonic-ish source of "now", in seconds.
        var now: () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
        /// Blocking wait between polls.
        var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
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
            switch firstUnsatisfied(probe, expectedText: expectedText) {
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
    static func firstUnsatisfied(_ probe: Probe, expectedText: String? = nil) -> Failure? {
        if !probe.isTrusted() { return .notTrusted }
        if !probe.appIsRunning() { return .appNotRunning }
        if !probe.hasWindow() { return .windowNotFound }
        guard let text = probe.composeText() else { return .composerNotFound }
        if !probe.sendButtonExists() { return .sendButtonNotFound }
        if let expectedText, text != expectedText {
            guard probe.replaceComposeText(expectedText), probe.composeText() == expectedText else {
                return .composeTextMismatch
            }
        }
        return nil
    }
}
