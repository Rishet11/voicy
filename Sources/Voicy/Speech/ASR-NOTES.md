# ASR accuracy work

## Log
- Created ASR-NOTES.md; listed Speech/ dir (Transcriber.swift, LegacySpeechTranscriber.swift) and Tests/audio/ (23 clips incl. manifest.tsv).
- Read Transcriber.swift (SpeechAnalyzer engine, macOS 26 API) and LegacySpeechTranscriber.swift (SFSpeechRecognizer fallback, en_US default).
- Read manifest.tsv (22 clips; names Pulkit/Aarav/Siddharth/Aditi/Shreya/Rahul/Meera/Xavier). Found harness entry in Sources/Voicy/Testing/TestHarness.swift.
- BASELINE (en_US SpeechAnalyzer): 22/22 pass, min 101.4 / median 123.3 / max 291.9 ms. Name mangling observed: msg-pulkit-saying="Paul Kit", msg-pulkit-bare="Polka", send-a-message="Arav", name-last-send="Polkit", name-last-say="our ab", name-last-tell="Polka", name-last-before="our ad", indian-aditi="Adidi", no-number="Mira Krishna", verbless-siddharth="Sidharth"; also special-chars/long-body/name-last-long="Polkit". Unit tests green (send path 6/6; full unit suite PASS).
- Env: macOS 26.5.1 (25F80), Swift 6.3.2, target arm64-apple-macosx26.0. SDK swiftinterface exists (36,648 bytes). Grep confirms: AssetInventory.status(forModules:), assetInstallationRequest(supporting:), AssetInstallationRequest.downloadAndInstall(), SpeechTranscriber.supportedLocales/installedLocales (get async).
- swiftinterface also shows SFCustomLanguageModelData + PhraseCount + TemplatePhraseCountGenerator + PhraseCountsFromTemplates(classes:builder:), and DictationTranscriber.ContentHint.customizedLanguage(modelConfiguration: SFSpeechLanguageModel.Configuration). SFSpeechLanguageModel class exists too. Reading exact signatures next.
