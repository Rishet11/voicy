import Foundation

// MARK: - Recipient resolution corpus
//
// The worst failure this product can have is sending the right message to the
// wrong person, confidently. Every row here is about that: ties must ask,
// weak matches must ask, and a correction the user makes once must change the
// answer the next time.

public func runRecipientTests() -> (passed: Int, failed: Int) {
    var t = TestRun("recipient")

    let resolver = ContactResolver()
    let contacts = FixtureContacts.all

    // MARK: Confident, correct resolutions

    for (spoken, expected) in [
        ("Pulkit", "fixture-pulkit"),
        ("Aarav", "fixture-aarav"),
        ("Shreya", "fixture-shreya"),
        ("Shru", "fixture-shreya"),               // nickname
        ("Rahul Sharma", "fixture-rahul-sharma"), // full name breaks the tie
        ("Rahul Verma", "fixture-rahul-verma"),
    ] {
        switch resolver.resolve(spoken: spoken, contacts: contacts, aliases: [:]) {
        case .resolved(let c):
            t.equal(c.identifier, expected, "\"\(spoken)\" resolves")
        case .ambiguous(let cs):
            t.check(false, "\"\(spoken)\" should resolve", "ambiguous: \(cs.map(\.displayName))")
        case .notFound:
            t.check(false, "\"\(spoken)\" should resolve", "notFound")
        }
    }

    // MARK: Ties must ALWAYS ask, never pick

    for spoken in ["Rahul", "rahul", "RAHUL"] {
        switch resolver.resolve(spoken: spoken, contacts: contacts, aliases: [:]) {
        case .ambiguous(let cs):
            let ids = Set(cs.map(\.identifier))
            t.check(ids.contains("fixture-rahul-sharma") && ids.contains("fixture-rahul-verma"),
                    "\"\(spoken)\" offers both Rahuls", "\(cs.map(\.displayName))")
        case .resolved(let c):
            t.check(false, "\"\(spoken)\" must never pick one of two Rahuls", "picked \(c.displayName)")
        case .notFound:
            t.check(false, "\"\(spoken)\" must offer the two Rahuls, not vanish")
        }
    }

    // An exact tie between two identical given names, in a minimal contact set,
    // must still ask. This is the pure form of the failure: identical scores.
    let twins = [
        Contact(identifier: "twin-a", givenName: "Rohit", familyName: "Sharma",
                nickname: "", organizationName: "",
                phones: [ContactPhone(label: "mobile", e164: "919812345680")]),
        Contact(identifier: "twin-b", givenName: "Rohit", familyName: "Verma",
                nickname: "", organizationName: "",
                phones: [ContactPhone(label: "mobile", e164: "919812345681")]),
    ]
    switch resolver.resolve(spoken: "Rohit", contacts: twins, aliases: [:]) {
    case .ambiguous(let cs):
        t.equal(cs.count, 2, "an exact score tie offers both candidates")
    default:
        t.check(false, "an exact score tie must be ambiguous, never resolved")
    }

    // MARK: Low confidence must ask or fail, never guess

    for spoken in ["Xavier Quinlan", "Bartholomew"] {
        switch resolver.resolve(spoken: spoken, contacts: contacts, aliases: [:]) {
        case .resolved(let c):
            t.check(false, "\"\(spoken)\" must not resolve to anybody", "got \(c.displayName)")
        default:
            t.check(true, "\"\(spoken)\" does not guess a recipient")
        }
    }

    // MARK: Phonetic folding for Indian names (recall, not identity)

    for (mangled, expected) in [
        ("Sidharth", "fixture-siddharth"),
        ("Sidarth", "fixture-siddharth"),
        ("Adithi", "fixture-aditi"),
        ("Arav", "fixture-aarav"),
        ("Shraya", "fixture-shreya"),
        ("Mira Krishna", "fixture-no-number"),
    ] {
        switch resolver.resolve(spoken: mangled, contacts: contacts, aliases: [:]) {
        case .resolved(let c):
            t.equal(c.identifier, expected, "\"\(mangled)\" resolves to the real contact")
        case .ambiguous(let cs):
            t.check(cs.contains { $0.identifier == expected },
                    "\"\(mangled)\" at least offers the real contact",
                    "\(cs.map(\.displayName))")
        case .notFound:
            t.check(false, "\"\(mangled)\" must not vanish; the contact is right there")
        }
    }

    // MARK: The learning loop

    // A correction must (a) persist, (b) survive a reload from disk, and
    // (c) actually change the next resolution for that spoken phrase.
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("voicy-recipient-tests-\(ProcessInfo.processInfo.processIdentifier)")
        .appendingPathComponent("aliases.json")
    try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())

    let store = AliasStore(fileURL: tmp)
    t.equal(store.count, 0, "a fresh alias store is empty")

    // Before the correction: "Rahul" is ambiguous.
    let beforeAliases = aliasMap(store)
    switch resolver.resolve(spoken: "Rahul", contacts: contacts, aliases: beforeAliases) {
    case .ambiguous:
        t.check(true, "before learning, \"Rahul\" asks")
    default:
        t.check(false, "before learning, \"Rahul\" must ask")
    }

    // The user picks Rahul Verma from the confirmation card.
    try? store.setAlias(spoken: "Rahul", contactIdentifier: "fixture-rahul-verma",
                        e164: "919812345672")
    t.equal(store.count, 1, "the correction is recorded")

    switch resolver.resolve(spoken: "Rahul", contacts: contacts, aliases: aliasMap(store)) {
    case .resolved(let c):
        t.equal(c.identifier, "fixture-rahul-verma", "after learning, \"Rahul\" resolves to the corrected contact")
    default:
        t.check(false, "after learning, \"Rahul\" must resolve to the corrected contact")
    }

    // Case and spacing of the spoken phrase must not defeat the learned alias.
    for variant in ["rahul", "  Rahul  ", "RAHUL"] {
        switch resolver.resolve(spoken: variant, contacts: contacts, aliases: aliasMap(store)) {
        case .resolved(let c):
            t.equal(c.identifier, "fixture-rahul-verma", "learned alias survives \"\(variant)\"")
        default:
            t.check(false, "learned alias must survive \"\(variant)\"")
        }
    }

    // A second process reading the same file sees the same correction.
    let reloaded = AliasStore(fileURL: tmp)
    t.equal(reloaded.entry(forSpoken: NameNormalizer.normalize("Rahul"))?.contactIdentifier,
            "fixture-rahul-verma",
            "the correction survives a reload from disk")

    // Learning one name must not silently redirect a different one.
    switch resolver.resolve(spoken: "Rahul Sharma", contacts: contacts, aliases: aliasMap(reloaded)) {
    case .resolved(let c):
        t.equal(c.identifier, "fixture-rahul-sharma", "a learned alias does not hijack a different name")
    default:
        t.check(false, "\"Rahul Sharma\" must still resolve to Rahul Sharma")
    }

    // Undoing the correction restores the confirmation prompt.
    try? reloaded.removeAlias(spoken: "Rahul")
    switch resolver.resolve(spoken: "Rahul", contacts: contacts, aliases: aliasMap(reloaded)) {
    case .ambiguous:
        t.check(true, "removing the alias restores the confirmation")
    default:
        t.check(false, "removing the alias must restore the confirmation")
    }

    try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())

    return t.result
}

/// The `[spoken: contactIdentifier]` map `ContactResolver` expects.
private func aliasMap(_ store: AliasStore) -> [String: String] { store.lookup }
