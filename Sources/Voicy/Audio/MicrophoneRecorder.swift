import AVFoundation
import Foundation

/// Captures microphone input to 16 kHz mono Float32 PCM in memory.
///
/// The hardware input format is almost never 16 kHz mono; we convert every
/// tap buffer through `AVAudioConverter` to the canonical analysis format
/// (16 kHz, mono, non-interleaved Float32) so the transcriber always sees a
/// known layout regardless of the hardware.
final class MicrophoneRecorder {
    enum RecordError: Error {
        case engineStartFailed
        case noInputDevice
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var pcmSamples: [Float] = []

    /// Delivers each converted capture chunk while recording.
    var onSamples: (@Sendable ([Float]) -> Void)?

    /// The 16 kHz mono Float32 samples captured since `start()`.
    var captured: [Float] { pcmSamples }

    // MARK: Onset instrumentation
    //
    // The augmented corpus measured that losing the first 250 ms of an
    // utterance costs more accuracy than mixing in noise at 5 dB SNR (21.6% WER
    // vs 20.5%, CER 16.7% vs 10.3%). Capture begins when the user presses the
    // key, so any delay between the keypress and the first real sample is
    // audio the recognizer never sees. These two timestamps measure that delay
    // instead of assuming it.

    /// When `start()` was called, i.e. as close to the keypress as this class
    /// can observe.
    private(set) var startedAt: Date?

    /// When the first tap buffer carrying samples arrived.
    private(set) var firstBufferAt: Date?

    /// Milliseconds between `start()` and the first tap CALLBACK.
    ///
    /// This is NOT the amount of audio lost, and reading it as such
    /// overstates the problem. A tap of 4096 frames at 48 kHz cannot fire
    /// until 85 ms of audio has been collected, and that 85 ms is inside the
    /// buffer, not missing. Use `capturedGapMs` for the audio that is actually
    /// gone.
    var onsetGapMs: Double? {
        guard let startedAt, let firstBufferAt else { return nil }
        return firstBufferAt.timeIntervalSince(startedAt) * 1000
    }

    /// `start()` in mach absolute time, paired with the hardware timestamp of
    /// the first captured frame, so the two can be compared on the same clock.
    private var startedAtHost: UInt64?
    private var firstSampleHost: UInt64?

    /// Milliseconds of audio that genuinely never reached us: from the
    /// `start()` call to the hardware timestamp of the FIRST captured sample.
    ///
    /// This is the number the pre-roll question turns on. Whatever it is, it
    /// is audio the recognizer will never see, because it was never recorded
    /// by anything.
    var capturedGapMs: Double? {
        guard let startedAtHost, let firstSampleHost, firstSampleHost > startedAtHost else { return nil }
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = Double(firstSampleHost - startedAtHost) * Double(info.numer) / Double(info.denom)
        return nanos / 1_000_000
    }

    var isRunning: Bool { engine.isRunning }

    /// True when macOS exposes an input device for capture. This check is
    /// deliberately separate from permission: an authorised Mac can still
    /// have no usable microphone connected.
    var hasInputDevice: Bool { AVCaptureDevice.default(for: .audio) != nil }

    /// Cached hardware input format, resolved once by `prewarm()`.
    private var cachedInputFormat: AVAudioFormat?

    /// Pays the audio graph's setup cost at launch instead of at key-down.
    ///
    /// Measured with `--test-latency`: a cold `start()` takes ~296 ms against a
    /// 100 ms budget. Most of that is first-touch work — bringing up the audio
    /// HAL via `inputNode`, resolving the hardware format, and building the
    /// sample-rate converter — none of which depends on the user pressing
    /// anything. Doing it at launch means key-down only has to install a tap and
    /// call `start()`.
    ///
    /// This does NOT open the microphone. `AVAudioEngine.prepare()` allocates
    /// resources without running the graph, so the macOS recording indicator
    /// stays off until the user actually holds the key. Keeping the engine
    /// *running* would be faster still and is deliberately not done: a permanent
    /// orange dot is not a trade this app is willing to make.
    func prewarm() {
        guard cachedInputFormat == nil else { return }
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { return }  // no input device
        cachedInputFormat = inputFormat

        let fmt = Self.analysisFormat
        targetFormat = fmt
        converter = AVAudioConverter(from: inputFormat, to: fmt)
        engine.prepare()
    }

    /// 16 kHz mono Float32, the format the transcriber expects.
    private static let analysisFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    /// Starts capturing. Returns the input sample rate actually used.
    func start() throws {
        guard hasInputDevice else { throw RecordError.noInputDevice }
        let input = engine.inputNode

        // Always read the LIVE hardware format. Reading it from the cache and
        // then comparing it against the cache is a comparison with itself, which
        // is always equal, so the converter could never be rebuilt after a
        // device change. Concretely: prewarm caches the built-in mic, the user
        // plugs in AirPods at a different sample rate, and the tap gets
        // installed with a format the node no longer has.
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw RecordError.noInputDevice }

        let fmt = Self.analysisFormat
        // Rebuild only when prewarm did not run, or the input device changed.
        if targetFormat == nil || converter == nil || cachedInputFormat != inputFormat {
            targetFormat = fmt
            converter = AVAudioConverter(from: inputFormat, to: fmt)
            cachedInputFormat = inputFormat
        }

        pcmSamples = []
        firstBufferAt = nil

        let converter = self.converter
        let target = self.targetFormat
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, when in
            guard let self, let converter, let target else { return }
            if self.firstSampleHost == nil, buffer.frameLength > 0, when.isHostTimeValid {
                self.firstSampleHost = when.hostTime
            }
            self.convertAndAppend(buffer, converter: converter, targetFormat: target)
        }

        engine.prepare()
        firstSampleHost = nil
        startedAtHost = mach_absolute_time()
        startedAt = Date()
        do {
            try engine.start()
        } catch {
            throw RecordError.engineStartFailed
        }
    }

    /// Stops capturing and returns the captured 16 kHz mono Float32 samples.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let result = pcmSamples
        pcmSamples = []
        return result
    }

    private func convertAndAppend(
        _ input: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        // Output capacity must scale by the sample-rate ratio. Hardware input is
        // typically 48 kHz and the analysis format is 16 kHz, so a 48 kHz buffer
        // yields ~1/3 as many frames. Sizing the output at the INPUT frame count
        // (the previous bug) meant no resampling actually happened: downstream
        // received 48 kHz samples labelled as 16 kHz, and the recognizer returned
        // an empty transcript.
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up) + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        // The input block must hand over each buffer exactly ONCE. Returning the
        // same buffer on every callback (the previous bug) makes the converter
        // consume it repeatedly and duplicate audio.
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }

        if status == .error {
            if let error { print("[voicy] audio convert error: \(error.localizedDescription)") }
            return
        }
        guard let channel = out.floatChannelData?[0] else { return }
        if firstBufferAt == nil, out.frameLength > 0 { firstBufferAt = Date() }
        pcmSamples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        onSamples?(Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength))))
    }
}
