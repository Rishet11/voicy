# Edge case audit

- Created EDGE-NOTES.md with required header + Log section.
- Read SelfTest.swift (297 lines): runSelfTestIfRequested(), runSelfTest(), resultLine/resultTier2 helpers, existing checks (Microphone, SpeechRecognition, Contacts, Accessibility, InputMonitoring, WhatsAppInstalled, WhatsAppMedia, TranscriptionEngine).
- Read AliasStore.swift (aliases.json at ~/Library/Application Support/Voicy/aliases.json, JSON dict [String: Entry], Entry is public Codable: spoken/contactIdentifier/e164), Blocklist.swift (blocklist.json at same dir, [String] array, .corrupt state = fail closed), ContactIndex.swift (keys used: identifier, givenName, familyName, nickname, organizationName, phoneNumbers), main.swift (selftest hook already wired), build.sh (dist/Voicy.app signed with stable identity, falls back to ad-hoc; stale-bundle trap documented), Package.swift (platforms: macOS 14).
- Planning checks: audio hardware, bundle identity, contacts quality, WhatsApp state, disk/config sanity.
