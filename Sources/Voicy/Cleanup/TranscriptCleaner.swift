import Foundation

/// Removes disfluency noise (filler words, immediate stutters) from a dictated
/// transcript using deletion-only rules. Never rewrites, reorders, or adds a word.
///
/// This is the safety-critical piece of Voicy: a dictation tool that silently
/// changes what you said is worse than one that does nothing. Every function
/// here either deletes whole words or leaves the text untouched.
public enum TranscriptCleaner {

    /// Standalone filler words removed when they appear as their own word,
    /// case-insensitively. Deliberately conservative: "like", "you know",
    /// "actually", "basically" are NOT here because they often carry meaning.
    ///
    /// This is the one filler list in the codebase. `TextFormatter` reads it too,
    /// so the deletion-only floor and the formatting pass can never drift apart.
    static let fillerWords: Set<String> = ["um", "umm", "uh", "uhh", "erm", "hmm", "ah", "er"]

    /// True when a token is a disfluency rather than a real word.
    ///
    /// The guard that matters: several fillers collide with acronyms a person
    /// actually dictates ("take him to the ER", "the AH gate"). An all-letters
    /// token in caps is an acronym, never an "uh", so it is kept.
    static func isFiller(_ token: some StringProtocol) -> Bool {
        let b = bareLower(Substring(token))
        guard !b.isEmpty, fillerWords.contains(b) else { return false }
        return !isAcronym(token)
    }

    private static func isAcronym(_ token: some StringProtocol) -> Bool {
        let letters = token.filter { $0.isLetter }
        return letters.count > 1 && letters.allSatisfy { $0.isUppercase }
    }

    /// A single token: the original slice (with its original casing and any
    /// attached punctuation) plus the bare word used for comparisons.
    private struct Token {
        let text: Substring
        let bareLower: String
    }

    /// Strips leading/trailing punctuation (anything that isn't a letter,
    /// digit, or apostrophe/hyphen inside the word) and lowercases, purely
    /// for comparison purposes. The original `text` is untouched.
    private static func bareLower(_ s: Substring) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'-")))
    }

    /// Splits on whitespace, keeping the original substrings (so we can
    /// rejoin exactly what we keep without re-rendering anything).
    private static func tokenize(_ text: String) -> [Token] {
        text.split(separator: " ").map { Token(text: $0, bareLower: bareLower($0)) }
    }

    /// Removes filler words and false starts using rules only. Never adds or
    /// changes a word; only ever deletes whole words. If deleting would empty
    /// the result, the original text is returned unchanged.
    public static func rulesOnly(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return text }

        // Split on single spaces so we can rejoin with the same separators
        // and keep original spacing between kept words.
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        let bareLowers: [String] = parts.map { bareLower($0) }

        // Words we still have, as strings, so a rescued sentence mark can be
        // re-attached to the word before a deleted filler. nil means deleted.
        var kept: [String?] = parts.map { String($0) }

        // Pass 1: drop standalone fillers (skip empty parts from repeated spaces).
        for i in 0..<parts.count {
            guard !bareLowers[i].isEmpty, isFiller(parts[i]) else { continue }
            kept[i] = nil
            // "I am on my way um." must not lose the full stop with the filler.
            if let mark = sentenceMark(parts[i]),
               let prev = (0..<i).last(where: { kept[$0] != nil && !bareLowers[$0].isEmpty }),
               let prevWord = kept[prev], sentenceMark(prevWord) == nil {
                kept[prev] = prevWord + String(mark)
            }
        }

        // Pass 2: drop the first of two adjacent identical runs, longest run
        // first so "I was I was going" collapses as a pair rather than leaving
        // a stray "I". n = 1 is the plain single-word stutter.
        for n in stride(from: 4, through: 1, by: -1) {
            collapseRepeatedRuns(&kept, bareLowers: bareLowers, length: n)
        }

        let result = kept.compactMap { $0 }.joined(separator: " ")
        if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return result
    }

    /// Trailing sentence-ending mark on a token, if any (".", "?", "!").
    private static func sentenceMark(_ token: some StringProtocol) -> Character? {
        token.reversed().first(where: { !$0.isWhitespace }).flatMap {
            ".?!".contains($0) ? $0 : nil
        }
    }

    /// Deletes the first of each pair of adjacent identical `length`-word runs.
    /// A run that ends a sentence is a real repetition, not a stutter
    /// ("that report is done. that report was late"), so it is left alone.
    private static func collapseRepeatedRuns(_ kept: inout [String?], bareLowers: [String], length n: Int) {
        // Positions still carrying a real word, in order.
        let live = kept.indices.filter { kept[$0] != nil && !bareLowers[$0].isEmpty }
        guard live.count >= 2 * n else { return }

        var p = 0
        while p + 2 * n <= live.count {
            let first = live[p..<(p + n)]
            let second = live[(p + n)..<(p + 2 * n)]
            let a = first.map { bareLowers[$0] }
            let b = second.map { bareLowers[$0] }
            let crossesSentence = first.contains { sentenceMark(kept[$0] ?? "") != nil }
            if a == b, !crossesSentence {
                for i in first { kept[i] = nil }
                p += n      // keep the second copy and re-test it against what follows
            } else {
                p += 1
            }
        }
    }

    /// True when `cleaned` can be produced from `original` by DELETING words
    /// only: every word of `cleaned` appears in `original`, in the same
    /// order, nothing added, nothing altered. Comparison is case-insensitive
    /// and ignores surrounding punctuation ("Hello," matches "hello").
    public static func isDeletionOnly(original: String, cleaned: String) -> Bool {
        let originalWords = tokenize(original).map(\.bareLower).filter { !$0.isEmpty }
        let cleanedWords = tokenize(cleaned).map(\.bareLower).filter { !$0.isEmpty }

        if cleanedWords.isEmpty {
            // Deleting everything is a valid (if extreme) deletion-only result.
            return true
        }

        var oi = 0
        for cw in cleanedWords {
            var matched = false
            while oi < originalWords.count {
                if originalWords[oi] == cw {
                    matched = true
                    oi += 1
                    break
                }
                oi += 1
            }
            if !matched { return false }
        }
        return true
    }
}
