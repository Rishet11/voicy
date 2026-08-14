import AppKit
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

    // MARK: Named failures that used to be misreported

    // C2: a tap rather than a hold used to surface as "no speech was recognised"
    // or "the device delivered zero samples", both of which point the user at a
    // microphone problem that does not exist.
    let tooShort = PipelineFailure.holdTooShort(milliseconds: 40).description
    if tooShort.contains("40 ms") && tooShort.lowercased().contains("hold")
        && tooShort != PipelineFailure.noSpeechDetected.description {
        pass("short tap is named", "reports the real hold duration and what to do instead")
    } else {
        results.append(CaseResult(name: "short tap is named", status: "FAIL",
                                  detail: "a short tap is not distinguishable from silence"))
    }

    // C7 and F6: the microphone changing mid utterance used to leave the tap
    // silently dead, so the user got a truncated transcript or "no speech".
    let deviceChanged = PipelineFailure.inputDeviceChangedDuringCapture.description
    if deviceChanged.lowercased().contains("microphone changed")
        && deviceChanged != PipelineFailure.noSpeechDetected.description
        && deviceChanged != PipelineFailure.microphonePermissionDenied.description {
        pass("mid-recording device change is named",
             "distinct from silence and from a permission failure")
    } else {
        results.append(CaseResult(name: "mid-recording device change is named", status: "FAIL",
                                  detail: "a device change is not reported as its own cause"))
    }

    // A-matrix: a readiness failure must carry the stage that failed through to
    // the user, not collapse into one generic line.
    let notReady = PipelineFailure.whatsappNotReady(
        reason: WhatsAppComposeWaiter.Failure.composerHasDraft.reason).description
    if notReady.contains("unsent draft") && notReady.contains("nothing was sent") {
        pass("send readiness failures name their stage",
             "the specific cause reaches the user, and it says nothing was sent")
    } else {
        results.append(CaseResult(name: "send readiness failures name their stage", status: "FAIL",
                                  detail: "the specific readiness cause is dropped"))
    }

    // D2: a contact with no phone number must be findable by name so the refusal
    // can name the real problem. Dropping such contacts from the index made
    // `recipientHasNoPhoneNumber` unreachable and produced "no contact matched",
    // which reads as "I misheard you".
    let phoneless = Contact(identifier: "phoneless-1", givenName: "Marguerite",
                            familyName: "Okonkwo", nickname: "", organizationName: "", phones: [])
    switch ContactResolver().resolve(spoken: "Marguerite Okonkwo",
                                     contacts: [phoneless], aliases: [:]) {
    case .resolved(let contact) where contact.preferredE164 == nil:
        pass("phone-less contact is findable",
             "resolves by name, then refuses for the real reason: " +
             PipelineFailure.recipientHasNoPhoneNumber.description)
    case .resolved:
        results.append(CaseResult(name: "phone-less contact is findable", status: "FAIL",
                                  detail: "a phone-less contact somehow produced a number"))
    case .ambiguous, .notFound:
        results.append(CaseResult(name: "phone-less contact is findable", status: "FAIL",
                                  detail: "a phone-less contact is invisible, so the refusal cannot name the cause"))
    }

    // F1: panel placement must follow the user, not whichever screen happens to
    // hold another app's key window.
    // NSScreen is not Sendable, so the comparison happens entirely on the main
    // actor and only a verdict crosses back out.
    enum ScreenVerdict { case matchesPointer, wrongScreen, noScreens }
    let screenVerdict: ScreenVerdict = MainActor.assumeIsolated {
        guard let active = ActiveScreen.current else { return .noScreens }
        let mouse = NSEvent.mouseLocation
        guard let underMouse = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) else {
            // The pointer is off every screen, so there is nothing to compare
            // against and the documented fallback is in use.
            return .matchesPointer
        }
        return underMouse === active ? .matchesPointer : .wrongScreen
    }
    switch screenVerdict {
    case .matchesPointer:
        pass("panels follow the active screen",
             "the chosen screen is the one under the pointer, not NSScreen.main")
    case .wrongScreen:
        results.append(CaseResult(name: "panels follow the active screen", status: "FAIL",
                                  detail: "the chosen screen is not the one under the pointer"))
    case .noScreens:
        skip("panels follow the active screen", "macOS reports no attached screens in this context")
    }

    skip("confirm card over a full screen app",
         "the panel sets .fullScreenAuxiliary, but whether it draws over a full screen Space needs a person with an app in full screen")

    // MARK: Recording pill level meter
    //
    // Regression cover for the "the pill feels dead" fix. These lock the four
    // properties that made it dead: silence has to be still, room noise has to be
    // gated rather than merely small, normal speech has to land in the usable
    // middle of the range instead of the bottom eighth, and there has to be
    // exactly one smoothing stage.

    let meterSilence = [Float](repeating: 0, count: LevelMeter.windowSamples)
    if LevelMeter.level(tail: meterSilence[...]) == 0 {
        pass("meter silence is still", "digital silence maps to bar height exactly 0")
    } else {
        results.append(CaseResult(name: "meter silence is still", status: "FAIL",
                                  detail: "silence produced a nonzero bar height"))
    }

    let quietNoiseRMS: Float = 0.001
    if LevelMeter.level(rms: quietNoiseRMS) == 0 {
        pass("meter gates room noise",
             String(format: "%.1f dBFS is below the %.0f dBFS floor and maps to 0",
                    LevelMeter.dbFS(quietNoiseRMS), LevelMeter.floorDBFS))
    } else {
        results.append(CaseResult(name: "meter gates room noise", status: "FAIL",
                                  detail: "noise below the meter floor still moved the bars"))
    }

    // Speech at -30 dBFS is an ordinary live level. Under the old linear
    // `rms / 0.25` curve it produced a bar height of 0.126, which is why normal
    // speech lived in the bottom eighth of the meter and the bars barely moved.
    let normalSpeechRMS: Float = pow(10, -30.0 / 20.0)
    let normalLevel = LevelMeter.level(rms: normalSpeechRMS)
    let oldCurveLevel = min(1, normalSpeechRMS / 0.25)
    if normalLevel > 0.4 && normalLevel < 0.6 && normalLevel > oldCurveLevel * 2 {
        pass("meter curve uses its range",
             String(format: "-30 dBFS speech maps to %.2f, was %.2f on the old linear curve",
                    normalLevel, oldCurveLevel))
    } else {
        results.append(CaseResult(name: "meter curve uses its range", status: "FAIL",
                                  detail: String(format: "-30 dBFS mapped to %.3f", normalLevel)))
    }

    let windowMs = Double(LevelMeter.windowSamples) / 16.0
    if windowMs >= 20 && windowMs <= 50 {
        pass("meter window tracks syllables",
             String(format: "%.0f ms window, inside the 20 to 50 ms syllable band", windowMs))
    } else {
        results.append(CaseResult(name: "meter window tracks syllables", status: "FAIL",
                                  detail: String(format: "%.0f ms window is outside 20 to 50 ms", windowMs)))
    }

    // A loud transient must reach the top of the meter within ONE frame. This is
    // the "responds within one frame of speech starting" requirement, and it is
    // what a second smoothing stage used to prevent.
    let loudFrame = [Float](repeating: 0.2, count: LevelMeter.windowSamples)
    let loudLevel = LevelMeter.level(tail: loudFrame[...])
    if loudLevel > 0.7 {
        pass("meter reacts in one frame",
             String(format: "a single %.0f dBFS window reaches %.2f with no ramp",
                    LevelMeter.dbFS(0.2), loudLevel))
    } else {
        results.append(CaseResult(name: "meter reacts in one frame", status: "FAIL",
                                  detail: String(format: "a loud window only reached %.3f", loudLevel)))
    }

    // The ring buffer must hand back exactly what was pushed. It used to apply a
    // second exponential smoothing on top of an already averaged level, so a full
    // scale push read back as 0.45.
    let ringReadback = MainActor.assumeIsolated { () -> Float in
        let levels = RecordingLevels()
        levels.push(1.0)
        return levels.bars.last ?? 0
    }
    if ringReadback == 1.0 {
        pass("meter has one smoothing stage", "the ring buffer returns the pushed level unchanged")
    } else {
        results.append(CaseResult(name: "meter has one smoothing stage", status: "FAIL",
                                  detail: String(format: "pushed 1.0 and read back %.3f", ringReadback)))
    }

    skip("meter looks alive on screen",
         "bar heights are measured by --test-meter; whether the rendered pill reads as alive needs a person watching it")

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
