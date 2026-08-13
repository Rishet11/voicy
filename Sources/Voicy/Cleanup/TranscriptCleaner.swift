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

    /// Standalone filler words removed when they appear as their own word,
    /// case-insensitively. Deliberately conservative: "like", "you know",
    /// "actually", "basically" are NOT here because they often carry meaning.
    /// "uhh"/"umm" are included as common lengthened variants of "uh"/"um".
    private static let fillers: Set<String> = ["um", "uh", "erm", "hmm", "ah", "er", "uhh", "umm"]

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

    /// Removes filler words and stutters using rules only. Never adds or
    /// changes a word; only ever deletes whole words via span deletion.
    /// If deleting would empty the result, the original text is returned
    /// unchanged. Result is built from original slices joined with single
    /// spaces, so every kept word is byte-identical to the original.
    public static func rulesOnly(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return text }

        let tokens = tokenizeWithRanges(text)
        if tokens.isEmpty { return text }

        var keep = Array(repeating: true, count: tokens.count)

        // Pass 1: drop standalone fillers.
        for i in 0..<tokens.count {
            if !tokens[i].bareLower.isEmpty, fillers.contains(tokens[i].bareLower) {
                keep[i] = false
            }
        }

        // Pass 2: drop an immediately repeated word (adjacent, identical when
        // lowercased/bare). Only compares against the previous kept word so
        // "I   I will" and repeated fillers already removed still work.
        // This handles stutters like "I I will" and repeated fillers that
        // survived pass 1 are already gone, but "hello hello" is still caught.
        var previousKeptIndex: Int? = nil
        for i in 0..<tokens.count {
            guard keep[i], !tokens[i].bareLower.isEmpty else { continue }
            if let prev = previousKeptIndex, tokens[prev].bareLower == tokens[i].bareLower {
                keep[i] = false
            } else {
                previousKeptIndex = i
            }
        }

        // Build result via span deletions: concatenate kept slices.
        // Using original Substrings guarantees no rewriting.
        var keptSlices: [Substring] = []
        for i in 0..<tokens.count where keep[i] {
            keptSlices.append(tokens[i].text)
        }

        if keptSlices.isEmpty { return text }
        let result = keptSlices.joined(separator: " ")
        let resultTrimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if resultTrimmed.isEmpty { return text }
        // Defensive: ensure result is deletion-only; if not, return original.
        // This guards against any future logic error that might reorder.
        if !isDeletionOnly(original: text, cleaned: result) { return text }
        return result
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
