import Foundation

/// Reference implementation for the standalone vnwatch tool. Returns a
/// deterministic placeholder so the watch -> decode -> transcribe pipeline is
/// verifiable before the real engine is wired in. The main app injects the real
/// `Transcriber` (see Speech/Transcriber.swift) instead.
struct StubTranscriber: Transcriber {
    init() {}

    func transcribe(pcm: [Float], hints: [String]) async throws -> String {
        let seconds = Double(pcm.count) / 48_000.0
        let hintSummary = hints.isEmpty ? "none" : hints.joined(separator: ", ")
        return "[stub-transcriber] \(pcm.count) frames (~\(String(format: "%.2f", seconds))s @48kHz); hints: \(hintSummary)"
    }
}
