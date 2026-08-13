import Foundation

/// Builds the `tg://resolve?...` deep link that opens Telegram for Mac and
/// pre-fills the message body in the chat's text input bar.
///
/// Both documented forms are used (https://core.telegram.org/api/links):
///
///   tg://resolve?domain=<username>&text=<draft_text>   (username target)
///   tg://resolve?phone=<digits>&text=<draft_text>      (phone target)
///
/// The spec says `draft_text` is "pre-entered into the text input bar, if the
/// user can write in the chat". Nothing is sent by opening the link; the
/// confirmed Return is posted by `TelegramSender` only after exact composer
/// verification.
///
/// The target identifier is classified deterministically and conservatively:
/// all-digits input (plus phone formatting like `+`, spaces, dashes, parens)
/// is a phone; anything else must be a valid Telegram username (a letter,
/// then letters/digits/underscores, 3-32 chars). Anything else is refused
/// with a named error — a Telegram recipient is never guessed.
enum TelegramDeepLink {

    /// What an identifier resolves to. Only these two shapes are dialable.
    enum Target: Equatable {
        /// A valid Telegram username, no leading `@`.
        case username(String)
        /// E.164 digits, no leading `+`, no formatting.
        case phone(String)
    }

    /// A malformed or unresolvable target is a named error, never a guess.
    enum BuildError: Error, Equatable {
        /// Empty, whitespace-only, or digits-only but too short to be a phone
        /// number. The contact has no Telegram-resolvable identifier.
        case noResolvableIdentifier
        /// Contains letters but is not a valid Telegram username.
        case invalidUsername
        case encodingFailed

        var reason: String {
            switch self {
            case .noResolvableIdentifier:
                return "recipient has no Telegram username or phone number"
            case .invalidUsername:
                return "recipient identifier is not a valid Telegram username"
            case .encodingFailed:
                return "could not build Telegram deep link"
            }
        }
    }

    /// Same encoding policy as the WhatsApp link: only the RFC 3986 unreserved
    /// ASCII set stays raw, so spaces, newlines, ampersands, emoji, Devanagari
    /// and every other non-ASCII symbol become explicit `%XX` sequences that
    /// Telegram decodes verbatim. Shared with `WhatsAppDeepLink` so the two
    /// deep links can never drift apart.
    static let textQueryValueAllowed: CharacterSet = WhatsAppDeepLink.textQueryValueAllowed

    /// Phone-formatting characters tolerated in an incoming phone identifier.
    /// They are stripped before the link is built; they are never part of the
    /// target. Deliberately narrow: a letter anywhere means "not a phone".
    private static let phoneFormatting = CharacterSet(charactersIn: "+-() ")

    /// Telegram username rules (core.telegram.org/mtproto/TL-types): 3-32
    /// characters, must start with a letter, then letters, digits, underscores.
    static func isValidUsername(_ candidate: String) -> Bool {
        guard candidate.count >= 3, candidate.count <= 32 else { return false }
        guard let first = candidate.first, first.isASCII, first.isLetter else { return false }
        return candidate.dropFirst().allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")
        }
    }

    /// Classifies an identifier as a phone or a username target.
    ///
    /// Order matters: a phone-shaped identifier (digits plus tolerated
    /// formatting) wins, then username validation, then refusal. The check is
    /// ASCII-only so non-Latin digits can never sneak into a phone link.
    static func target(for identifier: String) throws -> Target {
        var candidate = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("@") { candidate = String(candidate.dropFirst()) }
        guard !candidate.isEmpty else { throw BuildError.noResolvableIdentifier }

        let compact = candidate.components(separatedBy: phoneFormatting).joined()
        if compact.allSatisfy({ $0.isASCII && $0.isNumber }) {
            // Phone-normalized contact numbers are >= 8 digits (see
            // PhoneNormalizer); anything shorter is not a resolvable number.
            guard compact.count >= 8 else { throw BuildError.noResolvableIdentifier }
            return .phone(compact)
        }

        guard isValidUsername(candidate) else { throw BuildError.invalidUsername }
        return .username(candidate)
    }

    /// Builds the deep link for an identifier (username or phone) and a raw
    /// message body. The body is percent-encoded byte-for-byte from the user's
    /// words and is never rewritten.
    static func sendURL(identifier: String, text: String) throws -> URL {
        let target = try target(for: identifier)

        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: textQueryValueAllowed) else {
            throw BuildError.encodingFailed
        }

        let raw: String
        switch target {
        case .username(let name):
            raw = "tg://resolve?domain=\(name)&text=\(encoded)"
        case .phone(let digits):
            raw = "tg://resolve?phone=\(digits)&text=\(encoded)"
        }
        guard let url = URL(string: raw) else { throw BuildError.encodingFailed }
        return url
    }
}
