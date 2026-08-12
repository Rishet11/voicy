import Foundation

/// A fixed, deterministic contact set for the test harness.
///
/// The regression suite must produce the same result on any machine, so it does
/// not read the real address book by default (`--real-contacts` opts in). The
/// fixtures deliberately include the awkward cases:
///
/// - two people called "Rahul"      -> must come back `.ambiguous`, never a guess
/// - "Stone", a name that fuzzy-matches badly without contact-name biasing
/// - a contact with no phone number -> must be reported, never sent to
/// - a nickname that differs from the given name
///
/// The only real number here is the owner's (`917982913080`). Every other
/// number is in the reserved 91-98123-456xx block and belongs to nobody.
enum FixtureContacts {

    /// The one number Voicy is ever allowed to send to during testing.
    static let ownerE164 = "917982913080"

    static let all: [Contact] = [
        Contact(identifier: "fixture-pulkit",
                givenName: "Pulkit", familyName: "Sharma",
                nickname: "", organizationName: "",
                phones: [ContactPhone(label: "mobile", e164: ownerE164)]),

        Contact(identifier: "fixture-aarav",
                givenName: "Aarav", familyName: "Mehta",
                nickname: "", organizationName: "",
                phones: [ContactPhone(label: "mobile", e164: "919812345670")]),

        Contact(identifier: "fixture-rahul-sharma",
                givenName: "Rahul", familyName: "Sharma",
                nickname: "", organizationName: "",
                phones: [ContactPhone(label: "mobile", e164: "919812345671")]),

        Contact(identifier: "fixture-rahul-verma",
                givenName: "Rahul", familyName: "Verma",
                nickname: "", organizationName: "",
                phones: [ContactPhone(label: "mobile", e164: "919812345672")]),

        Contact(identifier: "fixture-shreya",
                givenName: "Shreya", familyName: "Iyer",
                nickname: "Shru", organizationName: "",
                phones: [ContactPhone(label: "iPhone", e164: "919812345673")]),

        Contact(identifier: "fixture-aditi",
                givenName: "Aditi", familyName: "Rao",
                nickname: "", organizationName: "",
                phones: [ContactPhone(label: "mobile", e164: "919812345674")]),

        Contact(identifier: "fixture-siddharth",
                givenName: "Siddharth", familyName: "Nair",
                nickname: "", organizationName: "",
                phones: [ContactPhone(label: "mobile", e164: "919812345675")]),

        Contact(identifier: "fixture-stone",
                givenName: "Stone", familyName: "Kapoor",
                nickname: "", organizationName: "",
                phones: [ContactPhone(label: "mobile", e164: "919812345676")]),

        // Deliberately phone-less: resolving this must succeed while SENDING to
        // it must fail loudly rather than silently doing nothing.
        Contact(identifier: "fixture-no-number",
                givenName: "Meera", familyName: "Krishnan",
                nickname: "", organizationName: "",
                phones: []),
    ]

    /// Every name string worth passing to the recognizer as a hint — the same
    /// shape `Pipeline.contactNames()` builds from the real address book.
    static var hints: [String] {
        all.flatMap { c in
            [c.givenName, c.familyName, c.nickname, c.organizationName, c.displayName]
                .filter { !$0.isEmpty }
        }
    }
}
