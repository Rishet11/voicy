import Foundation

/// Folds an already-normalized (lowercase, letters+spaces) name into a coarser
/// phonetic key that collapses the specific confusions the audio harness
/// measured in mangled Indian-name transcriptions. This is NOT Soundex: Soundex
/// is tuned for English consonant clusters and was previously measured not to
/// help here (see FuzzyMatcher's Soundex comment). This table is built only
/// from the failures actually observed, each row cites the one it addresses.
///
/// IMPORTANT: this key is deliberately lossy and merges names a human would
/// consider different (e.g. it folds t/d together). It exists purely to widen
/// RECALL for FuzzyMatcher's phonetic pass, which is structurally capped below
/// the auto-resolve floor (see FuzzyMatcher.phoneticRecallCeiling). It must
/// never be used as a standalone identity check.
public enum PhoneticFolder {
    /// Ordered digraph folds: aspirated consonant -> its unaspirated pair.
    /// Apple's recognizer does not reliably hear Indian aspiration, so
    /// "Siddharth" -> "Sid Harth" / "Sidharth" (dh -> d) and, more generally,
    /// th/kh/bh/ph collapse the same way even though this suite only measured
    /// the dh case directly.
    private static let digraphFolds: [(String, String)] = [
        ("dh", "d"),   // measured: "Siddharth" heard as "Sidharth" / "Sid Harth"
        ("th", "t"),   // same aspiration confusion, generalized (th/t)
        ("kh", "k"),   // same aspiration confusion, generalized (kh/k)
        ("bh", "b"),   // same aspiration confusion, generalized (bh/b)
        ("ph", "f"),   // same aspiration confusion, generalized (ph/f)
        ("sh", "s"),   // s/sh confusion, generalized from the family above
    ]

    /// Folds the name to its phonetic key: normalize input is expected already
    /// (lowercase, diacritics stripped, whitespace collapsed to single spaces).
    public static func fold(_ normalized: String) -> String {
        var s = normalized

        // 1. Aspirated -> unaspirated digraphs, and s/sh.
        for (from, to) in digraphFolds {
            s = s.replacingOccurrences(of: from, with: to)
        }

        // 2. Collapse ANY doubled letter to one. Addresses doubled consonants
        // directly: "dd" -> "d" ("Siddharth" vs "Sidharth" after step 1 both
        // end up "d"), "ll" -> "l". Also addresses doubled vowels: "aa" -> "a"
        // ("Aarav" vs "Arav") and "ee" -> "e" ("Meera" vs "Mira", combined with
        // the vowel-class fold below).
        var collapsed = ""
        var prevChar: Character?
        for ch in s {
            if ch == prevChar { continue }
            collapsed.append(ch)
            prevChar = ch
        }
        s = collapsed

        // 3. v/w fold: the recognizer's output and contact spellings both drift
        // between v and w for the same sound in Indian names (e.g. "Vivek" /
        // "Wivek"-style mishears). Canonicalize to v.
        s = String(s.map { $0 == "w" ? "v" : $0 })

        // 4. Vowel-class fold: o/u and e/i are the two vowel pairs the harness's
        // mishears actually swap. "Pulkit" heard as "Polkit"/"Polka"/"Palka"
        // (u/o), "Meera Krishnan" heard as "Mira Krishna" (e/i, combined with
        // step 2's ee->e). Folding both pairs to one representative lets the
        // folded strings line up without merging unrelated vowels like a/i.
        s = String(s.map { ch -> Character in
            switch ch {
            case "o": return "u"
            case "e": return "i"
            default: return ch
            }
        })

        // 5. Terminal vowel drift / stop-consonant voicing: "Aditi" heard as
        // "Adidi" is a t/d swap between two vowels, not a vowel problem at all.
        // Fold t and d together everywhere; this is deliberately the coarsest
        // rule in the table; it is why this key is recall-only and capped
        // below the auto-resolve floor in FuzzyMatcher, never an identity
        // check on its own.
        s = String(s.map { $0 == "t" ? "d" : $0 })

        return s
    }
}
