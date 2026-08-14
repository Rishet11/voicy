// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Voicy",
    platforms: [
        // macOS 26, matching the requirement the README already states.
        //
        // This used to say .v14, which was a support claim nobody had ever
        // tested. There are 13 `if #available(macOS 26.0, *)` sites across the
        // speech and pipeline code. Reading them shows the one-shot transcribe
        // path does have a genuine SFSpeechRecognizer fallback, so macOS 14
        // would most likely transcribe, minus the live partial transcript,
        // which has no fallback at all and would simply never appear. But
        // "most likely" is the problem: this app has only ever been run on
        // macOS 26, there is no macOS 14 machine to check it on, and shipping
        // an advertised floor backed by never-executed code is the kind of
        // claim that turns into a bug report from a stranger. Declaring the
        // floor that is actually tested is honest. Declaring one that is not
        // is not.
        //
        // Spelled as a version string rather than `.v26` because the `.v26`
        // enum case is not available at swift-tools-version 6.0.
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "Voicy",
            path: "Sources/Voicy",
            exclude: [
                "Cleanup/LLM-FINDINGS.md",
                "Cleanup/TEXT-NOTES.md",
                "Diagnostics/EDGE-NOTES.md",
                "Send/SEND-SAFETY.md",
                "Speech/ASR-NOTES.md",
                "UI/UI-NOTES.md",
                "VoiceNotes/FINDINGS.md"
            ]
        )
    ]
)
