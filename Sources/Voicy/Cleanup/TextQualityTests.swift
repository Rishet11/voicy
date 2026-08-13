import Foundation

// MARK: - Text quality corpus
//
// Table-driven, in the house style of Testing/UnitTests.swift (plain functions,
// no XCTest). Each row is a realistic messy dictation and the text a person
// would have typed instead. Rows are grouped by the failure they cover.
//
// Rule for this file: a row is never softened to make it pass. If something is
// not deterministically solvable it is written up in TEXT-NOTES.md and left out
// of the table, not asserted loosely.

/// One corpus row: what was heard, what should be sent.
struct TextCase {
    let heard: String
    let want: String
    let label: String
}

public func runTextQualityTests() -> (passed: Int, failed: Int) {
    var t = TestRun("text-quality")

    for c in textCorpus {
        t.equal(TextFormatter.format(c.heard), c.want, c.label)
    }

    // Idempotence: formatting already-clean text must be a no-op. Catches rules
    // that fire on their own output (e.g. a second pass eating a real "period").
    for c in textCorpus {
        t.equal(TextFormatter.format(c.want), c.want, "idempotent: \(c.label)")
    }

    // Degenerate inputs must not crash or invent text.
    t.equal(TextFormatter.format(""), "", "empty input")
    t.equal(TextFormatter.format("   "), "   ", "whitespace-only input")
    t.equal(TextFormatter.format("um"), "Um", "a lone filler is kept rather than emptying the message")

    return t.result
}

let textCorpus: [TextCase] = [

    // MARK: Fillers, stutters, false starts

    TextCase(heard: "um I will be there in ten minutes",
             want: "I will be there in 10 minutes",
             label: "leading filler dropped"),
    TextCase(heard: "I will uh be there soon",
             want: "I will be there soon",
             label: "mid-sentence filler dropped"),
    TextCase(heard: "I I will be there",
             want: "I will be there",
             label: "single-word stutter dropped"),
    TextCase(heard: "I was I was going to call you",
             want: "I was going to call you",
             label: "two-word false start dropped"),
    TextCase(heard: "can you can you send me the file",
             want: "Can you send me the file",
             label: "three-word false start dropped"),
    TextCase(heard: "I will like be there",
             want: "I will like be there",
             label: "\"like\" is content, never dropped"),
    TextCase(heard: "you know I will be there",
             want: "You know I will be there",
             label: "\"you know\" is content, never dropped"),
    TextCase(heard: "that report is done. that report was late",
             want: "That report is done. That report was late",
             label: "a genuine repetition across sentences survives"),

    // MARK: Self-correction

    TextCase(heard: "tell Mom I'll be late, actually no, I'll be on time",
             want: "Tell Mom I'll be on time",
             label: "\"actually no\" retracts back to the aligned phrase"),
    TextCase(heard: "send it to Rahul, sorry, Rohit",
             want: "Send it to Rohit",
             label: "\"sorry\" between commas replaces the wrong name"),
    TextCase(heard: "let's meet at five, scratch that, at six",
             want: "Let's meet at 6",
             label: "\"scratch that\" retracts the aligned phrase"),
    TextCase(heard: "I'll be there at seven, no wait, eight",
             want: "I'll be there at 8",
             label: "\"no wait\" replaces the last token"),
    TextCase(heard: "sorry I am late",
             want: "Sorry I am late",
             label: "a genuine apology is not a correction marker"),
    TextCase(heard: "I am sorry about yesterday",
             want: "I am sorry about yesterday",
             label: "mid-sentence \"sorry\" without commas is content"),

    // MARK: Spoken punctuation and formatting

    TextCase(heard: "I am on my way period see you soon",
             want: "I am on my way. See you soon",
             label: "spoken period ends the sentence and capitalizes the next"),
    TextCase(heard: "sure comma will do",
             want: "Sure, will do",
             label: "spoken comma"),
    TextCase(heard: "are you free tomorrow question mark",
             want: "Are you free tomorrow?",
             label: "spoken question mark"),
    TextCase(heard: "that is great exclamation mark",
             want: "That is great!",
             label: "spoken exclamation mark"),
    TextCase(heard: "hi new line I am running late",
             want: "Hi\nI am running late",
             label: "spoken new line"),
    TextCase(heard: "here is the plan new paragraph we ship on Friday",
             want: "Here is the plan\n\nWe ship on Friday",
             label: "spoken new paragraph"),
    TextCase(heard: "put a period at the end of the sentence",
             want: "Put a period at the end of the sentence",
             label: "\"a period\" is content, not a dictated mark"),
    TextCase(heard: "the comma is missing here",
             want: "The comma is missing here",
             label: "\"the comma\" is content, not a dictated mark"),
    TextCase(heard: "he said quote I am coming unquote and hung up",
             want: "He said \"I am coming\" and hung up",
             label: "quote ... unquote wraps the span"),

    // MARK: Numbers, times, dates, money, contact details

    TextCase(heard: "my email is rishet at gmail dot com",
             want: "My email is rishet@gmail.com",
             label: "spoken email address"),
    TextCase(heard: "check google dot com for it",
             want: "Check google.com for it",
             label: "spoken domain"),
    TextCase(heard: "my number is nine eight seven six five four three two one zero",
             want: "My number is 9876543210",
             label: "spoken phone number"),
    TextCase(heard: "call me on nine eight double seven six five four three two",
             want: "Call me on 987765432",
             label: "\"double\" inside a spoken number"),
    TextCase(heard: "meet at four thirty pm",
             want: "Meet at 4:30 PM",
             label: "spoken time with minutes"),
    TextCase(heard: "the call is at nine am",
             want: "The call is at 9 AM",
             label: "spoken time on the hour"),
    TextCase(heard: "it cost twenty five dollars",
             want: "It cost $25",
             label: "spoken money in dollars"),
    TextCase(heard: "transfer five hundred rupees",
             want: "Transfer ₹500",
             label: "spoken money in rupees"),
    TextCase(heard: "we are at eighty percent",
             want: "We are at 80%",
             label: "spoken percentage"),
    TextCase(heard: "the deadline is june twelfth",
             want: "The deadline is June 12",
             label: "spoken date"),
    TextCase(heard: "one of my friends is coming",
             want: "One of my friends is coming",
             label: "a small standalone number stays a word"),
    TextCase(heard: "I need twenty five copies",
             want: "I need 25 copies",
             label: "a compound number becomes digits"),

    // MARK: Capitalization

    TextCase(heard: "i think i will come",
             want: "I think I will come",
             label: "standalone i becomes I"),
    TextCase(heard: "i'll call you when i'm free",
             want: "I'll call you when I'm free",
             label: "i-contractions capitalized"),
    TextCase(heard: "send it asap",
             want: "Send it ASAP",
             label: "acronym uppercased"),
    TextCase(heard: "what is the eta",
             want: "What is the ETA",
             label: "acronym after an article"),

    // MARK: Hinglish

    TextCase(heard: "main thoda late hoon, ghar pe milte hain",
             want: "Main thoda late hoon, ghar pe milte hain",
             label: "Hindi words are not touched"),
    TextCase(heard: "um yaar I will reach in twenty minutes",
             want: "Yaar I will reach in 20 minutes",
             label: "filler removed around Hinglish, \"yaar\" kept"),
    TextCase(heard: "haan bhai theek hai, kal milte hain",
             want: "Haan bhai theek hai, kal milte hain",
             label: "\"haan\" is not treated as the filler \"ah\""),
    TextCase(heard: "kal subah nine am ka plan hai",
             want: "Kal subah 9 AM ka plan hai",
             label: "time formatting inside a Hinglish sentence"),

    // MARK: Trailing send cues

    TextCase(heard: "I am reaching in five minutes send it",
             want: "I am reaching in 5 minutes",
             label: "trailing \"send it\" is not message body"),
    TextCase(heard: "please bring the charger that's it",
             want: "Please bring the charger",
             label: "trailing \"that's it\" is not message body"),
    TextCase(heard: "meeting moved to three over",
             want: "Meeting moved to 3",
             label: "trailing \"over\" is not message body"),
    TextCase(heard: "send me the file when you can",
             want: "Send me the file when you can",
             label: "a leading \"send\" is content, not a cue"),
]
