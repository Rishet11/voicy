import Foundation

/// Normalizes raw phone strings to E.164 digits WITHOUT the leading '+', which
/// is the format the WhatsApp deep link requires.
///
/// Indian numbers are the primary case. "98765 43210", "+91 98765 43210" and
/// "098765 43210" all become "919876543210".
public enum PhoneNormalizer {

    /// Returns E.164 digits (no '+') or nil if the input is not a usable number.
    public static func normalize(_ raw: String) -> String? {
        let cleaned = raw.filter { $0.isNumber || $0 == "+" }
        guard !cleaned.isEmpty else { return nil }
        var digits = cleaned.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }

        if cleaned.hasPrefix("+") {
            // A leading '+' marks an explicit international number. Drop any
            // national trunk-prefix zero that follows the country code
            // (e.g. "+91 09876..." -> "9109876..." -> "919876...").
            while digits.hasPrefix("0") { digits.removeFirst() }
            if digits.count >= 12 && digits.hasPrefix("910") {
                digits.remove(at: digits.index(digits.startIndex, offsetBy: 2))
            }
            guard digits.count >= 8 && digits.count <= 15 else { return nil }
            return String(digits)
        }

        // No '+': drop the national trunk prefix zero.
        while digits.hasPrefix("0") { digits.removeFirst() }

        switch digits.count {
        case ..<10:
            return nil
        case 10:
            // 10-digit national number -> assume an Indian mobile.
            return "91" + String(digits)
        case 11...15:
            // Already carries a country code (e.g. "91..."). Keep as-is.
            return String(digits)
        default:
            return nil
        }
    }
}