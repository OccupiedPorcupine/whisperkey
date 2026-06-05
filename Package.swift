// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhisperKey",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WhisperKey",
            path: "Sources/WhisperKey"
        )
    ]
)
