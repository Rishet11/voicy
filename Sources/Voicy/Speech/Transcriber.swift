import AVFoundation
import Foundation
import Speech

/// What an engine heard: its best guess, plus any competing hypotheses it was
/// willing to offer for the same audio.
///
/// The alternatives matter because Apple's contextual-string biasing turned out
/// to do nothing measurable on this engine (verified by running the audio
/// harness with and without contact-name hints: the transcripts came back
/// byte-identical). Names therefore come back mangled — "Pulkit" as "Polkit",
/// "Aarav" as "our ab". When the recognizer offers a second hypothesis that
/// contains a name we actually know, that is a far better signal than trying to
/// repair the mangled text ourselves.
/// One finalized chunk of a transcript, with whatever competing readings the
/// engine offered for that chunk specifically.
///
/// The engine finalizes in segments, not all at once, and alternatives are
/// scoped to the segment that produced them. Keeping that structure is what
/// makes single-word recovery possible without inventing text.
struct TranscriptionSegment: Sendable {
    let best: String
    let alternatives: [String]
}

struct TranscriptionResult: Sendable {
    /// Finalized segments in order. Concatenating their `best` values
    /// reconstructs the full transcript exactly.
    let segments: [TranscriptionSegment]

    init(segments: [TranscriptionSegment]) {
        self.segments = segments
    }

    init(best: String, alternatives: [String] = []) {
        self.segments = [TranscriptionSegment(best: best, alternatives: alternatives)]
    }

    /// The engine's primary reading of the whole utterance.
    var best: String {
        segments.map(\.best).joined()
    }

    /// Flat list of every alternative the engine offered, for diagnostics.
    var alternatives: [String] {
        segments.flatMap(\.alternatives)
    }

    /// Whole-utterance readings built by swapping exactly ONE segment for one of
    /// its alternatives, primary first.
    ///
    /// Single substitution is the point. The failure being repaired is "one word
    /// came out wrong" (the harness reproducibly hears "Aarav" as "our ab"), and
    /// swapping one segment at a time stays linear in the number of alternatives
    /// while covering that case exactly. Combining substitutions would grow
    /// exponentially and would start assembling sentences the engine never
    /// actually proposed.
    ///
    /// Every string returned here is a reading the RECOGNIZER produced. Nothing
    /// is composed, corrected or reworded by us.
    var hypotheses: [String] {
        var seen = Set<String>()
        var out: [String] = []

        func add(_ candidate: String) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            out.append(candidate)
        }

        add(best)
        for (index, segment) in segments.enumerated() {
            for alternative in segment.alternatives {
                var swapped = segments.map(\.best)
                swapped[index] = alternative
                add(swapped.joined())
            }
        }
        return out
    }
}

/// Send-path seam: only finalized results are converted to text.
enum FinalTranscriptGate {
    static func text(from result: TranscriptionResult) -> String { result.best }
}

/// The transcription engine contract. Returned by `TranscriberFactory.make()`.
/// The orchestrator swaps the engine behind this protocol.
protocol Transcriber: Sendable {
    /// Transcribes 16 kHz mono Float32 PCM into a string, biased toward `hints`
    /// (expected words such as known contact names).
    func transcribe(pcm: [Float], hints: [String]) async throws -> String

    /// Transcribes and also returns competing hypotheses when the engine has
    /// them. Engines that cannot produce alternatives inherit the default, which
    /// simply wraps `transcribe`, so no engine is forced to fake them.
    func transcribeDetailed(pcm: [Float], hints: [String]) async throws -> TranscriptionResult
}

extension Transcriber {
    func transcribeDetailed(pcm: [Float], hints: [String]) async throws -> TranscriptionResult {
        TranscriptionResult(best: try await transcribe(pcm: pcm, hints: hints))
    }
}

/// Builds the best transcription engine available on the running OS.
enum TranscriberFactory {
    /// The shipped engine, nothing else. No environment variables, no launch
    /// flags: the locale resolves via `TranscriberLocale.requestedLocale()`
    /// (persisted user setting, else the system locale, else `en_US`), and
    /// every engine re-validates it against what the machine has installed,
    /// falling back sanely when it is unavailable.
    ///
    /// The legacy engine stays constructible directly for compatibility with
    /// older macOS versions; it is not selected by environment or flags.
    static func make(
        locale: Locale = TranscriberLocale.requestedLocale()
    ) -> Transcriber {
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

/// Builds an `AVAudioPCMBuffer` in `format` from raw Float32 samples,
/// converting when the target format differs from 16 kHz mono Float32.
/// Shared by the SpeechAnalyzer-based engines.
enum SpeechBufferFactory {
    static func makeBuffer(from pcm: [Float], to format: AVAudioFormat) -> AVAudioPCMBuffer? {
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
}

enum AudioTranscribeFailure: Error {
    case invalidAudio
}

/// Primary engine: the new macOS 26 Speech framework
/// (`SpeechAnalyzer` + `SpeechTranscriber`).
///
/// Hints are forwarded via `AnalysisContext.contextualStrings[.general]`, the
/// new-framework equivalent of the legacy `contextualStrings` list.
@available(macOS 26.0, *)
final class SpeechAnalyzerTranscriber: Transcriber {
    private let locale: Locale
    /// Effective locale, resolved once against the machine's installed
    /// inventory. If the requested locale is not installed, this is the
    /// fallback `TranscriberLocale` picked (never an unavailable locale).
    private let resolvedLocale: Task<Locale, Never>

    init(locale: Locale) {
        self.locale = locale
        self.resolvedLocale = Task { await TranscriberLocale.availableLocale(for: locale).locale }
    }

    func transcribe(pcm: [Float], hints: [String]) async throws -> String {
        try await transcribeDetailed(pcm: pcm, hints: hints).best
    }

    func transcribeDetailed(pcm: [Float], hints: [String]) async throws -> TranscriptionResult {
        // MEASURED, do not "improve" this back to `.transcriptionWithAlternatives`.
        //
        // Asking for alternatives was tried as a way to recover mangled contact
        // names, since contextual-string biasing measurably does nothing on this
        // engine. Both halves of that idea failed on real audio:
        //
        //   Accuracy: the alternatives are near-duplicates of the primary. For a
        //   clip where "Aarav" was heard as "our ab", the five alternatives were
        //   "our Av", "our av", "our Ab", "our ad" — no reading contained a real
        //   contact name. Most alternatives differ only in capitalization.
        //
        //   Cost: median transcription over the 22-clip suite went from 139 ms to
        //   277 ms, and the longest clip went from 321 ms to 829 ms, which breaks
        //   the 800 ms end-of-speech budget outright.
        //
        // Doubling latency for no accuracy gain is a bad trade, so the plain
        // preset stays. Mangled names are handled where they can actually be
        // fixed: fuzzy/phonetic contact matching, and alias learning, which makes
        // a name the user corrects once resolve instantly forever after.
        let module = SpeechTranscriber(locale: await resolvedLocale.value, preset: .transcription)
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

        guard let buffer = SpeechBufferFactory.makeBuffer(from: pcm, to: analysisFormat) else {
            throw AudioTranscribeFailure.invalidAudio
        }

        // Collect results as the analyzer runs, then feed and finalize.
        let collector = Task { () -> TranscriptionResult in
            // ACCUMULATE. The analyzer finalizes in segments, so a long sentence
            // arrives as several `isFinal` results. Overwriting on each one (the
            // previous behaviour) silently truncated the transcript to its last
            // segment — the harness caught it turning a full sentence into
            // " ab.". Appending is correct for both one-shot and segmented runs.
            var segments: [TranscriptionSegment] = []
            for try await result in module.results where result.isFinal {
                segments.append(TranscriptionSegment(
                    best: String(result.text.characters),
                    alternatives: result.alternatives.map { String($0.characters) }
                ))
            }
            return TranscriptionResult(segments: segments)
        }

        let input = AnalyzerInput(buffer: buffer)
        _ = try await analyzer.analyzeSequence(SingleInputSequence(input: input))
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        return try await collector.value
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
