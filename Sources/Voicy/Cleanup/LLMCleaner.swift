import Foundation
// https://developer.apple.com/documentation/foundationmodels
import FoundationModels

/// Optional on-device LLM pass that removes disfluencies FoundationModels
/// might catch beyond the fixed rule list in `TranscriptCleaner`.
///
/// Verified on this machine (macOS 26.5.1, Swift 6.3.2): `import FoundationModels`
/// compiles and links from a plain SwiftPM executable, `SystemLanguageModel.default`
/// reports `.available`, and `LanguageModelSession.respond(to:)` returns a real
/// response. So the framework is usable here; this type wires it up defensively
/// for machines where Apple Intelligence is off, the model is still downloading,
/// or the device doesn't support it.
///
/// THE HARD RULE: an LLM can reword. This type never trusts the model's output
/// directly — every response is run through `TranscriptCleaner.isDeletionOnly`
/// before it can be returned. Anything that is not a pure deletion of words
/// from the original is discarded and `clean` returns nil. There is no path
/// in this file that returns model output without that check.
public struct LLMCleaner: Sendable {
    public init() {}

    /// Returns the cleaned transcript, or nil when the on-device model is
    /// unavailable, errors, times out, or returns anything that is not
    /// deletion-only relative to `text`. Never returns reworded text.
    public func clean(_ text: String) async -> String? {
        guard #available(macOS 26.0, *) else { return nil }
        return await cleanWithFoundationModels(text)
    }

    @available(macOS 26.0, *)
    private func cleanWithFoundationModels(_ text: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable:
            // Apple Intelligence off, model not supported, or still downloading.
            return nil
        @unknown default:
            return nil
        }

        let instructions = """
        You clean up spoken dictation transcripts. You may ONLY delete filler \
        words (um, uh, erm, hmm, ah, er) and immediately repeated words. You must \
        NEVER add a word, change a word, fix grammar, reorder words, or rewrite \
        anything. Every word you keep must be copied character-for-character from \
        the input, in the same order. If nothing needs to change, return the \
        input exactly as given. Return ONLY the cleaned text, nothing else.
        """

        do {
            // https://developer.apple.com/documentation/foundationmodels/languagemodelsession
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: trimmed)
            let candidate = response.content

            // The real guarantee: reject anything that isn't a pure deletion,
            // regardless of what the prompt asked for or what the model did.
            guard TranscriptCleaner.isDeletionOnly(original: trimmed, cleaned: candidate) else {
                return nil
            }
            return candidate
        } catch {
            // Model errored (e.g. guardrail, context limit, transient failure).
            return nil
        }
    }
}
