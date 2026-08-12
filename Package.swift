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
            path: "Sources/Voicy"
        )
    ]
)