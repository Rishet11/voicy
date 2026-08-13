import AVFoundation
import Speech

enum VoicyPermissionState: Equatable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

enum VoicyPermissions {
    static var microphone: VoicyPermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: return .authorized
        @unknown default: return .restricted
        }
    }

    static var speechRecognition: VoicyPermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: return .authorized
        @unknown default: return .restricted
        }
    }

    static func requestMicrophone() async -> Bool {
        guard microphone == .notDetermined else { return microphone == .authorized }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func requestSpeechRecognition() async -> Bool {
        guard speechRecognition == .notDetermined else {
            return speechRecognition == .authorized
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
