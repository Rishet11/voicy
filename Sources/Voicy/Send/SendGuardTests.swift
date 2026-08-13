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
               focused: Bool = true, button: Bool = true) -> WhatsAppComposeWaiter.Probe {
        WhatsAppComposeWaiter.Probe(isTrusted: { trusted }, appIsRunning: { running },
                                    hasWindow: { window }, composeFieldFocused: { focused },
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
                probe p: WhatsAppComposeWaiter.Probe = probe()) -> WhatsAppSender {
        WhatsAppSender(blocklist: blocklist, probe: p, waitOptions: fastOptions(),
                       openURL: { spy.open($0) })
    }

    // A confirmed, unblocked contact opens the prefilled composer.
    let strangerSpy = OpenSpy()
    let strangerOutcome = await sender(openList, spy: strangerSpy)
        .send(phone: secondContact, body: "hello", contactName: "Stranger", dryRun: false)
    t.equal(strangerOutcome, .prefilled, "any confirmed contact is allowed")
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
    t.equal(live, .prefilled, "a confirmed send prefills the composer")
    t.equal(liveSpy.opened, 1, "the live path opens the deep link exactly once")

    // Live path where the composer never appears: the outcome names the cause
    // instead of claiming success.
    let stuckSpy = OpenSpy()
    let stuck = await sender(openList, spy: stuckSpy, probe: probe(focused: false))
        .send(phone: firstContact, body: "hello", contactName: "Pulkit", dryRun: false)
    t.equal(stuck, .prefilledNotReady(reason: WhatsAppComposeWaiter.Failure.composeFieldNotFocused.reason),
            "an unready composer is reported with its specific cause")
    t.equal(stuckSpy.opened, 1, "the unready path still opened the link once")

    // Without Accessibility the send still works and reports honestly rather
    // than blocking on an observation it cannot make (Tier-1-only path).
    let untrustedSpy = OpenSpy()
    let untrusted = await sender(openList, spy: untrustedSpy, probe: probe(trusted: false))
        .send(phone: firstContact, body: "hello", contactName: "Pulkit", dryRun: false)
    t.equal(untrusted, .prefilled, "no Accessibility still prefills; readiness is just unverified")
    t.equal(untrustedSpy.opened, 1, "the Tier-1 path opens the link")

    return t.result
}
