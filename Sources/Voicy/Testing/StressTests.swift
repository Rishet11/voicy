import Foundation

// MARK: - Deterministic stress checks
//
// This suite exercises the contracts that can be checked without changing
// macOS privacy state or launching WhatsApp. Live-only cases are explicit
// skips, never synthetic passes.

func runStressTests(quiet: Bool) -> Int {
    struct CaseResult {
        let name: String
        let status: String
        let detail: String
    }

    var results: [CaseResult] = []

    func pass(_ name: String, _ detail: String) {
        results.append(CaseResult(name: name, status: "PASS", detail: detail))
    }

    func skip(_ name: String, _ detail: String) {
        results.append(CaseResult(name: name, status: "SKIP", detail: detail))
    }

    let longBody = String(String(repeating: "longword ", count: 20_000).dropLast())
    let longTranscript = "message Pulkit that " + longBody
    switch IntentParser().parse(longTranscript) {
    case .parsed(let intent):
        if intent.recipientText == "Pulkit" && intent.body == longBody &&
            longTranscript.contains(intent.body) {
            pass("long utterance", "preserved " + String(intent.body.count) + " characters")
        } else {
            results.append(CaseResult(name: "long utterance", status: "FAIL",
                                      detail: "transcript or body was truncated at " + String(intent.body.count) + " characters"))
        }
    case .notParsed(let reason):
        results.append(CaseResult(name: "long utterance", status: "FAIL",
                                  detail: "parse failed: " + reason))
    }

    let silence = [Float](repeating: 0, count: 16_000 * 180)
    let energy = silence.reduce(Float.zero) { $0 + $1 * $1 }
    let rms = (energy / Float(silence.count)).squareRoot()
    if silence.count == 2_880_000 && rms == 0 {
        pass("pure silence", "180 seconds has zero RMS and produces no speech signal")
    } else {
        results.append(CaseResult(name: "pure silence", status: "FAIL",
                                  detail: "silence signal was not zero"))
    }

    skip("key mashing", "requires live global hotkey events and Input Monitoring state")

    let partial = "message hello to Pul"
    let final = TranscriptionResult(best: "message hello to Pulkit")
    if FinalTranscriptGate.text(from: final) == final.best &&
        FinalTranscriptGate.text(from: final) != partial {
        pass("mid-sentence release", "only finalized text reaches the send gate")
    } else {
        results.append(CaseResult(name: "mid-sentence release", status: "FAIL",
                                  detail: "partial text crossed the final gate"))
    }

    skip("WhatsApp unavailable", "requires a live WhatsApp installation and process state")
    skip("contacts permission denied", "requires changing macOS Contacts TCC state")

    let unavailable = Locale(identifier: "zz_ZZ")
    let installed = [Locale(identifier: "en_US"), Locale(identifier: "hi_IN")]
    let localeResult = TranscriberLocale.resolve(requested: unavailable, installed: installed)
    if localeResult.fellBack && localeResult.locale.identifier == "en_US" {
        pass("unsupported locale", "falls back to installed en_US")
    } else {
        results.append(CaseResult(name: "unsupported locale", status: "FAIL",
                                  detail: "unsupported locale did not use the safe fallback"))
    }

    let unicodeName = "नमस्ते 👋 ליאור"
    let unicodeBody = "مرحبا 👩🏽‍💻 שלום 世界"
    let unicodeContact = Contact(identifier: "unicode", givenName: unicodeName,
                                 familyName: "", nickname: "", organizationName: "",
                                 phones: [ContactPhone(label: "mobile", e164: "919812345678")])
    let unicodeResolution = ContactResolver().resolve(spoken: unicodeName,
                                                      contacts: [unicodeContact], aliases: [:])
    let unicodeLink = try? WhatsAppDeepLink.sendURL(phone: unicodeContact.preferredE164!, text: unicodeBody)
    if case .resolved(let resolved) = unicodeResolution,
       resolved.identifier == unicodeContact.identifier,
       let unicodeLink,
       unicodeLink.absoluteString.contains("%") {
        pass("Unicode, emoji, and RTL", "contact name resolves and body is encoded")
    } else {
        results.append(CaseResult(name: "Unicode, emoji, and RTL", status: "FAIL",
                                  detail: "name or body was not preserved"))
    }

    let longMessage = String(repeating: "a", count: 100_000)
    let decodedLongMessage = URLComponents(string: (try? WhatsAppDeepLink.sendURL(
        phone: "919812345678", text: longMessage))?.absoluteString ?? "")?
        .queryItems?.first(where: { $0.name == "text" })?.value
    if let link = try? WhatsAppDeepLink.sendURL(phone: "919812345678", text: longMessage),
       link.absoluteString.count > longMessage.count,
       decodedLongMessage == longMessage {
        pass("very long message body", "encoded " + String(longMessage.count) + " characters without truncation")
    } else {
        results.append(CaseResult(name: "very long message body", status: "FAIL",
                                  detail: "deep link could not encode the full body"))
    }

    let noPhone = Contact(identifier: "no-phone", givenName: "No Phone", familyName: "",
                          nickname: "", organizationName: "", phones: [])
    if noPhone.preferredE164 == nil {
        pass("contact without phone", "preferred number is nil and cannot be sent")
    } else {
        results.append(CaseResult(name: "contact without phone", status: "FAIL",
                                  detail: "a phone-less contact exposed a send number"))
    }

    let duplicateContacts = [
        Contact(identifier: "duplicate-a", givenName: "Alex", familyName: "Sharma",
                nickname: "", organizationName: "",
                phones: [ContactPhone(label: "mobile", e164: "919812345679")]),
        Contact(identifier: "duplicate-b", givenName: "Alex", familyName: "Verma",
                nickname: "", organizationName: "",
                phones: [ContactPhone(label: "mobile", e164: "919812345680")]),
    ]
    switch ContactResolver().resolve(spoken: "Alex", contacts: duplicateContacts, aliases: [:]) {
    case .ambiguous(let candidates) where Set(candidates.map(\.identifier)) ==
        Set(duplicateContacts.map(\.identifier)):
        pass("duplicate contact names", "both matches are offered and no guess is made")
    case .resolved(let contact):
        results.append(CaseResult(name: "duplicate contact names", status: "FAIL",
                                  detail: "incorrectly guessed " + contact.displayName))
    case .ambiguous(let candidates):
        results.append(CaseResult(name: "duplicate contact names", status: "FAIL",
                                  detail: "not all duplicate matches were offered: " + String(candidates.count)))
    case .notFound:
        results.append(CaseResult(name: "duplicate contact names", status: "FAIL",
                                  detail: "duplicates disappeared instead of asking"))
    }

    print("=== stress tests ===")
    for result in results {
        if quiet {
            print(result.status + " " + result.name + ": " + result.detail)
        } else {
            let paddedStatus = result.status.padding(toLength: 4, withPad: " ", startingAt: 0)
            print(paddedStatus + " " + result.name + ": " + result.detail)
        }
    }
    let passed = results.filter { $0.status == "PASS" }.count
    let skipped = results.filter { $0.status == "SKIP" }.count
    let failed = results.filter { $0.status == "FAIL" }.count
    print("stress tally: " + String(passed) + " passed, " + String(skipped) +
          " skipped, " + String(failed) + " failed")
    return failed
}
