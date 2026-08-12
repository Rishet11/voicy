import Foundation

/// Thresholds that turn ranked scores into a `Resolution`. Chosen and justified
/// in the test harness (see the "threshold sanity" section) and in the report.
public enum ResolutionThresholds {
    /// Below this score no candidate is worth offering at all.
    public static let notFoundFloor: Double = 0.55
    /// At/above this score AND above the runner-up by `gapMargin` resolves.
    public static let resolveFloor: Double = 0.80
    /// Minimum gap between the top two candidates for a decisive resolution.
    public static let gapMargin: Double = 0.12
}

/// Turns a spoken recipient name plus the contact set and any learned aliases
/// into a `Resolution`. Stateless and Sendable; safe to call from anywhere.
public final class ContactResolver: Sendable {
    private let matcher: FuzzyMatcher

    public init(matcher: FuzzyMatcher = FuzzyMatcher()) {
        self.matcher = matcher
    }

    /// `aliases` maps a normalized spoken phrase to a contact identifier.
    public func resolve(spoken: String, contacts: [Contact], aliases: [String: String]) -> Resolution {
        let normSpoken = NameNormalizer.normalize(spoken)

        // 1. A learned alias wins immediately and outranks everything.
        if let id = aliases[normSpoken],
           let contact = contacts.first(where: { $0.identifier == id }) {
            return .resolved(contact)
        }

        // 2. Rank by name similarity.
        let ranked = matcher.rank(query: spoken, among: contacts)
        guard let best = ranked.first else { return .notFound }

        // 3. Nothing above the floor is notFound.
        if best.score < ResolutionThresholds.notFoundFloor {
            return .notFound
        }

        let second = ranked.dropFirst().first
        if best.score >= ResolutionThresholds.resolveFloor,
           second == nil || best.score - second!.score >= ResolutionThresholds.gapMargin {
            return .resolved(best.contact)
        }

        // 4. Otherwise ambiguous: the top candidate plus any that are close.
        //    A single candidate below the resolve floor still lands here so the
        //    UI can ask for a confirmation instead of guessing.
        var candidates = [best.contact]
        for m in ranked.dropFirst() where best.score - m.score < ResolutionThresholds.gapMargin {
            candidates.append(m.contact)
        }
        return .ambiguous(candidates)
    }
}