// swift-tools-version: 6.2
//
// The voice engine, as a Swift package. The macOS app (App/) is built on it.
//
//   VoiceCore         the "core": conversation logic, turn detection, text clean-up, hardware tiers,
//                     model catalog and downloader, extension point. Pure Swift, no heavy dependency,
//                     unit-tested. Portable in spirit: nothing here is Apple-specific except the
//                     NaturalLanguage language guesser.
//   VoiceEngineApple  the Apple Silicon implementations of the four engine interfaces:
//                     Silero VAD + Parakeet STT + Pocket TTS on CoreML (FluidAudio), Gemma 4 on MLX.
//                     Porting to Windows or Linux means rewriting this target only.
//   voice-cli         command-line tool: measures the engine without an interface (feeds recorded speech in
//                     real time, reports latencies per stage, interruption time and memory) and manages the
//                     models.
//
// Build with xcodebuild, not `swift build`: MLX needs Xcode to compile its Metal shaders.
// See README.md for the exact command.

import PackageDescription

let package = Package(
    name: "VoiceEngine",
    platforms: [.macOS(.v15)],  // macOS 15 minimum (only macOS 27 is tested)
    products: [
        .library(name: "VoiceCore", targets: ["VoiceCore"]),
        .library(name: "VoiceEngineApple", targets: ["VoiceEngineApple"]),
        .executable(name: "voice-cli", targets: ["VoiceCLI"]),
    ],
    dependencies: [
        // Versions are pinned exactly: these are the measured ones, and an engine update must be a
        // deliberate, re-measured change.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),  // Apache-2.0
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),  // MIT
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5"),  // Apache-2.0
    ],
    targets: [
        .target(name: "VoiceCore"),
        .target(
            name: "VoiceEngineApple",
            dependencies: [
                "VoiceCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .executableTarget(
            name: "VoiceCLI",
            dependencies: ["VoiceCore", "VoiceEngineApple", .product(name: "FluidAudio", package: "FluidAudio")]),
        .testTarget(name: "VoiceCoreTests", dependencies: ["VoiceCore"]),
    ]
)
