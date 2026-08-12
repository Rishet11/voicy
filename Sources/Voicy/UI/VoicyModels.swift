import Foundation

// MARK: - UI-facing data types
//
// The UI owns only `Sources/Voicy/UI/*`. It must not reach into other workers'
// directories, so it declares its own small data model here. The orchestrator
// (W1) maps the Contacts/Intent results onto these types before handing them to
// the panels. Nothing here is a "fake": it is the exact display data the UI renders.

/// A recipient the user may send to, as the UI presents it.
/// Carries only display strings plus the exact E.164 digits the sender needs.
public struct VoicyRecipient: Identifiable, Equatable, Sendable {
    public var id: String
    /// Full display name, e.g. "Rahul Mehta".
    public var displayName: String
    /// Given name alone, used for the "Which <name>?" header.
    public var givenName: String
    /// Family name alone, emphasized in the ambiguous picker.
    public var familyName: String
    /// What to show for the number, e.g. "+91 98765 43210".
    public var phoneDisplay: String
    /// Exact E.164 digits (no '+') for the deep link, if known.
    public var phoneE164: String?
    /// Destination app name, e.g. "WhatsApp".
    public var appName: String
    /// SF Symbol name for the destination app icon.
    public var appSymbol: String

    public init(id: String,
                displayName: String,
                givenName: String,
                familyName: String,
                phoneDisplay: String,
                phoneE164: String?,
                appName: String,
                appSymbol: String) {
        self.id = id
        self.displayName = displayName
        self.givenName = givenName
        self.familyName = familyName
        self.phoneDisplay = phoneDisplay
        self.phoneE164 = phoneE164
        self.appName = appName
        self.appSymbol = appSymbol
    }
}

/// Everything the confirm card needs to render, in one value.
/// The three states are derived from its contents:
///   - exactly one recipient  → resolved (name + number + editable body)
///   - more than one recipient → ambiguous ("Which <name>?")
///   - zero recipients          → not found (shows the transcript)
public struct VoicyConfirmPayload: Equatable, Sendable {
    /// The recipient(s) to confirm.
    public var recipients: [VoicyRecipient]
    /// The message body, byte-for-byte from the transcript.
    public var message: String
    /// Set when nothing matched, to show the user what was actually heard.
    public var transcript: String?

    public init(recipients: [VoicyRecipient], message: String, transcript: String?) {
        self.recipients = recipients
        self.message = message
        self.transcript = transcript
    }
}