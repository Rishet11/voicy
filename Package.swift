// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Voicy",
    platforms: [
        .macOS(.v14)
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
