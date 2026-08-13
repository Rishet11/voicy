import Foundation

/// The single decision point for "may this message actually go out live?".
///
/// Every outbound path funnels through `SendGuard.decide`. It is pure: no I/O,
/// no globals, no environment variables, no CLI flags. That is what makes it
/// testable and what makes the guarantee auditable — there is one function to
/// read, and it fails closed in every branch it does not explicitly allow.
///
/// Three rails, checked in this order, cheapest and most absolute first:
///
///  1. **Kill switch.** A corrupt blocklist file or `neverSend` refuses
///     everything, including dry runs, because a user who thinks they are
///     protected and is not is the worst outcome this code can produce.
///  2. **Blocklist.** Both the phone number and the display name are checked,
///     under normalized matching (see `Blocklist.matches`).
///  3. **Allowlist.** During this build only `917982913080` may receive a live
///     message. Anyone else is refused outright — not downgraded, not queued.
///
/// Then, and only then, does the caller's confirmation matter: an unconfirmed
/// request becomes a forced dry run rather than a send. Defaulting to dry-run
/// means a future bug that forgets to pass confirmation cannot deliver a
/// message to the wrong person; it can only fail to deliver one.
enum SendGuard {

    /// Who may receive a live message in this build.
    ///
    /// Hardcoded on purpose. An env var or a CLI flag would be one typo away
    /// from a live send to a stranger, and the project ships with neither.
    /// Stored as E.164 digits, no leading `+`.
    static let allowedRecipients: Set<String> = ["917982913080"]

    /// Why a request was not allowed to go out live. Every case is distinct so
    /// the caller (and the tests) can tell exactly which rail fired.
    enum Refusal: Equatable {
        /// Blocklist file present but unparseable. Fail closed.
        case blocklistUnreadable
        /// Master `neverSend` switch is on.
        case neverSend
        /// This number or name is on the blocklist.
        case blocklisted(contact: String)
        /// Not `917982913080`. Nothing is opened.
        case notAllowlisted(phone: String)
        /// No digits in the phone number: no deep link can be built.
        case noPhoneDigits

        var reason: String {
            switch self {
            case .blocklistUnreadable: return "blocklist unreadable; refusing to send (fail closed)"
            case .neverSend: return "neverSend kill-switch is on"
            case .blocklisted(let c): return "'\(SendGuard.maskIdentifier(c))' is blocklisted"
            case .notAllowlisted(let p): return "\(SendGuard.maskPhone(p)) is not on the send allowlist"
            case .noPhoneDigits: return "recipient has no usable phone digits"
            }
        }
    }

    /// What the caller is allowed to do.
    enum Decision: Equatable {
        /// Every rail passed and the caller explicitly confirmed. Open for real.
        case live
        /// Nothing is wrong, but the caller did not explicitly confirm, so the
        /// request is downgraded rather than executed.
        case forcedDryRun
        /// The caller asked for a dry run and gets one.
        case dryRun
        /// Refused. Nothing is opened, posted or logged beyond the reason.
        case refused(Refusal)
    }

    /// - Parameters:
    ///   - phone: recipient, E.164 digits (a `+` and formatting are tolerated).
    ///   - contactName: display name, also checked against the blocklist.
    ///   - blocklist: the loaded kill switch.
    ///   - confirmed: true ONLY when a human explicitly confirmed this exact
    ///     recipient and body. Callers must never default this to true.
    ///   - requestedDryRun: the caller asked for a dry run outright.
    static func decide(phone: String,
                       contactName: String?,
                       blocklist: Blocklist,
                       confirmed: Bool,
                       requestedDryRun: Bool) -> Decision {
        // 1. Kill switch, before anything else, including dry runs.
        if case .corrupt = blocklist.state { return .refused(.blocklistUnreadable) }
        if blocklist.neverSend { return .refused(.neverSend) }

        // 2. Blocklist, on both identifiers.
        for identifier in [contactName, phone].compactMap({ $0 }) where blocklist.contains(identifier) {
            return .refused(.blocklisted(contact: identifier))
        }

        // 3. A target we cannot dial is a failure, not a silent no-op.
        let digits = phone.filter(\.isNumber)
        guard !digits.isEmpty else { return .refused(.noPhoneDigits) }

        // 4. Allowlist. Checked even for dry runs so the tests exercise the
        //    same rail the live path uses, and so a dry run can never be
        //    "promoted" later by a caller that only re-reads the outcome.
        guard allowedRecipients.contains(digits) else {
            return .refused(.notAllowlisted(phone: digits))
        }

        // 5. Confirmation. Absent it, downgrade — never proceed.
        if requestedDryRun { return .dryRun }
        return confirmed ? .live : .forcedDryRun
    }

    // MARK: - Redaction

    /// Phone numbers appear in logs only as their last 4 digits. Message
    /// bodies never appear at all (CLAUDE.md: never store message content).
    static func maskPhone(_ phone: String) -> String {
        let digits = phone.filter(\.isNumber)
        guard digits.count > 4 else { return String(repeating: "*", count: digits.count) }
        return "*******" + digits.suffix(4)
    }

    /// A blocklist hit may be a name or a number; mask numbers, keep names
    /// (the user typed the name into their own blocklist, and seeing which
    /// entry fired is the point of the log line).
    static func maskIdentifier(_ identifier: String) -> String {
        let digits = identifier.filter(\.isNumber)
        return digits.count >= 7 ? maskPhone(identifier) : identifier
    }
}
