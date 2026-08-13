import Foundation

/// Waits, with a hard ceiling, for Telegram to be genuinely ready to receive
/// the confirmed message before a Return is posted.
///
/// READ-ONLY. This waiter observes; it never types. Mirror of
/// `WhatsAppComposeWaiter`, with Telegram-specific failure naming, so the
/// safety story is the same file shape for both apps.
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
/// `appNotRunning`, never as `composeFieldNotFocused`.
enum TelegramComposeWaiter {

    /// Why the composer never became ready. One case per real-world cause.
    enum Failure: Equatable {
        /// Telegram is not running at all (deep link never launched it).
        case appNotRunning
        /// Running, but it has no window we can see (still launching, or the
        /// window is closed to the menu bar).
        case windowNotFound
        /// Window is up, but the compose field never took keyboard focus.
        case composeFieldNotFocused
        /// Composer focused, but the send affordance is absent — the chat is
        /// not in a sendable state (no recipient resolved, or an error sheet).
        case sendButtonNotFound
        /// The focused field does not contain the exact confirmed body.
        case composeTextMismatch
        /// Accessibility permission is not granted, so nothing can be observed.
        case notTrusted

        var reason: String {
            switch self {
            case .appNotRunning: return "Telegram is not running"
            case .windowNotFound: return "Telegram has no visible window yet"
            case .composeFieldNotFocused: return "the Telegram compose field never took focus"
            case .sendButtonNotFound: return "the Telegram send button was not found"
            case .composeTextMismatch: return "the Telegram compose text did not match the confirmed message"
            case .notTrusted: return "Accessibility permission is not granted"
            }
        }
    }

    enum Result: Equatable {
        /// Every stage satisfied. The confirmed Return may now be posted.
        case ready(attempts: Int, elapsedMs: Double)
        /// Gave up. `cause` is the first unsatisfied stage on the last attempt,
        /// `timedOut` distinguishes "ran out of clock" from "ran out of tries".
        case notReady(cause: Failure, attempts: Int, elapsedMs: Double, timedOut: Bool)
    }

    /// The observations the waiter needs, injected so the polling logic is unit
    /// testable without a running Telegram. `live` wires the real AX tree.
    struct Probe {
        var isTrusted: () -> Bool
        var appIsRunning: () -> Bool
        var hasWindow: () -> Bool
        var composeFieldFocused: () -> Bool
        var composeText: () -> String?
        var sendButtonExists: () -> Bool

        static var live: Probe {
            Probe(isTrusted: { TelegramAccessibility.isTrusted(prompt: false) },
                  appIsRunning: { TelegramAccessibility.telegramPID() != nil },
                  hasWindow: { TelegramAccessibility.telegramHasWindow() },
                  composeFieldFocused: { TelegramAccessibility.isTelegramFocusedOnTextInput() },
                  composeText: { TelegramAccessibility.focusedTextValue() },
                  sendButtonExists: { TelegramAccessibility.telegramSendButtonExists() })
        }
    }

    /// Timing knobs. Defaults are the shipped values; there is no env var or
    /// flag behind them. Tests inject a fake clock so they run instantly.
    struct Options {
        var timeout: TimeInterval = 5.0
        var pollInterval: TimeInterval = 0.05
        var maxAttempts: Int = 200
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
        if !probe.composeFieldFocused() { return .composeFieldNotFocused }
        if !probe.sendButtonExists() { return .sendButtonNotFound }
        if let expectedText, probe.composeText() != expectedText { return .composeTextMismatch }
        return nil
    }
}
