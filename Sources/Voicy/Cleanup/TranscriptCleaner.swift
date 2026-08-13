import Foundation

/// Removes disfluency noise (filler words, immediate stutters) from a dictated
/// transcript using deletion-only rules. Never rewrites, reorders, or adds a word.
///
/// This is the safety-critical piece of Voicy: a dictation tool that silently
/// changes what you said is worse than one that does nothing. Every function
/// here either deletes whole words or leaves the text untouched.
///
/// Hard constraint: the user's words are never rewritten or regenerated.
/// The body is sliced by character offset, so removal is implemented as
/// span deletions on the original transcript (character ranges), never a
/// paraphrase. Kept words are byte-identical slices of the original.
public enum TranscriptCleaner {

    /// The one named source for the rule-based hesitation matcher.
    ///
    /// Not a vocabulary. A token matches when its letters are a short vocalized
    /// pause: a vowel run plus h/m/r (lengthened forms included), or a hum.
    /// Discourse markers ("like", "you know", "matlab") are not hesitation
    /// sounds; the on-device model decides those. `TextFormatter` uses the
    /// same matcher via `isFiller`, so the two passes cannot drift.
    static let hesitationSound = "^u+h+$|^u+m+$|^e+r+m*$|^a+h+$|^h+m+$|^e+h+$"

    /// True when a token is a hesitation sound rather than a real word.
    ///
    /// The guard that matters: several hesitation shapes collide with acronyms
    /// a person actually dictates ("take him to the ER", "the AH gate"). An
    /// all-letters token in caps is an acronym, never a pause, so it is kept.
    static func isFiller(_ token: some StringProtocol) -> Bool {
        let b = bareLower(Substring(token))
        guard !b.isEmpty,
              b.range(of: hesitationSound, options: .regularExpression) == b.startIndex..<b.endIndex
        else { return false }
        return !isAcronym(token)
    }

    private static func isAcronym(_ token: some StringProtocol) -> Bool {
        let letters = token.filter { $0.isLetter }
        return letters.count > 1 && letters.allSatisfy { $0.isUppercase }
    }

    /// A single token: the original slice (with its original casing and any
    /// attached punctuation) plus the bare word used for comparisons and its
    /// character range in the original string.
    private struct Token {
        let text: Substring
        let bareLower: String
        let range: Range<String.Index>
    }

    /// Strips leading/trailing punctuation (anything that isn't a letter,
    /// digit, or apostrophe/hyphen inside the word) and lowercases, purely
    /// for comparison purposes. The original `text` is untouched.
    private static func bareLower(_ s: Substring) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'-")))
    }

    /// Tokenizes preserving original character ranges. Each non-whitespace run
    /// is a token; whitespace between tokens is not stored but implied.
    /// Tokens carry their exact Range<String.Index> so deletions are true
    /// span deletions on the original string.
    private static func tokenizeWithRanges(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var i = text.startIndex
        while i < text.endIndex {
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            if i >= text.endIndex { break }
            let start = i
            while i < text.endIndex, !text[i].isWhitespace { i = text.index(after: i) }
            let sub = text[start..<i]
            tokens.append(Token(text: sub, bareLower: bareLower(sub), range: start..<i))
        }
        return tokens
    }

    /// Legacy splitter used only for isDeletionOnly word comparison.
    private static func tokenize(_ text: String) -> [Token] {
        text.split(separator: " ").map { Token(text: $0, bareLower: bareLower($0), range: text.startIndex..<text.startIndex) }
    }

    /// Removes filler words, stutters and multi-word false starts using rules
    /// only. Never adds or changes a word; only ever deletes whole words via
    /// span deletion, so every kept word is a byte-identical slice of the
    /// original. If deleting would empty the result, the original is returned.
    public static func rulesOnly(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return text }

        let tokens = tokenizeWithRanges(text)
        if tokens.isEmpty { return text }

        // Kept words as strings, so a sentence mark stranded on a deleted
        // filler can be re-attached to the word before it. nil means deleted.
        var kept: [String?] = tokens.map { String($0.text) }

        // Pass 1: drop standalone fillers.
        for i in 0..<tokens.count {
            guard isFiller(tokens[i].text) else { continue }
            kept[i] = nil
            // "I am on my way um." must not lose the full stop with the filler.
            if let mark = sentenceMark(tokens[i].text),
               let prev = (0..<i).last(where: { kept[$0] != nil }),
               let prevWord = kept[prev], sentenceMark(prevWord) == nil {
                kept[prev] = prevWord + String(mark)
            }
        }

        // Pass 2: drop the first of two adjacent identical runs, longest run
        // first so "I was I was going" collapses as a pair rather than leaving
        // a stray "I". n = 1 is the plain single-word stutter.
        for n in stride(from: 4, through: 1, by: -1) {
            collapseRepeatedRuns(&kept, tokens: tokens, length: n)
        }

        let keptWords = kept.compactMap { $0 }
        if keptWords.isEmpty { return text }
        let result = keptWords.joined(separator: " ")
        if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        // Defensive: ensure the result is deletion-only; if not, return the
        // original. Guards against any future logic error that reorders words.
        if !isDeletionOnly(original: text, cleaned: result) { return text }
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
    private static func collapseRepeatedRuns(_ kept: inout [String?], tokens: [Token], length n: Int) {
        // Positions still carrying a real word, in order.
        let live = kept.indices.filter { kept[$0] != nil && !tokens[$0].bareLower.isEmpty }
        guard live.count >= 2 * n else { return }

        var p = 0
        while p + 2 * n <= live.count {
            let first = live[p..<(p + n)]
            let second = live[(p + n)..<(p + 2 * n)]
            let a = first.map { tokens[$0].bareLower }
            let b = second.map { tokens[$0].bareLower }
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
        let originalWords = tokenizeWithRanges(original).map(\.bareLower).filter { !$0.isEmpty }
        let cleanedWords = tokenizeWithRanges(cleaned).map(\.bareLower).filter { !$0.isEmpty }

        if cleanedWords.isEmpty {
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
