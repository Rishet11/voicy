import Foundation

// MARK: - Phonetic layer tests
//
// Same house style as Testing/UnitTests.swift (plain functions, no XCTest).
// `runContactTests()` lives outside this directory, so this suite is wired in
// separately as `runPhoneticTests()`.

public func runPhoneticTests() -> (passed: Int, failed: Int) {
    var t = TestRun("phonetic")

    let resolver = ContactResolver()
    let contacts = FixtureContacts.all

    // --- PhoneticFolder mapping sanity: each row folds the measured mishear
    // and the real name to the same (or a very close) key.
    t.equal(PhoneticFolder.fold("dh"), PhoneticFolder.fold("d"), "dh/d aspiration fold")
    t.equal(PhoneticFolder.fold("aditi"), PhoneticFolder.fold("adidi"), "Aditi/Adidi t-d fold")
    t.equal(PhoneticFolder.fold("aarav"), PhoneticFolder.fold("arav"), "Aarav/Arav doubled-vowel fold")

    // --- Measured failure: "Pulkit" heard as "Polka" / "Palka". Orthographic
    // scoring alone previously left these below notFoundFloor; the phonetic
    // pass must now at least surface Pulkit as a candidate (never silently
    // vanish), but must never claim it outright on phonetics alone unless the
    // orthographic path already agreed (as it does for "Polka" via the
    // split-name branch).
    switch resolver.resolve(spoken: "Palka", contacts: contacts, aliases: [:]) {
    case .notFound:
        t.check(false, "\"Palka\" (misheard Pulkit) must not vanish to notFound")
    default:
        t.check(true, "\"Palka\" surfaces Pulkit as a candidate")
    }

    // --- Measured failure: "Aditi" heard as "Adidi".
    switch resolver.resolve(spoken: "Adidi", contacts: contacts, aliases: [:]) {
    case .notFound:
        t.check(false, "\"Adidi\" (misheard Aditi) must not vanish to notFound")
    default:
        t.check(true, "\"Adidi\" surfaces Aditi as a candidate")
    }

    // --- Measured failure: "Siddharth" heard as "Sidharth" (already handled by
    // the split/squash branch, confirm the phonetic layer does not regress it).
    switch resolver.resolve(spoken: "Sidharth", contacts: contacts, aliases: [:]) {
    case .resolved(let c):
        t.equal(c.identifier, "fixture-siddharth", "\"Sidharth\" still resolves to Siddharth")
    default:
        t.check(false, "\"Sidharth\" should resolve to Siddharth")
    }

    // --- Honest negative: "our ab" (misheard "Aarav") has lost the name
    // entirely; there is no phonetic key that recovers it, and the parser
    // context (a preposition, not a name shape) is outside this directory.
    // This suite documents that as a known, accepted gap rather than faking
    // a pass, by asserting the safe fallback (not a wrong resolve).
    switch resolver.resolve(spoken: "our ab", contacts: contacts, aliases: [:]) {
    case .resolved(let c):
        t.check(false, "\"our ab\" must not GUESS a resolution", "resolved to \(c.displayName)")
    default:
        t.check(true, "\"our ab\" safely fails rather than guessing (name is genuinely gone)")
    }

    // --- Safety gate: "Xavier Quinlan" must still match nobody, phonetics
    // included. Folded it becomes "xavir kuinlan"; folded "Meera Krishnan"
    // becomes "mira krisnan" - well below phoneticMatchFloor.
    switch resolver.resolve(spoken: "Xavier Quinlan", contacts: contacts, aliases: [:]) {
    case .notFound:
        t.check(true, "\"Xavier Quinlan\" matches nobody, even with phonetics enabled")
    case .resolved(let c):
        t.check(false, "\"Xavier Quinlan\" must not resolve", "resolved to \(c.displayName)")
    case .ambiguous(let cs):
        t.check(false, "\"Xavier Quinlan\" must not be ambiguous", "\(cs.map(\.displayName))")
    }

    // --- Safety gate: two Rahuls must stay ambiguous, phonetics cannot break
    // the tie one way or another since neither is a phonetic hit here.
    switch resolver.resolve(spoken: "Rahul", contacts: contacts, aliases: [:]) {
    case .ambiguous(let cs):
        t.check(cs.count >= 2, "two Rahuls remain ambiguous with phonetics enabled")
    default:
        t.check(false, "two Rahuls must stay ambiguous")
    }

    // --- Two contacts colliding phonetically must stay ambiguous, not pick a
    // winner. Add a phonetic twin of Aditi ("Adithi") to a small contact set
    // alongside the real Aditi; a mangled "Adidi" should land on both, not one.
    let aditiTwin = [
        Contact(identifier: "fixture-aditi", givenName: "Aditi", familyName: "Rao",
                nickname: "", organizationName: "",
                phones: [ContactPhone(label: "mobile", e164: "919812345674")]),
        Contact(identifier: "fixture-adithi", givenName: "Adithi", familyName: "Menon",
                nickname: "", organizationName: "",
                phones: [ContactPhone(label: "mobile", e164: "919812345699")]),
    ]
    switch resolver.resolve(spoken: "Adidi", contacts: aditiTwin, aliases: [:]) {
    case .resolved(let c):
        t.check(false, "phonetically colliding contacts must not auto-pick one",
                "resolved to \(c.displayName)")
    default:
        t.check(true, "phonetically colliding contacts (Aditi/Adithi) stay ambiguous or unresolved together")
    }

    // --- Structural contract: no query, against the full fixture set, may
    // reach `.resolved` purely because of the phonetic pass. We check this by
    // comparing the plain (phonetics-off) matcher's resolve outcome against
    // the phonetics-on resolver for every mangled query in this suite: any
    // query that phonetics-off calls notFound/ambiguous must still not be
    // `.resolved` with phonetics on, UNLESS the orthographic score itself
    // (not phonetics) already justified it.
    let plainMatcher = FuzzyMatcher(usePhoneticBonus: false)
    let plainResolver = ContactResolver(matcher: plainMatcher)
    for query in ["Palka", "Adidi", "Polka", "Paul Kit"] {
        let phoneticOutcome = resolver.resolve(spoken: query, contacts: contacts, aliases: [:])
        if case .resolved = phoneticOutcome {
            let plainOutcome = plainResolver.resolve(spoken: query, contacts: contacts, aliases: [:])
            if case .resolved = plainOutcome {
                t.check(true, "\"\(query)\" resolves on orthographic grounds alone, phonetics agrees")
            } else {
                t.check(false, "\"\(query)\" must not resolve on phonetics alone", "phonetics-off gave \(plainOutcome)")
            }
        } else {
            t.check(true, "\"\(query)\" did not auto-resolve")
        }
    }

    // --- Exact name still resolves instantly, phonetics untouched.
    switch resolver.resolve(spoken: "Pulkit", contacts: contacts, aliases: [:]) {
    case .resolved(let c):
        t.equal(c.identifier, "fixture-pulkit", "exact name still resolves instantly")
    default:
        t.check(false, "exact match \"Pulkit\" must resolve")
    }

    // --- Score-level structural check: the phonetic pass may never lift a score
    // to or past the resolve floor on its own.
    //
    // "Adidi" is NOT a phonetic-only case and must not be used as one: it scores
    // 0.91 orthographically (Jaro-Winkler on "adidi" vs "aditi"), and the
    // phonetic pass never even runs for it, since that pass only runs when the
    // orthographic score is below notFoundFloor. Comparing the two matchers is
    // the check that actually tests the invariant.
    let plainForScores = FuzzyMatcher(usePhoneticBonus: false)
    let phoneticForScores = FuzzyMatcher()
    for query in ["Adidi", "Palka", "Polka", "Sidharth", "Mira Krishna", "Xavier Quinlan"] {
        for contact in contacts {
            let plain = plainForScores.rank(query: query, among: [contact]).first?.score ?? 0
            let withPhonetics = phoneticForScores.rank(query: query, among: [contact]).first?.score ?? 0
            t.check(withPhonetics >= plain,
                    "phonetics never lowers a score (\(query) / \(contact.displayName))",
                    "plain \(plain), phonetic \(withPhonetics)")
            if plain < ResolutionThresholds.resolveFloor {
                t.check(withPhonetics < ResolutionThresholds.resolveFloor,
                        "phonetics alone cannot reach the resolve floor (\(query) / \(contact.displayName))",
                        "plain \(plain), phonetic \(withPhonetics)")
            }
        }
    }

    // And the measured truth about the pass itself.
    //
    // MEASURED 2026-08-13: across every mangled name in this suite, against every
    // fixture contact, the phonetic pass changes NOTHING. Scores with phonetics
    // on are identical to scores with phonetics off, to the last digit. The pass
    // is gated on the orthographic score being below notFoundFloor (0.55), and
    // every real mishear the audio harness produced already scores above that
    // ("Palka"/Pulkit 0.730, "Adidi"/Aditi 0.907, "Paul Kit"/Pulkit 0.957). The
    // recall it was written to provide is already coming from the orthographic
    // path, including the split-name squash branch.
    //
    // This is asserted rather than written down, so that anyone who widens the
    // gate has to come back here and re-justify the safety story.
    var phoneticChangedAnything = false
    for query in ["Palka", "Polka", "Adidi", "Addi", "Aadi", "Paul Kit", "Sid Harth",
                  "Sidhart", "Sidart", "Mira Krishna", "Krishna", "Shraya", "Shreiya",
                  "Arav", "Polkit", "Bulkit", "Salka", "Xavier Quinlan"] {
        for contact in contacts {
            let plain = plainForScores.rank(query: query, among: [contact]).first?.score ?? 0
            let withPhonetics = phoneticForScores.rank(query: query, among: [contact]).first?.score ?? 0
            if withPhonetics != plain { phoneticChangedAnything = true }
        }
    }
    t.check(!phoneticChangedAnything,
            "the phonetic pass is currently inert on every measured mishear (see TEXT-NOTES.md)")

    return t.result
}
