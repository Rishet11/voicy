import Foundation
import Speech

/// How the transcription engine picks its locale.
///
/// Resolution, highest first, with no environment variables or launch flags:
///   1. An explicit `locale:` argument at the call site (the test harness's
///      `--locale` diagnostic flag for A/B runs).
///   2. The persisted user setting (`UserDefaults`, key `voicy.transcriberLocale`).
///   3. The user's system locale (`Locale.autoupdatingCurrent`), resolved live
///      at runtime, with any attribute suffix (`@rg=...`) stripped.
///   4. `en_US`, only when the system reports no usable locale.
///
/// The requested locale is then validated against what is actually installed
/// on this machine. A locale that is not installed would silently produce
/// garbage (or nothing) from Apple's recognizer, so `availableLocale(for:)`
/// falls back instead: same language if one is installed, then `en_US`, then
/// the first installed locale. The fallback is logged, never silent.
enum TranscriberLocale {

    /// The UserDefaults key the user-facing setting is stored under.
    static let persistedSettingKey = "voicy.transcriberLocale"

    /// The safe default every machine ships with.
    static let defaultIdentifier = "en_US"

    // MARK: - Persisted setting

    static func persistedIdentifier() -> String? {
        UserDefaults.standard.string(forKey: persistedSettingKey)
    }

    static func setPersisted(_ identifier: String) {
        UserDefaults.standard.set(identifier, forKey: persistedSettingKey)
    }

    static func clearPersisted() {
        UserDefaults.standard.removeObject(forKey: persistedSettingKey)
    }

    // MARK: - Requested locale (no availability check)

    /// The locale the user asked for: the persisted setting, else the system
    /// locale, else `en_US`. Pure function of its inputs so it is unit-testable.
    static func requestedLocale(
        persisted: String? = persistedIdentifier(),
        system: Locale = Locale.autoupdatingCurrent
    ) -> Locale {
        if let stored = persisted, !stored.isEmpty {
            return Locale(identifier: stored)
        }
        // The system locale can carry attributes (`en_AU@rg=inzzzz`) that no
        // speech module is installed under; drop them and keep the BCP-47 part.
        var systemID = system.identifier
        if let at = systemID.firstIndex(of: "@") { systemID = String(systemID[..<at]) }
        if !systemID.isEmpty, systemID.lowercased() != "und" {
            return Locale(identifier: systemID)
        }
        return Locale(identifier: defaultIdentifier)
    }

    // MARK: - Fallback on an unavailable locale

    /// Picks a usable locale for `requested` given the locales `installed` on
    /// this machine. Pure and deterministic:
    ///   exact match -> same-language match -> en_US -> first installed.
    /// Identifiers are compared after stripping attribute suffixes and
    /// normalizing `-` to `_`, so `en-us` matches an installed `en_US` and the
    /// system locale's `@rg=...` form does not defeat the match.
    /// An empty inventory means there is nothing to fall back TO; the request
    /// is returned unchanged and the engine surfaces its own error.
    static func resolve(requested: Locale, installed: [Locale]) -> (locale: Locale, fellBack: Bool) {
        func canonical(_ locale: Locale) -> String {
            var id = locale.identifier
            if let at = id.firstIndex(of: "@") { id = String(id[..<at]) }
            return id.replacingOccurrences(of: "-", with: "_")
        }
        let want = canonical(requested)
        let byCanonical = Dictionary(installed.map { (canonical($0), $0) },
                                     uniquingKeysWith: { first, _ in first })

        if let exact = byCanonical[want] { return (exact, false) }

        let language = requested.languageCode
        let sameLanguage = installed
            .filter { $0.languageCode == language }
            .sorted { canonical($0) < canonical($1) }
        // Inside the same language, prefer en_US: it is the fallback every
        // machine ships with, so it beats an alphabetically-earlier variant.
        if let enUS = sameLanguage.first(where: { canonical($0) == defaultIdentifier }) {
            return (enUS, true)
        }
        if let first = sameLanguage.first { return (first, true) }

        if let enUS = byCanonical[defaultIdentifier] {
            return (enUS, true)
        }

        if let first = installed.sorted(by: { canonical($0) < canonical($1) }).first {
            return (first, true)
        }

        return (requested, false)
    }

    // MARK: - Machine availability

    /// Installed locale inventory for the shipped engine family, cached for the
    /// process. On macOS 26 that is `SpeechTranscriber.installedLocales` (an
    /// installed locale needs no asset download); below macOS 26 the legacy
    /// `SFSpeechRecognizer.supportedLocales` is the best the OS exposes.
    nonisolated(unsafe) private static var installedCache: [Locale]?

    static func installedLocales() async -> [Locale] {
        if let cached = installedCache { return cached }
        let installed: [Locale]
        if #available(macOS 26.0, *) {
            installed = await SpeechTranscriber.installedLocales
        } else {
            installed = Array(SFSpeechRecognizer.supportedLocales())
        }
        installedCache = installed
        return installed
    }

    /// Validates `requested` against the machine and applies the fallback chain
    /// when it is unavailable. Fallbacks are logged so a wrong setting is
    /// visible in diagnostics instead of silently transcribing with a locale
    /// the user did not pick.
    static func availableLocale(for requested: Locale) async -> (locale: Locale, fellBack: Bool) {
        let result = resolve(requested: requested, installed: await installedLocales())
        if result.fellBack {
            print("[voicy] transcriber locale \"\(requested.identifier)\" not installed; "
                  + "using \"\(result.locale.identifier)\"")
        }
        return result
    }
}
