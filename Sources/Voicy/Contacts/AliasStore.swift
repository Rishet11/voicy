import Foundation

/// Persistent "correct once and it remembers" store. Maps a normalized spoken
/// phrase to a contact identifier and its E.164 number. Stored as JSON at
/// `~/Library/Application Support/Voicy/aliases.json`.
///
/// HARD RULE: this file holds name mappings ONLY. Message content is never
/// written here.
public final class AliasStore: @unchecked Sendable {

    /// A single name mapping. No message content, ever.
    public struct Entry: Codable, Equatable, Sendable {
        public let spoken: String
        public let contactIdentifier: String
        public let e164: String

        public init(spoken: String, contactIdentifier: String, e164: String) {
            self.spoken = spoken
            self.contactIdentifier = contactIdentifier
            self.e164 = e164
        }
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Defaults to `~/Library/Application Support/Voicy/aliases.json`.
    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
            self.fileURL = support.appendingPathComponent("Voicy", isDirectory: true)
                                .appendingPathComponent("aliases.json")
        }
        load()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// Returns the entry for a normalized spoken phrase, if any.
    public func entry(forSpoken normalized: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[normalized]
    }

    /// The `[normalized spoken phrase: contact identifier]` map that
    /// `ContactResolver.resolve(spoken:contacts:aliases:)` takes.
    public var lookup: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return entries.mapValues(\.contactIdentifier)
    }

    /// All resolved contact identifiers currently aliased.
    public var knownIdentifiers: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(entries.values.map(\.contactIdentifier))
    }

    /// Records (or overwrites) an alias and persists it immediately.
    public func setAlias(spoken: String, contactIdentifier: String, e164: String) throws {
        let normalized = NameNormalizer.normalize(spoken)
        guard !normalized.isEmpty else { return }
        let entry = Entry(spoken: normalized, contactIdentifier: contactIdentifier, e164: e164)
        lock.lock()
        entries[normalized] = entry
        lock.unlock()
        try saveToDisk()
    }

    /// Removes an alias and persists the change.
    public func removeAlias(spoken: String) throws {
        let normalized = NameNormalizer.normalize(spoken)
        lock.lock()
        let removed = entries.removeValue(forKey: normalized) != nil
        lock.unlock()
        if removed { try saveToDisk() }
    }

    // MARK: - Persistence

    private func load() {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        entries = (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    /// Atomic write: encode to a temp file, then swap it into place. Safe
    /// against partial writes on crash or power loss.
    private func saveToDisk() throws {
        lock.lock()
        let snapshot = entries
        lock.unlock()

        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        let tmp = fileURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
    }
}