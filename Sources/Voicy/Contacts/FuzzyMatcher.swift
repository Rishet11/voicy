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
    /// When true, apply a capped Soundex bonus to weak matches. Default off.
    public let usePhoneticBonus: Bool

    public init(usePhoneticBonus: Bool = false) {
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
        let variants = searchVariants(contact).map(NameNormalizer.normalize).filter { !$0.isEmpty }
        guard !variants.isEmpty else { return 0.0 }
        let queryTokens = query.split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !queryTokens.isEmpty else { return 0.0 }

        var best = 0.0
        for v in variants {
            if v == query { return 1.0 }
            let variantTokens = v.split(whereSeparator: { !$0.isLetter }).map(String.init)
            let s: Double
            if queryTokens.count >= 2 {
                // Multi-token name: every token must find a match, otherwise a
                // shared first name alone would let "Rahul Sharma" match
                // "Rahul Verma". Average the best per-token similarity.
                guard !variantTokens.isEmpty else { continue }
                s = queryTokens.reduce(into: 0.0) { acc, qt in
                    acc += variantTokens.map { JaroWinkler.similarity(qt, $0) }.max() ?? 0
                } / Double(queryTokens.count)
            } else {
                s = JaroWinkler.similarity(query, v)
                if v.hasPrefix(query) { best = max(best, 0.97) }
            }
            best = max(best, s)
        }

        if usePhoneticBonus && best < 0.8 {
            if let qSound = Soundex.encode(query),
               variants.contains(where: { Soundex.encode($0) == qSound }) {
                // Capped well below the resolve floor so it can only help recall,
                // never tip a borderline match into a decisive resolution.
                best = max(best, min(0.75, best + 0.15))
            }
        }
        return best
    }

    private func searchVariants(_ contact: Contact) -> [String] {
        var v: [String] = []
        if !contact.givenName.isEmpty { v.append(contact.givenName) }
        if !contact.nickname.isEmpty { v.append(contact.nickname) }
        if !contact.familyName.isEmpty { v.append(contact.familyName) }
        if !contact.organizationName.isEmpty { v.append(contact.organizationName) }
        let full = contact.displayName
        if !full.isEmpty && !v.contains(full) { v.append(full) }
        return v
    }
}