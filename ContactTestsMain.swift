import Foundation

// Standalone unit-test harness for the Contacts module (W2).
// NOT part of the Swift package. Lives at repo root so SPM ignores it and it
// never collides with the Voicy executable target.
//
// Build + run (from the repo root):
//   swiftc -swift-version 6 -framework Contacts \
//     Sources/Voicy/Contacts/Contact.swift Sources/Voicy/Contacts/PhoneNormalizer.swift \
//     Sources/Voicy/Contacts/FuzzyMatcher.swift Sources/Voicy/Contacts/ContactResolver.swift \
//     Sources/Voicy/Contacts/AliasStore.swift ContactTestsMain.swift -o /tmp/voicy_contacts_tests
//   /tmp/voicy_contacts_tests

@main
@MainActor
struct ContactTestsMain {

    static var failures = 0

    static func main() {
        testPhoneNormalization()
        testPreferredE164()
        testResolution()
        testNicknameAndDiacritics()
        testAliasStorePersistence()
        testRankingOrder()
        testThresholdSanity()
        evaluatePhoneticRecall()

        print("")
        if failures == 0 {
            print("ALL CONTACT TESTS PASSED")
        } else {
            print("\(failures) CONTACT TEST(S) FAILED")
            exit(1)
        }
    }

    // MARK: - Fake contact set

    static func fakeContacts() -> [Contact] {
        [
            Contact(identifier: "pulkit", givenName: "Pulkit", familyName: "Sharma",
                    nickname: "Pul", organizationName: "", phones: [
                        ContactPhone(label: "mobile", e164: "919876543210")
                    ]),
            Contact(identifier: "rishet", givenName: "Rishet", familyName: "Mehra",
                    nickname: "", organizationName: "", phones: [
                        ContactPhone(label: "work", e164: "919876543211"),
                        ContactPhone(label: "home", e164: "911123456789")
                    ]),
            Contact(identifier: "aarav", givenName: "Aarav", familyName: "Kapoor",
                    nickname: "", organizationName: "", phones: [
                        ContactPhone(label: "mobile", e164: "919876543212")
                    ]),
            Contact(identifier: "shreya", givenName: "Shreya", familyName: "Iyer",
                    nickname: "", organizationName: "", phones: [
                        ContactPhone(label: "mobile", e164: "919876543213")
                    ]),
            Contact(identifier: "rahul_sharma", givenName: "Rahul", familyName: "Sharma",
                    nickname: "", organizationName: "", phones: [
                        ContactPhone(label: "mobile", e164: "919876543214")
                    ]),
            Contact(identifier: "rahul_verma", givenName: "Rahul", familyName: "Verma",
                    nickname: "", organizationName: "", phones: [
                        ContactPhone(label: "mobile", e164: "919876543215")
                    ]),
            Contact(identifier: "sid", givenName: "Siddharth", familyName: "Rao",
                    nickname: "Sid", organizationName: "", phones: [
                        ContactPhone(label: "mobile", e164: "919876543216")
                    ]),
            Contact(identifier: "aditi", givenName: "Aditi", familyName: "Nair",
                    nickname: "", organizationName: "", phones: [
                        ContactPhone(label: "mobile", e164: "919876543217")
                    ]),
            Contact(identifier: "acme", givenName: "", familyName: "",
                    nickname: "", organizationName: "Acme Corp", phones: [
                        ContactPhone(label: "work", e164: "912222222222")
                    ]),
        ]
    }

    // MARK: - Tests

    static func testPhoneNormalization() {
        func eq(_ input: String, _ expected: String, _ name: String) {
            let got = PhoneNormalizer.normalize(input)
            check(got == expected, "\(name) -> \(got ?? "nil"), expected \(expected)")
        }

        // The three documented Indian cases.
        eq("98765 43210", "919876543210", "space-separated 10-digit")
        eq("+91 98765 43210", "919876543210", "plus +91")
        eq("098765 43210", "919876543210", "leading-national-zero")

        // Other formats.
        eq("987-654-3210", "919876543210", "dashes")
        eq("919876543210", "919876543210", "already-e164")
        eq("+44 20 7946 0958", "442079460958", "uk plus")
        eq("+91 098765 43210", "919876543210", "plus +91 with trunk zero")

        // Invalid / not usable.
        check(PhoneNormalizer.normalize("") == nil, "empty -> nil")
        check(PhoneNormalizer.normalize("12345") == nil, "too short -> nil")
        check(PhoneNormalizer.normalize("abc") == nil, "no digits -> nil")
    }

    static func testPreferredE164() {
        let rishet = fakeContacts()[1]
        check(rishet.preferredE164 == "919876543211" || rishet.preferredE164 == "911123456789",
              "preferredE164 falls back to first number")

        let c = Contact(identifier: "x", givenName: "X", familyName: "Y",
                        nickname: "", organizationName: "",
                        phones: [ContactPhone(label: "work", e164: "911111111111"),
                                 ContactPhone(label: "mobile", e164: "912222222222")])
        check(c.preferredE164 == "912222222222", "mobile label preferred over work")
    }

    static func testResolution() {
        let contacts = fakeContacts()
        let resolver = ContactResolver()

        if case .resolved(let c) = resolver.resolve(spoken: "Pulkit", contacts: contacts, aliases: [:]) {
            check(c.identifier == "pulkit", "resolve 'Pulkit' -> pulkit")
        } else {
            check(false, "resolve 'Pulkit' should resolve")
        }

        if case .resolved(let c) = resolver.resolve(spoken: "Pulkit Sharma", contacts: contacts, aliases: [:]) {
            check(c.identifier == "pulkit", "resolve 'Pulkit Sharma' -> pulkit")
        } else {
            check(false, "resolve 'Pulkit Sharma' should resolve")
        }

        if case .ambiguous(let cands) = resolver.resolve(spoken: "Rahul", contacts: contacts, aliases: [:]) {
            let ids = cands.map(\.identifier).sorted()
            check(ids == ["rahul_sharma", "rahul_verma"], "resolve 'Rahul' ambiguous over both Rahuls")
        } else {
            check(false, "resolve 'Rahul' should be ambiguous")
        }

        if case .resolved(let c) = resolver.resolve(spoken: "Rahul Sharma", contacts: contacts, aliases: [:]) {
            check(c.identifier == "rahul_sharma", "resolve 'Rahul Sharma' -> rahul_sharma")
        } else {
            check(false, "resolve 'Rahul Sharma' should resolve")
        }

        if case .notFound = resolver.resolve(spoken: "Zzzxyz Nobody", contacts: contacts, aliases: [:]) {
            check(true, "resolve unknown -> notFound")
        } else {
            check(false, "resolve unknown should be notFound")
        }

        let aliases = ["bhai": "pulkit"]
        if case .resolved(let c) = resolver.resolve(spoken: "bhai", contacts: contacts, aliases: aliases) {
            check(c.identifier == "pulkit", "alias 'bhai' -> pulkit")
        } else {
            check(false, "alias 'bhai' should resolve")
        }
    }

    static func testNicknameAndDiacritics() {
        let contacts = fakeContacts()
        let resolver = ContactResolver()

        if case .resolved(let c) = resolver.resolve(spoken: "Sid", contacts: contacts, aliases: [:]) {
            check(c.identifier == "sid", "nickname 'Sid' -> Siddharth")
        } else {
            check(false, "nickname 'Sid' should resolve")
        }

        if case .resolved(let c) = resolver.resolve(spoken: "Shréya", contacts: contacts, aliases: [:]) {
            check(c.identifier == "shreya", "diacritic 'Shréya' -> shreya")
        } else {
            check(false, "diacritic 'Shréya' should resolve")
        }

        if case .resolved(let c) = resolver.resolve(spoken: "Acme Corp", contacts: contacts, aliases: [:]) {
            check(c.identifier == "acme", "organization 'Acme Corp' -> acme")
        } else {
            check(false, "organization name should resolve")
        }
    }

    static func testAliasStorePersistence() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicy_tests_\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("aliases.json")

        do {
            let store = AliasStore(fileURL: url)
            try store.setAlias(spoken: "bhai", contactIdentifier: "pulkit", e164: "919876543210")
            check(store.entry(forSpoken: "bhai")?.contactIdentifier == "pulkit", "alias set in memory")

            let reloaded = AliasStore(fileURL: url)
            check(reloaded.entry(forSpoken: "bhai")?.e164 == "919876543210", "alias persisted and reloaded")

            try store.setAlias(spoken: "bhai", contactIdentifier: "rishet", e164: "919876543211")
            check(AliasStore(fileURL: url).entry(forSpoken: "bhai")?.contactIdentifier == "rishet",
                  "alias overwrite persisted")

            try store.removeAlias(spoken: "bhai")
            check(AliasStore(fileURL: url).entry(forSpoken: "bhai") == nil, "alias removal persisted")

            try? FileManager.default.removeItem(at: dir)
        } catch {
            check(false, "alias store threw: \(error)")
        }
    }

    static func testRankingOrder() {
        let contacts = fakeContacts()
        let matcher = FuzzyMatcher()
        let ranked = matcher.rank(query: "Pulkit", among: contacts)
        guard let first = ranked.first else {
            check(false, "ranking returned no candidates")
            return
        }
        check(first.contact.identifier == "pulkit", "ranking best is pulkit")
        check(ranked[0].score >= ranked[1].score, "ranking is sorted descending")
    }

    static func testThresholdSanity() {
        let contacts = fakeContacts()
        let resolver = ContactResolver()

        if case .resolved(let c) = resolver.resolve(spoken: "Aditi", contacts: contacts, aliases: [:]) {
            check(c.identifier == "aditi", "threshold sanity: 'Aditi' resolves")
        } else {
            check(false, "threshold sanity: 'Aditi' should resolve")
        }

        if case .ambiguous = resolver.resolve(spoken: "Rahul", contacts: contacts, aliases: [:]) {
            check(true, "threshold sanity: shared first name is ambiguous, never guessed")
        } else {
            check(false, "threshold sanity: shared first name must be ambiguous")
        }
    }

    /// Empirically check the Soundex recall bonus on the provided Indian names.
    /// If it does not clearly help, the shipped default (off) stands, per the
    /// constitution rule: don't ship a clever thing that doesn't earn its place.
    static func evaluatePhoneticRecall() {
        let names = ["Pulkit", "Rishet", "Aarav", "Shreya", "Siddharth", "Aditi"]
        let codes = names.compactMap { Soundex.encode(NameNormalizer.normalize($0)) }
        let unique = Set(codes).count
        print("PHONETIC: \(names.count) names -> \(unique) unique Soundex codes")

        let contacts = fakeContacts()
        let resolverOn = ContactResolver(matcher: FuzzyMatcher(usePhoneticBonus: true))
        var wrong = 0
        for name in names {
            if case .resolved(let c) = resolverOn.resolve(spoken: name, contacts: contacts, aliases: [:]) {
                if c.givenName.lowercased() != name.lowercased() { wrong += 1 }
            }
        }
        check(wrong == 0, "phonetic bonus does not misresolve distinct Indian names (\(wrong) wrong)")
    }

    static func check(_ cond: Bool, _ name: String) {
        if cond {
            print("PASS: \(name)")
        } else {
            print("FAIL: \(name)")
            failures += 1
        }
    }
}
