import Foundation

// Plain-function test suite matching the house style in Sources/Voicy/Testing/UnitTests.swift
// (no XCTest; this is a single executable SPM target).

public func runCleanupTests() -> (passed: Int, failed: Int) {
    var t = TestRun("cleanup")

    // --- rulesOnly: fillers at start/middle/end (required)
    t.equal(TranscriptCleaner.rulesOnly("um I will be there"), "I will be there", "leading filler removed")
    t.equal(TranscriptCleaner.rulesOnly("I will uh be there"), "I will be there", "mid-sentence filler removed")
    t.equal(TranscriptCleaner.rulesOnly("I will be there um"), "I will be there", "trailing filler removed")
    t.equal(TranscriptCleaner.rulesOnly("erm I will be there"), "I will be there", "leading filler erm removed")
    t.equal(TranscriptCleaner.rulesOnly("I will be there er"), "I will be there", "trailing filler er removed")
    t.equal(TranscriptCleaner.rulesOnly("hmm I think so"), "I think so", "leading filler hmm removed")

    // --- rulesOnly: repeated fillers (required)
    t.equal(TranscriptCleaner.rulesOnly("um um I will be there"), "I will be there", "repeated leading fillers removed")
    t.equal(TranscriptCleaner.rulesOnly("I will be there um um"), "I will be there", "repeated trailing fillers removed")
    t.equal(TranscriptCleaner.rulesOnly("I um uh will be there"), "I will be there", "consecutive different fillers removed")
    t.equal(TranscriptCleaner.rulesOnly("um uh erm I will be there"), "I will be there", "three fillers at start removed")
    t.equal(TranscriptCleaner.rulesOnly("I will um um be there"), "I will be there", "repeated filler mid-sentence removed")

    // --- rulesOnly: stutters
    t.equal(TranscriptCleaner.rulesOnly("I I will be there"), "I will be there", "leading repeated word removed")
    t.equal(TranscriptCleaner.rulesOnly("I will be there there"), "I will be there", "trailing repeated word removed")
    t.equal(TranscriptCleaner.rulesOnly("I will will be there"), "I will be there", "mid repeated word removed")

    // --- rulesOnly: unchanged text
    t.equal(TranscriptCleaner.rulesOnly("I will be there"), "I will be there", "clean text unchanged")

    // --- rulesOnly: empty / whitespace, no crash (required)
    t.equal(TranscriptCleaner.rulesOnly(""), "", "empty string handled")
    t.equal(TranscriptCleaner.rulesOnly("   "), "   ", "whitespace-only handled")
    t.equal(TranscriptCleaner.rulesOnly("\n\t  "), "\n\t  ", "newline whitespace handled")

    // --- rulesOnly: all-fillers returns original unchanged (would otherwise empty out)
    t.equal(TranscriptCleaner.rulesOnly("um uh erm"), "um uh erm", "all-filler sentence returns original")
    t.equal(TranscriptCleaner.rulesOnly("um"), "um", "single filler returns original (not empty)")
    t.equal(TranscriptCleaner.rulesOnly("um um um"), "um um um", "repeated single filler type returns original")

    // --- rulesOnly: words we must NOT remove (filler word that is real word in context, required)
    t.equal(TranscriptCleaner.rulesOnly("I will like be there"), "I will like be there", "'like' preserved")
    t.equal(TranscriptCleaner.rulesOnly("you know I will be there"), "you know I will be there", "'you know' preserved")
    t.equal(TranscriptCleaner.rulesOnly("actually I will be there"), "actually I will be there", "'actually' preserved")
    t.equal(TranscriptCleaner.rulesOnly("basically I will be there"), "basically I will be there", "'basically' preserved")
    t.equal(TranscriptCleaner.rulesOnly("her umbrella is here"), "her umbrella is here", "'her' not treated as 'er', 'umbrella' not as 'um'")
    t.equal(TranscriptCleaner.rulesOnly("The umbrella is blue"), "The umbrella is blue", "'umbrella' preserved")
    t.equal(TranscriptCleaner.rulesOnly("I like her idea"), "I like her idea", "real words containing filler substrings preserved")
    t.equal(TranscriptCleaner.rulesOnly("Hmm, I think her answer is um good"), "I think her answer is good", "mixed fillers and real words with substrings")

    // --- rulesOnly: non-adjacent repeats must be preserved (deleting them would
    // be an over-aggressive, non-conservative edit — "that report" appearing
    // twice in a sentence is a legitimate repetition, not a stutter).
    t.equal(TranscriptCleaner.rulesOnly("that report is done, that report was late"),
            "that report is done, that report was late",
            "non-adjacent repeated words preserved")

    // --- rulesOnly: casing/punctuation preserved on kept words
    t.equal(TranscriptCleaner.rulesOnly("Um, I will be there."), "I will be there.", "leading filler with punctuation removed, rest untouched")
    t.equal(TranscriptCleaner.rulesOnly("I will, uh, be there"), "I will, be there", "filler with surrounding punctuation removed")
    // Span deletion guarantee: kept words are byte-identical slices
    let original = "Um I WILL be there"
    let cleaned = TranscriptCleaner.rulesOnly(original)
    t.check(cleaned == "I WILL be there", "kept words retain original casing via span deletion")
    t.check(TranscriptCleaner.isDeletionOnly(original: original, cleaned: cleaned), "span deletion is deletion-only")

    // --- rulesOnly: repeated fillers, in every position
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

    // --- hesitation matcher is a pattern, not a buried word list
    t.check(TranscriptCleaner.isFiller("um") && TranscriptCleaner.isFiller("uhh")
            && TranscriptCleaner.isFiller("umm") && TranscriptCleaner.isFiller("hmm"),
            "lengthened hesitation sounds still match the pattern")
    t.check(!TranscriptCleaner.isFiller("am") && !TranscriptCleaner.isFiller("I")
            && !TranscriptCleaner.isFiller("like") && !TranscriptCleaner.isFiller("matlab"),
            "real short words are not hesitation sounds")
    t.check(!LLMCleaner.instructions.localizedCaseInsensitiveContains("um, uh")
            && !LLMCleaner.instructions.localizedCaseInsensitiveContains("erm")
            && !LLMCleaner.instructions.localizedCaseInsensitiveContains("hmm"),
            "LLM prompt names the class, not a filler vocabulary")

    // --- shipping apply(): rules fallback still deletion-only when the model
    // sits this one out (empty input is the cheap nil path).
    t.equal(TranscriptCleaner.rulesOnly("um I will be there"), "I will be there",
            "rules fallback still drops hesitation sounds")

    var (passed, failed) = t.result
    // The on-device model cases are intentionally kept out of the fast unit
    // suite. They belong to the opt-in live-LLM verification run.

    // These suites live in Cleanup/ and Contacts/ and are wired in here so that
    // `--unit-tests` runs them without Testing/TestHarness.swift needing to know
    // about every file. Their counts fold into the "cleanup" line.
    for suite in [runTextQualityTests(), runRecipientTests(), runPhoneticTests()] {
        passed += suite.passed
        failed += suite.failed
    }

    return (passed, failed)
}

// MARK: - LLM pass + new disfluency cases

private struct LLMCase {
    let heard: String
    let mustKeep: [String]
    let mustDrop: [String]
    let label: String
}

/// Discourse-marker cases the old filler list could not see, plus the
/// load-bearing twins that must survive. `mustDrop` is asserted only when
/// the model actually returned a deletion-only result.
private let llmDisfluencyCases: [LLMCase] = [
    LLMCase(heard: "I will like be there", mustKeep: ["I", "will", "be", "there"],
            mustDrop: ["like"], label: "filler like dropped"),
    LLMCase(heard: "you know I will be there", mustKeep: ["I", "will", "be", "there"],
            mustDrop: ["you", "know"], label: "filler you know dropped"),
    LLMCase(heard: "I mean I will be there", mustKeep: ["I", "will", "be", "there"],
            mustDrop: ["mean"], label: "filler I mean dropped"),
    LLMCase(heard: "basically I will be there", mustKeep: ["I", "will", "be", "there"],
            mustDrop: ["basically"], label: "filler basically dropped"),
    LLMCase(heard: "actually I will be there", mustKeep: ["I", "will", "be", "there"],
            mustDrop: ["actually"], label: "filler actually dropped"),
    LLMCase(heard: "matlab I will be there", mustKeep: ["I", "will", "be", "there"],
            mustDrop: ["matlab"], label: "Hinglish hesitation matlab dropped"),
    LLMCase(heard: "arre I will be there", mustKeep: ["I", "will", "be", "there"],
            mustDrop: ["arre"], label: "Hinglish hesitation arre dropped"),
    LLMCase(heard: "I like it", mustKeep: ["I", "like", "it"],
            mustDrop: [], label: "load-bearing like kept"),
    LLMCase(heard: "you know the answer", mustKeep: ["you", "know", "the", "answer"],
            mustDrop: [], label: "load-bearing you know kept"),
    LLMCase(heard: "I mean what I say", mustKeep: ["I", "mean", "what", "say"],
            mustDrop: [], label: "load-bearing I mean kept"),
    LLMCase(heard: "this is basically ready", mustKeep: ["this", "is", "basically", "ready"],
            mustDrop: [], label: "load-bearing basically kept"),
    LLMCase(heard: "I actually like it", mustKeep: ["I", "actually", "like", "it"],
            mustDrop: [], label: "load-bearing actually and like kept"),
]

private func runLLMCleanupTests() -> (passed: Int, failed: Int) {
    var t = TestRun("llm-cleanup")

    // rulesOnly must still refuse to guess at discourse markers.
    t.equal(TranscriptCleaner.rulesOnly("matlab I will be there"),
            "matlab I will be there", "rules keep matlab")
    t.equal(TranscriptCleaner.rulesOnly("arre I will be there"),
            "arre I will be there", "rules keep arre")
    t.equal(TranscriptCleaner.rulesOnly("I like it"), "I like it", "rules keep I like it")
    t.equal(TranscriptCleaner.rulesOnly("you know the answer"),
            "you know the answer", "rules keep you know the answer")

    let applyEmpty = awaitForTests { await DisfluencyCleanup.apply("") }
    t.equal(applyEmpty.text, "", "apply on empty is a no-op")
    t.check(TranscriptCleaner.isDeletionOnly(original: "", cleaned: applyEmpty.text),
            "apply on empty stays deletion-only")

    print("  llm-cleanup: warming on-device model")
    awaitForTests { await LLMCleaner().warm() }

    var times: [Double] = []
    var modelAnswers = 0

    for c in llmDisfluencyCases {
        let result = awaitForTests { await DisfluencyCleanup.apply(c.heard) }
        times.append(result.elapsedMs)
        t.check(TranscriptCleaner.isDeletionOnly(original: c.heard, cleaned: result.text),
                "apply is deletion-only: \(c.label)")
        t.check(!result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "apply does not empty: \(c.label)")
        let got = bareWordsForTest(result.text)
        for word in c.mustKeep {
            t.check(got.contains(word.lowercased()),
                    "kept '\(word)': \(c.label)",
                    "got \(result.text)")
        }
        if result.source == .llm && result.text != c.heard {
            modelAnswers += 1
            for word in c.mustDrop {
                t.check(!got.contains(word.lowercased()),
                        "dropped '\(word)': \(c.label)",
                        "got \(result.text)")
            }
        }
    }

    // Shipping path on the dictation corpus: rulesOnly vs the formatter's
    // expected leftover words. This is the path Pipeline actually calls.
    var improve = 0, unchanged = 0, regress = 0
    for c in textCorpus {
        let rules = TranscriptCleaner.rulesOnly(c.heard)
        t.check(TranscriptCleaner.isDeletionOnly(original: c.heard, cleaned: rules),
                "corpus rulesOnly is deletion-only: \(c.label)")
        let content = Set(bareWordsForTest(c.heard)).intersection(Set(bareWordsForTest(c.want)))
        let droppedContent = content.subtracting(Set(bareWordsForTest(rules)))
        if !droppedContent.isEmpty {
            regress += 1
        } else if rules == c.heard {
            unchanged += 1
        } else {
            improve += 1
        }
    }

    times.sort()
    let median = times.isEmpty ? 0 : times[times.count / 2]
    let minT = times.first ?? 0
    let maxT = times.last ?? 0
    print("  llm-cleanup: rules on \(textCorpus.count) corpus rows -> "
          + "\(improve) improved, \(unchanged) unchanged, \(regress) regress")
    print("  llm-cleanup: \(modelAnswers)/\(llmDisfluencyCases.count) new cases the model actually edited")
    print("  llm-cleanup: apply latency min \(String(format: "%.1f", minT)) ms  "
          + "median \(String(format: "%.1f", median)) ms  "
          + "max \(String(format: "%.1f", maxT)) ms  (n=\(times.count))")

    t.check(regress == 0, "corpus has no content-word regressions",
            "\(regress) row(s) dropped a word that both heard and want contain")

    return t.result
}

private func bareWordsForTest(_ text: String) -> [String] {
    text.split { $0.isWhitespace }.map {
        $0.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }.filter { !$0.isEmpty }
}

/// Pump the current run loop so a MainActor-isolated `--unit-tests` call
/// can wait on FoundationModels without deadlocking the main thread.
private final class AwaitBox<Value>: @unchecked Sendable {
    var value: Value?
    var done = false
}

private func awaitForTests<T>(_ work: @escaping @Sendable () async -> T) -> T {
    let box = AwaitBox<T>()
    Task {
        box.value = await work()
        box.done = true
    }
    let deadline = Date().addingTimeInterval(180)
    while !box.done {
        if Date() > deadline {
            fatalError("llm-cleanup test timed out waiting for the on-device model")
        }
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    return box.value!
}
