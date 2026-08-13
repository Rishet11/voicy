import Foundation
import WhisperKit

// Scores a Whisper-class on-device model on the same corpus, with the same WER
// scorer, as the shipped Apple Speech engine. Nothing here is stubbed: it
// downloads a real CoreML model, runs real inference on the real WAVs, and
// reports what it measured.
//
//   swift run -c release whisper-eval <manifest.tsv> [options]
//
//   --model <name>        WhisperKit model name (default openai_whisper-base.en)
//   --prompt-names        put the contact names in the decoder prompt, the
//                         Whisper equivalent of contact-name biasing
//   --language <code>     force a language instead of detecting (default en)
//   --out <file.tsv>      write per-clip scores, same format as --wer-out
//   --limit <n>           score only the first n clips
//
// Model names come from huggingface.co/argmaxinc/whisperkit-coreml. Useful
// ones, smallest first:
//   openai_whisper-tiny.en, openai_whisper-base.en,
//   openai_whisper-small.en_217MB, distil-whisper_distil-large-v3_turbo_600MB,
//   openai_whisper-large-v3-v20240930_turbo_632MB

struct ManifestCase {
    let name: String
    let spoken: String
}

func parseManifest(_ text: String) -> [ManifestCase] {
    text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
        let line = String(rawLine)
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty, !line.hasPrefix("#") else { return nil }
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 3 else { return nil }
        return ManifestCase(name: f[0].trimmingCharacters(in: .whitespaces), spoken: f[2])
    }
}

func arg(_ flag: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1].hasPrefix("--") ? nil : args[i + 1]
}
func has(_ flag: String) -> Bool { CommandLine.arguments.contains(flag) }
func fmt(_ ms: Double) -> String { String(format: "%.1f", ms) }
func pct(_ rate: Double) -> String { String(format: "%.1f%%", rate * 100) }
func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }

// The contact names the app biases toward. Kept in sync by hand with
// Sources/Voicy/Testing/FixtureContacts.swift; if that list changes and this
// one does not, the comparison is unfair to Whisper, not to Apple.
let contactNames = [
    "Pulkit Sharma", "Aarav Mehta", "Siddharth Nair", "Aditi Rao", "Shreya Iyer",
    "Rahul Verma", "Rahul Krishnan", "Meera Krishnan",
]

guard CommandLine.arguments.count > 1, !CommandLine.arguments[1].hasPrefix("--") else {
    print("usage: whisper-eval <manifest.tsv> [--model <name>] [--prompt-names] [--out <file>]")
    exit(2)
}
let manifestPath = CommandLine.arguments[1]
let manifestURL = URL(fileURLWithPath: manifestPath)
guard let manifestText = try? String(contentsOf: manifestURL, encoding: .utf8) else {
    print("could not read \(manifestPath)")
    exit(1)
}
var cases = parseManifest(manifestText)
if let limit = arg("--limit").flatMap(Int.init) { cases = Array(cases.prefix(limit)) }
guard !cases.isEmpty else { print("manifest has no cases"); exit(1) }
let dir = manifestURL.deletingLastPathComponent()

let modelName = arg("--model") ?? "openai_whisper-base.en"
let language = arg("--language") ?? "en"

print("model: \(modelName)")
let loadStart = Date()
let pipe: WhisperKit
do {
    pipe = try await WhisperKit(WhisperKitConfig(model: modelName, download: true))
} catch {
    print("model load FAILED: \(error)")
    exit(1)
}
let loadMs = Date().timeIntervalSince(loadStart) * 1000
print("model load (download + compile + warm): \(fmt(loadMs)) ms")

// Where the model actually landed, and how big it is. A model the user has to
// download is a real product cost, so it gets reported alongside the accuracy.
if let folder = pipe.modelFolder {
    let size = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])?
        .compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }
        .reduce(0, +) ?? 0
    print("model on disk: \(String(format: "%.0f", Double(size) / 1_048_576)) MB at \(folder.path)")
}

// Contact-name biasing, the Whisper way: the names go into the decoder's
// prompt, which is a real conditioning signal rather than the contextualStrings
// list Apple Speech was measured to ignore.
var promptTokens: [Int]?
if has("--prompt-names") {
    if let tokenizer = pipe.tokenizer {
        let promptText = " Contacts: " + contactNames.joined(separator: ", ") + "."
        promptTokens = tokenizer.encode(text: promptText).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        print("prompt: \"\(promptText)\" -> \(promptTokens?.count ?? 0) tokens")
    } else {
        print("prompt: tokenizer unavailable, running WITHOUT name biasing")
    }
}

let options = DecodingOptions(
    task: .transcribe,
    language: language,
    usePrefillPrompt: true,
    detectLanguage: false,
    skipSpecialTokens: true,
    withoutTimestamps: true,
    promptTokens: promptTokens,
    chunkingStrategy: .none
)

// One throwaway pass, so the first real clip is not paying warm-up cost. The
// app pays this at launch (TranscriberWarmup), so measuring it inside the
// corpus would be measuring something the user never feels.
_ = try? await pipe.transcribe(audioArray: [Float](repeating: 0, count: 16_000), decodeOptions: options)

struct Row {
    let name: String
    let hypothesis: String
    let wer: ErrorRate.Score
    let cer: ErrorRate.Score
    let ms: Double
    let failed: String?
}

var rows: [Row] = []
var missing = 0
for testCase in cases {
    let audioURL = dir.appendingPathComponent("\(testCase.name).wav")
    guard let pcm = try? AudioFileLoader.loadPCM(url: audioURL), !pcm.isEmpty else {
        print("MISSING \(testCase.name)")
        missing += 1
        continue
    }
    let start = Date()
    var hypothesis = ""
    var failure: String?
    do {
        let results = try await pipe.transcribe(audioArray: pcm, decodeOptions: options)
        hypothesis = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        failure = "transcribe: \(error)"
    }
    let ms = Date().timeIntervalSince(start) * 1000
    if failure == nil, hypothesis.isEmpty { failure = "empty transcript" }
    rows.append(Row(
        name: testCase.name,
        hypothesis: hypothesis,
        wer: ErrorRate.word(reference: testCase.spoken, hypothesis: hypothesis),
        cer: ErrorRate.character(reference: testCase.spoken, hypothesis: hypothesis),
        ms: ms,
        failed: failure
    ))
}

guard !rows.isEmpty else { print("no clips scored"); exit(1) }

print("")
print("=== WER / CER over \(rows.count) clip(s) ===")
print("\(pad("clip", 30)) \(pad("WER", 8)) \(pad("CER", 8)) \(pad("S/D/I", 10)) \(pad("ms", 8)) transcript")
for row in rows.sorted(by: { $0.wer.rate > $1.wer.rate }) {
    let sdi = "\(row.wer.substitutions)/\(row.wer.deletions)/\(row.wer.insertions)"
    print("\(pad(row.name, 30)) \(pad(pct(row.wer.rate), 8)) \(pad(pct(row.cer.rate), 8)) "
          + "\(pad(sdi, 10)) \(pad(fmt(row.ms), 8)) \"\(row.hypothesis)\"")
    if let failed = row.failed { print("       ERROR \(failed)") }
}

let corpusWER = ErrorRate.corpus(rows.map(\.wer))
let corpusCER = ErrorRate.corpus(rows.map(\.cer))
let times = rows.map(\.ms)
print("")
print("corpus WER \(pct(corpusWER.rate))  (\(corpusWER.substitutions) sub, \(corpusWER.deletions) del, "
      + "\(corpusWER.insertions) ins over \(corpusWER.referenceLength) words)")
print("corpus CER \(pct(corpusCER.rate))")
print("clean clips (WER 0): \(rows.filter { $0.wer.errors == 0 }.count)/\(rows.count)")
print("latency: median \(fmt(Percentile.of(times, 0.5))) ms  p95 \(fmt(Percentile.of(times, 0.95))) ms  "
      + "max \(fmt(times.max() ?? 0)) ms")
if missing > 0 { print("missing audio for \(missing) clip(s)") }

let grouped = Dictionary(grouping: rows) { row -> String in
    let parts = row.name.split(separator: ".")
    return parts.count > 1 ? String(parts.last!) : "clean"
}
if grouped.count > 1 {
    print("")
    print("by variant:")
    for key in grouped.keys.sorted() {
        let group = grouped[key]!
        print("  \(pad(key, 18)) n=\(pad(String(group.count), 4)) "
              + "WER \(pad(pct(ErrorRate.corpus(group.map(\.wer)).rate), 8)) "
              + "CER \(pad(pct(ErrorRate.corpus(group.map(\.cer)).rate), 8)) "
              + "median \(fmt(Percentile.of(group.map(\.ms), 0.5))) ms")
    }
}

if let outPath = arg("--out") {
    let tsv = rows.map { row in
        [row.name, String(format: "%.4f", row.wer.rate), String(format: "%.4f", row.cer.rate),
         String(format: "%.1f", row.ms), row.hypothesis].joined(separator: "\t")
    }.joined(separator: "\n") + "\n"
    try? tsv.write(to: URL(fileURLWithPath: outPath), atomically: true, encoding: .utf8)
    print("wrote \(outPath)")
}
