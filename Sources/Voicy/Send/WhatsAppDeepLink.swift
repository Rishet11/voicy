import Foundation

/// Builds the `whatsapp://send?phone=...&text=...` deep link that opens
/// WhatsApp for Mac and pre-fills the message in the composer.
///
/// Verified live: opening this URL puts WhatsApp in the foreground with the
/// message text already in the input field, UNSENT. That is the end of Voicy's
/// involvement: the user presses Return themselves. Nothing here or in
/// `WhatsAppSender` synthesizes that keystroke.
enum WhatsAppDeepLink {
    /// Characters allowed un-encoded in the `text` query value.
    ///
    /// This is deliberately NOT `CharacterSet.urlQueryAllowed` (which leaves
    /// `&`, `+`, `=`, `?`, `/` and every non-ASCII symbol un-encoded and would
    /// let them corrupt the query or WhatsApp's parser). We keep only the RFC
    /// 3986 unreserved ASCII set plus nothing else, so spacing, newlines,
    /// ampersands, emoji, Devanagari, plus signs, etc. all become explicit
    /// `%XX` sequences that WhatsApp decodes verbatim.
    static let textQueryValueAllowed: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    /// A malformed deep link (e.g. no phone digits) is a `nil` return.
    enum BuildError: Error {
        case noPhoneDigits
        case encodingFailed
    }

    /// Builds the deep link for a phone number (E.164, no leading `+`) and a
    /// raw message body. The body is percent-encoded byte-for-byte from the
    /// user's words and is never rewritten.
    static func sendURL(phone: String, text: String) throws -> URL {
        // E.164 digits only; strip any stray formatting so the target is exact.
        let digits = phone.filter(\.isNumber)
        guard !digits.isEmpty else { throw BuildError.noPhoneDigits }

        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: textQueryValueAllowed) else {
            throw BuildError.encodingFailed
        }

        let raw = "whatsapp://send?phone=\(digits)&text=\(encoded)"
        guard let url = URL(string: raw) else { throw BuildError.encodingFailed }
        return url
    }
}