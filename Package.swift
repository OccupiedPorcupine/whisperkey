// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhisperKey",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "WhisperKey",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/WhisperKey"
        )
    ]
)
