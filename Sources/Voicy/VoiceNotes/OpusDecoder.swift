import Foundation
import AVFoundation

/// Errors thrown while decoding an Opus file to PCM.
enum OpusDecodeError: Error, LocalizedError {
    case fileUnreadable(String)
    case noAudioBuffer
    case emptyAudio
    case ffmpegUnavailable
    case ffmpegFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileUnreadable(let p): return "Cannot read audio file: \(p)"
        case .noAudioBuffer: return "Failed to allocate audio buffer"
        case .emptyAudio: return "Decoded audio is empty"
        case .ffmpegUnavailable: return "ffmpeg not found on PATH (needed for fallback decode)"
        case .ffmpegFailed(let msg): return "ffmpeg decode failed: \(msg)"
        }
    }
}

/// Decodes an Opus file (in an Ogg container, as WhatsApp produces) into
/// single-channel Float PCM in [-1, 1].
///
/// Primary path is AVFoundation (`AVAudioFile`), which on current macOS reads
/// Opus-in-Ogg directly. If that fails, we fall back to shelling out to ffmpeg
/// to transcode to raw float32 PCM. ffmpeg is acceptable here because it is not
/// a keystroke/permission-sensitive operation.
  enum OpusDecoder {

    /// Decode the file at `url` into `[Float]` PCM (mono, 48 kHz).
    static func decode(url: URL) throws -> [Float] {
        do {
            return try decodeWithAVFoundation(url: url)
        } catch {
            // Prefer a meaningful fallback over swallowing the reason.
            return try decodeWithFFmpeg(url: url)
        }
    }

    // MARK: AVFoundation

    private static func decodeWithAVFoundation(url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw OpusDecodeError.fileUnreadable(url.path)
        }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw OpusDecodeError.noAudioBuffer
        }
        try file.read(into: buffer, frameCount: frameCount)

        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
            throw OpusDecodeError.emptyAudio
        }
        let frames = Int(buffer.frameLength)
        let channel = channelData[0]
        var samples = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            samples[i] = channel[i]
        }
        return samples
    }

    // MARK: ffmpeg fallback

    private static func decodeWithFFmpeg(url: URL) throws -> [Float] {
        guard let ffmpeg = findExecutable("ffmpeg") else {
            throw OpusDecodeError.ffmpegUnavailable
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vn-\(UUID().uuidString).f32")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-v", "error", "-y",
            "-i", url.path,
            "-f", "f32le",
            "-ac", "1",
            "-ar", "48000",
            tmp.path,
        ]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            throw OpusDecodeError.ffmpegUnavailable
        }
        process.waitUntilExit()

        defer { try? FileManager.default.removeItem(at: tmp) }

        guard process.terminationStatus == 0 else {
            let errData = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8) ?? "unknown ffmpeg error"
            throw OpusDecodeError.ffmpegFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let data = try? Data(contentsOf: tmp), !data.isEmpty else {
            throw OpusDecodeError.emptyAudio
        }
        let count = data.count / MemoryLayout<Float>.size
        var samples = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            for i in 0..<count {
                samples[i] = floats[i]
            }
        }
        return samples
    }

    private static func findExecutable(_ name: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let custom = env["PATH"] {
            for dir in custom.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        // Common fallbacks if PATH is minimal.
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c) {
                return URL(fileURLWithPath: c)
            }
        }
        return nil
    }
}