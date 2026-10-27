// swift-tools-version: 6.2
//
// The voice engine, as a Swift package. The macOS app (App/) is built on it.
//
//   VoiceCore         the "core": conversation logic, turn detection, text clean-up, hardware tiers,
//                     model catalog and downloader, extension point. Pure Swift, no heavy dependency,
//                     unit-tested. Portable in spirit: nothing here is Apple-specific except the
//                     NaturalLanguage language guesser.
//   VoiceEngineApple  the Apple Silicon implementations of the four engine interfaces:
//                     Silero VAD + Parakeet STT + Pocket TTS on CoreML (FluidAudio), Gemma 4 on MLX;
//                     and the memory's journal (SQLite) with its sentence-embedding model (MLX).
//                     Porting to Windows or Linux means rewriting this target only.
//   voice-cli         command-line tool: measures the engine without an interface (feeds recorded speech in
//                     real time, reports latencies per stage, interruption time and memory) and manages the
//                     models.
//   OpenMaeLink       the link between the iPhone app and the Mac (relay/PROTOCOL.md): device keys, pairing,
//                     Noise encryption, direct and relayed connections, the voice's codec and jitter buffer.
//                     Shared by both apps, so it builds for iOS too (as VoiceCore does, for the
//                     commands/events contract).
//
// Build with xcodebuild, not `swift build`: MLX needs Xcode to compile its Metal shaders.
// See README.md for the exact command.

import PackageDescription

let package = Package(
    name: "VoiceEngine",
    // macOS 15 minimum (only macOS 27 is tested); iOS for the iPhone app, which only uses VoiceCore and OpenMaeLink.
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "VoiceCore", targets: ["VoiceCore"]),
        .library(name: "VoiceEngineApple", targets: ["VoiceEngineApple"]),
        .library(name: "OpenMaeLink", targets: ["OpenMaeLink"]),
        .executable(name: "voice-cli", targets: ["VoiceCLI"]),
    ],
    dependencies: [
        // Versions are pinned exactly: these are the measured ones, and an engine update must be a
        // deliberate, re-measured change.
        // OpenMaé's fork: FluidAudio 0.17.7 and one fix, the FlowLM step's caches written into arrays the session keeps
        // (with Gemma 4 26B loaded, allocating them anew at every frame slowed the voice from 45 to 57 ms per 80 ms).
        .package(url: "https://github.com/LGentila/FluidAudio.git", exact: "0.17.7-openmae.1"),  // Apache-2.0
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
                // The journal's search by meaning (`SentenceEmbedder`).
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .target(name: "OpenMaeLink", dependencies: ["VoiceCore"]),
        // A pretend Home Assistant (its MCP server on a local port), for the tests and voice-cli: never in the apps.
        .target(name: "FakeHomeAssistant", dependencies: ["VoiceCore"]),
        .executableTarget(
            name: "VoiceCLI",
            dependencies: ["VoiceCore", "VoiceEngineApple", "OpenMaeLink", "FakeHomeAssistant",
                           .product(name: "FluidAudio", package: "FluidAudio")]),
        .testTarget(name: "VoiceCoreTests", dependencies: ["VoiceCore", "FakeHomeAssistant"]),
        .testTarget(name: "OpenMaeLinkTests", dependencies: ["OpenMaeLink"]),
    ]
)
