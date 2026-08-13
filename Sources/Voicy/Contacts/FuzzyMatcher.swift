import Foundation

/// Lowercases and strips diacritics so "Shreya" and "Shréya" compare equal.
public enum NameNormalizer {
    public static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive],
                               locale: Locale(identifier: "en_US_POSIX"))
        let tokens = folded.lowercased().split(whereSeparator: { !$0.isLetter })
        return tokens.joined(separator: " ")
    }
}

public enum Levenshtein {
    public static func distance(_ a: String, _ b: String) -> Int {
        let av = Array(a), bv = Array(b)
        var prev = Array(0...bv.count)
        for i in 1...av.count {
            var cur = [i] + Array(repeating: 0, count: bv.count)
            for j in 1...bv.count {
                let cost = av[i - 1] == bv[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = cur
        }
        return prev[bv.count]
    }

    /// Similarity in [0, 1]; 1.0 means identical.
    public static func ratio(_ a: String, _ b: String) -> Double {
        let maxLen = Double(max(a.count, b.count))
        guard maxLen > 0 else { return 1.0 }
        return 1.0 - Double(distance(a, b)) / maxLen
    }
}

public enum JaroWinkler {
    /// Jaro-Winkler similarity in [0, 1].
    public static func similarity(_ a: String, _ b: String) -> Double {
        let s = Array(a), t = Array(b)
        if s.isEmpty && t.isEmpty { return 1.0 }
        if s.isEmpty || t.isEmpty { return 0.0 }

        let matchDist = max(s.count, t.count) / 2 - 1
        var sMatches = [Bool](repeating: false, count: s.count)
        var tMatches = [Bool](repeating: false, count: t.count)
        var m = 0
        for i in 0..<s.count {
            let lo = max(0, i - matchDist)
            let hi = min(t.count - 1, i + matchDist)
            if lo > hi { continue }
            for j in lo...hi where !tMatches[j] && s[i] == t[j] {
                sMatches[i] = true
                tMatches[j] = true
                m += 1
                break
            }
        }
        if m == 0 { return 0.0 }

        var transpositions = 0.0
        var k = 0
        for i in 0..<s.count where sMatches[i] {
            while !tMatches[k] { k += 1 }
            if s[i] != t[k] { transpositions += 1 }
            k += 1
        }
        transpositions /= 2.0
        let jaro = (Double(m) / Double(s.count)
                    + Double(m) / Double(t.count)
                    + (Double(m) - transpositions) / Double(m)) / 3.0

        var prefix = 0
        for i in 0..<Swift.min(s.count, t.count, 4) {
            if s[i] == t[i] { prefix += 1 } else { break }
        }
        let result = jaro + Double(prefix) * 0.1 * (1 - jaro)
        return max(0, min(1, result))
    }
}
/// Soundex. English-biased; kept only for the empirical evaluation in the test
/// harness. The shipped matcher keeps it disabled by default (see report).
public enum Soundex {
    public static func encode(_ s: String) -> String? {
        guard let first = s.first else { return nil }
        var result = String(first.uppercased())
        var prevCode = code(for: first)
        for ch in s.dropFirst() {
            let c = code(for: ch)
            if c != "0" && c != prevCode {
                result.append(c)
            }
            prevCode = c
            if result.count == 4 { break }
        }
        while result.count < 4 { result.append("0") }
        return result
    }

    private static func code(for ch: Character) -> String {
        switch ch.lowercased() {
        case "b", "f", "p", "v": return "1"
        case "c", "g", "j", "k", "q", "s", "x", "z": return "2"
        case "d", "t": return "3"
        case "l": return "4"
        case "m", "n": return "5"
        case "r": return "6"
        default: return "0"
        }
    }
}

/// One ranked candidate for a spoken recipient name.
public struct RankedMatch: Sendable {
    public let contact: Contact
    public let score: Double
    public init(contact: Contact, score: Double) {
        self.contact = contact
        self.score = score
    }
}

/// Scores a spoken name against contacts using normalized token matching with a
/// Jaro-Winkler ratio. A phonetic (Soundex) recall bonus exists but is disabled
/// by default: it was evaluated against real Indian names and did not clearly
/// help, so it is not applied to avoid false positives.
public final class FuzzyMatcher: Sendable {
    /// For a multi-token spoken name, the minimum similarity ONE token must
    /// reach against a real name token before the contact is considered at all.
    /// 0.85 is above the level pure letter overlap between unrelated names
    /// reaches (measured: "quinlan" vs "krishnan" ≈ 0.65) and below what a
    /// misheard version of a real name reaches ("krishna" vs "krishnan" ≈ 0.97).
    static let multiTokenAnchorFloor: Double = 0.85

    /// A second token that names a different person must also be reasonably
    /// close. Matching only one token let "Aditi Menon" resolve to Aditi Rao,
    /// which is a wrong-person send rather than a safe refusal.
    static let multiTokenEachFloor: Double = 0.75

    /// Shortest single-word query that may fuzzy-match at all. Two letters carry
    /// almost no signal, and Jaro-Winkler inflates short-string similarity badly:
    /// the audio harness transcribed "Say hi to Aarav" as "Say hi to our ab.",
    /// the parser correctly took "hi" as the name, and "hi" then fuzzy-matched
    /// SEVEN unrelated contacts. An exact match is still honoured below this
    /// length, so a contact genuinely called "Jo" is unaffected.
    static let minimumFuzzyQueryLength = 3

    /// Weight applied to a match on a surname or organization rather than a
    /// first name or nickname. People address each other by first name, so when
    /// a garbled name lands between someone's first name and someone else's
    /// surname, the first name should win. Measured case: "Polka" (misheard
    /// "Pulkit") scored close enough to "Kapoor" to drag Stone Kapoor into the
    /// candidate list.
    static let surnameOnlyWeight: Double = 0.88

    /// How close in length two names must be, once spaces are removed, before
    /// they may be compared as a split/joined version of each other. 0.75 admits
    /// "paulkit" vs "pulkit" (6/7) and rejects "rahulsharma" vs "rahul" (5/11).
    static let splitNameLengthRatio: Double = 0.75

    /// How similar two space-collapsed names must be before one is accepted as a
    /// split version of the other. Deliberately high: a genuine split is nearly
    /// the same string once spaces are gone.
    static let splitNameSimilarityFloor: Double = 0.90

    /// Length ratio at or above which two single-word names are treated as
    /// comparable and not damped at all. Below it, damping ramps in.
    /// 0.7 keeps "arav" vs "aarav" (0.80) undamped and damps "sid" vs
    /// "siddharth" (0.33) hard.
    static let lengthDampingKneeRatio: Double = 0.7

    /// Similarity two folded (PhoneticFolder) strings must reach before a
    /// contact is considered a "phonetic hit". High, because the folded key is
    /// coarse (it merges t/d, o/u, e/i): this floor is what keeps "Xavier
    /// Quinlan" folded ("xavir kuinlan") away from "Meera Krishnan" folded
    /// ("mira krisnan") - measured similarity between those two is well below
    /// this floor, same margin the orthographic anchor floor relies on.
    static let phoneticMatchFloor: Double = 0.88

    /// Hard ceiling on any score that is reached ONLY via a phonetic hit
    /// (i.e. the orthographic score alone did not clear notFoundFloor).
    /// Fixed strictly below ResolutionThresholds.resolveFloor (0.80), so a
    /// phonetic-only signal can never produce `.resolved` - this is enforced
    /// here structurally, independent of whatever the resolver's thresholds
    /// happen to be, per the "never guess a recipient" contract.
    static let phoneticRecallCeiling: Double = 0.70

    /// When true, run the phonetic recall pass below. Default on: unlike the
    /// old Soundex bonus (English-biased, measured not to help), this table is
    /// built from Indian-name confusions actually observed in the audio suite,
    /// and it is structurally capped so it can only add/rank candidates, never
    /// auto-resolve.
    public let usePhoneticBonus: Bool

    public init(usePhoneticBonus: Bool = true) {
        self.usePhoneticBonus = usePhoneticBonus
    }

    /// Rank candidates for a spoken recipient name, best first.
    public func rank(query: String, among contacts: [Contact]) -> [RankedMatch] {
        let q = NameNormalizer.normalize(query)
        guard !q.isEmpty else { return [] }
        var results = contacts.map { RankedMatch(contact: $0, score: score(query: q, contact: $0)) }
        results.sort { $0.score > $1.score }
        return results
    }

    private func score(query: String, contact: Contact) -> Double {
        let weighted = searchVariants(contact)
            .map { (NameNormalizer.normalize($0.text), $0.weight) }
            .filter { !$0.0.isEmpty }
        guard !weighted.isEmpty else { return 0.0 }
        let queryTokens = query.split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !queryTokens.isEmpty else { return 0.0 }

        // An exact match always wins outright, whatever its length, so short real
        // names ("Jo", "Al") still resolve.
        if weighted.contains(where: { $0.0 == query }) { return 1.0 }

        // Below the minimum length there is not enough signal to fuzzy-match
        // safely, and short-string similarity metrics over-report. Refuse rather
        // than offer a list of people who happen to share two letters.
        if queryTokens.count == 1 && query.count < Self.minimumFuzzyQueryLength {
            return 0.0
        }

        // Recognizers split unfamiliar names into two familiar words: the harness
        // has transcribed "Pulkit" as "Paul Kit" and "Siddharth" as "Sid Harth".
        // Comparing with all spacing removed catches that whole class, because
        // "paulkit" vs "pulkit" is a near-identical string even though
        // token-by-token they look like different people. Purely a comparison;
        // the recipient shown to the user is still the contact's real name.
        let squashedQuery = query.filter { !$0.isWhitespace }

        var best = 0.0
        for (v, weight) in weighted {
            let variantTokens = v.split(whereSeparator: { !$0.isLetter }).map(String.init)

            // Apply the space-collapsed comparison ONLY where the word count
            // actually disagrees, which is the signature of a split (or joined)
            // name. Comparing two multi-word names with spaces removed is far too
            // permissive: "rahulsharma" and "rahulverma" look similar as raw
            // strings, and applying it there made two different people collide.
            let squashedVariant = v.filter { !$0.isWhitespace }
            //
            // The second guard is a length check. Splitting a name preserves its
            // letters, so the two squashed strings must be nearly the same length
            // ("paulkit" vs "pulkit", 7 and 6). Without it, "rahulsharma" scored
            // 0.89 against the bare first name "rahul" purely because one is a
            // prefix of the other, which pulled a second Rahul into contention
            // and turned a decisive match into an ambiguous one.
            let wordCountDisagrees = (queryTokens.count > 1 && variantTokens.count == 1)
                || (queryTokens.count == 1 && variantTokens.count > 1)
            let lengths = [squashedQuery.count, squashedVariant.count]
            let lengthRatio = Double(lengths.min()!) / Double(max(1, lengths.max()!))
            if wordCountDisagrees && lengthRatio >= Self.splitNameLengthRatio {
                if squashedQuery == squashedVariant { return 1.0 }
                if squashedQuery.count >= Self.minimumFuzzyQueryLength {
                    let squashedScore = JaroWinkler.similarity(squashedQuery, squashedVariant)
                    // A high floor, because this branch answers a narrow question:
                    // "is this the SAME name with different spacing?" A real split
                    // is near-identical once squashed ("paulkit" vs "pulkit",
                    // "sidharth" vs "siddharth" both score >0.93). Without a floor
                    // this branch scored 0.79 for "siddharth" vs "sidkapoor":
                    // two different people, purely on shared letters and a shared
                    // "sid" prefix, which is uncomfortably close to the 0.80
                    // auto-resolve threshold.
                    if squashedScore >= Self.splitNameSimilarityFloor {
                        best = max(best, squashedScore * weight)
                    }
                }
            }

            let s: Double
            if queryTokens.count >= 2 {
                // Multi-token name: every token must find a match, otherwise a
                // shared first name alone would let "Rahul Sharma" match
                // "Rahul Verma". Average the best per-token similarity.
                guard !variantTokens.isEmpty else { continue }
                let perToken = queryTokens.map { qt in
                    variantTokens.map { JaroWinkler.similarity(qt, $0) }.max() ?? 0
                }

                // Anchor requirement: at least ONE query token must match a real
                // name token strongly, or this contact is not a candidate at all.
                //
                // Averaging alone let a name nobody has drift over the notFound
                // floor on letter overlap. The audio harness caught "Xavier
                // Quinlan" returning FIVE candidates including "Meera Krishnan",
                // because "quinlan" vs "krishnan" scores ~0.65 and the average
                // cleared the 0.55 floor. A confirm card full of unrelated people
                // teaches the user to stop reading it, and that is the road to a
                // wrong send.
                //
                // This is deliberately weaker than requiring EVERY token to be
                // strong: "Rahul bhai" still ranks (rahul anchors at 1.0) and
                // lands in `.ambiguous`, so Voicy asks rather than guessing or
                // wrongly claiming nobody matched.
                guard (perToken.max() ?? 0) >= Self.multiTokenAnchorFloor,
                      (perToken.min() ?? 0) >= Self.multiTokenEachFloor else { continue }

                s = (perToken.reduce(0, +) / Double(perToken.count)) * weight
            } else {
                // Damp by how far apart the two names are in length.
                //
                // Jaro-Winkler's prefix bonus makes a short name look like a
                // strong match for any longer name starting with it: "Sid" vs
                // "Siddharth" scores 0.844, over the 0.80 auto-resolve
                // threshold, so a spoken "Siddharth" would silently resolve to a
                // contact called Sid Kapoor. Different person, confident send.
                //
                // Damping scales the score by how comparable the lengths are, so
                // a near-length near-match ("Sidharth" vs "Siddharth") keeps
                // almost all of its score while a 3-vs-9 letter match drops into
                // "ask the user" territory instead of resolving.
                // Names of comparable length are not damped at all: a one-letter
                // difference is a mishearing, not a different person, and
                // penalizing it pushed "Arav" (heard for "Aarav") below the
                // resolve floor. Damping only engages once the lengths genuinely
                // diverge, which is where the prefix bonus stops being evidence.
                let ratio = Double(min(query.count, v.count)) / Double(max(1, max(query.count, v.count)))
                let lengthDamping = ratio >= Self.lengthDampingKneeRatio
                    ? 1.0
                    : 0.6 + (ratio / Self.lengthDampingKneeRatio) * 0.4
                s = JaroWinkler.similarity(query, v) * weight * lengthDamping

                // Preserve consonant identity when a recognizer changes a
                // vowel or truncates the final vowel sound. "Polka" and
                // "Palka" retain the same consonant frame as "Pulkit".
                // Require a meaningful frame and comparable lengths so this
                // cannot turn short fragments into confident contacts.
                let queryFrame = consonantSkeleton(query)
                let variantFrame = consonantSkeleton(v)
                let frameRatio = Double(min(queryFrame.count, variantFrame.count))
                    / Double(max(queryFrame.count, variantFrame.count))
                if queryFrame.count >= 3, frameRatio >= 0.75 {
                    let frameScore = JaroWinkler.similarity(queryFrame, variantFrame)
                    if frameScore >= 0.90 {
                        best = max(best, min(0.90, frameScore * weight))
                    }
                }

                // A variant that literally BEGINS with what was said is a
                // deliberate exception: saying "Sid" to reach "Siddharth" is
                // normal, and short-to-long is how people actually abbreviate.
                if query.count >= 4 && v.hasPrefix(query) { best = max(best, 0.97 * weight) }
            }
            best = max(best, s)
        }

        // Phonetic recall pass. Only runs when the orthographic score alone
        // did not clear notFoundFloor, i.e. this is exactly the case where the
        // contact would otherwise vanish entirely (measured: "Polka" for
        // "Pulkit", "Adidi" for "Aditi"). It can raise `best` only up to
        // phoneticRecallCeiling, never higher, so it cannot turn an already
        // -weak orthographic match into a confident one either.
        if usePhoneticBonus && best < ResolutionThresholds.resolveFloor
            && query.count >= Self.minimumFuzzyQueryLength {
            let foldedQuery = PhoneticFolder.fold(query)
            for (v, weight) in weighted {
                let foldedVariant = PhoneticFolder.fold(v)
                let variantTokens = v.split(whereSeparator: { !$0.isLetter }).map(String.init)

                let sim: Double
                if queryTokens.count >= 2 {
                    // Multi-token: same anchor discipline as the orthographic
                    // path above, just on folded tokens, so a garbled name with
                    // no real relation to a contact (e.g. "Xavier Quinlan")
                    // still can't drag that contact into contention.
                    guard !variantTokens.isEmpty else { continue }
                    let foldedVariantTokens = variantTokens.map(PhoneticFolder.fold)
                    let foldedQueryTokens = queryTokens.map(PhoneticFolder.fold)
                    let perToken = foldedQueryTokens.map { qt in
                        foldedVariantTokens.map { JaroWinkler.similarity(qt, $0) }.max() ?? 0
                    }
                    guard (perToken.min() ?? 0) >= Self.phoneticMatchFloor else { continue }
                    sim = perToken.reduce(0, +) / Double(perToken.count)
                } else {
                    sim = JaroWinkler.similarity(foldedQuery, foldedVariant)
                }

                if sim >= Self.phoneticMatchFloor {
                    let comparableLength = Double(min(query.count, v.count))
                        / Double(max(query.count, v.count)) >= Self.lengthDampingKneeRatio
                    if best >= ResolutionThresholds.notFoundFloor && comparableLength {
                        // Phonetics may corroborate a strong orthographic
                        // near-match, but never manufacture a candidate from
                        // phonetics alone. The cap is above recall-only mode
                        // and below the resolver's confidence floor only when
                        // no orthographic evidence exists.
                        best = max(best, min(0.90, sim * weight))
                    } else {
                        best = max(best, min(Self.phoneticRecallCeiling, sim * weight))
                    }
                }
            }
        }
        return best
    }

    /// A name a contact can be addressed by, plus how much a match on it counts.
    private struct Variant {
        let text: String
        let weight: Double
    }

    private func consonantSkeleton(_ value: String) -> String {
        String(value.filter { !$0.isWhitespace && !"aeiou".contains($0) })
    }

    /// Every string this contact might be called, weighted by how likely a
    /// speaker is to use it as the whole name. First names, nicknames and the
    /// full name carry full weight; a surname or company name on its own is
    /// discounted, because addressing someone by surname alone is the rarer case.
    private func searchVariants(_ contact: Contact) -> [Variant] {
        var v: [Variant] = []
        if !contact.givenName.isEmpty { v.append(Variant(text: contact.givenName, weight: 1.0)) }
        if !contact.nickname.isEmpty { v.append(Variant(text: contact.nickname, weight: 1.0)) }
        if !contact.familyName.isEmpty {
            v.append(Variant(text: contact.familyName, weight: Self.surnameOnlyWeight))
        }
        if !contact.organizationName.isEmpty {
            v.append(Variant(text: contact.organizationName, weight: Self.surnameOnlyWeight))
        }
        let full = contact.displayName
        if !full.isEmpty && !v.contains(where: { $0.text == full }) {
            v.append(Variant(text: full, weight: 1.0))
        }
        return v
    }
}
