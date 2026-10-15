# OpenMaé

A voice assistant for Apple silicon Macs that runs **entirely on your Mac**. You talk, it answers out loud, in
French or English, in real time — like the voice mode of the big chat apps, but local: speech recognition,
the language model and the voice all run on the Mac, and nothing you say ever leaves it.

> **Status:** proof of concept, under active development. The app does not download its models by itself
> yet, and is not distributed as a disk image: for now it is built from source, with models fetched during
> development (see below).

## Features

- **Spoken conversation.** The assistant starts talking while the language model is still writing: the
  answer goes to the voice sentence by sentence.
- **Interrupt at any time.** Speak over the assistant and it stops within about a quarter of a second. A
  click on the indicator or the Escape key works too.
- **Echo cancellation.** On the Mac's speakers, the assistant does not hear itself. A headphones mode skips
  the echo processing, and push-to-talk (hold the space bar) helps in noisy places.
- **French first, English too.** It answers in the language you speak, and switches by itself.
- **Private by design.** No account, no telemetry, no cloud.
- **Adapted to your Mac.** The language model is chosen from the Mac's memory (see below).
- **Measurements built in.** A side panel shows the latency of each stage, interruption times, memory and
  audio devices.
- Interface in French and English.

## Requirements

A Mac with Apple silicon (M1 or later) and macOS 15 or later.

| Tier | Memory | Language model | Status |
|---|---|---|---|
| Minimum | 8 GB | Gemma 4 E2B, 4-bit | untested, estimated |
| Standard | 16 to 24 GB | Gemma 4 E4B, 4-bit | untested, estimated |
| Comfort | 32 to 36 GB | Gemma 4 26B-A4B, 4-bit | tested (M1 Pro, 32 GB) |
| Maximum | 48 GB and more | Gemma 4 26B-A4B, 8-bit | untested, estimated |

Only the comfort tier could be measured so far. The app says so when it runs on another one.

## How it works

```
microphone ─► voice activity ─► speech recognition ─► language model ─► voice ─► speakers
              Silero VAD          Parakeet TDT v3        Gemma 4          Pocket TTS
              (CPU)               (Neural Engine)        (MLX, GPU)       (GPU)
```

- The end of your turn is detected after a short silence. During a pause in the middle of a sentence, the
  answer is already prepared, and dropped if you go on.
- Answers stream: each sentence goes to the voice as soon as it is written.
- The conversation stays in the model's memory between turns, so each answer only has to read your last
  sentence.

Measured on an M1 Pro with 32 GB:
- **End of your sentence → first sound:** about 1.6 s (median). The target is under 1 s, not reached yet:
  most of the delay is the voice getting started.
- **Interruption:** the voice stops about 0.25 s after you start speaking.
- **Memory:** about 16 GB in all, 14 GB of it for the language model.

The app (SwiftUI) and the engine (a Swift package) only talk through a small set of commands and events
(`Sources/VoiceCore/AssistantProtocol.swift`). The Apple-specific parts of the engine live in one target, so
porting to another platform means rewriting that target and the interface, not the conversation logic.

## Models and licenses

| Component | Role | License | Source |
|---|---|---|---|
| Silero VAD v6.2.1 | voice activity detection | MIT | CoreML export by aufklarer, shipped in the app |
| Parakeet TDT 0.6B v3 | speech recognition (25 European languages) | CC-BY-4.0 | NVIDIA; CoreML export by FluidInference |
| Gemma 4 (E2B, E4B, 26B-A4B) | language model | Apache-2.0 | Google; MLX conversions by mlx-community |
| Pocket TTS | voice ("estelle" in French, "alba" in English) | CC-BY-4.0 (weights), MIT (code) | Kyutai; CoreML export by FluidInference |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | runs the CoreML models | Apache-2.0 | |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | runs the language model | MIT | |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | tokenizers | Apache-2.0 | |

## Models during development

The engine reads the models from the download caches:
- speech recognition and the voice are fetched by FluidAudio into its own caches the first time they are
  used;
- the language model of the Mac's tier must be in the Hugging Face cache, for instance for the comfort tier:

```bash
hf download mlx-community/gemma-4-26b-a4b-it-4bit
```

## Building from source

Requirements:
- Xcode 27 with its Metal Toolchain component: MLX compiles Metal shaders, which `swift build` cannot do.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), which generates the Xcode project from `App/project.yml`.

Install the two tools (once):

```bash
xcodebuild -downloadComponent MetalToolchain
```

```bash
brew install xcodegen
```

Build the app:

```bash
zsh scripts/build-app.sh
```

Launch it:

```bash
open .build/app/Build/Products/Release/OpenMae.app
```

macOS asks for access to the microphone: click "Allow". The first loading of the models takes one to two
minutes (macOS prepares speech recognition for the chip), then about twenty seconds at each launch.

The app's file name has no accent (`codesign` rejects one in an executable's name); macOS shows "OpenMaé"
through the localized display name. To sign with your own Apple Developer team, copy
`App/Signing.local.xcconfig.example` to `App/Signing.local.xcconfig` and fill it in; without it, the app is
signed for local use only.

To see a timestamped log of every stage, launch it with:

```bash
open --env VOICE_DEBUG=1 --stderr /tmp/openmae.log .build/app/Build/Products/Release/OpenMae.app
```

Build the engine and the command-line tool:

```bash
xcodebuild -scheme VoiceEngine-Package -destination 'platform=macOS,arch=arm64' -configuration Release -derivedDataPath .build/xcode -skipMacroValidation -skipPackagePluginValidation build
```

Run the tests:

```bash
xcodebuild test -scheme VoiceEngine-Package -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -skipMacroValidation -skipPackagePluginValidation -only-testing:VoiceCoreTests
```

## Command-line tool

`voice-cli` measures the engine without any interface: it plays recorded speech in real time, as a
microphone would. First generate the test phrases with macOS's built-in voices:

```bash
zsh scripts/make-test-audio.sh
```

A conversation, with the latency of each stage:

```bash
.build/xcode/Build/Products/Release/voice-cli conversation measurements/audio/0*.wav
```

Interruptions (speaking over the assistant):

```bash
.build/xcode/Build/Products/Release/voice-cli interruption measurements/audio/10-histoire.wav measurements/audio/11-stop.wav
```

Memory over time (here 10 minutes):

```bash
.build/xcode/Build/Products/Release/voice-cli endurance --minutes 10 measurements/audio/0*.wav
```

## Project layout

```
App/                         the macOS app (SwiftUI): screens only; its Xcode project is generated from
                             App/project.yml
Package.swift                the voice engine, as a Swift package:
Sources/VoiceCore/             conversation logic, end-of-turn detection, text clean-up for the voice,
                               hardware tiers, extension point
Sources/VoiceEngineApple/      the Apple implementations: Silero, Parakeet and Pocket TTS (CoreML),
                               Gemma 4 (MLX), microphone and speakers (AVAudioEngine)
Sources/VoiceCLI/              voice-cli
Tests/VoiceCoreTests/          unit tests of the core
scripts/                     build script, test phrases
```

The app's name is defined in one place for the engine (`Sources/VoiceCore/AppIdentity.swift`), and in
`App/project.yml` and `App/Resources/InfoPlist.xcstrings` for the app bundle.

## License

No license has been chosen yet: until a license file is added, all rights are reserved. The models and
libraries keep their own licenses (table above).
