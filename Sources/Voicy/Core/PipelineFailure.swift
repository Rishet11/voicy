import Foundation

/// A user-actionable failure at the recording/transcription boundary.
///
/// These are deliberately named rather than inferred from log text.  The UI
/// and diagnostics can therefore give the same answer for a denied permission,
/// a short keypress, and an engine failure without exposing message content.
enum PipelineFailure: Error, Equatable, CustomStringConvertible {
    case hotkeyUnavailable
    case microphonePermissionDenied
    case speechRecognitionPermissionDenied
    case contactsPermissionDenied
    case recordingAlreadyActive
    case transcriptionInProgress
    case microphoneStartFailed
    case noSpeechDetected
    case transcriptionFailed
    case speechModelUnavailable(locale: String)
    case noRecipient
    case ambiguousRecipient
    case recipientHasNoPhoneNumber
    case whatsappNotInstalled
    case whatsappUnavailable

    var description: String {
        switch self {
        case .hotkeyUnavailable:
            return "HotkeyUnavailable: Ctrl+Space is already in use. Choose another hotkey in Settings."
        case .microphonePermissionDenied:
            return "MicrophonePermissionDenied: allow Voicy in System Settings > Privacy & Security > Microphone, then try again."
        case .speechRecognitionPermissionDenied:
            return "SpeechRecognitionPermissionDenied: allow Voicy in System Settings > Privacy & Security > Speech Recognition, then try again."
        case .contactsPermissionDenied:
            return "ContactsPermissionDenied: allow Voicy in System Settings > Privacy & Security > Contacts, then try again."
        case .recordingAlreadyActive:
            return "RecordingAlreadyActive: release the key before starting another recording."
        case .transcriptionInProgress:
            return "TranscriptionInProgress: wait for the previous transcription to finish, then try again."
        case .microphoneStartFailed:
            return "MicrophoneStartFailed: select a working input in System Settings > Sound > Input, then try again."
        case .noSpeechDetected:
            return "NoSpeechDetected: no speech was captured. Hold the key while speaking and try again."
        case .transcriptionFailed:
            return "TranscriptionFailed: speech could not be transcribed. Check Speech Recognition permission and try again."
        case .speechModelUnavailable(let locale):
            return "SpeechModelUnavailable: no speech model is installed for \(locale). Choose an installed language in Settings."
        case .noRecipient:
            return "RecipientNotFound: no contact matched. Say the contact's full name and try again."
        case .ambiguousRecipient:
            return "RecipientAmbiguous: more than one contact matched. Choose the intended contact."
        case .recipientHasNoPhoneNumber:
            return "RecipientHasNoPhoneNumber: add a phone number to this contact in Contacts, then try again."
        case .whatsappNotInstalled:
            return "WhatsAppNotInstalled: install WhatsApp for Mac, then try again."
        case .whatsappUnavailable:
            return "WhatsAppUnavailable: open WhatsApp and try again."
        }
    }
}
