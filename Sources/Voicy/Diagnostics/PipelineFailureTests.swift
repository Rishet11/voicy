import Foundation

/// Pure checks for the named failure contract. These require no microphone,
/// permissions, contacts, or WhatsApp and run as part of `--selftest`.
func runPipelineFailureTests() -> (passed: Int, failed: Int) {
    let failures: [PipelineFailure] = [
        .hotkeyUnavailable, .microphonePermissionDenied,
        .microphonePermissionNotDetermined, .speechRecognitionPermissionDenied,
        .speechRecognitionPermissionNotDetermined, .contactsPermissionDenied,
        .recordingAlreadyActive, .transcriptionInProgress,
        .microphoneStartFailed, .noInputDevice,
        .deviceDeliveredZeroSamples, .noSpeechDetected, .transcriptionFailed,
        .speechModelUnavailable(locale: "xx_XX"), .noRecipient,
        .ambiguousRecipient, .recipientHasNoPhoneNumber,
        .whatsappNotInstalled, .whatsappUnavailable,
    ]
    var passed = 0
    var failed = 0
    for failure in failures {
        let text = failure.description
        if text.contains(":") && text.count > 20 {
            passed += 1
        } else {
            failed += 1
            print("FAIL  named failure is not actionable")
        }
    }

    let requiredNames: [(PipelineFailure, String)] = [
        (.microphonePermissionDenied, "MicrophonePermissionDenied"),
        (.microphonePermissionNotDetermined, "MicrophonePermissionNotDetermined"),
        (.speechRecognitionPermissionDenied, "SpeechRecognitionPermissionDenied"),
        (.speechRecognitionPermissionNotDetermined, "SpeechRecognitionPermissionNotDetermined"),
        (.noInputDevice, "NoInputDevice"),
        (.deviceDeliveredZeroSamples, "DeviceDeliveredZeroSamples"),
        (.noSpeechDetected, "NoSpeechDetected"),
    ]
    for (failure, name) in requiredNames {
        if failure.description.hasPrefix(name + ":") {
            passed += 1
        } else {
            failed += 1
            print("FAIL  missing named recording failure: \(name)")
        }
    }
    if PipelineFailure.noSpeechDetected.description.contains("audio was captured") {
        passed += 1
    } else {
        failed += 1
        print("FAIL  NoSpeechDetected does not say audio was captured")
    }
    print("Pipeline failure contract: \(passed) passed, \(failed) failed")
    return (passed, failed)
}
