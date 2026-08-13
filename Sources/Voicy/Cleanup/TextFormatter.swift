import Foundation

/// Turns a raw dictation transcript into the text a person would have typed.
///
/// This is the deliberately-rewriting half of the cleanup path. `TranscriptCleaner`
/// is deletion-only and stays that way: it is the safety floor. This type is
/// allowed to substitute text, because the things it handles (spoken punctuation,
/// spoken emails, self-corrections) cannot be expressed as deletions.
///
/// Every rewrite here is a closed, enumerated rule. There is no model call and no
/// open-ended "make it nicer" step, so the output is a pure function of the input
/// and every change is traceable to one rule below.
///
/// Order matters and is fixed:
///   1. disfluencies (fillers, stutters, false starts) - deletion only
///   2. self-corrections                               - deletion of the retracted span
///   3. spoken entities (email, url, phone, money, time, numbers)
///   4. spoken punctuation and line breaks
///   5. trailing send cues
///   6. capitalization
public enum TextFormatter {

    public static func format(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return text }

        let original = tokenize(trimmed)
        var tokens = removeDisfluencies(original)
        // An utterance that is nothing but fillers still has to come out as
        // something. Keep the words rather than sending an empty message.
        if tokens.isEmpty { tokens = original }
        tokens = applySelfCorrections(tokens)
        tokens = applySpokenEntities(tokens)
        tokens = applySpokenPunctuation(tokens)
        tokens = stripTrailingSendCues(tokens)
        tokens = applyCapitalization(tokens)

        let rendered = render(tokens)
        return rendered.isEmpty ? trimmed : rendered
    }

    // MARK: - Tokens

    /// Whitespace-separated tokens, with line breaks kept as their own tokens so
    /// formatting is idempotent: running `format` on its own output must not
    /// swallow the newlines the first pass produced.
    private static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var newlineRun = 0

        func flushWord() {
            if !current.isEmpty { tokens.append(current); current = "" }
        }
        func flushNewlines() {
            if newlineRun > 0 {
                tokens.append(newlineRun >= 2 ? "\n\n" : "\n")
                newlineRun = 0
            }
        }

        for ch in s {
            if ch == "\n" || ch == "\r" {
                flushWord()
                newlineRun += 1
            } else if ch.isWhitespace {
                flushWord()
                flushNewlines()
            } else {
                flushNewlines()
                current.append(ch)
            }
        }
        flushWord()
        flushNewlines()
        return tokens
    }

    /// Lowercased, with attached punctuation stripped from both ends. Used for
    /// every vocabulary comparison; never used to build output.
    private static func bare(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?\"'"))
    }

    private static func trailingPunct(_ token: String) -> String {
        var out = ""
        for ch in token.reversed() {
            if ",.;:!?".contains(ch) { out.append(ch) } else { break }
        }
        return String(out.reversed())
    }

    private static let punctuationTokens: Set<String> = [".", ",", ";", ":", "!", "?", "-"]

    /// Joins tokens back into a string. Punctuation tokens attach to the word
    /// before them; newline tokens swallow the space on both sides.
    private static func render(_ tokens: [String]) -> String {
        var out = ""
        for token in tokens {
            if token.isEmpty { continue }
            if token == "\n" || token == "\n\n" {
                out = out.trimmingCharacters(in: CharacterSet(charactersIn: " "))
                out += token
                continue
            }
            if out.isEmpty || out.hasSuffix("\n") {
                out += token
            } else if punctuationTokens.contains(token) {
                out += token
            } else {
                out += " " + token
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 1. Disfluencies

    /// Drops fillers, adjacent repeated words, and repeated multi-word false
    /// starts ("I was I was going to"). Deletion only: no token is ever altered.
    ///
    /// The hesitation-sound matcher and the acronym guard live in
    /// `TranscriptCleaner` so the deletion-only floor and this pass cannot
    /// disagree about what a hesitation is.
    static func removeDisfluencies(_ tokens: [String]) -> [String] {
        var kept: [String] = []
        for token in tokens {
            if TranscriptCleaner.isFiller(token) {
                // A filler carrying sentence punctuation ("um,") must not take
                // the punctuation with it if that punctuation ends a sentence.
                let punct = trailingPunct(token)
                if punct.contains(".") || punct.contains("?") || punct.contains("!"),
                   let last = kept.last, !punctuationTokens.contains(last) {
                    kept[kept.count - 1] = last + String(punct.first!)
                }
                continue
            }
            kept.append(token)
        }

        // Repeated n-grams, longest first, so "I was I was going" collapses as a
        // 2-gram rather than leaving a stray "I".
        for n in stride(from: 4, through: 1, by: -1) {
            kept = collapseRepeatedRuns(kept, length: n)
        }
        return kept
    }

    /// Removes the first of two adjacent identical runs of `length` words.
    private static func collapseRepeatedRuns(_ tokens: [String], length n: Int) -> [String] {
        guard tokens.count >= 2 * n else { return tokens }
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            if i + 2 * n <= tokens.count {
                let a = tokens[i..<(i + n)].map(bare)
                let b = tokens[(i + n)..<(i + 2 * n)].map(bare)
                // A run that ends a sentence is a real repetition, not a stutter
                // ("that report is done. that report was late").
                let crossesSentence = tokens[i..<(i + n)].contains { trailingPunct($0).contains(".") }
                if a == b, !a.contains(""), !crossesSentence {
                    i += n   // drop the first copy, keep the second
                    continue
                }
            }
            out.append(tokens[i])
            i += 1
        }
        return out
    }

    // MARK: - 2. Self-corrections

    /// Correction markers. Each is a token sequence (already bare/lowercased).
    ///
    /// `requiresComma` guards the markers that are ordinary English on their own:
    /// "sorry" is only a correction when it is set off by commas
    /// ("to Rahul, sorry, Rohit"), never in "sorry I am late".
    private struct CorrectionMarker {
        let words: [String]
        let requiresComma: Bool
    }

    private static let correctionMarkers: [CorrectionMarker] = [
        .init(words: ["scratch", "that"], requiresComma: false),
        .init(words: ["no", "wait"], requiresComma: false),
        .init(words: ["actually", "no"], requiresComma: false),
        .init(words: ["no", "sorry"], requiresComma: false),
        .init(words: ["i", "mean"], requiresComma: true),
        .init(words: ["sorry"], requiresComma: true),
    ]

    /// Applies the retraction rule. The correction that FOLLOWS the marker
    /// replaces a span BEFORE it, chosen by aligning on the correction's first
    /// word:
    ///
    ///   "tell Mom I'll be late, actually no, I'll be on time"
    ///     the correction starts with "I'll", which appears in the clause, so the
    ///     retraction starts there -> "tell Mom I'll be on time"
    ///
    ///   "send it to Rahul, sorry, Rohit"
    ///     "Rohit" appears nowhere before, so it falls back to retracting as many
    ///     tokens as the correction has -> "send it to Rohit"
    ///
    /// Both are clamped to the clause the marker sits in, so a correction never
    /// eats a previous sentence.
    static func applySelfCorrections(_ tokens: [String]) -> [String] {
        var tokens = tokens
        var searchFrom = 0

        while true {
            guard let hit = findMarker(tokens, from: searchFrom) else { break }
            let (start, end) = hit   // marker occupies start..<end

            // The correction runs from the marker to the end of its clause.
            var replacementEnd = end
            while replacementEnd < tokens.count {
                if endsClause(tokens[replacementEnd]) { replacementEnd += 1; break }
                replacementEnd += 1
            }
            let replacementCount = replacementEnd - end
            guard replacementCount > 0 else {
                // Nothing follows the marker: drop the marker only.
                tokens.removeSubrange(start..<end)
                searchFrom = start
                continue
            }

            // The comma that sets the marker off belongs to the marker, not to
            // the clause, so drop it before looking for the clause start.
            if start > 0, trailingPunct(tokens[start - 1]) == "," {
                tokens[start - 1] = String(tokens[start - 1].dropLast())
            }

            var clauseStart = start
            while clauseStart > 0, !endsClause(tokens[clauseStart - 1]) {
                clauseStart -= 1
            }

            let correctionHead = bare(tokens[end])
            let deleteFrom: Int
            if !correctionHead.isEmpty,
               let anchor = (clauseStart..<start).first(where: { bare(tokens[$0]) == correctionHead }) {
                deleteFrom = anchor
            } else {
                deleteFrom = max(clauseStart, start - replacementCount)
            }

            tokens.removeSubrange(deleteFrom..<end)
            searchFrom = deleteFrom
        }
        return tokens
    }

    /// True when a token closes a clause (carries a comma or sentence-ending mark).
    private static func endsClause(_ token: String) -> Bool {
        let p = trailingPunct(token)
        return p.contains(",") || p.contains(".") || p.contains("!") || p.contains("?") || p.contains(";")
    }

    private static func findMarker(_ tokens: [String], from: Int) -> (Int, Int)? {
        var i = from
        while i < tokens.count {
            for marker in correctionMarkers {
                let n = marker.words.count
                guard i + n <= tokens.count else { continue }
                let slice = tokens[i..<(i + n)].map(bare)
                guard slice == marker.words else { continue }
                if marker.requiresComma {
                    // Must be comma-delimited on both sides to count as a retraction.
                    let beforeComma = i > 0 && trailingPunct(tokens[i - 1]).contains(",")
                    let afterComma = trailingPunct(tokens[i + n - 1]).contains(",")
                    guard beforeComma, afterComma else { continue }
                }
                return (i, i + n)
            }
            i += 1
        }
        return nil
    }

    // MARK: - 3. Spoken entities

    private static let unitsWords: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tensWords: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scaleWords: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "lakh": 100_000, "lakhs": 100_000,
        "million": 1_000_000, "crore": 10_000_000, "crores": 10_000_000,
        "billion": 1_000_000_000,
    ]
    private static let digitWords: [String: Character] = [
        "zero": "0", "oh": "0", "o": "0", "one": "1", "two": "2", "three": "3",
        "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    ]
    private static let ordinalWords: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
        "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11,
        "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
        "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30,
    ]
    private static let months: [String: String] = [
        "january": "January", "february": "February", "march": "March",
        "april": "April", "may": "May", "june": "June", "july": "July",
        "august": "August", "september": "September", "october": "October",
        "november": "November", "december": "December",
    ]
    private static let currencyWords: [String: String] = [
        "dollar": "$", "dollars": "$", "bucks": "$",
        "rupee": "₹", "rupees": "₹", "rupaye": "₹",
        "euro": "€", "euros": "€", "pound": "£", "pounds": "£",
    ]
    /// Units that turn a bare small number into a counted quantity.
    private static let measurementUnits: Set<String> = [
        "minute", "minutes", "min", "mins", "hour", "hours", "hr", "hrs",
        "second", "seconds", "sec", "secs", "day", "days", "week", "weeks",
        "month", "months", "year", "years", "km", "kms", "kilometers",
        "meters", "metres", "miles", "kg", "kgs", "grams", "litres", "liters",
        "degrees", "times", "copies", "pages", "people",
    ]

    /// Prepositions that mark the number after them as a quantity or a clock
    /// time rather than a word ("at eight", "moved to three").
    private static let quantityPrepositions: Set<String> = [
        "at", "by", "before", "after", "around", "till", "until", "to",
    ]

    private static let tlds: Set<String> = [
        "com", "in", "org", "net", "edu", "gov", "io", "co", "ai", "dev", "me", "app",
    ]

    /// A parsed spoken cardinal: its value and how many tokens it consumed.
    private struct NumberRun { let value: Int; let length: Int }

    private static func parseNumber(_ tokens: [String], at i: Int) -> NumberRun? {
        var total = 0        // completed scale groups
        var current = 0      // group being built
        var j = i
        var sawAny = false
        // A cardinal reads tens-then-units ("twenty five"). Once a units word is
        // taken, a following tens word starts a NEW number and must not be added
        // in: "four thirty" is a time, not 34.
        var sawUnits = false

        while j < tokens.count {
            let w = bare(tokens[j])
            if let u = unitsWords[w], w != "oh" {
                if sawUnits { break }
                current += u
                sawAny = true
                sawUnits = true
                j += 1
            } else if let t = tensWords[w] {
                if sawUnits { break }
                current += t
                sawAny = true
                j += 1
            } else if let s = scaleWords[w], sawAny {
                sawUnits = false
                if s >= 1_000 {
                    total += max(current, 1) * s
                    current = 0
                } else {
                    current = max(current, 1) * s
                }
                j += 1
            } else {
                break
            }
            // A clause boundary ends the number ("thirty, and then five").
            if j > i, endsClause(tokens[j - 1]) { break }
        }
        guard sawAny else { return nil }
        return NumberRun(value: total + current, length: j - i)
    }

    /// A run of single-digit words, used for phone numbers. Supports "double"
    /// and "triple" as repeat markers ("double seven" -> "77").
    private static func parseDigitRun(_ tokens: [String], at i: Int) -> (digits: String, length: Int)? {
        var digits = ""
        var j = i
        while j < tokens.count {
            let w = bare(tokens[j])
            if w == "double" || w == "triple", j + 1 < tokens.count,
               let d = digitWords[bare(tokens[j + 1])] {
                digits += String(repeating: String(d), count: w == "double" ? 2 : 3)
                j += 2
            } else if let d = digitWords[w] {
                digits.append(d)
                j += 1
            } else {
                break
            }
            if j > i, endsClause(tokens[j - 1]) { break }
        }
        guard !digits.isEmpty else { return nil }
        return (digits, j - i)
    }

    static func applySpokenEntities(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var i = 0

        while i < tokens.count {
            let w = bare(tokens[i])

            // --- email: "<local> at <domain> dot <tld>"
            if i + 4 < tokens.count, bare(tokens[i + 1]) == "at", bare(tokens[i + 3]) == "dot",
               isWordy(tokens[i]), isWordy(tokens[i + 2]), tlds.contains(bare(tokens[i + 4])) {
                var address = "\(bare(tokens[i]))@\(bare(tokens[i + 2])).\(bare(tokens[i + 4]))"
                var j = i + 5
                // Trailing "dot <tld>" chains, e.g. "gmail dot co dot in".
                while j + 1 < tokens.count, bare(tokens[j]) == "dot", tlds.contains(bare(tokens[j + 1])) {
                    address += ".\(bare(tokens[j + 1]))"
                    j += 2
                }
                out.append(address + trailingPunct(tokens[j - 1]))
                i = j
                continue
            }

            // --- bare domain / url: "<host> dot <tld>"
            if i + 2 < tokens.count, bare(tokens[i + 1]) == "dot",
               isWordy(tokens[i]), tlds.contains(bare(tokens[i + 2])),
               !(i > 0 && bare(tokens[i - 1]) == "at") {
                var host = "\(bare(tokens[i])).\(bare(tokens[i + 2]))"
                var j = i + 3
                while j + 1 < tokens.count, bare(tokens[j]) == "dot", tlds.contains(bare(tokens[j + 1])) {
                    host += ".\(bare(tokens[j + 1]))"
                    j += 2
                }
                out.append(host + trailingPunct(tokens[j - 1]))
                i = j
                continue
            }

            // --- phone number: 7 or more spoken digits in a row.
            if let run = parseDigitRun(tokens, at: i), run.digits.count >= 7 {
                out.append(run.digits + trailingPunct(tokens[i + run.length - 1]))
                i += run.length
                continue
            }

            // --- date: "<month> <ordinal>"
            if let month = months[w], i + 1 < tokens.count,
               let day = ordinalWords[bare(tokens[i + 1])] {
                out.append("\(month) \(day)" + trailingPunct(tokens[i + 1]))
                i += 2
                continue
            }

            // --- money written before the amount: "rupees five hundred"
            if let symbol = currencyWords[w], let n = parseNumber(tokens, at: i + 1) {
                out.append(symbol + formatGrouped(n.value) + trailingPunct(tokens[i + n.length]))
                i += 1 + n.length
                continue
            }

            if let n = parseNumber(tokens, at: i) {
                let after = i + n.length
                let nextWord = after < tokens.count ? bare(tokens[after]) : ""

                // --- money: "twenty five dollars"
                if let symbol = currencyWords[nextWord] {
                    out.append(symbol + formatGrouped(n.value) + trailingPunct(tokens[after]))
                    i = after + 1
                    continue
                }

                // --- percent: "twenty percent"
                if nextWord == "percent" {
                    out.append("\(n.value)%" + trailingPunct(tokens[after]))
                    i = after + 1
                    continue
                }

                // --- time: "four thirty pm", "four pm", "four o'clock"
                if let time = parseTime(tokens, at: i, first: n) {
                    out.append(time.text)
                    i = time.end
                    continue
                }

                // --- plain cardinal. A bare small number stays a word, because
                // "one of my friends" must not become "1 of my friends". It
                // becomes a digit only when it is clearly being counted: a unit
                // follows ("five minutes"), or a quantity preposition precedes
                // ("at eight", "moved to three").
                let previousWord = i > 0 ? bare(tokens[i - 1]) : ""
                let countsAsQuantity =
                    measurementUnits.contains(nextWord)
                    || (quantityPrepositions.contains(previousWord) && nextWord != "of")

                if n.value >= 10 || n.length > 1 || countsAsQuantity {
                    out.append(formatGrouped(n.value) + trailingPunct(tokens[after - 1]))
                    i = after
                    continue
                }
            }

            out.append(tokens[i])
            i += 1
        }
        return out
    }

    /// "<hour> [<minute>] (am|pm|o'clock)" -> "4:30 PM" / "4 PM" / "4 o'clock".
    private static func parseTime(_ tokens: [String], at i: Int, first: NumberRun) -> (text: String, end: Int)? {
        guard (1...12).contains(first.value) || (first.value <= 23) else { return nil }
        var j = i + first.length
        var minute: Int? = nil

        if j < tokens.count, let m = parseNumber(tokens, at: j), m.value < 60,
           j + m.length < tokens.count {
            let after = bare(tokens[j + m.length])
            if after == "am" || after == "pm" || after == "a.m" || after == "p.m" {
                minute = m.value
                j += m.length
            }
        }
        guard j < tokens.count else { return nil }
        let marker = bare(tokens[j])
        let punct = trailingPunct(tokens[j])

        if marker == "am" || marker == "pm" || marker == "a.m" || marker == "p.m" {
            let suffix = marker.hasPrefix("a") ? "AM" : "PM"
            let hour = first.value > 12 ? first.value : first.value
            let body = minute == nil ? "\(hour)" : String(format: "%d:%02d", hour, minute!)
            return ("\(body) \(suffix)" + punct, j + 1)
        }
        if marker == "o'clock" || marker == "oclock" {
            return ("\(first.value) o'clock" + punct, j + 1)
        }
        return nil
    }

    private static func formatGrouped(_ value: Int) -> String {
        guard value >= 10_000 else { return String(value) }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// True for a token that could be an email local part or host name.
    private static func isWordy(_ token: String) -> Bool {
        let b = bare(token)
        guard !b.isEmpty else { return false }
        if unitsWords[b] != nil || tensWords[b] != nil { return false }
        return b.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    // MARK: - 4. Spoken punctuation

    /// Multi-word forms first; each maps to the literal it produces.
    private static let punctuationPhrases: [([String], String)] = [
        (["new", "paragraph"], "\n\n"),
        (["new", "line"], "\n"),
        (["newline"], "\n"),
        (["next", "line"], "\n"),
        (["question", "mark"], "?"),
        (["exclamation", "mark"], "!"),
        (["exclamation", "point"], "!"),
        (["full", "stop"], "."),
        (["period"], "."),
        (["comma"], ","),
        (["colon"], ":"),
        (["semicolon"], ";"),
        (["semi", "colon"], ";"),
    ]

    /// Words that, immediately before a punctuation word, mean the speaker is
    /// talking ABOUT the mark rather than dictating it: "put a period at the
    /// end", "the comma is missing".
    private static let punctuationContentGuards: Set<String> = [
        "a", "an", "the", "another", "this", "that", "these", "those",
        "one", "no", "any", "some", "each", "every", "with", "without", "missing",
    ]

    static func applySpokenPunctuation(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            var matched = false
            for (phrase, literal) in punctuationPhrases {
                guard i + phrase.count <= tokens.count else { continue }
                guard tokens[i..<(i + phrase.count)].map(bare) == phrase else { continue }
                // Only the LAST word of the phrase may carry punctuation of its
                // own; a comma inside "question, mark" means they are separate.
                let inner = tokens[i..<(i + phrase.count - 1)]
                if inner.contains(where: { !trailingPunct($0).isEmpty }) { continue }
                // Content guard: "a period" is a noun, not a dictated mark.
                if i > 0, punctuationContentGuards.contains(bare(tokens[i - 1])) { continue }
                // A dictated mark that is followed by more of the same noun
                // phrase ("period at the end of the sentence") is also content.
                if literal == ".", i + phrase.count < tokens.count,
                   ["at", "of", "in", "key"].contains(bare(tokens[i + phrase.count])) { continue }

                appendLiteral(literal, to: &out)
                // Carry any punctuation the speaker's own pause attached.
                i += phrase.count
                matched = true
                break
            }
            if matched { continue }

            // --- quote ... unquote
            if bare(tokens[i]) == "quote", let close = findUnquote(tokens, from: i + 1) {
                var inner = Array(tokens[(i + 1)..<close])
                if inner.isEmpty {
                    // "quote unquote <word>" wraps the single word that follows.
                    if close + 1 < tokens.count {
                        inner = [tokens[close + 1]]
                        i = close + 2
                    } else {
                        i = close + 1
                        continue
                    }
                } else {
                    i = close + 1
                }
                let punct = trailingPunct(inner[inner.count - 1])
                if !punct.isEmpty {
                    inner[inner.count - 1] = String(inner[inner.count - 1].dropLast(punct.count))
                }
                inner[0] = "\"" + inner[0]
                inner[inner.count - 1] = inner[inner.count - 1] + "\"" + punct
                out.append(contentsOf: inner)
                continue
            }

            out.append(tokens[i])
            i += 1
        }
        return out
    }

    private static func findUnquote(_ tokens: [String], from: Int) -> Int? {
        for j in from..<tokens.count where bare(tokens[j]) == "unquote" { return j }
        return nil
    }

    /// Attaches a dictated mark to the preceding word, or emits it as its own
    /// token when there is nothing to attach to.
    private static func appendLiteral(_ literal: String, to out: inout [String]) {
        if literal == "\n" || literal == "\n\n" {
            out.append(literal)
            return
        }
        guard let last = out.last, !last.isEmpty,
              last != "\n", last != "\n\n" else {
            out.append(literal)
            return
        }
        // Do not stack marks: "period comma" keeps the first.
        if !trailingPunct(last).isEmpty { return }
        out[out.count - 1] = last + literal
    }

    // MARK: - 5. Trailing send cues

    /// Spoken hand-offs that end a dictation and are not part of the message.
    private static let sendCues: [[String]] = [
        ["send", "it"], ["send", "that"], ["send", "it", "now"],
        ["that's", "it"], ["thats", "it"], ["that", "is", "it"],
        ["over", "and", "out"], ["over"], ["end", "of", "message"], ["send"],
    ]

    static func stripTrailingSendCues(_ tokens: [String]) -> [String] {
        var tokens = tokens
        // Ignore trailing standalone punctuation and newlines while matching.
        var end = tokens.count
        while end > 0, punctuationTokens.contains(tokens[end - 1]) || tokens[end - 1] == "\n" || tokens[end - 1] == "\n\n" {
            end -= 1
        }
        for cue in sendCues {
            guard end >= cue.count else { continue }
            let slice = tokens[(end - cue.count)..<end].map(bare)
            guard slice == cue else { continue }
            // Never strip the entire message.
            guard end - cue.count > 0 else { continue }
            tokens.removeSubrange((end - cue.count)..<tokens.count)
            // Restore the sentence mark the cue was carrying, if the body lost one.
            if let last = tokens.last, trailingPunct(last).isEmpty, !punctuationTokens.contains(last) {
                tokens[tokens.count - 1] = last
            }
            break
        }
        return tokens
    }

    // MARK: - 6. Capitalization

    /// Acronyms people dictate as words and expect uppercase. Kept short on
    /// purpose: every entry here is a word that has no lowercase meaning.
    private static let acronyms: [String: String] = [
        "asap": "ASAP", "eta": "ETA", "api": "API", "url": "URL", "atm": "ATM",
        "pdf": "PDF", "usa": "USA", "uk": "UK", "iit": "IIT", "gst": "GST",
        "faq": "FAQ", "ceo": "CEO", "cto": "CTO", "hr": "HR", "otp": "OTP",
        "upi": "UPI", "emi": "EMI", "id": "ID", "eod": "EOD",
    ]

    private static let capitalIForms: Set<String> = ["i", "i'll", "i'm", "i've", "i'd"]

    static func applyCapitalization(_ tokens: [String]) -> [String] {
        var out = tokens
        var startOfSentence = true

        for idx in out.indices {
            let token = out[idx]
            if token == "\n" || token == "\n\n" { startOfSentence = true; continue }
            if punctuationTokens.contains(token) {
                if ".!?".contains(token) { startOfSentence = true }
                continue
            }

            let b = bare(token)

            // "i" and its contractions, wherever they appear.
            if capitalIForms.contains(b) {
                out[idx] = uppercaseFirstLetter(token)
            } else if let acronym = acronyms[b], token == token.lowercased() {
                out[idx] = token.replacingOccurrences(of: b, with: acronym)
            } else if startOfSentence {
                out[idx] = uppercaseFirstLetter(token)
            }

            let punct = trailingPunct(token)
            startOfSentence = punct.contains(".") || punct.contains("!") || punct.contains("?")
        }
        return out
    }

    private static func uppercaseFirstLetter(_ token: String) -> String {
        guard let idx = token.firstIndex(where: { $0.isLetter }) else { return token }
        // Leave words that are already capitalized or all-caps alone.
        if token[idx].isUppercase { return token }
        var s = token
        s.replaceSubrange(idx...idx, with: String(token[idx]).uppercased())
        return s
    }
}
