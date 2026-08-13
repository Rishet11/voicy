import Foundation

/// Unit tests for the hardened send path: the pure `SendGuard` decision table,
/// the bounded composer wait, and the `WhatsAppSender` outcomes that follow
/// from them.
///
/// WHAT THESE PROVE (all deterministic, no WhatsApp required):
///  - every guard rail refuses, in the documented priority order
///  - any confirmed resolved contact may receive
///  - an unconfirmed request is downgraded to a dry run, never executed
///  - every composer-wait failure cause is reachable and correctly named
///  - the wait is bounded by BOTH the clock and the attempt budget
///
/// WHAT THESE CANNOT PROVE (needs a human at the keyboard, see the report):
///  - that the real Accessibility tree reports the shapes the live `Probe`
///    expects (window list, focused text area, a button described "send")
///  - that the deep link lands in the right chat on a real machine
///  - the actual send, which is the user's own Return inside WhatsApp
@MainActor
func runSendGuardTests() async -> (passed: Int, failed: Int) {
    var t = TestRun("send-guard")

    let firstContact = "917982913080"
    let secondContact = "919999999999"
    let openList = Blocklist(state: .loaded([]))

    // MARK: Guard decision table

    t.equal(SendGuard.decide(phone: firstContact, contactName: "Pulkit", blocklist: openList,
                             confirmed: true, requestedDryRun: false),
            .live, "a confirmed contact goes live")

    t.equal(SendGuard.decide(phone: secondContact, contactName: "Stranger", blocklist: openList,
                             confirmed: true, requestedDryRun: false),
            .live, "any confirmed contact may go live")

    t.equal(SendGuard.decide(phone: firstContact, contactName: "Pulkit", blocklist: openList,
                             confirmed: false, requestedDryRun: false),
            .forcedDryRun, "unconfirmed live request is refused as a dry run")

    t.equal(SendGuard.decide(phone: firstContact, contactName: "Pulkit", blocklist: openList,
                             confirmed: true, requestedDryRun: true),
            .dryRun, "an explicit dry run stays a dry run even when confirmed")

    // Formatting is normalized before the deep link is built.
    t.equal(SendGuard.decide(phone: "+91 79829 13080", contactName: nil, blocklist: openList,
                             confirmed: true, requestedDryRun: false),
            .live, "phone formatting is normalized, ignoring +, spaces and punctuation")

    t.equal(SendGuard.decide(phone: "9179829130801", contactName: nil, blocklist: openList,
                             confirmed: true, requestedDryRun: false),
            .live, "a different confirmed contact is also allowed")

    t.equal(SendGuard.decide(phone: "not a number", contactName: nil, blocklist: openList,
                             confirmed: true, requestedDryRun: false),
            .refused(.noPhoneDigits), "a digitless target is refused, not opened")

    // Priority: the kill switch outranks everything, including a dry run and
    // an otherwise-valid recipient.
    t.equal(SendGuard.decide(phone: firstContact, contactName: "Pulkit",
                             blocklist: Blocklist(state: .corrupt),
                             confirmed: false, requestedDryRun: true),
            .refused(.blocklistUnreadable), "corrupt blocklist refuses even a dry run")

    t.equal(SendGuard.decide(phone: firstContact, contactName: "Pulkit",
                             blocklist: Blocklist(state: .loaded([]), neverSend: true),
                             confirmed: true, requestedDryRun: false),
            .refused(.neverSend), "neverSend refuses an confirmed send")

    t.equal(SendGuard.decide(phone: firstContact, contactName: "Pulkit",
                             blocklist: Blocklist(state: .loaded([firstContact])),
                             confirmed: true, requestedDryRun: false),
            .refused(.blocklisted(contact: firstContact)),
            "blocklisted number is refused even when confirmed")

    t.equal(SendGuard.decide(phone: firstContact, contactName: "Pulkit Sharma",
                             blocklist: Blocklist(state: .loaded(["Pulkit Sharma"])),
                             confirmed: true, requestedDryRun: false),
            .refused(.blocklisted(contact: "Pulkit Sharma")),
            "blocklisted display name refuses even when confirmed")

    // Redaction: no full numbers in anything the guard produces.
    t.equal(SendGuard.maskPhone("917982913080"), "*******3080", "phone masked to last 4")
    t.check(!SendGuard.Refusal.notAllowlisted(phone: secondContact).reason.contains(secondContact),
            "refusal text never contains the full number")

    // MARK: Composer wait — one case per failure cause

    func probe(trusted: Bool = true, running: Bool = true, window: Bool = true,
               focused: Bool = true, text: String? = "hello", button: Bool = true) -> WhatsAppComposeWaiter.Probe {
        WhatsAppComposeWaiter.Probe(isTrusted: { trusted }, appIsRunning: { running },
                                    hasWindow: { window }, composeFieldFocused: { focused },
                                    composeText: { text },
                                    sendButtonExists: { button })
    }

    /// A fake clock so the bounded-wait tests take microseconds, not seconds.
    func fastOptions(timeout: TimeInterval = 1.0, maxAttempts: Int = 200) -> WhatsAppComposeWaiter.Options {
        var clock: TimeInterval = 0
        var o = WhatsAppComposeWaiter.Options()
        o.timeout = timeout
        o.pollInterval = 0.05
        o.maxAttempts = maxAttempts
        o.now = { clock }
        o.sleep = { clock += $0 }
        return o
    }

    func causeOf(_ p: WhatsAppComposeWaiter.Probe) -> WhatsAppComposeWaiter.Failure? {
        if case .notReady(let cause, _, _, _) = WhatsAppComposeWaiter.wait(probe: p, options: fastOptions()) {
            return cause
        }
        return nil
    }

    t.equal(causeOf(probe(trusted: false)), .notTrusted, "no Accessibility -> notTrusted")
    t.equal(causeOf(probe(running: false)), .appNotRunning, "WhatsApp not running -> appNotRunning")
    t.equal(causeOf(probe(running: true, focused: false)), .composeFieldNotFocused,
            "WhatsApp running but not frontmost is not unavailable")
    t.equal(causeOf(probe(window: false)), .windowNotFound, "no window -> windowNotFound")
    t.equal(causeOf(probe(focused: false)), .composeFieldNotFocused,
            "composer not focused -> composeFieldNotFocused")
    t.equal(causeOf(probe(button: false)), .sendButtonNotFound,
            "no send button -> sendButtonNotFound")

    // Causes are reported in dependency order: the FIRST thing wrong wins, so
    // a not-running app is never misreported as an unfocused composer.
    t.equal(causeOf(probe(running: false, window: false, focused: false, button: false)),
            .appNotRunning, "the earliest unsatisfied stage is the reported cause")

    // Ready path.
    if case .ready(let attempts, _) = WhatsAppComposeWaiter.wait(probe: probe(), options: fastOptions()) {
        t.equal(attempts, 1, "an already-ready composer needs exactly one poll")
    } else {
        t.check(false, "a fully satisfied probe must report ready")
    }

    // Becomes ready partway through: the loop must keep going, then succeed.
    var polls = 0
    let flaky = WhatsAppComposeWaiter.Probe(isTrusted: { true }, appIsRunning: { true },
                                            hasWindow: { true },
                                            composeFieldFocused: { polls += 1; return polls >= 4 },
                                            composeText: { "hello" },
                                            sendButtonExists: { true })
    if case .ready(let attempts, _) = WhatsAppComposeWaiter.wait(probe: flaky, options: fastOptions()) {
        t.equal(attempts, 4, "the waiter keeps polling until the composer focuses")
    } else {
        t.check(false, "a composer that focuses on the 4th poll must be seen as ready")
    }

    // Bounded by the clock. 1.0s / 0.05s poll = 19 polls before the next sleep
    // would cross the timeout. The point is that it terminates and says so.
    if case .notReady(_, let attempts, _, let timedOut) =
        WhatsAppComposeWaiter.wait(probe: probe(focused: false), options: fastOptions(timeout: 1.0)) {
        t.check(timedOut, "an unsatisfied wait reports timedOut")
        t.check(attempts > 1 && attempts <= 21, "clock-bounded wait polls a sane number of times",
                "attempts=\(attempts)")
    } else {
        t.check(false, "an unsatisfied wait must return notReady")
    }

    // Bounded by attempts, independently of the clock. A clock that never
    // advances still cannot produce an infinite loop.
    var frozen = WhatsAppComposeWaiter.Options()
    frozen.timeout = .greatestFiniteMagnitude
    frozen.pollInterval = 0
    frozen.maxAttempts = 7
    frozen.now = { 0 }
    frozen.sleep = { _ in }
    if case .notReady(let cause, let attempts, _, let timedOut) =
        WhatsAppComposeWaiter.wait(probe: probe(window: false), options: frozen) {
        t.equal(attempts, 7, "the attempt budget bounds the wait when the clock does not")
        t.check(!timedOut, "an attempt-exhausted wait is not reported as a timeout")
        t.equal(cause, .windowNotFound, "the cause survives the attempt-bounded exit")
    } else {
        t.check(false, "a frozen clock must still terminate via the attempt budget")
    }

    // A zero budget still takes one honest look.
    if case .notReady(let cause, let attempts, _, _) =
        WhatsAppComposeWaiter.wait(probe: probe(running: false), options: fastOptions(timeout: 0)) {
        t.equal(attempts, 1, "a zero timeout still polls once")
        t.equal(cause, .appNotRunning, "a zero timeout reports the real cause")
    } else {
        t.check(false, "a zero timeout must return notReady")
    }

    // MARK: Sender outcomes — nothing is opened unless the guard says live

    /// Records whether the deep link was opened, so "refused" can be proven to
    /// mean "nothing happened" rather than "happened and was reported oddly".
    final class OpenSpy: @unchecked Sendable {
        var opened = 0
        func open(_ url: URL) -> Bool { opened += 1; return true }
    }

    func sender(_ blocklist: Blocklist, spy: OpenSpy,
                probe p: WhatsAppComposeWaiter.Probe = probe(),
                returnCount: Counter = Counter()) -> WhatsAppSender {
        WhatsAppSender(blocklist: blocklist, probe: p, waitOptions: fastOptions(),
                       openURL: { spy.open($0) },
                       postReturn: { returnCount.value += 1 })
    }

    final class Counter: @unchecked Sendable { var value = 0 }

    // A confirmed, unblocked contact opens the prefilled composer.
    let strangerSpy = OpenSpy()
    let strangerOutcome = await sender(openList, spy: strangerSpy)
        .send(phone: secondContact, body: "hello", contactName: "Stranger", dryRun: false)
    t.equal(strangerOutcome, .sentVerified, "any confirmed contact is allowed")
    t.equal(strangerSpy.opened, 1, "a confirmed contact opens once")

    // Default argument: a caller that forgets `dryRun` cannot send.
    let forgetfulSpy = OpenSpy()
    let forgetful = await sender(openList, spy: forgetfulSpy)
        .send(phone: firstContact, body: "hello", contactName: "Pulkit")
    t.equal(forgetful, .dryRun, "omitting dryRun defaults to a dry run")
    t.equal(forgetfulSpy.opened, 0, "a defaulted dry run opens nothing")

    let blockedSpy = OpenSpy()
    let blocked = await sender(Blocklist(state: .loaded([firstContact])), spy: blockedSpy)
        .send(phone: firstContact, body: "hello", contactName: "Pulkit", dryRun: false)
    // The outcome is what Pipeline prints verbatim, so the number must already
    // be masked by the time it leaves the sender.
    t.equal(blocked, .blocked(contact: "*******3080"), "blocklisted number is refused")
    t.check(!"\(blocked)".contains(firstContact), "the blocked outcome never carries a full number")
    t.equal(blockedSpy.opened, 0, "a blocklisted recipient opens nothing")

    let corruptSpy = OpenSpy()
    let corrupt = await sender(Blocklist(state: .corrupt), spy: corruptSpy)
        .send(phone: firstContact, body: "hello", contactName: "Pulkit", dryRun: true)
    if case .failed = corrupt {
        t.check(true, "corrupt blocklist fails closed")
    } else {
        t.check(false, "corrupt blocklist must fail", "got \(corrupt)")
    }
    t.equal(corruptSpy.opened, 0, "a corrupt blocklist opens nothing")

    // Live path, with the readiness probe satisfied.
    let liveSpy = OpenSpy()
    let live = await sender(openList, spy: liveSpy)
        .send(phone: firstContact, body: "hello", contactName: "Pulkit", dryRun: false)
    t.equal(live, .sentVerified, "a confirmed send posts Return after verification")
    t.equal(liveSpy.opened, 1, "the live path opens the deep link exactly once")

    let liveReturns = Counter()
    let liveWithReturn = await sender(openList, spy: OpenSpy(), returnCount: liveReturns)
        .send(phone: firstContact, body: "hello", contactName: "Pulkit", dryRun: false)
    t.equal(liveWithReturn, .sentVerified, "verified composer reports sent")
    t.equal(liveReturns.value, 1, "one confirmation posts exactly one Return")

    // Live path where the composer never appears: the outcome names the cause
    // instead of claiming success.
    let stuckSpy = OpenSpy()
    let stuck = await sender(openList, spy: stuckSpy, probe: probe(focused: false))
        .send(phone: firstContact, body: "hello", contactName: "Pulkit", dryRun: false)
    t.equal(stuck, .prefilledNotReady(reason: WhatsAppComposeWaiter.Failure.composeFieldNotFocused.reason),
            "an unready composer is reported with its specific cause")
    t.equal(stuckSpy.opened, 1, "the unready path still opened the link once")

    let mismatchReturns = Counter()
    let mismatch = await sender(openList, spy: OpenSpy(), probe: probe(text: "different"),
                                returnCount: mismatchReturns)
        .send(phone: firstContact, body: "hello", contactName: "Pulkit", dryRun: false)
    t.equal(mismatch, .prefilledNotReady(reason: WhatsAppComposeWaiter.Failure.composeTextMismatch.reason),
            "text mismatch aborts before Return")
    t.equal(mismatchReturns.value, 0, "text mismatch never posts Return")

    // A stale composer is replaced through the injected Accessibility setter,
    // then read back exactly before Return is authorized.
    var composerText = "stale text from an earlier attempt"
    var replacements = 0
    let replacementProbe = WhatsAppComposeWaiter.Probe(
        isTrusted: { true }, appIsRunning: { true }, hasWindow: { true },
        composeFieldFocused: { true }, composeText: { composerText },
        sendButtonExists: { true },
        replaceComposeText: { expected in
            replacements += 1
            composerText = expected
            return true
        })
    let replacementReturns = Counter()
    let replacement = await sender(openList, spy: OpenSpy(), probe: replacementProbe,
                                   returnCount: replacementReturns)
        .send(phone: firstContact, body: "new confirmed body", contactName: "Pulkit", dryRun: false)
    t.equal(replacement, .sentVerified, "stale composer is replaced before send")
    t.equal(composerText, "new confirmed body", "composer contains exactly the new body")
    t.equal(replacements, 1, "stale composer is replaced once")
    t.equal(replacementReturns.value, 1, "exact replacement permits one Return")

    let failedReplacement = WhatsAppComposeWaiter.Probe(
        isTrusted: { true }, appIsRunning: { true }, hasWindow: { true },
        composeFieldFocused: { true }, composeText: { "stale text" },
        sendButtonExists: { true }, replaceComposeText: { _ in false })
    let failedReplacementReturns = Counter()
    let failedReplacementOutcome = await sender(openList, spy: OpenSpy(), probe: failedReplacement,
                                               returnCount: failedReplacementReturns)
        .send(phone: firstContact, body: "new confirmed body", contactName: "Pulkit", dryRun: false)
    t.equal(failedReplacementOutcome,
            .prefilledNotReady(reason: WhatsAppComposeWaiter.Failure.composeTextMismatch.reason),
            "failed exact replacement aborts with a named mismatch")
    t.equal(failedReplacementReturns.value, 0, "failed exact replacement never posts Return")

    // Without Accessibility the send still works and reports honestly rather
    // than blocking on an observation it cannot make (Tier-1-only path).
    let untrustedSpy = OpenSpy()
    let untrusted = await sender(openList, spy: untrustedSpy, probe: probe(trusted: false))
        .send(phone: firstContact, body: "hello", contactName: "Pulkit", dryRun: false)
    t.equal(untrusted, .prefilled,
            "no Accessibility leaves a verified-unsent prefill and aborts auto-send")
    t.equal(untrustedSpy.opened, 1, "the Tier-1 path opens the link")


    // MARK: Telegram — deep link, guard rail, waiter, sender abort paths

    func tgLink(_ identifier: String, _ text: String) -> String? {
        guard let url = try? TelegramDeepLink.sendURL(identifier: identifier, text: text) else {
            return nil
        }
        return url.absoluteString
    }

    // Link construction: username and phone forms, byte-for-byte encoding.
    t.equal(tgLink("pulkit", "hello"),
            "tg://resolve?domain=pulkit&text=hello", "telegram username link")
    t.equal(tgLink("@pulkit", "hello"),
            "tg://resolve?domain=pulkit&text=hello", "leading @ stripped from username")
    t.equal(tgLink("917982913080", "hello"),
            "tg://resolve?phone=917982913080&text=hello", "telegram phone link")
    t.equal(tgLink("+91 79829 13080", "hello"),
            "tg://resolve?phone=917982913080&text=hello", "phone formatting stripped")
    t.equal(tgLink("pulkit", "I am late"),
            "tg://resolve?domain=pulkit&text=I%20am%20late", "spaces encoded")
    t.equal(tgLink("pulkit", "a&b"),
            "tg://resolve?domain=pulkit&text=a%26b", "ampersand encoded")
    t.equal(tgLink("pulkit", "1+1=2"),
            "tg://resolve?domain=pulkit&text=1%2B1%3D2", "plus and equals encoded")
    t.equal(tgLink("pulkit", "50% off?"),
            "tg://resolve?domain=pulkit&text=50%25%20off%3F", "percent and question mark encoded")
    t.equal(tgLink("pulkit", "line1\nline2"),
            "tg://resolve?domain=pulkit&text=line1%0Aline2", "newline encoded")

    if let devanagari = tgLink("pulkit", "नमस्ते") {
        t.check(devanagari.hasPrefix("tg://resolve?domain=pulkit&text=%"),
                "devanagari percent-encoded", devanagari)
        let decoded = URLComponents(string: devanagari)?
            .percentEncodedQuery?
            .components(separatedBy: "text=").last?
            .removingPercentEncoding
        t.equal(decoded, "नमस्ते", "devanagari round-trips")
    } else {
        t.check(false, "devanagari telegram link should build")
    }
    if let emoji = tgLink("pulkit", "on my way 🚗") {
        let decoded = emoji.components(separatedBy: "text=").last?.removingPercentEncoding
        t.equal(decoded, "on my way 🚗", "emoji round-trips")
    } else {
        t.check(false, "emoji telegram link should build")
    }
    t.equal(tgLink("pulkit", ""),
            "tg://resolve?domain=pulkit&text=", "empty body still builds")

    // Unresolvable targets are named refusals, never guesses.
    t.equal(tgLink("", "hello"), nil, "empty identifier throws")
    t.equal(tgLink("   ", "hello"), nil, "whitespace-only identifier throws")
    t.equal(tgLink("123abc", "hello"), nil, "digit-prefixed identifier is not a username")
    t.equal(tgLink("pulkit!", "hello"), nil, "punctuated identifier is not a username")
    t.equal(tgLink("a b", "hello"), nil, "spaced identifier is not a username")
    t.equal(tgLink("ab", "hello"), nil, "too-short username throws")
    t.equal(tgLink(String(repeating: "a", count: 33), "hello"), nil, "too-long username throws")
    t.equal(tgLink("1234567", "hello"), nil, "too-short phone throws")
    t.equal(tgLink("12345678", "hello"),
            "tg://resolve?phone=12345678&text=hello", "8-digit phone builds")

    // Telegram rail on the shared guard: same rails, same priority.
    t.equal(SendGuard.decide(identifier: "pulkit", contactName: "Pulkit", blocklist: openList,
                             confirmed: true, requestedDryRun: false),
            .live, "a confirmed telegram username goes live")
    t.equal(SendGuard.decide(identifier: "917982913080", contactName: "Pulkit", blocklist: openList,
                             confirmed: true, requestedDryRun: false),
            .live, "a confirmed telegram phone goes live")
    t.equal(SendGuard.decide(identifier: "pulkit", contactName: "Pulkit", blocklist: openList,
                             confirmed: false, requestedDryRun: false),
            .forcedDryRun, "unconfirmed telegram request is refused as a dry run")
    t.equal(SendGuard.decide(identifier: "pulkit", contactName: nil,
                             blocklist: Blocklist(state: .loaded(["pulkit"])),
                             confirmed: true, requestedDryRun: false),
            .refused(.blocklisted(contact: "pulkit")), "blocklisted username refused even when confirmed")
    t.equal(SendGuard.decide(identifier: "917982913080", contactName: nil,
                             blocklist: Blocklist(state: .loaded(["917982913080"])),
                             confirmed: true, requestedDryRun: false),
            .refused(.blocklisted(contact: "917982913080")), "blocklisted telegram phone refused")
    t.equal(SendGuard.decide(identifier: "", contactName: "Pulkit", blocklist: openList,
                             confirmed: true, requestedDryRun: false),
            .refused(.noResolvableIdentifier), "empty identifier refused with a named refusal")
    t.equal(SendGuard.decide(identifier: "pulkit", contactName: nil,
                             blocklist: Blocklist(state: .corrupt),
                             confirmed: true, requestedDryRun: false),
            .refused(.blocklistUnreadable), "telegram rail inherits the kill switch")
    t.equal(SendGuard.decide(identifier: "pulkit", contactName: nil,
                             blocklist: Blocklist(state: .loaded([]), neverSend: true),
                             confirmed: true, requestedDryRun: false),
            .refused(.neverSend), "telegram rail inherits neverSend")


    // Telegram compose waiter: one case per failure cause, bounded two ways.
    func tgProbe(trusted: Bool = true, running: Bool = true, window: Bool = true,
                 focused: Bool = true, text: String? = "hello", button: Bool = true) -> TelegramComposeWaiter.Probe {
        TelegramComposeWaiter.Probe(isTrusted: { trusted }, appIsRunning: { running },
                                    hasWindow: { window }, composeFieldFocused: { focused },
                                    composeText: { text },
                                    sendButtonExists: { button })
    }

    func tgFastOptions(timeout: TimeInterval = 1.0, maxAttempts: Int = 200) -> TelegramComposeWaiter.Options {
        var clock: TimeInterval = 0
        var o = TelegramComposeWaiter.Options()
        o.timeout = timeout
        o.pollInterval = 0.05
        o.maxAttempts = maxAttempts
        o.now = { clock }
        o.sleep = { clock += $0 }
        return o
    }

    func tgCauseOf(_ p: TelegramComposeWaiter.Probe) -> TelegramComposeWaiter.Failure? {
        if case .notReady(let cause, _, _, _) =
            TelegramComposeWaiter.wait(probe: p, expectedText: "hello", options: tgFastOptions()) {
            return cause
        }
        return nil
    }

    t.equal(tgCauseOf(tgProbe(trusted: false)), .notTrusted, "telegram: no Accessibility -> notTrusted")
    t.equal(tgCauseOf(tgProbe(running: false)), .appNotRunning, "telegram not running -> appNotRunning")
    t.equal(tgCauseOf(tgProbe(running: false)).map(\.reason), "Telegram is not running",
            "the not-running cause names Telegram")
    t.equal(tgCauseOf(tgProbe(window: false)), .windowNotFound, "telegram: no window -> windowNotFound")
    t.equal(tgCauseOf(tgProbe(focused: false)), .composeFieldNotFocused,
            "telegram: composer not focused -> composeFieldNotFocused")
    t.equal(tgCauseOf(tgProbe(button: false)), .sendButtonNotFound,
            "telegram: no send button -> sendButtonNotFound")
    t.equal(tgCauseOf(tgProbe(text: "different")), .composeTextMismatch,
            "telegram: wrong composer text -> composeTextMismatch")
    t.equal(tgCauseOf(tgProbe(running: false, window: false, focused: false, button: false)),
            .appNotRunning, "telegram: the earliest unsatisfied stage is reported")
    if case .ready(let attempts, _) =
        TelegramComposeWaiter.wait(probe: tgProbe(), expectedText: "hello", options: tgFastOptions()) {
        t.equal(attempts, 1, "telegram: an already-ready composer needs one look")
    } else {
        t.check(false, "telegram: a ready composer must report ready")
    }
    if case .notReady(_, let attempts, _, let timedOut) =
        TelegramComposeWaiter.wait(probe: tgProbe(focused: false), options: tgFastOptions(timeout: 1.0)) {
        t.check(timedOut, "telegram: an unsatisfied wait reports timedOut")
        t.check(attempts > 1 && attempts <= 21, "telegram: clock-bounded wait polls a sane number of times",
                "attempts=\(attempts)")
    } else {
        t.check(false, "telegram: an unsatisfied wait must return notReady")
    }
    var tgFrozen = TelegramComposeWaiter.Options()
    tgFrozen.timeout = .greatestFiniteMagnitude
    tgFrozen.pollInterval = 0
    tgFrozen.maxAttempts = 7
    tgFrozen.now = { 0 }
    tgFrozen.sleep = { _ in }
    if case .notReady(_, let attempts, _, let timedOut) =
        TelegramComposeWaiter.wait(probe: tgProbe(window: false), options: tgFrozen) {
        t.equal(attempts, 7, "telegram: the attempt budget bounds the wait when the clock does not")
        t.check(!timedOut, "telegram: attempt exhaustion is not reported as a timeout")
    } else {
        t.check(false, "telegram: a frozen clock must still terminate via the attempt budget")
    }
    if case .notReady(let cause, let attempts, _, _) =
        TelegramComposeWaiter.wait(probe: tgProbe(running: false), options: tgFastOptions(timeout: 0)) {
        t.equal(attempts, 1, "telegram: a zero timeout still polls once")
        t.equal(cause, .appNotRunning, "telegram: a zero timeout reports the real cause")
    } else {
        t.check(false, "telegram: a zero timeout must return notReady")
    }


    // Telegram sender: every abort path, nothing opened unless the guard says live.
    func tgSender(_ blocklist: Blocklist, spy: OpenSpy,
                  probe p: TelegramComposeWaiter.Probe = tgProbe(),
                  returnCount: Counter = Counter(),
                  installed: Bool = true) -> TelegramSender {
        TelegramSender(blocklist: blocklist, probe: p, waitOptions: tgFastOptions(),
                       openURL: { spy.open($0) },
                       postReturn: { returnCount.value += 1 },
                       isInstalled: { installed })
    }

    let tgLiveSpy = OpenSpy()
    let tgLiveReturns = Counter()
    let tgLive = await tgSender(openList, spy: tgLiveSpy, returnCount: tgLiveReturns)
        .send(identifier: "pulkit", body: "hello", contactName: "Pulkit", dryRun: false)
    t.equal(tgLive, .sentVerified, "a confirmed telegram send posts Return after verification")
    t.equal(tgLiveSpy.opened, 1, "the telegram live path opens exactly once")
    t.equal(tgLiveReturns.value, 1, "one telegram confirmation posts exactly one Return")

    let tgPhoneSpy = OpenSpy()
    let tgPhone = await tgSender(openList, spy: tgPhoneSpy)
        .send(identifier: "917982913080", body: "hello", contactName: "Pulkit", dryRun: false)
    t.equal(tgPhone, .sentVerified, "a telegram phone target is allowed")
    t.equal(tgPhoneSpy.opened, 1, "the telegram phone path opens exactly once")

    let tgForgetfulSpy = OpenSpy()
    let tgForgetful = await tgSender(openList, spy: tgForgetfulSpy)
        .send(identifier: "pulkit", body: "hello", contactName: "Pulkit")
    t.equal(tgForgetful, .dryRun, "omitting dryRun defaults to a dry run for telegram")
    t.equal(tgForgetfulSpy.opened, 0, "a defaulted telegram dry run opens nothing")

    let tgBlockedSpy = OpenSpy()
    let tgBlocked = await tgSender(Blocklist(state: .loaded(["pulkit"])), spy: tgBlockedSpy)
        .send(identifier: "pulkit", body: "hello", contactName: nil, dryRun: false)
    t.equal(tgBlocked, .blocked(contact: "pulkit"), "blocklisted telegram username is refused")
    t.equal(tgBlockedSpy.opened, 0, "a blocklisted telegram recipient opens nothing")

    let tgNoIdSpy = OpenSpy()
    let tgNoId = await tgSender(openList, spy: tgNoIdSpy)
        .send(identifier: "", body: "hello", contactName: "Pulkit", dryRun: false)
    t.equal(tgNoId, .failed("recipient has no Telegram username or phone number"),
            "an identifier-less telegram target is a named refusal")
    t.equal(tgNoIdSpy.opened, 0, "an identifier-less telegram target opens nothing")

    let tgBadUserSpy = OpenSpy()
    let tgBadUser = await tgSender(openList, spy: tgBadUserSpy)
        .send(identifier: "123abc", body: "hello", contactName: "Pulkit", dryRun: false)
    t.equal(tgBadUser, .failed("recipient identifier is not a valid Telegram username"),
            "an invalid telegram username is a named refusal")
    t.equal(tgBadUserSpy.opened, 0, "an invalid telegram username opens nothing")

    let tgMissingSpy = OpenSpy()
    let tgMissing = await tgSender(openList, spy: tgMissingSpy, installed: false)
        .send(identifier: "pulkit", body: "hello", contactName: "Pulkit", dryRun: false)

    let tgNotRunningSpy = OpenSpy()
    let tgNotRunningReturns = Counter()
    let tgNotRunning = await tgSender(openList, spy: tgNotRunningSpy, probe: tgProbe(running: false),
                                      returnCount: tgNotRunningReturns)
        .send(identifier: "pulkit", body: "hello", contactName: "Pulkit", dryRun: false)
    t.equal(tgNotRunning, .prefilledNotReady(reason: "Telegram is not running"),
            "not running is distinct from not installed")
    t.equal(tgNotRunningSpy.opened, 1, "the not-running path opened the link once")
    t.equal(tgNotRunningReturns.value, 0, "not running never posts Return")

    let tgNoWindow = await tgSender(openList, spy: OpenSpy(), probe: tgProbe(window: false))
        .send(identifier: "pulkit", body: "hello", contactName: "Pulkit", dryRun: false)
    t.equal(tgNoWindow, .prefilledNotReady(reason: TelegramComposeWaiter.Failure.windowNotFound.reason),
            "no window aborts with its specific cause")

    let tgUnfocused = await tgSender(openList, spy: OpenSpy(), probe: tgProbe(focused: false))
        .send(identifier: "pulkit", body: "hello", contactName: "Pulkit", dryRun: false)
    t.equal(tgUnfocused, .prefilledNotReady(reason: TelegramComposeWaiter.Failure.composeFieldNotFocused.reason),
            "unfocused composer aborts with its specific cause")

    let tgNoButton = await tgSender(openList, spy: OpenSpy(), probe: tgProbe(button: false))
        .send(identifier: "pulkit", body: "hello", contactName: "Pulkit", dryRun: false)
    t.equal(tgNoButton, .prefilledNotReady(reason: TelegramComposeWaiter.Failure.sendButtonNotFound.reason),
            "missing send button aborts with its specific cause")

    let tgMismatchReturns = Counter()
    let tgMismatch = await tgSender(openList, spy: OpenSpy(), probe: tgProbe(text: "different"),
                                    returnCount: tgMismatchReturns)
        .send(identifier: "pulkit", body: "hello", contactName: "Pulkit", dryRun: false)
    t.equal(tgMismatch, .prefilledNotReady(reason: TelegramComposeWaiter.Failure.composeTextMismatch.reason),
            "text mismatch aborts before Return")
    t.equal(tgMismatchReturns.value, 0, "telegram text mismatch never posts Return")

    let tgUntrusted = await tgSender(openList, spy: OpenSpy(), probe: tgProbe(trusted: false))
        .send(identifier: "pulkit", body: "hello", contactName: "Pulkit", dryRun: false)
    t.equal(tgUntrusted, .prefilled,
            "no Accessibility leaves a telegram prefill and aborts auto-send")

    let tgOpenFailSpy = OpenSpy()
    let tgOpenFail: TelegramSender.Outcome = await TelegramSender(blocklist: openList, probe: tgProbe(),
                                                                  waitOptions: tgFastOptions(),
                                                                  openURL: { tgOpenFailSpy.open($0) && false },
                                                                  postReturn: {},
                                                                  isInstalled: { true })
        .send(identifier: "pulkit", body: "hello", contactName: "Pulkit", dryRun: false)
    t.equal(tgOpenFail, .failed("NSWorkspace.open failed"), "an open failure is named")
    t.equal(tgOpenFailSpy.opened, 1, "the open failure path still attempted one open")

    t.equal(tgMissing, .telegramNotInstalled, "missing Telegram is a distinct named outcome")
    t.equal(tgMissingSpy.opened, 0, "a missing Telegram app opens nothing")

    return t.result
}
