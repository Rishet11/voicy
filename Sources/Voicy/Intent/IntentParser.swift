import Foundation

// MARK: - Intent model (W5 / Sources/Voicy/Intent)
//
// Turns a spoken transcript into a structured outgoing-message intent WITHOUT
// rewriting the user's words. The body is sliced byte-for-byte from the
// original transcript (we carry character ranges, never regenerate text).
// This is the "never rewrite the user's words" fidelity rule from CLAUDE.md.

public enum MessagingApp: Sendable {
    case whatsapp
    case telegram
    case imessage
}

public struct ParsedIntent: Sendable {
    /// The spoken recipient name, e.g. "Pulkit" — original case preserved.
    public let recipientText: String
    /// The message body, sliced from the transcript, byte-identical.
    public let body: String
    public let app: MessagingApp

    public init(recipientText: String, body: String, app: MessagingApp) {
        self.recipientText = recipientText
        self.body = body
        self.app = app
    }
}

public enum ParseResult: Sendable {
    case parsed(ParsedIntent)
    case notParsed(reason: String)
}

public struct IntentParser: Sendable {

    public init() {}

    // MARK: - Vocabulary

    /// Words that terminate a name and are stripped when they immediately
    /// follow it. Stripped exactly once; the same word later in the body is
    /// preserved (e.g. "that that report is done").
    private static let connectors: Set<String> = ["that", "saying", "ki"]

    /// Conjunctions a recognizer sometimes inserts in the pause between the name
    /// and the connector. Stripped ONLY when immediately followed by a connector
    /// ("and that", "so that", "and saying"), which is the exact artifact
    /// observed: "Message Meera Krishnan that I am late" came back as
    /// "Message Mira Krishna, and that I am late." and the body kept the "and".
    ///
    /// The "followed by a connector" requirement is what keeps this safe. A bare
    /// "and" or "so" starting a real body is left alone, because removing a word
    /// the user meant to say would be rewriting them.
    private static let preConnectorFillers: Set<String> = ["and", "so", "then", "ok", "okay"]

    /// Words people start a sentence with that are never a person's name. Used
    /// only to reject the verb-less shape; they are untouched everywhere else.
    private static let discourseMarkers: Set<String> = [
        "actually", "so", "look", "well", "ok", "okay", "right", "anyway",
        "honestly", "basically", "listen", "hey", "yeah", "yes", "no", "nope",
        "um", "uh", "hmm", "oh", "and", "but", "then", "also", "sorry",
        "wait", "please", "just", "maybe", "like",
    ]

    /// Command verbs. Matched case-insensitively.
    private static let verbs: Set<String> = [
        "message", "tell", "send", "text", "say",
        "whatsapp", "telegram", "imessage",
    ]

    /// Pronoun-ish / function-word boundaries. A name stops at the first word
    /// in this set (they are far more likely to start the body than to be part
    /// of a first/last name). Preferring the shorter name here is deliberate:
    /// contact matching downstream disambiguates the real recipient.
    private static let nameBoundaries: Set<String> = {
        var s: Set<String> = [
            // connectors (also serve as boundaries)
            "that", "saying", "ki",
            // subject/object pronouns
            "i", "i'll", "i'm", "i've", "i'd",
            "you", "you'll", "you're", "you've", "you'd",
            "we", "we'll", "we're", "they", "they'll", "they're",
            "he", "he'll", "he's", "she", "she'll", "she's",
            "it", "it'll", "it's", "me", "us", "them", "him", "her",
            // possessive pronouns
            "his", "hers", "my", "mine", "your", "yours",
            "our", "ours", "their", "theirs", "its",
            // auxiliaries / copulas common at body start
            "am", "is", "are", "was", "were",
            "will", "would", "can", "could", "shall", "should",
            "may", "might", "must",
            // prepositions / determiners common at body start
            "on", "at", "in", "to", "for", "about", "with", "from", "by", "of",
            "the", "a", "an",
            // politeness / Hinglish "I"
            "please", "main",
            // conjunctions. A name never continues through one, so they end the
            // recipient; whether the word itself survives into the body is
            // decided separately by the inserted-conjunction rule below.
            "and", "so", "then", "ok", "okay",
        ]
        return s
    }()
// MARK: - Parsing

    public func parse(_ transcript: String) -> ParseResult {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .notParsed(reason: "empty transcript")
        }

        // Optional wake phrase(s): "hey voicy ..." or "voicy ...".
        var working = trimmed
        let lower = working.lowercased()
        if lower.hasPrefix("hey voicy") {
            working = String(working[working.index(working.startIndex, offsetBy: "hey voicy".count)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if lower.hasPrefix("voicy") {
            working = String(working[working.index(working.startIndex, offsetBy: "voicy".count)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !working.isEmpty else {
            return .notParsed(reason: "no command after wake phrase")
        }

        let tokens = tokenize(working)
        guard let first = tokens.first else {
            return .notParsed(reason: "no tokens")
        }

        let verb = first.word.lowercased()
        let hasVerb = Self.verbs.contains(verb)

        // Recognizers drop the leading command verb often enough that requiring
        // it loses real utterances. Measured with the audio harness: "Tell
        // Siddharth that the file is ready" came back as "Siddharth, that the
        // file is ready." — the verb simply vanished, and the whole intent was
        // rejected even though the meaning is unambiguous.
        //
        // So a verb-less utterance is accepted ONLY in the shape that actually
        // occurs: a leading name terminated by punctuation, or followed by a
        // connector ("that" / "saying" / "ki"). That is narrow on purpose. Plain
        // speech that happens to be picked up ("what is the weather in Bangalore
        // today") has neither, so it is still rejected rather than turned into a
        // message to somebody called "What".
        //
        // This is safe to be permissive about because the recipient still has to
        // survive contact resolution, and an unmatched name shows the "nobody
        // found" card instead of sending anything.
        if !hasVerb {
            guard startsWithNameLikeAddress(tokens) else {
                return .notParsed(reason: "no command verb found")
            }
        }

        let app: MessagingApp
        switch verb {
        case "telegram": app = .telegram
        case "imessage": app = .imessage
        default: app = .whatsapp   // "message", "tell", "send", "text", "whatsapp"
        }

        // With no verb the first token IS the recipient, so nothing is dropped.
        let rest = hasVerb ? Array(tokens.dropFirst()) : tokens
        guard !rest.isEmpty else {
            return .notParsed(reason: "no recipient or body")
        }

        // An explicit "to <Name>" recipient phrase wins over the verb-first
        // shape. This handles speech like "send hello to Pulkit" where the
        // recipient does NOT immediately follow the verb.
        if let phrase = findToPhrase(rest) {
            return parseWithToPhrase(working, rest: rest, phrase: phrase, app: app)
        }

        // Collect the name: words until a boundary word.
        var nameTokens: [Token] = []
        var i = 0
        while i < rest.count, !Self.nameBoundaries.contains(rest[i].word.lowercased()) {
            nameTokens.append(rest[i])
            i += 1
            // Punctuation terminates the name. Speech recognizers insert a comma
            // for the natural pause after a name ("Message Stone, hello") and
            // without this the whole utterance is swallowed as the recipient and
            // the parse fails with "no message body".
            if let last = nameTokens.last?.word,
               let ch = last.last,
               ",.;:!?".contains(ch) {
                break
            }
        }
        guard !nameTokens.isEmpty else {
            return .notParsed(reason: "no recipient name")
        }

        // "send X a message ..." — skip the "a message" filler after the name.
        if verb == "send",
           i + 1 < rest.count,
           rest[i].word.lowercased() == "a",
           rest[i + 1].word.lowercased() == "message" {
            i += 2
        }

        // Drop an inserted conjunction that sits directly in front of a
        // connector ("... Krishna, and that I am late" -> "I am late").
        if i + 1 < rest.count,
           Self.preConnectorFillers.contains(Self.bareWord(rest[i].word)),
           Self.connectors.contains(Self.bareWord(rest[i + 1].word)) {
            i += 1
        }

        // Strip exactly one connector if it immediately follows the name.
        if i < rest.count, Self.connectors.contains(rest[i].word.lowercased()) {
            i += 1
        }

        guard i < rest.count else {
            return .notParsed(reason: "no message body")
        }

        // Slice the name and body from `working` (== original transcript bytes;
        // wake phrase / verb / connector are all strict prefixes, so the body is
        // a contiguous suffix of the original user input).
        let nameStart = nameTokens.first!.range.lowerBound
        let nameEnd = nameTokens.last!.range.upperBound
        let bodyStart = rest[i].range.lowerBound

        var name = String(working[nameStart..<nameEnd])
        // Drop punctuation the recognizer attached to the name ("Stone," -> "Stone").
        // Only the NAME is cleaned; the body is always sliced verbatim.
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!? "))
        let body = String(working[bodyStart..<working.endIndex])

        return .parsed(ParsedIntent(recipientText: name, body: body, app: app))
    }

    /// True when a verb-less utterance still looks like it is addressing someone:
    /// one or two leading non-boundary words, terminated either by punctuation
    /// the recognizer inserted for the natural pause after a name, or by an
    /// explicit connector.
    ///
    /// Requires a body to follow, so a bare "Siddharth" is not an intent.
    private func startsWithNameLikeAddress(_ tokens: [Token]) -> Bool {
        guard tokens.count >= 2 else { return false }

        // A discourse marker is not a name. Without this, ordinary speech that
        // merely pauses after its first word — "Actually, I think we should go",
        // "Look, I can't make it", "So, let's talk later" — was accepted as a
        // message addressed to someone called "Actually". Resolution would find
        // nobody, so nothing could be sent, but offering to message a person who
        // does not exist is still wrong.
        if Self.discourseMarkers.contains(Self.bareWord(tokens[0].word)) { return false }

        var nameCount = 0
        while nameCount < tokens.count, nameCount < 2 {
            // Compare with punctuation stripped. The boundary set holds bare
            // words, so "so," would not have matched "so" and the check leaked.
            let word = Self.bareWord(tokens[nameCount].word)
            if Self.nameBoundaries.contains(word) { break }
            nameCount += 1
            // Punctuation after the name is the strongest signal: "Siddharth,".
            if let ch = tokens[nameCount - 1].word.last, ",.;:!?".contains(ch) {
                return nameCount < tokens.count
            }
        }
        guard nameCount > 0, nameCount < tokens.count else { return false }

        // Otherwise an explicit connector must follow the name, and something
        // must follow that connector to serve as the body.
        let next = tokens[nameCount].word.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?"))
        return Self.connectors.contains(next) && nameCount + 1 < tokens.count
    }

    // MARK: - "to <Name>" recipient phrase (verb-last / name-last shape)

    private struct ToPhrase {
        /// Index (into `rest`) of the "to" token.
        let toIndex: Int
        /// Name tokens that immediately follow "to".
        let nameTokens: [Token]
    }

    /// Scans `rest` for the FIRST "to <Name>" phrase. A name is 1+ tokens that
    /// start right after "to" and stop at a boundary word or punctuation. If
    /// the words after "to" are empty (e.g. "to the store"), that "to" is not a
    /// recipient marker, so we keep scanning for a later useful "to".
    private func findToPhrase(_ rest: [Token]) -> ToPhrase? {
        for toIndex in rest.indices where rest[toIndex].word.lowercased() == "to" {
            var nameTokens: [Token] = []
            var j = toIndex + 1
            while j < rest.count, !Self.nameBoundaries.contains(rest[j].word.lowercased()) {
                nameTokens.append(rest[j])
                j += 1
                // Punctuation terminates the name ("to Pulkit:").
                if let last = nameTokens.last?.word.last, ",.;:!?".contains(last) {
                    break
                }
            }
            if !nameTokens.isEmpty {
                return ToPhrase(toIndex: toIndex, nameTokens: nameTokens)
            }
        }
        return nil
    }

    private func parseWithToPhrase(_ working: String, rest: [Token],
                                   phrase: ToPhrase, app: MessagingApp) -> ParseResult {
        let nameTokens = phrase.nameTokens
        let lastNameIdx = phrase.toIndex + nameTokens.count

        // Recipient name, sliced from the original transcript.
        let nameStart = nameTokens.first!.range.lowerBound
        let nameEnd = nameTokens.last!.range.upperBound
        var name = String(working[nameStart..<nameEnd])
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!? "))

        let beforeTokens = Array(rest[0..<phrase.toIndex])
        let afterTokens = Array(rest[(lastNameIdx + 1)...])

        // Body: prefer the content AFTER the "to <Name>" phrase — that is where a
        // speaker usually puts the message ("send a message to X saying I am late"
        // -> "I am late"). Only when nothing meaningful follows do we fall back to
        // the content BEFORE the phrase ("send hello to X" -> "hello"). Either way
        // the body is a SINGLE contiguous slice of the original transcript, so the
        // byte-for-byte fidelity rule always holds and no space-joining of
        // non-contiguous pieces is ever required.
        let cleanAfter = stripLeadingNoise(afterTokens)
        if let firstAfter = cleanAfter.first {
            let body = String(working[firstAfter.range.lowerBound..<working.endIndex])
            return .parsed(ParsedIntent(recipientText: name, body: body, app: app))
        }

        guard let firstBefore = beforeTokens.first, let lastBefore = beforeTokens.last else {
            return .notParsed(reason: "no message body")
        }
        let body = String(working[firstBefore.range.lowerBound..<lastBefore.range.upperBound])
        return .parsed(ParsedIntent(recipientText: name, body: body, app: app))
    }

    /// Drops leading punctuation and exactly one connector from a token list, so
    /// the after-phrase body ("saying I am late", "that I am late") loses its
    /// filler but keeps everything the user actually said.
    private func stripLeadingNoise(_ tokens: [Token]) -> [Token] {
        var t = tokens
        func stripPunct() {
            while let first = t.first, let ch = first.word.first, ",.;:!?".contains(ch) {
                t = Array(t.dropFirst())
            }
        }
        stripPunct()
        // Same inserted-conjunction case as the verb-first path, e.g.
        // "send a message to Pulkit and saying I am late".
        if t.count >= 2,
           Self.preConnectorFillers.contains(Self.bareWord(t[0].word)),
           Self.connectors.contains(Self.bareWord(t[1].word)) {
            t = Array(t.dropFirst())
        }
        if let first = t.first, Self.connectors.contains(first.word.lowercased()) {
            t = Array(t.dropFirst())
        }
        stripPunct()
        return t
    }

    /// A token lowercased with any attached punctuation removed, for comparing
    /// against the vocabulary sets. Never used to build the body.
    private static func bareWord(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?"))
    }

    // MARK: - Tokenization (range-preserving)

    private struct Token {
        let word: String
        let range: Range<String.Index>
    }

    /// Whitespace-separated tokens, each carrying its character range so the
    /// body can be sliced byte-for-byte from the original string.
    private func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        var i = s.startIndex
        while i < s.endIndex {
            while i < s.endIndex, s[i].isWhitespace {
                i = s.index(after: i)
            }
            if i >= s.endIndex { break }
            let start = i
            while i < s.endIndex, !s[i].isWhitespace {
                i = s.index(after: i)
            }
            tokens.append(Token(word: String(s[start..<i]), range: start..<i))
        }
        return tokens
    }
}