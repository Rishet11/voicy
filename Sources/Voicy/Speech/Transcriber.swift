import AVFoundation
import Foundation
import Speech

/// The transcription engine contract. Returned by `TranscriberFactory.make()`.
/// The orchestrator swaps the engine behind this protocol.
protocol Transcriber: Sendable {
    /// Transcribes 16 kHz mono Float32 PCM into a string, biased toward `hints`
    /// (expected words such as known contact names).
    func transcribe(pcm: [Float], hints: [String]) async throws -> String
}

/// Builds the best transcription engine available on the running OS.
enum TranscriberFactory {
    static func make(locale: Locale = Locale(identifier: "en_US")) -> Transcriber {
        if #available(macOS 26.0, *) {
            return SpeechAnalyzerTranscriber(locale: locale)
        } else {
            return LegacySpeechTranscriber(locale: locale)
        }
    }
}

/// Pays the on-device model load cost once, at launch, instead of on the user's
/// first sentence.
///
/// Measured on this machine with the audio-injection harness
/// (`--test-latency`, `--test-audio`): the FIRST `transcribe` call after process
/// start costs ~920 ms, and every call after it costs ~130-210 ms for the same
/// clip. The cost is process-global model loading, not per-instance setup, so a
/// single throwaway call at startup moves the whole 920 ms off the critical
/// path. That is the difference between blowing the 800 ms end-of-speech budget
/// on the first utterance and landing inside it every time.
///
/// Deliberately fire-and-forget: warm-up must never delay app launch, and a
/// failure here is harmless because the next real call just pays the cost the
/// old way.
enum TranscriberWarmup {

    /// Half a second of silence: long enough to force the model to load, short
    /// enough to be effectively free, and it transcribes to nothing so no state
    /// is polluted.
    private static let silenceSampleCount = 8_000

    static func warm(_ engine: Transcriber) async {
        let t0 = Date()
        let silence = [Float](repeating: 0, count: silenceSampleCount)
        do {
            _ = try await engine.transcribe(pcm: silence, hints: [])
            let ms = Date().timeIntervalSince(t0) * 1000
            print("[voicy] engine: warmed in \(String(format: "%.1f", ms)) ms "
                  + "(this cost is now OFF the first utterance)")
        } catch {
            // Non-fatal by design. The first real utterance will simply pay the
            // load cost itself, exactly as it did before warm-up existed.
            print("[voicy] engine: warm-up skipped (\(error))")
        }
    }
}

/// Primary engine: the new macOS 26 Speech framework
/// (`SpeechAnalyzer` + `SpeechTranscriber`).
///
/// Hints are forwarded via `AnalysisContext.contextualStrings[.general]`, the
/// new-framework equivalent of the legacy `contextualStrings` list.
@available(macOS 26.0, *)
final class SpeechAnalyzerTranscriber: Transcriber {
    private let locale: Locale

    init(locale: Locale) {
        self.locale = locale
    }

    func transcribe(pcm: [Float], hints: [String]) async throws -> String {
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [module])

        // Bias recognition toward expected words (contact names).
        let context = AnalysisContext()
        if !hints.isEmpty {
            context.contextualStrings[.general] = hints
        }
        try await analyzer.setContext(context)

        // Match the analyzer's preferred format so the module accepts our audio.
        let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
            ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

        try await analyzer.prepareToAnalyze(in: analysisFormat)

        guard let buffer = makeBuffer(from: pcm, to: analysisFormat) else {
            throw TranscribeFailure.invalidAudio
        }

        // Collect results as the analyzer runs, then feed and finalize.
        let collector = Task { () -> String in
            var text = ""
            for try await result in module.results {
                if result.isFinal {
                    text = String(result.text.characters)
                }
            }
            return text
        }

        let input = AnalyzerInput(buffer: buffer)
        _ = try await analyzer.analyzeSequence(SingleInputSequence(input: input))
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        return try await collector.value
    }

    /// Builds an `AVAudioPCMBuffer` in `format` from raw Float32 samples,
    /// converting when the target format differs from 16 kHz mono Float32.
    private func makeBuffer(from pcm: [Float], to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!

        guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(pcm.count)) else {
            return nil
        }
        source.frameLength = AVAudioFrameCount(pcm.count)
        pcm.withUnsafeBufferPointer { src in
            source.floatChannelData![0].update(from: src.baseAddress!, count: pcm.count)
        }

        if format.sampleRate == sourceFormat.sampleRate
            && format.channelCount == 1
            && format.commonFormat == sourceFormat.commonFormat
            && !format.isInterleaved {
            return source
        }

        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: source.frameCapacity) else { return nil }
        let converter = AVAudioConverter(from: sourceFormat, to: format)
        var error: NSError?
        let status = converter?.convert(to: out, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return source
        }
        guard status == .haveData || status == .inputRanDry else { return nil }
        return out
    }

    enum TranscribeFailure: Error {
        case invalidAudio
    }
}

/// A single-element `AsyncSequence` of `AnalyzerInput`, used to feed one
/// captured clip into `SpeechAnalyzer.analyzeSequence(_:)`.
@available(macOS 26.0, *)
struct SingleInputSequence: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput

    let input: AnalyzerInput

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(input: input)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        let input: AnalyzerInput
        var yielded = false

        mutating func next() async -> AnalyzerInput? {
            if yielded { return nil }
            yielded = true
            return input
        }
    }
}
