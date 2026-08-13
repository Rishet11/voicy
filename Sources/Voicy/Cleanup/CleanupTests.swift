import Foundation

// Plain-function test suite matching the house style in Sources/Voicy/Testing/UnitTests.swift
// (no XCTest; this is a single executable SPM target).

public func runCleanupTests() -> (passed: Int, failed: Int) {
    var t = TestRun("cleanup")

    // --- rulesOnly: fillers
    t.equal(TranscriptCleaner.rulesOnly("um I will be there"), "I will be there", "leading filler removed")
    t.equal(TranscriptCleaner.rulesOnly("I will uh be there"), "I will be there", "mid-sentence filler removed")
    t.equal(TranscriptCleaner.rulesOnly("I will be there um"), "I will be there", "trailing filler removed")

    // --- rulesOnly: stutters
    t.equal(TranscriptCleaner.rulesOnly("I I will be there"), "I will be there", "leading repeated word removed")
    t.equal(TranscriptCleaner.rulesOnly("I will be there there"), "I will be there", "trailing repeated word removed")
    t.equal(TranscriptCleaner.rulesOnly("I will will be there"), "I will be there", "mid repeated word removed")

    // --- rulesOnly: unchanged text
    t.equal(TranscriptCleaner.rulesOnly("I will be there"), "I will be there", "clean text unchanged")

    // --- rulesOnly: empty / whitespace, no crash
    t.equal(TranscriptCleaner.rulesOnly(""), "", "empty string handled")
    t.equal(TranscriptCleaner.rulesOnly("   "), "   ", "whitespace-only handled")

    // --- rulesOnly: all-fillers returns original unchanged (would otherwise empty out)
    t.equal(TranscriptCleaner.rulesOnly("um uh erm"), "um uh erm", "all-filler sentence returns original")

    // --- rulesOnly: words we must NOT remove
    t.equal(TranscriptCleaner.rulesOnly("I will like be there"), "I will like be there", "'like' preserved")
    t.equal(TranscriptCleaner.rulesOnly("you know I will be there"), "you know I will be there", "'you know' preserved")
    t.equal(TranscriptCleaner.rulesOnly("actually I will be there"), "actually I will be there", "'actually' preserved")
    t.equal(TranscriptCleaner.rulesOnly("basically I will be there"), "basically I will be there", "'basically' preserved")

    // --- rulesOnly: non-adjacent repeats must be preserved (deleting them would
    // be an over-aggressive, non-conservative edit — "that report" appearing
    // twice in a sentence is a legitimate repetition, not a stutter).
    t.equal(TranscriptCleaner.rulesOnly("that report is done, that report was late"),
            "that report is done, that report was late",
            "non-adjacent repeated words preserved")

    // --- rulesOnly: casing/punctuation preserved on kept words
    t.equal(TranscriptCleaner.rulesOnly("Um, I will be there."), "I will be there.", "leading filler with punctuation removed, rest untouched")

    // --- rulesOnly: repeated fillers, in every position
    t.equal(TranscriptCleaner.rulesOnly("um um I will be there"), "I will be there", "repeated leading fillers removed")
    t.equal(TranscriptCleaner.rulesOnly("I will uh uh be there"), "I will be there", "repeated mid fillers removed")
    t.equal(TranscriptCleaner.rulesOnly("I will be there um uh"), "I will be there", "run of different trailing fillers removed")
    t.equal(TranscriptCleaner.rulesOnly("um I uh will erm be hmm there"), "I will be there", "a filler between every word removed")

    // --- rulesOnly: a filler word that is a real word in context must be kept.
    // "ER" is a place you go, not an "er": an all-caps token is an acronym.
    t.equal(TranscriptCleaner.rulesOnly("take him to the ER now"), "take him to the ER now", "acronym ER kept, not treated as a filler")
    t.equal(TranscriptCleaner.rulesOnly("the AH gate is closed"), "the AH gate is closed", "acronym AH kept, not treated as a filler")
    t.check(!TranscriptCleaner.isFiller("ER"), "isFiller says an acronym is not a filler")
    t.check(TranscriptCleaner.isFiller("er"), "isFiller says a lowercase er is a filler")

    // --- rulesOnly: multi-word false starts (the same rule TextFormatter uses)
    t.equal(TranscriptCleaner.rulesOnly("I was I was going to call you"), "I was going to call you", "two-word false start removed")
    t.equal(TranscriptCleaner.rulesOnly("can you can you send me the file"), "can you send me the file", "three-word false start removed")

    // --- rulesOnly: a deleted filler must not take a sentence mark with it
    t.equal(TranscriptCleaner.rulesOnly("I am on my way um."), "I am on my way.", "full stop rescued off a deleted filler")

    // --- rulesOnly over the dictation corpus: never empty, always deletion-only,
    // and never in disagreement with TextFormatter about what a disfluency is.
    for c in textCorpus {
        let cleaned = TranscriptCleaner.rulesOnly(c.heard)
        t.check(!cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "corpus row is never emptied: \(c.label)")
        t.check(TranscriptCleaner.isDeletionOnly(original: c.heard, cleaned: cleaned),
                "corpus row stays deletion-only: \(c.label)")
        let viaFormatter = TextFormatter.removeDisfluencies(c.heard.split(separator: " ").map(String.init))
        t.equal(cleaned, viaFormatter.joined(separator: " "),
                "both disfluency passes agree: \(c.label)")
    }

    // --- isDeletionOnly: basic true/false cases
    t.check(TranscriptCleaner.isDeletionOnly(original: "I will be there in ten", cleaned: "I will be there"),
            "trailing deletion is deletion-only")
    t.check(!TranscriptCleaner.isDeletionOnly(original: "I will be there", cleaned: "I'll be there"),
            "contraction rewrite is rejected")
    t.check(!TranscriptCleaner.isDeletionOnly(original: "I will be there", cleaned: "I will definitely be there"),
            "added word is rejected")
    t.check(!TranscriptCleaner.isDeletionOnly(original: "I will be there", cleaned: "be there I will"),
            "reordering is rejected")
    t.check(TranscriptCleaner.isDeletionOnly(original: "Hello, world", cleaned: "hello world"),
            "case and punctuation ignored")

    // --- isDeletionOnly: fillers mid-sentence
    t.check(TranscriptCleaner.isDeletionOnly(original: "I will um be there uh soon", cleaned: "I will be there soon"),
            "mid-sentence fillers deleted is deletion-only")

    // --- isDeletionOnly: repeated word at very start and very end
    t.check(TranscriptCleaner.isDeletionOnly(original: "I I will be there there", cleaned: "I will be there"),
            "repeats at start and end collapse to deletion-only")

    t.check(!TranscriptCleaner.isDeletionOnly(original: "I will be there", cleaned: "I will be there there"),
            "adding an extra word (even a duplicate) is rejected")

    var (passed, failed) = t.result

    // These suites live in Cleanup/ and Contacts/ and are wired in here so that
    // `--unit-tests` runs them without Testing/TestHarness.swift needing to know
    // about every file. Their counts fold into the "cleanup" line.
    for suite in [runTextQualityTests(), runRecipientTests(), runPhoneticTests()] {
        passed += suite.passed
        failed += suite.failed
    }

    return (passed, failed)
}
