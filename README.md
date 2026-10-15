# OpenMaé

A voice assistant for Apple silicon Macs that runs **entirely on your Mac**. You talk, it answers out loud, in
French or English, in real time — like the voice mode of the big chat apps, but local: speech recognition,
the language model and the voice all run on the Mac, and nothing you say ever leaves it.

The only network access is the one-time download of the models, at first launch. After that, OpenMaé works
in airplane mode.

> **Status:** proof of concept, under active development. Distribution as a signed, notarized disk image is
> not ready yet: for now the app is built from source (see below).

## Features

- **Spoken conversation.** The assistant starts talking while the language model is still writing: the
  answer goes to the voice sentence by sentence.
- **Interrupt at any time.** Speak over the assistant and it stops within about a quarter of a second. The
  Interrupt button, a click on the orb or the Escape key work too.
- **Echo cancellation.** On the Mac's speakers, the assistant does not hear itself. A headphones mode skips
  the echo processing, and push-to-talk (hold the space bar) helps in noisy places.
- **French first, English too.** It answers in the language you speak, and switches by itself.
- **Private by design.** No account, no telemetry, no cloud. The models are downloaded once, then the app
  never goes online again.
- **Adapted to your Mac.** The language model is chosen from the Mac's memory (see below); another tier can
  be forced in Settings › Advanced.
- **Measurements built in.** A side panel (View › Show Measurements, ⌥⌘M) shows the latency of each stage,
  interruption times, memory and audio devices.
- Interface in French and English.

## Requirements

- A Mac with Apple silicon (M1 or later) and macOS 15 or later.
- Free disk space for the models, from 5.7 GB to 30 GB depending on the Mac (table below).

| Tier | Memory | Language model | First download | Status |
|---|---|---|---|---|
| Minimum | 8 GB | Gemma 4 E2B, 4-bit | 5.7 GB | untested, estimated |
| Standard | 16 to 24 GB | Gemma 4 E4B, 4-bit | 7.3 GB | untested, estimated |
| Comfort | 32 to 36 GB | Gemma 4 26B-A4B, 4-bit | 17.5 GB | tested (M1 Pro, 32 GB) |
| Maximum | 48 GB and more | Gemma 4 26B-A4B, 8-bit | 30.1 GB | untested, estimated |

Only the comfort tier could be measured so far. The app says so when it runs on another one.

## First launch

1. macOS asks for access to the microphone: click "Allow". Sound never leaves the Mac.
2. The app shows the Mac, its tier, the models it needs with their size and license, the total to download
   and the free space, and waits for a click on "Download".
3. The download can be paused, or the app quit: it resumes where it stopped, and after a network cut it
   resumes by itself. Every file is checked against the SHA-256 recorded in the app: the models are pinned to
   the exact versions that were tested.
4. The first loading of the models takes one to two minutes (macOS prepares speech recognition for the
   chip), then about twenty seconds at each launch.

Settings › Advanced shows the space taken by the models, and can delete the models of the other tiers, or
all of them.

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
| Bricolage Grotesque, Figtree | interface typefaces | SIL Open Font License 1.1 | shipped in the app with their license (`App/Resources/Fonts`) |

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

`voice-cli` uses the same engine and the same models as the app, without any interface.

Download the models of this Mac's tier (or of `--tier minimum|standard|comfort|max`):

```bash
.build/xcode/Build/Products/Release/voice-cli download
```

Check every downloaded file against its SHA-256 (about one second per GB):

```bash
.build/xcode/Build/Products/Release/voice-cli verify
```

Measure the engine with recorded speech, played in real time as a microphone would. First generate the test
phrases with macOS's built-in voices:

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

To move a model to another version (a deliberate change, to be measured again): edit its `revision` in
`Sources/VoiceCore/ModelCatalog.swift`, then regenerate the list of its files, sizes and SHA-256 from Hugging
Face:

```bash
.build/xcode/Build/Products/Release/voice-cli catalog
```

## Project layout

```
App/                         the macOS app (SwiftUI): screens only; its Xcode project is generated from
                             App/project.yml
Package.swift                the voice engine, as a Swift package:
Sources/VoiceCore/             conversation logic, end-of-turn detection, text clean-up for the voice,
                               hardware tiers, model catalog and downloader, extension point
Sources/VoiceEngineApple/      the Apple implementations: Silero, Parakeet and Pocket TTS (CoreML),
                               Gemma 4 (MLX), microphone and speakers (AVAudioEngine)
Sources/VoiceCLI/              voice-cli
Tests/VoiceCoreTests/          unit tests of the core
scripts/                     build script, test phrases
```

The app's name is defined in one place for the engine (`Sources/VoiceCore/AppIdentity.swift`), and in
`App/project.yml` and `App/Resources/InfoPlist.xcstrings` for the app bundle.

## Uninstalling

Move the app to the Trash. To get back the space taken by the models, either use Settings › Advanced ›
"Delete the models…" first, or delete these folders by hand:
- `~/Library/Application Support/OpenMaé` (the models);
- `~/Library/Caches/io.github.lgentilla.openmae` (the models compiled for the chip, about 2 GB).

The settings live in `~/Library/Preferences/io.github.lgentilla.openmae.plist`.

## License

No license has been chosen yet: until a license file is added, all rights are reserved. The models and
libraries keep their own licenses (table above).
