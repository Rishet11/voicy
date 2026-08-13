import Foundation
import Speech

/// Builds a compiled custom language model (`SFSpeechLanguageModel.Configuration`)
/// from expected phrases (contact names), via the documented pipeline:
///
///   1. `SFCustomLanguageModelData` + one `PhraseCount` per phrase (training data),
///   2. `export(to:)` — writes the training-data asset,
///   3. `SFSpeechLanguageModel.prepareCustomLanguageModel(for:configuration:)` —
///      compiles the asset into the model file named by the configuration.
///
/// Every signature here was verified against the macOS 26 SDK:
/// `Speech.swiftmodule/arm64e-apple-macos.swiftinterface` and
/// `Speech.framework/Headers/SFSpeechLanguageModel.h`.
///
/// This is the SDK's real mechanism for biasing recognition toward a custom
/// vocabulary, distinct from `contextualStrings`, which was measured to do
/// nothing on the primary engine.
///
/// Compilation is expensive (seconds), so configurations are cached per unique
/// hint set for the lifetime of the process. An actor keeps the cache safe
/// under Swift 6 concurrency; `SFSpeechLanguageModel.Configuration` is
/// `NS_SWIFT_SENDABLE`, so storing it is legal.
actor CustomLanguageModelCache {
    static let shared = CustomLanguageModelCache()

    private var cache: [String: SFSpeechLanguageModel.Configuration] = [:]

    /// Relative bias weight per phrase. Apple's sample code uses 1000 for
    /// terms the recognizer otherwise never gets right (proper names).
    private static let phraseCount = 1000

    /// Best-effort CMU-style pronunciations (tokens from
    /// `SFCustomLanguageModelData.supportedPhonemes`, verified against the
    /// 79-token en_US inventory) for the Indian given names the recognizer
    /// systematically mangles. These are guesses, not verified pronunciations;
    /// the point is to measure whether `CustomPronunciation` changes anything.
    private static let pronunciations: [String: [String]] = [
        "pulkit": ["p", "U", "l", "k", "I", "t"],
        "aarav": ["A", "r", "@", "v"],
        "siddharth": ["s", "I", "d", "A", "r", "T"],
        "aditi": ["A", "d", "I", "t", "I"],
        "shreya": ["S", "r", "e", "I", "@"],
        "rahul": ["r", "A", "h", "U", "l"],
        "meera": ["m", "I", "r", "@"],
    ]

    func configuration(for hints: [String], locale: Locale) async throws -> SFSpeechLanguageModel.Configuration {
        let phrases = hints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !phrases.isEmpty else {
            throw CustomLanguageModelError.noPhrases
        }

        let key = phrases.sorted().joined(separator: "\u{1F}")
        if let hit = cache[key] { return hit }

        // Captured as locals so the result-builder closure stays Sendable-safe.
        let phraseWeight = Self.phraseCount
        let pronunciations = Self.pronunciations
        // Pronunciation terms are an experiment; they ride behind an env gate
        // so their effect can be measured separately from the weight knob.
        let includePronunciations =
            ProcessInfo.processInfo.environment["VOICY_LM_PRONUNCIATIONS"] == "1"
        // Template-class form of the data: the documented WWDC shape
        // (TemplatePhraseCountGenerator + one class holding every phrase)
        // instead of a flat PhraseCount list.
        let useTemplates =
            ProcessInfo.processInfo.environment["VOICY_LM_TEMPLATES"] == "1"

        // Step 1: training data, one PhraseCount per expected phrase, plus a
        // best-effort pronunciation term for the known-problem names.
        let data: SFCustomLanguageModelData
        if useTemplates {
            data = SFCustomLanguageModelData(
                locale: locale,
                identifier: "com.voicy.contact-names",
                version: "3"
            )
            let generator = SFCustomLanguageModelData.TemplatePhraseCountGenerator()
            generator.define(className: "CONTACT_NAME", values: phrases)
            generator.insert(template: "[CONTACT_NAME]", count: phraseWeight)
            data.insert(phraseCountGenerator: generator)
        } else {
            data = SFCustomLanguageModelData(
                locale: locale,
                identifier: "com.voicy.contact-names",
                version: "2",
                builder: {
                    for phrase in phrases {
                        SFCustomLanguageModelData.PhraseCount(phrase: phrase, count: phraseWeight)
                        if includePronunciations,
                           let phonemes = pronunciations[phrase.lowercased()] {
                            SFCustomLanguageModelData.CustomPronunciation(grapheme: phrase, phonemes: phonemes)
                        }
                    }
                }
            )
        }

        // Step 2: export the training-data asset.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicy-language-models", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let digest = abs(key.hashValue)
        let assetURL = root.appendingPathComponent("data-\(digest).bin")

        // Step 3: compile. `prepareCustomLanguageModel` writes the compiled
        // model to the URL in the configuration. Weight is macOS 26+ only;
        // without it the system default applies.
        let modelDir = root.appendingPathComponent("model-\(digest)", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let modelURL = modelDir.appendingPathComponent("languageModel.bin")

        let configuration: SFSpeechLanguageModel.Configuration
        if #available(macOS 26.0, *) {
            configuration = SFSpeechLanguageModel.Configuration(
                languageModel: modelURL,
                vocabulary: nil,
                weight: 1.0
            )
        } else {
            configuration = SFSpeechLanguageModel.Configuration(languageModel: modelURL)
        }

        // Export is async/throws; prepare is completion-based.
        try await data.export(to: assetURL)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            SFSpeechLanguageModel.prepareCustomLanguageModel(
                for: assetURL,
                configuration: configuration
            ) { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }

        cache[key] = configuration
        return configuration
    }

    enum CustomLanguageModelError: Error {
        case noPhrases
    }
}
