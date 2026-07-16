// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhisperKey",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .executableTarget(
            name: "WhisperKey",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/WhisperKey"
        ),
        .testTarget(
            name: "WhisperKeyTests",
            dependencies: ["WhisperKey"],
            path: "Tests/WhisperKeyTests"
        ),
    ]
)
