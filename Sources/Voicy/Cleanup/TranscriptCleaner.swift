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
    private static let fillers: Set<String> = ["um", "uh", "erm", "hmm", "ah", "er"]

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

    /// Removes filler words and stutters using rules only. Never adds or
    /// changes a word; only ever deletes whole words. If deleting would empty
    /// the result, the original text is returned unchanged.
    public static func rulesOnly(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return text }

        // Split on single spaces so we can rejoin with the same separators
        // and keep original spacing between kept words.
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        let bareLowers: [String] = parts.map { bareLower($0) }

        var keep = Array(repeating: true, count: parts.count)

        // Pass 1: drop standalone fillers (skip empty parts from repeated spaces).
        for i in 0..<parts.count {
            if !bareLowers[i].isEmpty, fillers.contains(bareLowers[i]) {
                keep[i] = false
            }
        }

        // Pass 2: drop an immediately repeated word (adjacent, identical when
        // lowercased/bare). Only compares against the previous still-real
        // (non-empty) word so "I   I will" and multi-space cases still work.
        var previousKeptRealIndex: Int? = nil
        for i in 0..<parts.count {
            guard keep[i], !bareLowers[i].isEmpty else { continue }
            if let prev = previousKeptRealIndex, bareLowers[prev] == bareLowers[i] {
                keep[i] = false
            } else {
                previousKeptRealIndex = i
            }
        }

        var resultParts: [Substring] = []
        for i in 0..<parts.count where keep[i] {
            resultParts.append(parts[i])
        }

        let result = resultParts.joined(separator: " ")
        let resultTrimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if resultTrimmed.isEmpty {
            return text
        }
        return result
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
