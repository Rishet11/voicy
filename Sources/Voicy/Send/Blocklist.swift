import Foundation

/// Kill-switch: a hard blocklist of contacts that can NEVER be auto-sent to.
///
/// The list is loaded from `~/Library/Application Support/Voicy/blocklist.json`
/// and holds phone numbers (E.164, no leading `+`) and/or contact names. The
/// default state is empty, but the mechanism is always wired in so the app
/// ships with the safety rail in place.
///
/// Fail-closed semantics: if the file exists but cannot be parsed, we treat
/// the blocklist as unusable and refuse every auto-send. A malformed blocklist
/// must never silently allow a send to a contact the user tried to protect.
struct Blocklist: Sendable {
    enum LoadState: Sendable, Equatable {
        /// No file (default) or a valid, parsed list.
        case loaded(Set<String>)
        /// File present but unreadable / not a `[String]` array.
        case corrupt
    }

    let state: LoadState

    /// Entry-point for the rest of the app. Reads the on-disk blocklist.
    static func load(fileManager: FileManager = .default) -> Blocklist {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let url = base?.appendingPathComponent("Voicy/blocklist.json")
        return Blocklist.load(from: url, fileManager: fileManager)
    }

    /// Whether auto-send is safe to proceed at all. False when the kill-switch
    /// file is corrupt (fail closed).
    var isUsable: Bool {
        if case .corrupt = state { return false }
        return true
    }

    /// True if `identifier` (a phone number or contact name) is blocked.
    func contains(_ identifier: String) -> Bool {
        guard case .loaded(let set) = state else { return false }
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return set.contains(trimmed)
    }

    var count: Int {
        guard case .loaded(let set) = state else { return 0 }
        return set.count
    }

    private static func load(from url: URL?, fileManager: FileManager) -> Blocklist {
        guard let url, fileManager.fileExists(atPath: url.path) else {
            return Blocklist(state: .loaded([]))
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([String].self, from: data)
            return Blocklist(state: .loaded(Set(decoded)))
        } catch {
            print("[voicy] ERROR: blocklist unreadable at \(url.path): \(error). Refusing auto-send (fail closed).")
            return Blocklist(state: .corrupt)
        }
    }
}