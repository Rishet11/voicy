import Foundation

// MARK: - In-module unit tests for the Intent parser (Intent/)
//
// `runIntentTests()` is intentionally main-free so it can live inside the app
// target without colliding with main.swift. The orchestrator (or a scratch
// harness compiled OUTSIDE the SPM package) invokes it and prints the counts.
//
// Build/run standalone (from repo root):
//   swiftc -swift-version 6 Sources/Voicy/Intent/IntentParser.swift \
//     Sources/Voicy/Intent/IntentTests.swift /tmp/voicy_intent_main.swift \
//     -o /tmp/voicy_intent_tests && /tmp/voicy_intent_tests

/// Runs every Intent parser test. Returns (passed, failed); prints each failure.
public func runIntentTests() -> (passed: Int, failed: Int) {
    var passed = 0
    var failed = 0

    func pass(_ label: String) {
        passed += 1
        print("PASS: \(label)")
    }

    func fail(_ label: String, _ detail: String) {
        failed += 1
        print("FAIL: \(label) — \(detail)")
    }

    /// Asserts a full parse: recipient, byte-identical body, and app.
    func expect(_ transcript: String, recipient: String, body: String,
                app: MessagingApp, _ label: String) {
        let parser = IntentParser()
        switch parser.parse(transcript) {
        case .parsed(let intent):
            var ok = true
            if intent.recipientText != recipient {
                ok = false
                fail(label, "recipient got '\(intent.recipientText)' want '\(recipient)'")
            }
            if intent.body != body {
                ok = false
                fail(label, "body got '\(intent.body)' want '\(body)'")
            }
            if intent.app != app {
                ok = false
                fail(label, "app got \(intent.app) want \(app)")
            }
            // Fidelity rule: the body must be a literal substring of the input.
            if !transcript.contains(intent.body) {
                ok = false
                fail(label, "body '\(intent.body)' is NOT a substring of the transcript")
            }
            if ok { pass(label) }
        case .notParsed(let reason):
            fail(label, "expected parsed, got notParsed(\(reason))")
        }
    }

    /// Asserts a transcript is rejected.
    func expectNotParsed(_ transcript: String, _ label: String) {
        let parser = IntentParser()
        switch parser.parse(transcript) {
        case .parsed(let intent):
            fail(label, "expected notParsed, got parsed(\(intent.recipientText): \(intent.body))")
        case .notParsed:
            pass(label)
        }
    }

    // MARK: Required phrasings

    expect("message Pulkit that I'll reach Bangalore tomorrow",
           recipient: "Pulkit", body: "I'll reach Bangalore tomorrow", app: .whatsapp,
           "connector 'that' stripped once")

    expect("message Pulkit saying I am late",
           recipient: "Pulkit", body: "I am late", app: .whatsapp,
           "connector 'saying'")

    expect("message Pulkit I am late",
           recipient: "Pulkit", body: "I am late", app: .whatsapp,
           "no connector, 'I' pronoun boundary")

    expect("tell Rahul Sharma that the meeting is at five",
           recipient: "Rahul Sharma", body: "the meeting is at five", app: .whatsapp,
           "multi-word name + 'that'")

    expect("send Aarav a message saying happy birthday",
           recipient: "Aarav", body: "happy birthday", app: .whatsapp,
           "'send X a message saying ...' filler + connector")

    expect("whatsapp Shreya I'll call you",
           recipient: "Shreya", body: "I'll call you", app: .whatsapp,
           "app verb 'whatsapp' -> .whatsapp")

    expect("telegram Pulkit that I am late",
           recipient: "Pulkit", body: "I am late", app: .telegram,
           "verb 'telegram' -> .telegram")

    expect("telegram Rahul Sharma that the meeting is at five",
           recipient: "Rahul Sharma", body: "the meeting is at five", app: .telegram,
           "telegram with a multi-word name")

    expect("telegram Pulkit I'll be there soon",
           recipient: "Pulkit", body: "I'll be there soon", app: .telegram,
           "telegram with pronoun boundary, no connector")

    expect("text Siddharth on my way",
           recipient: "Siddharth", body: "on my way", app: .whatsapp,
           "verb 'text' + 'on' preposition boundary")

    expect("message Pulkit ki main kal aaunga",
           recipient: "Pulkit", body: "main kal aaunga", app: .whatsapp,
           "Hinglish connector 'ki'")

    expect("hey voicy message Aditi that I'm outside",
           recipient: "Aditi", body: "I'm outside", app: .whatsapp,
           "optional wake phrase 'hey voicy'")

    expect("message Pulkit that that report is done",
           recipient: "Pulkit", body: "that report is done", app: .whatsapp,
           "second 'that' inside body is preserved")

    expect("message Pulkit, hello",
           recipient: "Pulkit", body: "hello", app: .whatsapp,
           "name terminated by comma, body after")

    expect("message Pulkit hello",
           recipient: "Pulkit", body: "hello", app: .whatsapp,
           "name terminated by pronoun-free body boundary")

    expect("tell Pulkit, I am late",
           recipient: "Pulkit", body: "I am late", app: .whatsapp,
           "tell with comma after recipient")

    expect("message Pulkit; hello",
           recipient: "Pulkit", body: "hello", app: .whatsapp,
           "semicolon terminates recipient")

    expect("message Pulkit: hello",
           recipient: "Pulkit", body: "hello", app: .whatsapp,
           "colon terminates recipient")

    expect("message Pulkit! hello",
           recipient: "Pulkit", body: "hello", app: .whatsapp,
           "exclamation mark terminates recipient")

    expect("message Pulkit? hello",
           recipient: "Pulkit", body: "hello", app: .whatsapp,
           "question mark terminates recipient")

    expect("tell Rahul Sharma the meeting is at five",
           recipient: "Rahul Sharma", body: "the meeting is at five", app: .whatsapp,
           "multi-word name, no connector, 'the' boundary")

    // MARK: Name-last — "to <Name>" recipient phrase (the main fix)

    expect("send hello to Pulkit",
           recipient: "Pulkit", body: "hello", app: .whatsapp,
           "name-last: 'send body to name'")

    expect("say hello to Pulkit",
           recipient: "Pulkit", body: "hello", app: .whatsapp,
           "name-last: verb 'say'")

    expect("send a message to Pulkit saying I am late",
           recipient: "Pulkit", body: "I am late", app: .whatsapp,
           "name-last: 'send a message to X saying ...' filler")

    expect("send I'll be there in ten minutes to Aarav",
           recipient: "Aarav", body: "I'll be there in ten minutes", app: .whatsapp,
           "name-last: multi-word body before 'to'")

    expect("message to Pulkit that I am late",
           recipient: "Pulkit", body: "I am late", app: .whatsapp,
           "name-last: leading 'to' + connector 'that'")

    expect("send this to Pulkit: I am late",
           recipient: "Pulkit", body: "I am late", app: .whatsapp,
           "name-last: trailing colon after name")

    expect("hey voicy send hello to Pulkit",
           recipient: "Pulkit", body: "hello", app: .whatsapp,
           "name-last: optional wake phrase")

    expect("send hello to Rahul Sharma",
           recipient: "Rahul Sharma", body: "hello", app: .whatsapp,
           "name-last: multi-word name in 'to' form")

    // MARK: Conjunction inserted before the connector (measured)
    //
    // The audio harness transcribed "Message Meera Krishnan that I am late" as
    // "Message Mira Krishna, and that I am late." and the body kept the "and".

    expect("Message Mira Krishna, and that I am late.",
           recipient: "Mira Krishna", body: "I am late.", app: .whatsapp,
           "inserted 'and' before connector is dropped")

    expect("message Pulkit so that I am late",
           recipient: "Pulkit", body: "I am late", app: .whatsapp,
           "inserted 'so' before connector is dropped")

    expect("send a message to Pulkit and saying I am late",
           recipient: "Pulkit", body: "I am late", app: .whatsapp,
           "name-last: inserted 'and' before connector is dropped")

    // A conjunction NOT followed by a connector is the user's own word and must
    // survive. Removing it would be rewriting them.
    expect("message Pulkit and I will call you",
           recipient: "Pulkit", body: "and I will call you", app: .whatsapp,
           "bare 'and' starting the body is preserved")

    expect("message Pulkit that and then we leave",
           recipient: "Pulkit", body: "and then we leave", app: .whatsapp,
           "connector first, then the user's own 'and'")

    // MARK: Verb dropped by the recognizer (measured, not hypothetical)
    //
    // The audio harness transcribed "Tell Siddharth that the file is ready" as
    // "Siddharth, that the file is ready." — the verb vanished. Accepting that
    // shape recovers the utterance; the cases below pin down exactly how far
    // that permissiveness goes.

    expect("Siddharth, that the file is ready.",
           recipient: "Siddharth", body: "the file is ready.", app: .whatsapp,
           "verb-less: name + comma + connector")

    expect("Pulkit, I am late",
           recipient: "Pulkit", body: "I am late", app: .whatsapp,
           "verb-less: name + comma + body")

    expect("Pulkit that I am late",
           recipient: "Pulkit", body: "I am late", app: .whatsapp,
           "verb-less: name + connector, no punctuation")

    expect("Rahul Sharma, I am late",
           recipient: "Rahul Sharma", body: "I am late", app: .whatsapp,
           "verb-less: two-word name + comma")

    // MARK: Rejections

    expectNotParsed("what is the weather", "no command verb")
    expectNotParsed("what is the weather in Bangalore today?",
                    "verb-less plain speech is not an address")
    expectNotParsed("I am running late", "verb-less sentence starting with a pronoun")
    expectNotParsed("Pulkit", "a bare name is not a message")
    expectNotParsed("Pulkit,", "a bare name with punctuation is not a message")
    expectNotParsed("hello there everyone", "no verb, no connector, no punctuation")

    // Ordinary speech that merely pauses after its first word must NOT become a
    // message addressed to somebody called "Actually".
    expectNotParsed("Actually, I think we should go", "discourse marker 'Actually,'")
    expectNotParsed("Look, I can't make it", "discourse marker 'Look,'")
    expectNotParsed("So, let's talk later", "discourse marker 'So,'")
    expectNotParsed("Well, that went badly", "discourse marker 'Well,'")
    expectNotParsed("Honestly, I am tired", "discourse marker 'Honestly,'")
    expectNotParsed("Hey, are you around", "discourse marker 'Hey,'")
    expectNotParsed("Sorry, I am late", "discourse marker 'Sorry,'")
    expectNotParsed("Wait, that is wrong", "discourse marker 'Wait,'")

    // ...but a real name in the same shape still works.
    expect("Aarav, I am late",
           recipient: "Aarav", body: "I am late", app: .whatsapp,
           "a real name in the verb-less shape still parses")
    expectNotParsed("message", "verb only, no recipient or body")
    expectNotParsed("", "empty transcript")

    return (passed, failed)
}
