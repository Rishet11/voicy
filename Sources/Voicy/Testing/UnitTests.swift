import Foundation

// MARK: - In-process unit tests
//
// Deliberately plain functions rather than XCTest: the app is a single
// executable SPM target and adding a test target would mean splitting it into a
// library. These run inside the shipped binary behind `--unit-tests`, which
// also means they exercise exactly the code that ships.

/// Tiny assertion recorder shared by the suites below.
struct TestRun {
    private(set) var passed = 0
    private(set) var failed = 0
    let name: String

    init(_ name: String) { self.name = name }

    mutating func check(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
        } else {
            failed += 1
            let d = detail()
            print("  FAIL [\(name)] \(label)\(d.isEmpty ? "" : " — \(d)")")
        }
    }

    mutating func equal<T: Equatable>(_ got: T, _ want: T, _ label: String) {
        check(got == want, label, "got \(got), want \(want)")
    }

    var result: (passed: Int, failed: Int) { (passed, failed) }
}

// MARK: - Contacts

func runContactTests() -> (passed: Int, failed: Int) {
    var t = TestRun("contacts")

    // --- PhoneNormalizer: Indian numbers are the primary case.
    t.equal(PhoneNormalizer.normalize("98765 43210"), "919876543210", "10-digit national -> +91")
    t.equal(PhoneNormalizer.normalize("+91 98765 43210"), "919876543210", "explicit +91")
    t.equal(PhoneNormalizer.normalize("098765 43210"), "919876543210", "trunk-prefix zero dropped")
    t.equal(PhoneNormalizer.normalize("+91 09876543210"), "919876543210", "+91 then trunk zero")
    t.equal(PhoneNormalizer.normalize("+1 (415) 555-0123"), "14155550123", "US number kept as-is")
    t.equal(PhoneNormalizer.normalize("917982913080"), "917982913080", "already E.164")
    t.equal(PhoneNormalizer.normalize("123"), nil, "too short is nil")
    t.equal(PhoneNormalizer.normalize(""), nil, "empty is nil")
    t.equal(PhoneNormalizer.normalize("no digits here"), nil, "letters only is nil")

    // --- NameNormalizer: diacritics and case must not matter.
    t.equal(NameNormalizer.normalize("Shréya"), "shreya", "diacritics folded")
    t.equal(NameNormalizer.normalize("  RAHUL   Sharma "), "rahul sharma", "case + whitespace")
    t.equal(NameNormalizer.normalize("O'Brien"), "o brien", "apostrophe splits tokens")

    // --- Contact.preferredE164 prefers a mobile-ish label.
    let multi = Contact(identifier: "x", givenName: "Test", familyName: "User",
                        nickname: "", organizationName: "",
                        phones: [ContactPhone(label: "home", e164: "911111111111"),
                                 ContactPhone(label: "mobile", e164: "912222222222")])
    t.equal(multi.preferredE164, "912222222222", "mobile beats home")
    let onlyWork = Contact(identifier: "y", givenName: "Test", familyName: "User",
                           nickname: "", organizationName: "",
                           phones: [ContactPhone(label: "work", e164: "913333333333")])
    t.equal(onlyWork.preferredE164, "913333333333", "falls back to first number")
    let noPhone = Contact(identifier: "z", givenName: "Test", familyName: "User",
                          nickname: "", organizationName: "", phones: [])
    t.equal(noPhone.preferredE164, nil, "no phones -> nil")

    // --- displayName
    t.equal(Contact(identifier: "a", givenName: "", familyName: "",
                    nickname: "", organizationName: "Acme Ltd", phones: []).displayName,
            "Acme Ltd", "org name used when no person name")
    t.equal(Contact(identifier: "b", givenName: "", familyName: "",
                    nickname: "", organizationName: "", phones: []).displayName,
            "Unknown", "empty contact -> Unknown")

    // --- Resolver against the fixture set. THE safety-critical behaviour.
    let resolver = ContactResolver()
    let contacts = FixtureContacts.all

    switch resolver.resolve(spoken: "Pulkit", contacts: contacts, aliases: [:]) {
    case .resolved(let c):
        t.equal(c.preferredE164, FixtureContacts.ownerE164, "exact first name resolves to the right number")
    default:
        t.check(false, "\"Pulkit\" should resolve", "got something else")
    }

    // Two Rahuls: guessing here is the unrecoverable failure mode.
    switch resolver.resolve(spoken: "Rahul", contacts: contacts, aliases: [:]) {
    case .ambiguous(let candidates):
        t.check(candidates.count >= 2, "two Rahuls are ambiguous", "got \(candidates.count) candidate(s)")
    case .resolved(let c):
        t.check(false, "two Rahuls must NOT auto-resolve", "resolved to \(c.displayName)")
    case .notFound:
        t.check(false, "two Rahuls must be ambiguous, not notFound")
    }

    // A full name disambiguates.
    switch resolver.resolve(spoken: "Rahul Verma", contacts: contacts, aliases: [:]) {
    case .resolved(let c):
        t.equal(c.identifier, "fixture-rahul-verma", "full name disambiguates")
    default:
        t.check(false, "\"Rahul Verma\" should resolve")
    }

    // A name nobody has must not match anybody.
    switch resolver.resolve(spoken: "Xzqwptl", contacts: contacts, aliases: [:]) {
    case .notFound:
        t.check(true, "unknown name -> notFound")
    case .resolved(let c):
        t.check(false, "unknown name must not resolve", "resolved to \(c.displayName)")
    case .ambiguous(let cs):
        t.check(false, "unknown name must not be ambiguous", "\(cs.count) candidates")
    }

    // A learned alias outranks fuzzy matching entirely.
    let aliases = [NameNormalizer.normalize("Bhai"): "fixture-aarav"]
    switch resolver.resolve(spoken: "Bhai", contacts: contacts, aliases: aliases) {
    case .resolved(let c):
        t.equal(c.identifier, "fixture-aarav", "alias wins")
    default:
        t.check(false, "alias should resolve")
    }

    // An alias pointing at a contact that no longer exists must not crash or
    // silently resolve to the wrong person.
    let staleAlias = [NameNormalizer.normalize("Ghost"): "no-such-identifier"]
    switch resolver.resolve(spoken: "Ghost", contacts: contacts, aliases: staleAlias) {
    case .resolved(let c):
        t.check(false, "stale alias must not resolve", "resolved to \(c.displayName)")
    default:
        t.check(true, "stale alias falls through safely")
    }

    // Empty address book: every path must degrade, never crash.
    switch resolver.resolve(spoken: "Pulkit", contacts: [], aliases: [:]) {
    case .notFound: t.check(true, "no contacts -> notFound")
    default: t.check(false, "no contacts must be notFound")
    }

    // A two-letter fragment carries no signal. The harness transcribed
    // "Say hi to Aarav" as "Say hi to our ab.", the parser took "hi" as the
    // name, and "hi" fuzzy-matched SEVEN unrelated contacts.
    switch resolver.resolve(spoken: "hi", contacts: contacts, aliases: [:]) {
    case .notFound:
        t.check(true, "two-letter fragment matches nobody")
    case .resolved(let c):
        t.check(false, "\"hi\" must not resolve", "resolved to \(c.displayName)")
    case .ambiguous(let cs):
        t.check(false, "\"hi\" must not be ambiguous", "\(cs.count) candidates")
    }

    // ...but an exact match on a genuinely short name still works.
    let shortName = [Contact(identifier: "short", givenName: "Jo", familyName: "",
                             nickname: "", organizationName: "",
                             phones: [ContactPhone(label: "mobile", e164: "919812345699")])]
    switch resolver.resolve(spoken: "Jo", contacts: shortName, aliases: [:]) {
    case .resolved(let c):
        t.equal(c.identifier, "short", "exact short name still resolves")
    default:
        t.check(false, "an exact match on \"Jo\" must resolve")
    }

    // Recognizers split unfamiliar names into two familiar words. Measured:
    // "Pulkit" came back as "Paul Kit", "Siddharth" as "Sid Harth".
    switch resolver.resolve(spoken: "Paul Kit", contacts: contacts, aliases: [:]) {
    case .resolved(let c):
        t.equal(c.identifier, "fixture-pulkit", "split name \"Paul Kit\" resolves to Pulkit")
    case .ambiguous(let cs):
        t.check(false, "\"Paul Kit\" should resolve", "ambiguous over \(cs.map(\.displayName))")
    case .notFound:
        t.check(false, "\"Paul Kit\" should resolve, got notFound")
    }

    switch resolver.resolve(spoken: "Sid Harth", contacts: contacts, aliases: [:]) {
    case .resolved(let c):
        t.equal(c.identifier, "fixture-siddharth", "split name \"Sid Harth\" resolves to Siddharth")
    default:
        t.check(false, "\"Sid Harth\" should resolve to Siddharth")
    }

    // Collapsing spaces must not make two genuinely different people collide.
    switch resolver.resolve(spoken: "Rahul Sharma", contacts: contacts, aliases: [:]) {
    case .resolved(let c):
        t.equal(c.identifier, "fixture-rahul-sharma", "space collapsing keeps full names distinct")
    default:
        t.check(false, "\"Rahul Sharma\" should still resolve exactly")
    }

    // A first name outranks somebody else's surname. "Polka" (misheard "Pulkit")
    // was previously close enough to "Kapoor" to drag Stone Kapoor in as a
    // candidate.
    let ranked = FuzzyMatcher().rank(query: "Polka", among: contacts)
    if let top = ranked.first {
        t.equal(top.contact.identifier, "fixture-pulkit", "misheard first name ranks first")
    } else {
        t.check(false, "\"Polka\" should rank at least one candidate")
    }

    // A phone-less contact still resolves; the SEND path is what must refuse.
    switch resolver.resolve(spoken: "Meera Krishnan", contacts: contacts, aliases: [:]) {
    case .resolved(let c):
        t.equal(c.preferredE164, nil, "phone-less contact resolves with nil number")
    default:
        t.check(false, "\"Meera Krishnan\" should resolve")
    }

    return t.result
}

// MARK: - Send

func runSendTests() -> (passed: Int, failed: Int) {
    var t = TestRun("send")

    // Deep link: the body must survive percent-encoding byte-for-byte.
    func link(_ phone: String, _ text: String) -> String? {
        try? WhatsAppDeepLink.sendURL(phone: phone, text: text).absoluteString
    }

    t.equal(link("917982913080", "hello"),
            "whatsapp://send?phone=917982913080&text=hello", "simple body")
    t.equal(link("+91 79829 13080", "hello"),
            "whatsapp://send?phone=917982913080&text=hello", "phone formatting stripped")
    t.equal(link("917982913080", "I am late"),
            "whatsapp://send?phone=917982913080&text=I%20am%20late", "spaces encoded")

    // These characters would corrupt the query if left raw.
    t.equal(link("917982913080", "a&b"),
            "whatsapp://send?phone=917982913080&text=a%26b", "ampersand encoded")
    t.equal(link("917982913080", "1+1=2"),
            "whatsapp://send?phone=917982913080&text=1%2B1%3D2", "plus and equals encoded")
    t.equal(link("917982913080", "50% off?"),
            "whatsapp://send?phone=917982913080&text=50%25%20off%3F", "percent and question mark encoded")
    t.equal(link("917982913080", "line1\nline2"),
            "whatsapp://send?phone=917982913080&text=line1%0Aline2", "newline encoded")

    // Non-ASCII must round-trip, not get dropped.
    if let devanagari = link("917982913080", "नमस्ते") {
        t.check(devanagari.hasPrefix("whatsapp://send?phone=917982913080&text=%"),
                "devanagari percent-encoded", devanagari)
        let decoded = URLComponents(string: devanagari)?
            .percentEncodedQuery?
            .components(separatedBy: "text=").last?
            .removingPercentEncoding
        t.equal(decoded, "नमस्ते", "devanagari round-trips")
    } else {
        t.check(false, "devanagari link should build")
    }
    if let emoji = link("917982913080", "on my way 🚗") {
        let decoded = emoji.components(separatedBy: "text=").last?.removingPercentEncoding
        t.equal(decoded, "on my way 🚗", "emoji round-trips")
    } else {
        t.check(false, "emoji link should build")
    }

    t.equal(link("no digits", "hello"), nil, "phone with no digits throws")
    t.equal(link("", "hello"), nil, "empty phone throws")
    // An empty body is legal: the deep link just opens the chat.
    t.equal(link("917982913080", ""),
            "whatsapp://send?phone=917982913080&text=", "empty body still builds")

    // Blocklist: default is permissive, corrupt is fail-closed.
    let empty = Blocklist(state: .loaded([]))
    t.check(empty.isUsable, "empty blocklist is usable")
    t.check(!empty.contains("917982913080"), "empty blocklist blocks nobody")

    let populated = Blocklist(state: .loaded(["917982913080", "Boss"]))
    t.check(populated.contains("917982913080"), "blocked number is caught")
    t.check(populated.contains("Boss"), "blocked name is caught")
    t.check(populated.contains(" Boss "), "blocked name is trimmed before compare")
    t.check(!populated.contains("919812345670"), "unblocked number passes")

    let corrupt = Blocklist(state: .corrupt)
    t.check(!corrupt.isUsable, "corrupt blocklist fails closed")

    return t.result
}

// MARK: - Send path (the most dangerous code in the app)
//
// Every case here runs with `dryRun: true`, which opens nothing and posts
// nothing (see WhatsAppSender step 2). What is being tested is the DECISION:
// does the kill-switch fire before anything happens, and does a malformed
// target fail rather than proceed.
@MainActor
func runSendPathTests() async -> (passed: Int, failed: Int) {
    var t = TestRun("send-path")

    let owner = FixtureContacts.ownerE164

    // A normal dry run reaches the dry-run branch and stops there.
    let open = WhatsAppSender(blocklist: Blocklist(state: .loaded([])))
    let normal = await open.send(phone: owner, body: "I am late",
                                 contactName: "Pulkit Sharma", dryRun: true)
    t.equal(normal, .dryRun, "clean dry run reports dryRun")

    // Blocklisted by NUMBER: refused before the deep link is even built.
    let byNumber = WhatsAppSender(blocklist: Blocklist(state: .loaded([owner])))
    let blockedNumber = await byNumber.send(phone: owner, body: "I am late",
                                            contactName: "Pulkit Sharma", dryRun: true)
    t.equal(blockedNumber, .blocked(contact: owner), "blocklisted number is refused")

    // Blocklisted by NAME: same refusal via the other identifier.
    let byName = WhatsAppSender(blocklist: Blocklist(state: .loaded(["Pulkit Sharma"])))
    let blockedName = await byName.send(phone: owner, body: "I am late",
                                        contactName: "Pulkit Sharma", dryRun: true)
    t.equal(blockedName, .blocked(contact: "Pulkit Sharma"), "blocklisted name is refused")

    // Fail closed: an unreadable blocklist must refuse EVERY send, including a
    // dry run. A corrupt kill-switch that silently allows sends is the worst
    // possible failure mode, because the user believes they are protected.
    let broken = WhatsAppSender(blocklist: Blocklist(state: .corrupt))
    let brokenOutcome = await broken.send(phone: owner, body: "I am late",
                                          contactName: "Pulkit Sharma", dryRun: true)
    if case .failed = brokenOutcome {
        t.check(true, "corrupt blocklist refuses even a dry run")
    } else {
        t.check(false, "corrupt blocklist must refuse", "got \(brokenOutcome)")
    }

    // A target with no digits cannot produce a deep link, and must fail rather
    // than proceed to open anything.
    let noDigits = await open.send(phone: "not a number", body: "I am late",
                                   contactName: "Nobody", dryRun: true)
    if case .failed = noDigits {
        t.check(true, "unusable phone number fails instead of proceeding")
    } else {
        t.check(false, "unusable phone number must fail", "got \(noDigits)")
    }

    // An empty body is a legal send: the deep link just opens the chat.
    let emptyBody = await open.send(phone: owner, body: "",
                                    contactName: "Pulkit Sharma", dryRun: true)
    t.equal(emptyBody, .dryRun, "empty body still reaches dry run")

    return t.result
}
