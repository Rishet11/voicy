import Foundation
import CoreServices

let usage = """
vnwatch — standalone voice-note watcher for the Voicy module.

Usage:
  vnwatch <directory> [--hint <text>]...
  vnwatch --decode <file.opus>
  vnwatch --help

Commands:
  <directory>          Watch a directory tree for new .opus files, decode each
                       to PCM, and run it through the Transcriber. Prints the
                       transcription for every settled file.
  --decode <file.opus> Decode a single .opus file to PCM and print frame stats
                       (verifies the decode path without the watcher).
  --hint <text>        Recognition hint(s) passed to the Transcriber.
  --help               Show this help.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - CLI

let args = CommandLine.arguments
var remainder: [String] = []
var hints: [String] = []
var decodeOnly = false
var i = 1
while i < args.count {
    let a = args[i]
    switch a {
    case "--help", "-h":
        print(usage)
        exit(0)
    case "--decode":
        decodeOnly = true
        if i + 1 < args.count { remainder.append(args[i + 1]); i += 1 }
    case "--hint":
        if i + 1 < args.count { hints.append(args[i + 1]); i += 1 }
    default:
        remainder.append(a)
    }
    i += 1
}

if decodeOnly {
    guard let file = remainder.first else { fail("--decode requires a file path") }
    do {
        let pcm = try OpusDecoder.decode(url: URL(fileURLWithPath: file))
        print("decoded \(pcm.count) frames")
        print("duration: \(String(format: "%.2f", Double(pcm.count) / 48_000.0))s @48kHz")
        print("min/max: \(pcm.min() ?? 0) / \(pcm.max() ?? 0)")
        exit(0)
    } catch {
        fail("decode failed: \(error.localizedDescription)")
    }
}

guard let dir = remainder.first else {
    print(usage)
    exit(1)
}

let root = URL(fileURLWithPath: dir)
guard FileManager.default.fileExists(atPath: root.path) else {
    fail("directory does not exist: \(dir)")
}

print("vnwatch: watching \(root.path)")
print("hints: \(hints.isEmpty ? "none" : hints.joined(separator: ", "))")

let pipeline = VoiceNotePipeline(
    root: root,
    transcriber: StubTranscriber(),
    hintsProvider: { _ in hints }
) { url, result in
    switch result {
    case .success(let text):
        print("TRANSCRIBED \(url.path)\n  -> \(text)")
    case .failure(let error):
        print("ERROR \(url.path): \(error.localizedDescription)")
    }
}

pipeline.start()

// Keep the process alive. The pipeline + FSEvents run on background threads.
dispatchMain()