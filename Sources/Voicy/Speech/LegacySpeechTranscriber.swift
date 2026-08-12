import AVFoundation
import Foundation
import Speech

/// Fallback engine: the legacy `SFSpeechRecognizer` with
/// `requiresOnDeviceRecognition = true`, used on macOS < 26.
///
/// Hints are forwarded to `SFSpeechRecognitionRequest.contextualStrings`.
final class LegacySpeechTranscriber: Transcriber {
    enum LegacyError: Error {
        case recognizerUnavailable
        case invalidAudio
    }

    private let locale: Locale

    init(locale: Locale = Locale(identifier: "en_US")) {
        self.locale = locale
    }

    /// Requests (and waits for) speech recognition permission.
    static func requestAuthorization() async -> Bool {
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { s in
                cont.resume(returning: s)
            }
        }
        return status == .authorized
    }

    func transcribe(pcm: [Float], hints: [String]) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw LegacyError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        if !hints.isEmpty {
            request.contextualStrings = hints
        }

        guard let buffer = makePCMBuffer(from: pcm) else {
            throw LegacyError.invalidAudio
        }
        request.append(buffer)
        request.endAudio()

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                cont.resume(returning: result.bestTranscription.formattedString)
            }
        }
    }

    private func makePCMBuffer(from pcm: [Float]) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(pcm.count)
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        pcm.withUnsafeBufferPointer { src in
            channel.update(from: src.baseAddress!, count: pcm.count)
        }
        return buffer
    }
}