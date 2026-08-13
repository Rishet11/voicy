import Foundation
// https://developer.apple.com/documentation/foundationmodels
import FoundationModels

/// On-device LLM pass that removes disfluencies the rule-based matcher
/// cannot see (discourse markers, self-corrections, other-language pauses).
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
    /// Class of thing to delete. No word list: the model decides, in the
    /// speaker's language, what is a hesitation vs a real word.
    public static let instructions = """
        You clean spoken dictation transcripts. Delete only disfluencies. \
        A disfluency is a spoken stumble that does not change the claim: \
        hesitation sounds, false starts, self-corrections, stutters, \
        immediately repeated words, and discourse hedges that sit outside \
        the predicate, in whatever language the speaker used. You decide \
        what counts. Do not use a fixed word list. \
        Keep a word when it is the verb, object, or otherwise load-bearing. \
        If deleting it would change what is being said, keep it. \
        You must NEVER add a word, change a word, fix grammar, reorder words, \
        or rewrite anything. Every word you keep must be copied \
        character-for-character from the input, in the same order. If nothing \
        needs to change, return the input exactly as given. Return ONLY the \
        cleaned text, nothing else.
        """

    public init() {}

    /// Returns the cleaned transcript, or nil when the on-device model is
    /// unavailable, errors, times out, or returns anything that is not
    /// deletion-only relative to `text`. Never returns reworded text.
    public func clean(_ text: String) async -> String? {
        guard #available(macOS 26.0, *) else { return nil }
        return await cleanWithFoundationModels(text)
    }

    /// Pays the first-call model load so the user's first utterance is not
    /// the one that waits. Result is discarded. Safe to call at launch.
    public func warm() async {
        _ = await clean("ready")
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

        // https://developer.apple.com/documentation/foundationmodels/languagemodelsession
        // Race the model against a timer with an unstructured task so a
        // cancelled respond() cannot hold this function open (TaskGroup waits
        // for every child, including a respond that ignores cancel).
        let candidate: String? = await withCheckedContinuation { cont in
            let state = ResumeOnce<String?>()
            Task.detached {
                do {
                    let session = LanguageModelSession(instructions: Self.instructions)
                    let options = GenerationOptions(sampling: .greedy, temperature: 0)
                    let response = try await session.respond(to: trimmed, options: options)
                    state.resume(cont, response.content)
                } catch {
                    state.resume(cont, nil)
                }
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(8))
                state.resume(cont, nil)
            }
        }
        guard let candidate else { return nil }

        // The real guarantee: reject anything that isn't a pure deletion,
        // regardless of what the prompt asked for or what the model did.
        guard TranscriptCleaner.isDeletionOnly(original: trimmed, cleaned: candidate) else {
            return nil
        }
        return candidate
    }
}

/// Shipping cleanup: on-device model first, rule-based fallback, then the
/// deletion-only gate on whichever result we got. Pipeline calls this and
/// nothing else for the disfluency pass.
public enum DisfluencyCleanup {
    public enum Source: String, Sendable {
        case llm
        case rules
        case original
    }

    public struct Result: Sendable {
        public let text: String
        public let source: Source
        public let elapsedMs: Double
    }

    /// Clean `text`. Never returns a rewrite: if the chosen pass is not a
    /// pure word deletion of `text`, the original is returned instead.
    ///
    /// The model runs first. The pattern-based pass then runs on that
    /// result (or on the original when the model is down / returns nothing)
    /// so a conservative model cannot leave a hesitation sound the rules
    /// already know how to drop. Both outputs are gated.
    public static func apply(_ text: String) async -> Result {
        let t0 = Date()
        let llm = await LLMCleaner().clean(text)
        let seed = llm ?? text
        let rules = TranscriptCleaner.rulesOnly(seed)
        let afterRules = TranscriptCleaner.isDeletionOnly(original: seed, cleaned: rules)
            ? rules : seed
        let final = TranscriptCleaner.isDeletionOnly(original: text, cleaned: afterRules)
            ? afterRules : text
        let source: Source = {
            if llm != nil { return .llm }
            if final == text { return .original }
            return .rules
        }()
        return Result(text: final, source: source,
                      elapsedMs: Date().timeIntervalSince(t0) * 1000)
    }
}

/// Resumes a continuation at most once. The losing racer is ignored.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resume(_ cont: CheckedContinuation<T, Never>, _ value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        cont.resume(returning: value)
    }
}
