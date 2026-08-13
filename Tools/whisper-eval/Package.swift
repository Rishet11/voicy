// swift-tools-version: 6.0
import PackageDescription

// A SEPARATE package on purpose.
//
// The question being answered is "would a Whisper-class model transcribe this
// corpus better than Apple Speech, and at what latency". Answering it does not
// require WhisperKit to be a dependency of the shipped app, and making it one
// would force every other agent working in this repo to build a CoreML stack
// they do not need, on a file (Package.swift) several of them share.
//
// So the evaluation lives here, reuses the same WER scorer as the app harness
// (WordErrorRate.swift is symlinked, not copied, so the two can never drift),
// and reads the same manifests and WAVs. If Whisper wins on the numbers, adding
// the dependency to the app is a separate, deliberate change.
let package = Package(
    name: "whisper-eval",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "whisper-eval",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")],
            path: "Sources/whisper-eval"
        )
    ]
)
