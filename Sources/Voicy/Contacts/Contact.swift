import Foundation

/// A phone number belonging to a contact, normalized to E.164 digits with no '+'.
/// This is exactly the format the `whatsapp://send?phone=` deep link needs.
public struct ContactPhone: Equatable, Sendable {
    /// Friendly label, e.g. "mobile", "home", "work", "iPhone".
    public let label: String
    /// E.164 digits without the leading '+', e.g. "919876543210".
    public let e164: String

    public init(label: String, e164: String) {
        self.label = label
        self.e164 = e164
    }
}

/// A contact as Voicy understands it. A sendable value type, safe to cache and
/// to pass across concurrency boundaries.
public struct Contact: Equatable, Sendable {
    public let identifier: String
    public let givenName: String
    public let familyName: String
    public let nickname: String
    public let organizationName: String
    public let phones: [ContactPhone]

    public init(identifier: String,
                givenName: String,
                familyName: String,
                nickname: String,
                organizationName: String,
                phones: [ContactPhone]) {
        self.identifier = identifier
        self.givenName = givenName
        self.familyName = familyName
        self.nickname = nickname
        self.organizationName = organizationName
        self.phones = phones
    }

    /// Human-friendly name for display in the confirm card.
    public var displayName: String {
        if !givenName.isEmpty && !familyName.isEmpty {
            return "\(givenName) \(familyName)"
        }
        if !givenName.isEmpty { return givenName }
        if !organizationName.isEmpty { return organizationName }
        return "Unknown"
    }

    /// The number to use for a WhatsApp deep link. Prefers a mobile-labelled
    /// number (mobile / iPhone / cell / main), otherwise the first normalized
    /// number we have.
    public var preferredE164: String? {
        if let mobile = phones.first(where: { Self.mobileLabels.contains(Self.normalizeLabel($0.label)) }) {
            return mobile.e164
        }
        return phones.first?.e164
    }

    private static let mobileLabels: Set<String> = ["mobile", "iphone", "cell", "main"]

    private static func normalizeLabel(_ raw: String) -> String {
        raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The outcome of resolving a spoken recipient name. The UI switches on this
/// to decide whether to auto-send, ask "which one?", or report nobody found.
public enum Resolution: Sendable {
    case resolved(Contact)
    case ambiguous([Contact])
    case notFound
}