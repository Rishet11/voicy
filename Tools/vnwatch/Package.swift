// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "vnwatch",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "VoiceNotes", path: "../../Sources/Voicy/VoiceNotes"),
        .executableTarget(
            name: "vnwatch",
            dependencies: ["VoiceNotes"],
            path: "Sources/vnwatch"
        )
    ]
)
