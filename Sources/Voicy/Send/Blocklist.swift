import Foundation

/// Kill-switch: a hard blocklist of contacts that can NEVER be sent to, plus a
/// master `neverSend` flag that stops every outbound path at once.
///
/// The list is loaded from `~/Library/Application Support/Voicy/blocklist.json`
/// in either of two shapes:
///
///   ["919876543210", "Boss"]                         // entries only
///   {"neverSend": true, "entries": ["919876543210"]}  // entries + master switch
///
/// The default state is empty with `neverSend` off, but the mechanism is always
/// wired in so the app ships with the safety rail in place.
///
/// Fail-closed semantics: if the file exists but cannot be parsed, we treat the
/// blocklist as unusable and refuse every send. A malformed blocklist must never
/// silently allow a send to a contact the user tried to protect.
///
/// Matching is normalized, not literal. A blocklist that only catches the exact
/// string the user happened to type is not a safety rail: `+91 98765 43210`,
/// `098765 43210` and `9876543210` are the same person, and so are `Rahul
/// Sharma`, `rahul  sharma` and `Rahúl Sharma`. See `matches(_:entry:)`.
struct Blocklist: Sendable {
    enum LoadState: Sendable, Equatable {
        /// No file (default) or a valid, parsed list.
        case loaded(Set<String>)
        /// File present but unreadable / not a recognized shape.
        case corrupt
    }

    let state: LoadState

    /// Master never-send switch. When true, every outbound path refuses,
    /// regardless of who the recipient is.
    var neverSend: Bool = false

    /// Entry-point for the rest of the app. Reads the on-disk blocklist.
    static func load(fileManager: FileManager = .default) -> Blocklist {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let url = base?.appendingPathComponent("Voicy/blocklist.json")
        return Blocklist.load(from: url, fileManager: fileManager)
    }

    /// Whether sending is safe to proceed at all. False when the kill-switch
    /// file is corrupt (fail closed) or the master switch is on.
    var isUsable: Bool {
        if case .corrupt = state { return false }
        return !neverSend
    }

    /// True if `identifier` (a phone number or contact name) is blocked, under
    /// any spelling or number format that resolves to a blocked entry.
    func contains(_ identifier: String) -> Bool {
        guard case .loaded(let set) = state else { return false }
        let candidate = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return false }
        return set.contains { Blocklist.matches(candidate, entry: $0) }
    }

    var count: Int {
        guard case .loaded(let set) = state else { return 0 }
        return set.count
    }

    // MARK: - Matching

    /// Does `candidate` refer to the same target as blocklist `entry`?
    ///
    /// Checked in order, cheapest first. Any hit blocks. Over-blocking is the
    /// safe direction here: a false positive costs the user one manual send, a
    /// false negative costs them the message they were trying to prevent.
    static func matches(_ candidate: String, entry: String) -> Bool {
        // 1. Literal, after trimming. Covers the plain case and keeps the
        //    behaviour of the original exact-match implementation.
        let e = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate == e { return true }

        // 2. Phone numbers, normalized to E.164 digits. This is what catches
        //    "+91 ...", leading zeros, hyphens and spacing.
        if let a = PhoneNormalizer.normalize(candidate),
           let b = PhoneNormalizer.normalize(e) {
            if a == b { return true }
            // A number whose country code we could not infer still matches when
            // the national part is identical (last 10 digits).
            if a.count >= 10, b.count >= 10, a.suffix(10) == b.suffix(10) { return true }
        }

        // 3. Names, case- and diacritic-folded with collapsed whitespace.
        let na = NameNormalizer.normalize(candidate)
        let nb = NameNormalizer.normalize(e)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }

        // 4. Phonetic. Blocks the nickname/misheard-spelling route: a spoken
        //    name that sounds like a blocked name must not slip past because the
        //    transcript spelled it differently ("Rahool", "Raahul").
        return phoneticallyEqual(na, nb)
    }

    /// True when two normalized names have identical Soundex codes token for
    /// token. Requires the same token count so "rahul" cannot match
    /// "rahul sharma" (a different, more specific person).
    private static func phoneticallyEqual(_ a: String, _ b: String) -> Bool {
        let ta = a.split(separator: " ")
        let tb = b.split(separator: " ")
        guard ta.count == tb.count, !ta.isEmpty else { return false }
        for (x, y) in zip(ta, tb) {
            guard let cx = Soundex.encode(String(x)), let cy = Soundex.encode(String(y)),
                  cx == cy else { return false }
        }
        return true
    }

    // MARK: - Loading

    /// Object form of the file. `entries` is optional so `{"neverSend": true}`
    /// alone is a valid "block everything" file.
    private struct FileShape: Decodable {
        let neverSend: Bool?
        let entries: [String]?
    }

    private static func load(from url: URL?, fileManager: FileManager) -> Blocklist {
        guard let url, fileManager.fileExists(atPath: url.path) else {
            return Blocklist(state: .loaded([]))
        }
        guard let data = try? Data(contentsOf: url) else {
            print("[voicy] ERROR: blocklist unreadable at \(url.path). Refusing to send (fail closed).")
            return Blocklist(state: .corrupt)
        }
        if let array = try? JSONDecoder().decode([String].self, from: data) {
            return Blocklist(state: .loaded(Set(array)))
        }
        if let object = try? JSONDecoder().decode(FileShape.self, from: data) {
            return Blocklist(state: .loaded(Set(object.entries ?? [])),
                             neverSend: object.neverSend ?? false)
        }
        print("[voicy] ERROR: blocklist at \(url.path) is neither [String] nor {neverSend,entries}. Refusing to send (fail closed).")
        return Blocklist(state: .corrupt)
    }
}
