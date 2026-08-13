import Foundation

/// Pure checks for the named failure contract. These require no microphone,
/// permissions, contacts, or WhatsApp and run as part of `--selftest`.
func runPipelineFailureTests() -> (passed: Int, failed: Int) {
    let failures: [PipelineFailure] = [
        .hotkeyUnavailable, .microphonePermissionDenied,
        .speechRecognitionPermissionDenied, .contactsPermissionDenied,
        .recordingAlreadyActive, .transcriptionInProgress,
        .microphoneStartFailed, .noSpeechDetected, .transcriptionFailed,
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
    print("Pipeline failure contract: \(passed) passed, \(failed) failed")
    return (passed, failed)
}
