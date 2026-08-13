import Foundation

/// Word- and character-error-rate scoring for transcripts.
///
/// Why this exists: the audio suite reported pass/fail against an expected
/// recipient and body, and it reported 22/22. That number says the intent
/// pipeline survived, it does NOT say the recognizer heard the words. A clip
/// where "Aarav" comes back as "our ab" can still pass, because the case that
/// covers it expects a non-match. Pass/fail therefore cannot measure whether
/// transcription is getting better or worse.
///
/// WER is the standard measure: edit distance between the reference words and
/// the hypothesis words, divided by the reference length. CER is the same over
/// characters, and it is kept because a name mangled into two words ("Paul Kit"
/// for "Pulkit") costs a whole word in WER but only a few characters in CER,
/// so the pair tells you WHAT kind of error happened.
enum ErrorRate {

    struct Score: Sendable {
        var substitutions: Int
        var deletions: Int
        var insertions: Int
        var referenceLength: Int

        var errors: Int { substitutions + deletions + insertions }

        /// Errors per reference token. Can exceed 1.0 when the hypothesis is
        /// much longer than the reference; that is normal and not clamped,
        /// because clamping would hide a runaway recognizer.
        var rate: Double {
            referenceLength == 0 ? (errors == 0 ? 0 : 1) : Double(errors) / Double(referenceLength)
        }
    }

    /// Lowercases, drops punctuation, collapses whitespace and maps spelled
    /// numbers to digits.
    ///
    /// The number mapping matters: the reference says "at five" and the
    /// recognizer writes "at 5". That is a formatting choice, not a
    /// mis-hearing, and scoring it as an error would make the WER number
    /// measure Apple's number formatter instead of its acoustic model.
    static func normalize(_ text: String) -> [String] {
        let scalars = text.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { numberWords[String($0)] ?? String($0) }
    }

    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "ten": "10", "eleven": "11", "twelve": "12", "twenty": "20",
        "thirty": "30", "forty": "40", "fifty": "50", "hundred": "100",
    ]

    static func word(reference: String, hypothesis: String) -> Score {
        align(normalize(reference), normalize(hypothesis))
    }

    static func character(reference: String, hypothesis: String) -> Score {
        // Score over the normalized token stream joined by single spaces, so
        // CER and WER see exactly the same text and differ only in unit.
        let ref = Array(normalize(reference).joined(separator: " ")).map(String.init)
        let hyp = Array(normalize(hypothesis).joined(separator: " ")).map(String.init)
        return align(ref, hyp)
    }

    /// Levenshtein alignment with backtrace, so the three error kinds are
    /// reported separately instead of only their total. Knowing that a clip
    /// lost 3 words to deletion (endpointing cut it off) rather than to
    /// substitution (it mis-heard them) points at completely different fixes.
    static func align(_ reference: [String], _ hypothesis: [String]) -> Score {
        let n = reference.count
        let m = hypothesis.count
        if n == 0 { return Score(substitutions: 0, deletions: 0, insertions: m, referenceLength: 0) }
        if m == 0 { return Score(substitutions: 0, deletions: n, insertions: 0, referenceLength: n) }

        // cost[i][j] = edits to turn reference[0..<i] into hypothesis[0..<j].
        var cost = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                if reference[i - 1] == hypothesis[j - 1] {
                    cost[i][j] = cost[i - 1][j - 1]
                } else {
                    cost[i][j] = 1 + min(cost[i - 1][j - 1], cost[i - 1][j], cost[i][j - 1])
                }
            }
        }

        var subs = 0, dels = 0, ins = 0
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, reference[i - 1] == hypothesis[j - 1], cost[i][j] == cost[i - 1][j - 1] {
                i -= 1; j -= 1
            } else if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + 1 {
                subs += 1; i -= 1; j -= 1
            } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                dels += 1; i -= 1
            } else {
                ins += 1; j -= 1
            }
        }
        return Score(substitutions: subs, deletions: dels, insertions: ins, referenceLength: n)
    }

    /// Corpus-level rate: total errors over total reference length, NOT the
    /// mean of the per-clip rates. Averaging rates lets a two-word clip weigh
    /// as much as a thirty-word one and is the usual way a WER number gets
    /// quietly flattered.
    static func corpus(_ scores: [Score]) -> Score {
        Score(
            substitutions: scores.reduce(0) { $0 + $1.substitutions },
            deletions: scores.reduce(0) { $0 + $1.deletions },
            insertions: scores.reduce(0) { $0 + $1.insertions },
            referenceLength: scores.reduce(0) { $0 + $1.referenceLength }
        )
    }
}

/// Percentile over already-collected samples, nearest-rank.
enum Percentile {
    static func of(_ samples: [Double], _ p: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}
