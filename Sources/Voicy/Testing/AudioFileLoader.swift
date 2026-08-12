import AVFoundation
import Foundation

/// Reads an audio file from disk into the canonical analysis format the
/// transcriber expects: 16 kHz mono Float32.
///
/// This is the seam that makes Voicy testable without a microphone. The mic
/// path (`MicrophoneRecorder`) and this path both hand the transcriber the
/// exact same thing — `[Float]` at 16 kHz mono — so a WAV fed through here
/// exercises every stage downstream of the hardware.
///
/// Any container/codec AVFoundation can decode works (wav, aiff, caf, m4a,
/// mp3). Sample rate and channel count are converted, so a 22 kHz stereo file
/// is as valid an input as a 16 kHz mono one.
enum AudioFileLoader {

    /// 16 kHz mono Float32, non-interleaved. Same constant the mic path targets.
    static let analysisFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    enum LoadError: Error, CustomStringConvertible {
        case missingFile(String)
        case unreadable(String, String)
        case emptyFile(String)
        case bufferAllocationFailed
        case converterUnavailable(String)
        case conversionFailed(String)

        var description: String {
            switch self {
            case .missingFile(let path):
                return "no such audio file: \(path)"
            case .unreadable(let path, let reason):
                return "could not decode \(path): \(reason)"
            case .emptyFile(let path):
                return "audio file has zero frames: \(path)"
            case .bufferAllocationFailed:
                return "could not allocate a PCM buffer"
            case .converterUnavailable(let detail):
                return "no converter available for \(detail)"
            case .conversionFailed(let reason):
                return "sample-rate conversion failed: \(reason)"
            }
        }
    }

    /// Decodes `url` into 16 kHz mono Float32 samples.
    static func loadPCM(url: URL) throws -> [Float] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LoadError.missingFile(url.path)
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw LoadError.unreadable(url.lastPathComponent, error.localizedDescription)
        }

        let sourceFormat = file.processingFormat  // always Float32 deinterleaved
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { throw LoadError.emptyFile(url.lastPathComponent) }

        guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw LoadError.bufferAllocationFailed
        }
        do {
            try file.read(into: input)
        } catch {
            throw LoadError.unreadable(url.lastPathComponent, error.localizedDescription)
        }

        return try convertToAnalysisFormat(input)
    }

    /// Converts an arbitrary PCM buffer to 16 kHz mono Float32 samples.
    ///
    /// The output buffer is sized by the sample-rate ratio, and the input block
    /// hands the source buffer over exactly once. Both are the mistakes that
    /// silently produced empty transcripts on the mic path; the same rules
    /// apply here.
    static func convertToAnalysisFormat(_ input: AVAudioPCMBuffer) throws -> [Float] {
        let target = analysisFormat
        let source = input.format

        if source.sampleRate == target.sampleRate,
           source.channelCount == 1,
           source.commonFormat == .pcmFormatFloat32,
           !source.isInterleaved,
           let channel = input.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(input.frameLength)))
        }

        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw LoadError.converterUnavailable("\(source) -> \(target)")
        }

        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up) + 4096)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw LoadError.bufferAllocationFailed
        }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }

        if status == .error {
            throw LoadError.conversionFailed(error?.localizedDescription ?? "unknown")
        }
        guard let channel = output.floatChannelData?[0] else {
            throw LoadError.conversionFailed("no output channel data")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    // MARK: - Signal description (used by the harness report)

    /// Peak absolute amplitude in [0, 1].
    static func peak(_ pcm: [Float]) -> Float {
        var maxValue: Float = 0
        for sample in pcm { maxValue = max(maxValue, abs(sample)) }
        return maxValue
    }

    /// Root-mean-square amplitude in [0, 1].
    static func rms(_ pcm: [Float]) -> Float {
        guard !pcm.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in pcm { sum += sample * sample }
        return (sum / Float(pcm.count)).squareRoot()
    }

    /// Duration in seconds at the analysis sample rate.
    static func duration(_ pcm: [Float]) -> Double {
        Double(pcm.count) / 16_000
    }
}
