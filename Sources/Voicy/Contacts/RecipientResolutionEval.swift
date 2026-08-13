import Foundation

/// A labelled recipient-resolution case. Refusal cases intentionally include
/// both not-found and ambiguous outcomes: either is safe, a guessed person is
/// not.
private struct RecipientEvalCase {
    let label: String
    let spoken: String
    let expectedIdentifier: String?
}

private struct RecipientEvalSummary {
    let cases: Int
    let expectedContacts: Int
    let expectedRefusals: Int
    let correctResolutions: Int
    let correctRefusals: Int
    let wrongPeople: Int

    var top1Accuracy: Double { rate(correctResolutions, expectedContacts) }
    var correctRefusalRate: Double { rate(correctRefusals, expectedRefusals) }
    var wrongPersonRate: Double { rate(wrongPeople, cases) }

    private func rate(_ numerator: Int, _ denominator: Int) -> Double {
        denominator == 0 ? 1 : Double(numerator) / Double(denominator)
    }
}

/// Deterministic, reviewable accuracy corpus for the safety-critical resolver.
/// Keep every row explicit: this is an evaluation, not a generated smoke test.
public func runRecipientResolutionEval() -> (passed: Int, failed: Int) {
    var t = TestRun("recipient-eval")
    let contacts = RecipientEvalFixtures.contacts
    let cases = recipientEvalCases

    t.check(cases.count >= 60, "corpus contains at least 60 labelled cases", "got (cases.count)")

    let off = evaluate(cases, contacts: contacts, matcher: FuzzyMatcher(usePhoneticBonus: false))
    let on = evaluate(cases, contacts: contacts, matcher: FuzzyMatcher(usePhoneticBonus: true))

    print("recipient eval: \(on.cases) cases")
    print("  phonetic off: top-1 \(pct(off.top1Accuracy)), correct-refusal \(pct(off.correctRefusalRate)), wrong-person \(pct(off.wrongPersonRate))")
    print("  phonetic on:  top-1 \(pct(on.top1Accuracy)), correct-refusal \(pct(on.correctRefusalRate)), wrong-person \(pct(on.wrongPersonRate))")

    // The bonus may improve recall, but it must not trade safety for recall.
    // The measured corpus decides whether production should keep it enabled.
    t.check(on.wrongPeople <= off.wrongPeople,
            "phonetic bonus does not increase wrong-person guesses",
            "off (off.wrongPeople), on (on.wrongPeople)")
    t.check(on.correctResolutions >= off.correctResolutions,
            "phonetic bonus does not reduce top-1 correct resolutions",
            "off (off.correctResolutions), on (on.correctResolutions)")

    // The default is deliberately selected from the measured safety result.
    // If this assertion fails, re-evaluate the corpus before changing the gate.
    t.check(FuzzyMatcher().usePhoneticBonus,
            "phonetic bonus remains enabled only after safe corpus comparison")
    return t.result
}

private func evaluate(_ cases: [RecipientEvalCase], contacts: [Contact], matcher: FuzzyMatcher) -> RecipientEvalSummary {
    let resolver = ContactResolver(matcher: matcher)
    var correctResolutions = 0
    var correctRefusals = 0
    var wrongPeople = 0

    for row in cases {
        let resolution = resolver.resolve(spoken: row.spoken, contacts: contacts, aliases: [:])
        switch (row.expectedIdentifier, resolution) {
        case let (expected?, .resolved(contact)) where contact.identifier == expected:
            correctResolutions += 1
        case (nil, .resolved):
            wrongPeople += 1
        case let (expected?, .resolved(contact)) where contact.identifier != expected:
            _ = expected
            wrongPeople += 1
        case (nil, .ambiguous), (nil, .notFound):
            correctRefusals += 1
        default:
            break
        }
    }

    return RecipientEvalSummary(
        cases: cases.count,
        expectedContacts: cases.filter { $0.expectedIdentifier != nil }.count,
        expectedRefusals: cases.filter { $0.expectedIdentifier == nil }.count,
        correctResolutions: correctResolutions,
        correctRefusals: correctRefusals,
        wrongPeople: wrongPeople)
}

private func pct(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }

/// Additional contacts make the collision and refusal labels independent of
/// the production fixture list, while retaining the real fixture names.
private enum RecipientEvalFixtures {
    static let contacts: [Contact] = FixtureContacts.all + [
        Contact(identifier: "eval-adithi", givenName: "Adithi", familyName: "Menon",
                nickname: "", organizationName: "",
                phones: [ContactPhone(label: "mobile", e164: "919812345699")]),
        Contact(identifier: "eval-rohit-sharma", givenName: "Rohit", familyName: "Sharma",
                nickname: "", organizationName: "",
                phones: [ContactPhone(label: "mobile", e164: "919812345680")]),
        Contact(identifier: "eval-rohit-verma", givenName: "Rohit", familyName: "Verma",
                nickname: "", organizationName: "",
                phones: [ContactPhone(label: "mobile", e164: "919812345681")]),
    ]
}

private let recipientEvalCases: [RecipientEvalCase] = [
    RecipientEvalCase(label: "exact Pulkit", spoken: "Pulkit", expectedIdentifier: "fixture-pulkit"),
    RecipientEvalCase(label: "exact Aarav", spoken: "Aarav", expectedIdentifier: "fixture-aarav"),
    RecipientEvalCase(label: "exact Shreya", spoken: "Shreya", expectedIdentifier: "fixture-shreya"),
    RecipientEvalCase(label: "exact Aditi", spoken: "Aditi", expectedIdentifier: "fixture-aditi"),
    RecipientEvalCase(label: "exact Siddharth", spoken: "Siddharth", expectedIdentifier: "fixture-siddharth"),
    RecipientEvalCase(label: "exact Stone", spoken: "Stone", expectedIdentifier: "fixture-stone"),
    RecipientEvalCase(label: "exact Meera", spoken: "Meera", expectedIdentifier: "fixture-no-number"),
    RecipientEvalCase(label: "nickname Shru", spoken: "Shru", expectedIdentifier: "fixture-shreya"),
    RecipientEvalCase(label: "nickname case", spoken: "SHRU", expectedIdentifier: "fixture-shreya"),
    RecipientEvalCase(label: "nickname padded", spoken: "  Shru  ", expectedIdentifier: "fixture-shreya"),
    RecipientEvalCase(label: "full Rahul Sharma", spoken: "Rahul Sharma", expectedIdentifier: "fixture-rahul-sharma"),
    RecipientEvalCase(label: "full Rahul Verma", spoken: "Rahul Verma", expectedIdentifier: "fixture-rahul-verma"),
    RecipientEvalCase(label: "full Rohit Sharma", spoken: "Rohit Sharma", expectedIdentifier: "eval-rohit-sharma"),
    RecipientEvalCase(label: "full Rohit Verma", spoken: "Rohit Verma", expectedIdentifier: "eval-rohit-verma"),
    RecipientEvalCase(label: "surname Sharma", spoken: "Sharma", expectedIdentifier: nil),
    RecipientEvalCase(label: "surname Verma", spoken: "Verma", expectedIdentifier: nil),
    RecipientEvalCase(label: "surname Kapoor", spoken: "Kapoor", expectedIdentifier: "fixture-stone"),
    RecipientEvalCase(label: "surname Nair", spoken: "Nair", expectedIdentifier: "fixture-siddharth"),
    RecipientEvalCase(label: "Pulkit Palkit", spoken: "Palkit", expectedIdentifier: "fixture-pulkit"),
    RecipientEvalCase(label: "Pulkit Pull kit", spoken: "Pull kit", expectedIdentifier: "fixture-pulkit"),
    RecipientEvalCase(label: "Pulkit Paul Kit", spoken: "Paul Kit", expectedIdentifier: "fixture-pulkit"),
    RecipientEvalCase(label: "Pulkit Polkit", spoken: "Polkit", expectedIdentifier: "fixture-pulkit"),
    RecipientEvalCase(label: "Pulkit Polka", spoken: "Polka", expectedIdentifier: "fixture-pulkit"),
    RecipientEvalCase(label: "Pulkit Palka", spoken: "Palka", expectedIdentifier: "fixture-pulkit"),
    RecipientEvalCase(label: "Aarav Arav", spoken: "Arav", expectedIdentifier: "fixture-aarav"),
    RecipientEvalCase(label: "Aarav Aravv", spoken: "Aravv", expectedIdentifier: "fixture-aarav"),
    RecipientEvalCase(label: "Aditi Adidi", spoken: "Adidi", expectedIdentifier: nil),
    RecipientEvalCase(label: "Aditi Adithi collision", spoken: "Adidi", expectedIdentifier: nil),
    RecipientEvalCase(label: "Siddharth Sidharth", spoken: "Sidharth", expectedIdentifier: "fixture-siddharth"),
    RecipientEvalCase(label: "Siddharth Sid Harth", spoken: "Sid Harth", expectedIdentifier: "fixture-siddharth"),
    RecipientEvalCase(label: "Siddharth Sidarth", spoken: "Sidarth", expectedIdentifier: "fixture-siddharth"),
    RecipientEvalCase(label: "Shreya Shraya", spoken: "Shraya", expectedIdentifier: "fixture-shreya"),
    RecipientEvalCase(label: "Shreya Shreeya", spoken: "Shreeya", expectedIdentifier: "fixture-shreya"),
    RecipientEvalCase(label: "Meera Mira", spoken: "Mira", expectedIdentifier: "fixture-no-number"),
    RecipientEvalCase(label: "Meera Krishnan", spoken: "Meera Krishnan", expectedIdentifier: "fixture-no-number"),
    RecipientEvalCase(label: "Rahul first-name tie", spoken: "Rahul", expectedIdentifier: nil),
    RecipientEvalCase(label: "Rahul lower tie", spoken: "rahul", expectedIdentifier: nil),
    RecipientEvalCase(label: "Rahul upper tie", spoken: "RAHUL", expectedIdentifier: nil),
    RecipientEvalCase(label: "Rohit first-name tie", spoken: "Rohit", expectedIdentifier: nil),
    RecipientEvalCase(label: "Rohit lower tie", spoken: "rohit", expectedIdentifier: nil),
    RecipientEvalCase(label: "Rohit upper tie", spoken: "ROHIT", expectedIdentifier: nil),
    RecipientEvalCase(label: "unknown Bartholomew", spoken: "Bartholomew", expectedIdentifier: nil),
    RecipientEvalCase(label: "unknown Xavier Quinlan", spoken: "Xavier Quinlan", expectedIdentifier: nil),
    RecipientEvalCase(label: "unknown Xzqwptl", spoken: "Xzqwptl", expectedIdentifier: nil),
    RecipientEvalCase(label: "unknown Kavya", spoken: "Kavya", expectedIdentifier: nil),
    RecipientEvalCase(label: "unknown Priyanka", spoken: "Priyanka", expectedIdentifier: nil),
    RecipientEvalCase(label: "unknown Rahul Kapoor", spoken: "Rahul Kapoor", expectedIdentifier: nil),
    RecipientEvalCase(label: "unknown Siddharth Kapoor", spoken: "Siddharth Kapoor", expectedIdentifier: nil),
    RecipientEvalCase(label: "unknown Pulkit Verma", spoken: "Pulkit Verma", expectedIdentifier: nil),
    RecipientEvalCase(label: "unknown Meera Sharma", spoken: "Meera Sharma", expectedIdentifier: nil),
    RecipientEvalCase(label: "fragment hi", spoken: "hi", expectedIdentifier: nil),
    RecipientEvalCase(label: "fragment jo", spoken: "jo", expectedIdentifier: nil),
    RecipientEvalCase(label: "empty spoken", spoken: "", expectedIdentifier: nil),
    RecipientEvalCase(label: "punctuation only", spoken: "!!!", expectedIdentifier: nil),
    RecipientEvalCase(label: "wrong surname for Pulkit", spoken: "Pulkit Verma", expectedIdentifier: nil),
    RecipientEvalCase(label: "wrong surname for Aarav", spoken: "Aarav Sharma", expectedIdentifier: nil),
    RecipientEvalCase(label: "phonetic Adithi full name", spoken: "Aditi Menon", expectedIdentifier: "eval-adithi"),
    RecipientEvalCase(label: "wrong surname for Shreya", spoken: "Shreya Rao", expectedIdentifier: nil),
    RecipientEvalCase(label: "phonetic twin Adidi", spoken: "Adidi", expectedIdentifier: nil),
    RecipientEvalCase(label: "phonetic Adithi full name", spoken: "Adidi Menon", expectedIdentifier: "eval-adithi"),
    RecipientEvalCase(label: "short Sid", spoken: "Sid", expectedIdentifier: nil),
    RecipientEvalCase(label: "short Roh", spoken: "Roh", expectedIdentifier: nil),
    RecipientEvalCase(label: "wrong Sid Kapoor", spoken: "Siddharth Kapoor", expectedIdentifier: nil),
    RecipientEvalCase(label: "wrong Meera Nair", spoken: "Meera Nair", expectedIdentifier: nil),
    RecipientEvalCase(label: "wrong Stone Sharma", spoken: "Stone Sharma", expectedIdentifier: nil),
    RecipientEvalCase(label: "organization-like unknown", spoken: "Acme", expectedIdentifier: nil),
    RecipientEvalCase(label: "mixed unknown", spoken: "Aarav Quinlan", expectedIdentifier: nil),
    RecipientEvalCase(label: "mixed unknown two", spoken: "Rahul Krishnan", expectedIdentifier: nil),
    RecipientEvalCase(label: "mixed unknown three", spoken: "Pulkit Kapoor", expectedIdentifier: nil),
    RecipientEvalCase(label: "mixed unknown four", spoken: "Shreya Sharma", expectedIdentifier: nil),
    RecipientEvalCase(label: "mixed unknown five", spoken: "Aditi Verma", expectedIdentifier: nil),
    RecipientEvalCase(label: "mixed unknown six", spoken: "Siddharth Sharma", expectedIdentifier: nil),
]
