// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "apple-speech-analyzer-streaming-asr",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "speech-analyzer", targets: ["SpeechAnalyzerCLI"]),
    ],
    targets: [
        .executableTarget(
            name: "SpeechAnalyzerCLI",
            path: "Sources/SpeechAnalyzerCLI"
        ),
        .testTarget(
            name: "SpeechAnalyzerCLITests",
            dependencies: ["SpeechAnalyzerCLI"],
            path: "Tests/SpeechAnalyzerCLITests"
        ),
    ]
)
