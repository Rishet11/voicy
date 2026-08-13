import AVFoundation
import Foundation
import Speech
import os

/// Streaming transcription: text that appears while the user is still talking,
/// and a clean final result when they stop.
///
/// Today the app records the whole utterance, then transcribes it in one call
/// after the key is released. Everything the recognizer produced while the user
/// was speaking is thrown away, so the user stares at nothing until they let go
/// and then waits again. That is most of the difference in feel between this
/// and a dictation product that streams.
///
/// `SpeechTranscriber.Preset.progressiveTranscription` reports volatile
/// results, which is the mechanism for this. A volatile result is the
/// recognizer's current guess for audio it has not finished with; it will be
/// revised, and it is replaced wholesale by the finalized text for the same
/// span. So the rule here is strict: **volatile text is for display only.**
/// `finish()` returns finalized segments only, exactly like the one-shot path,
/// so nothing downstream ever consumes a guess that was later revised.
@available(macOS 26.0, *)
final class LiveTranscriptionSession: @unchecked Sendable {

    /// Called on every revision with the best current reading of the whole
    /// utterance: finalized text plus the current volatile tail.
    private let onPartial: @Sendable (String) -> Void

    private let module: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let locale: Locale
    private let hints: [String]

    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var collector: Task<TranscriptionResult, Error>?
    private var analysis: Task<Void, Never>?
    private var analysisFormat: AVAudioFormat?

    /// Finalized segments and the current volatile tail. The collector task
    /// writes them while a UI thread reads `currentText`, so they live behind a
    /// lock. `OSAllocatedUnfairLock` rather than `NSLock` because this is
    /// touched from async contexts and NSLock is unavailable there.
    private struct State {
        var finalized: [TranscriptionSegment] = []
        var volatileTail = ""
        var text: String { finalized.map(\.best).joined() + volatileTail }
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(locale: Locale, hints: [String], onPartial: @escaping @Sendable (String) -> Void) {
        self.locale = locale
        self.hints = hints
        self.onPartial = onPartial
        self.module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        self.analyzer = SpeechAnalyzer(modules: [module])
    }

    /// The text a UI should be showing right now.
    var currentText: String {
        state.withLock { $0.text }
    }

    /// Brings up the analyzer and starts consuming results. Call once, before
    /// the first `append`.
    func start() async throws {
        let context = AnalysisContext()
        if !hints.isEmpty {
            context.contextualStrings[.general] = hints
        }
        try await analyzer.setContext(context)

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
            ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        analysisFormat = format
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation

        collector = Task { [module, onPartial] in
            for try await result in module.results {
                let text = String(result.text.characters)
                let alternatives = result.alternatives.map { String($0.characters) }
                let snapshot = self.state.withLock { state -> String in
                    if result.isFinal {
                        // A finalized result supersedes the volatile guess for
                        // the same span. Dropping the tail here is what stops
                        // finalized text being shown twice.
                        state.finalized.append(TranscriptionSegment(best: text, alternatives: alternatives))
                        state.volatileTail = ""
                    } else {
                        state.volatileTail = text
                    }
                    return state.text
                }
                onPartial(snapshot)
            }
            return TranscriptionResult(segments: self.state.withLock { $0.finalized })
        }

        analysis = Task { [analyzer] in
            _ = try? await analyzer.analyzeSequence(stream)
        }
    }

    /// Feeds captured audio. Safe to call from the microphone tap.
    func append(_ pcm: [Float]) {
        guard let format = analysisFormat, let continuation else { return }
        guard let buffer = SpeechBufferFactory.makeBuffer(from: pcm, to: format) else { return }
        continuation.yield(AnalyzerInput(buffer: buffer))
    }

    /// Closes the input, waits for the recognizer to finalize everything it has,
    /// and returns FINALIZED text only. No volatile guess can reach a caller
    /// through this.
    func finish() async throws -> TranscriptionResult {
        continuation?.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let result = try await collector?.value ?? TranscriptionResult(segments: [])
        analysis?.cancel()
        return result
    }

    /// Abandons the session without producing a transcript. Used when the user
    /// cancels mid-utterance.
    func cancel() {
        continuation?.finish()
        collector?.cancel()
        analysis?.cancel()
        state.withLock { $0 = State() }
    }
}
