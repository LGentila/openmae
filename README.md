# OpenMaé

A voice assistant for Apple silicon Macs that runs **entirely on your Mac**. You talk, it answers out loud, in
French or English, in real time — like the voice mode of the big chat apps, but local: speech recognition,
the language model and the voice all run on the Mac, and nothing you say ever leaves your own devices.

The only network access is the one-time download of the models, at first launch, and — only if you turn them
on — the link with your iPhone and the web search. After that, OpenMaé works in airplane mode.

> **Status:** proof of concept, under active development. Distribution as a signed, notarized disk image is
> not ready yet: for now the app is built from source (see below).

## Features

- **Spoken conversation.** The assistant starts talking while the language model is still writing: the
  answer goes to the voice sentence by sentence.
- **Interrupt at any time.** Speak over the assistant and it stops within about a quarter of a second. The
  Interrupt button, a click on the orb or the Escape key work too.
- **From any app.** Press ⌥ Space to talk, and again to finish: a small capsule at the bottom of the screen
  shows that Maé listens, thinks or answers, without bringing the window forward (Escape cancels or
  interrupts). Closing the window leaves OpenMaé in the menu bar, where its icon shows when Maé is active and
  has Quit; with the window closed, Maé only listens after ⌥ Space (unless she waits for « OK Maé », below).
  While OpenMaé runs, ⌥ Space no longer types a non-breaking space in other apps.
- **« OK Maé » (optional).** In Settings › Sound, choose to talk after « OK Maé »: Maé then only answers the
  sentences that start with it, so the TV and the conversations around no longer start her, and listens to any
  voice for a few seconds after each answer. While she speaks, only « OK Maé, stop », ⌥ Space, a click on the orb or
  Escape interrupt her. With the window closed she still waits for the phrase, and the capsule shows when she wakes;
  plugged in, the Mac does not go to sleep. The phrase is read in what speech recognition writes: say it in one
  breath with the request (« OK Maé, quelle heure est-il ? »); said alone it is often misheard (when it is heard, a
  chime, then she listens), and it often misses you while the TV talks.
- **Echo cancellation.** On the Mac's speakers, the assistant does not hear itself. A headphones mode skips
  the echo processing, and push-to-talk (hold the space bar) helps in noisy places.
- **French first, English too.** It answers in the language you speak, and switches by itself.
- **Actions (optional).** Turn on Settings › Conversation › Actions, and Maé adds events and reminders to your
  calendars (every account macOS knows: iCloud, Google, Exchange…), reads you what is planned, sets timers and
  runs the shortcuts you put in an “OpenMaé” folder of the Shortcuts app. The app, not the model, carries them
  out and says what was really saved; say “annule” (or “cancel”) within two minutes to take it back, and a shortcut can be
  set to ask first. OpenMaé itself still never goes online: macOS syncs the calendars.
- **Long tasks handed to Claude Code (optional).** With the actions on, switch on Claude Code in Settings ›
  Conversation, then ask for something long: “lance le développement d’un site pour la boulangerie de ma sœur”.
  Maé reads the task back, waits for your “oui”, and hands it to the Claude Code installed and signed in on
  your Mac, which works on its own in a new folder of `~/OpenMae` (or in a folder you allowed). Ask “où en est
  le site ?” whenever you like; a notification tells you when it is done, and the result is in the history.
  By default Claude Code may only change the files of its folder: anything else is refused, and Maé tells you.
  What you hand to Claude Code leaves your Mac — that is the point of handing it over.
- **Searching the internet (optional).** Switch on Settings › Conversation › Search the internet and choose where
  the searches go: **Brave Search**, with your own API key (create one on [Brave's site](https://brave.com/search/api/)
  and paste it), or **your own [SearXNG](https://docs.searxng.org/)**, with its JSON format on (and the password of
  a protection in front of it, if any). Keys and passwords go in the keychain; "Test" checks it all. Ask something
  Maé cannot know — “qui a gagné le match du PSG hier soir ?”, “à quelle heure ferme la piscine le dimanche ?” —
  and she searches, reads the first results and answers in a sentence or two, naming the site; whatever the pages
  say, nothing is carried out while she sums them up. Only the few keywords she searches for leave the Mac: to
  Brave Search, or to your SearXNG and from there to the search engines. The results are never stored (no cache):
  they only live in the conversation. Public SearXNG instances are not used: they turn programs away, and OpenMaé
  never passes for a browser.
- **From your iPhone (optional).** The iPhone app is the Mac's microphone, speaker and screen: pair it once
  with a QR code (Settings › iPhone), then talk to Maé from the iPhone — directly on the home Wi-Fi, through an
  encrypted relay elsewhere (see [iPhone app](#iphone-app)). The work stays on the Mac.
- **Private by design.** No account, no telemetry, no cloud. The models are downloaded once, then the app
  never goes online again — unless you pair an iPhone: the Mac then stays reachable by it, everything between
  the two being end-to-end encrypted. (Claude Code, when you hand it a task, goes online on its own, with your
  account; the web search, when you turn it on, sends its keywords to Brave Search or to your SearXNG.)
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

## iPhone app

The iPhone app (iOS 18 or later) talks to OpenMaé on your Mac: it is its microphone, its speaker and its screen,
while the models keep running on the Mac. A conversation started on one goes on on the other, it continues with
the screen locked, and whoever speaks last has it (the Mac's window shows "Maé is on your iPhone" and "Take over
here").

- **Pairing, once.** On the Mac, Settings › iPhone › "Add an iPhone" shows a QR code, valid five minutes and
  usable once; scan it with the app. It carries the Mac's public key and a one-time code, after the `#` of a link
  (a browser never sends that part to a server).
- **At home**, the iPhone finds the Mac with Bonjour and talks to it directly over QUIC. The Mac and the iPhone
  each ask once for access to the local network (on the Mac, when you add your first iPhone).
- **Elsewhere**, both go through an OpenMaé relay (`relay/`, a small open-source server anyone can host): the
  Mac stays registered on it, the iPhone asks for it, and the relay passes their packets along. If UDP is
  blocked, a WebSocket over HTTPS takes over.
- **End-to-end encryption.** Noise (`IK` for sessions, `XXpsk3` for pairing; Curve25519, ChaChaPoly, SHA-256,
  checked against the official test vectors), keys in the keychain. A relay sees addresses and amounts of
  traffic, never a word or a sound. The protocol is in [relay/PROTOCOL.md](relay/PROTOCOL.md).
- **Sound.** Opus in 20 ms frames (Apple's own codec): 16 kHz from the iPhone's microphone, which removes the
  echo itself; 24 kHz for the voice, through a jitter buffer that conceals lost frames.
- **Powers.** The iPhone can talk, interrupt, start a new conversation and choose hands-free or hold-to-talk;
  downloading or deleting models, and quitting, stay on the Mac. Sensitive actions still ask for a spoken "yes".
- While an iPhone is paired, the Mac can stay awake when plugged in (Settings › iPhone › Sleep). An iPhone cannot
  wake a sleeping Mac.

Build it and install it on the iPhone connected to this Mac (with your Apple Developer team in
`App/Signing.local.xcconfig`):

```bash
zsh scripts/build-iphone.sh
```

`SIMULATOR=1 zsh scripts/build-iphone.sh` builds it for the simulator instead.

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
xcodebuild test -scheme VoiceEngine-Package -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -skipMacroValidation -skipPackagePluginValidation -only-testing:VoiceCoreTests -only-testing:OpenMaeLinkTests
```

The link's end-to-end tests (pairing, sessions, sound, on this Mac) use the network: they run with
`OPENMAE_NETWORK_TESTS=1` in the environment, and through a relay too with `OPENMAE_TEST_RELAY=<its URL>`
(see `relay/README.md` to run one locally).

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

`--actions` puts the actions in the model's instructions, as in the app when they are on (none is carried out, a call
is declined); with `--new-conversation-every 4`, a new conversation starts every four turns, as with "New
conversation" in the app, and the time it takes is shown. `--wake-word` only answers the recordings that start with
« OK Maé », as the app's wake-word mode; add `--follow-up 0` so that every recording needs the phrase (no seconds of
attention after an answer). `--no-voice-restart` keeps the voice going when its opening stays near-silent (the app
starts it again after 1.2 s of near-silence), and `--racing-voices 2` starts each answer with two voices at once, the
first one audible saying it (off in the app: 1.2 GB more memory).

The voice alone: how long it takes to make its first audible sound on typical first sentences, and the near-silence it
produces before (Pocket TTS opens each sentence with a breath of random length). `--parallel 2` has two voices speak
each sentence at once, the first audible one counting (as `--racing-voices 2` in a conversation); `--with-llm` has the
language model write an answer meanwhile, paused once its first sentence is written, as in a turn:

```bash
.build/xcode/Build/Products/Release/voice-cli voice-onset --repeats 5 --parallel 2
```

With `VOICE_DEBUG=1`, every engine command also logs, for each sentence the voice says, how long its first frame took,
how many near-silent frames came before the first audible one and how fast the frames came.

Check that the language model picks the right action, with the right date. Text only, nothing is created: the
French requests of `Tests/Fixtures/actions-fr.json` (actions, and traps that only look like one) are sent at a
fixed reference time, and the report gives the right-tool rate, the dates, false triggers and the time to a
complete call:

```bash
.build/xcode/Build/Products/Release/voice-cli actions-bench
```

The same with the tools that hand tasks to Claude Code (requests to hand over, questions about programming
that must not be, and questions about a task already handed over):

```bash
.build/xcode/Build/Products/Release/voice-cli actions-bench --corpus Tests/Fixtures/agents-fr.json
```

Searching the internet: requests that need a search, requests that do not (traps included) and research for an
agent. The model sums up the results recorded for each request in the corpus, as the app would have it do, and the
report gives the right decisions, the searches made by mistake, the keywords and what the summaries said:

```bash
.build/xcode/Build/Products/Release/voice-cli actions-bench --corpus Tests/Fixtures/web-fr.json
```

With `--searxng <address>`, the searches are made for real on that SearXNG, with the model's own keywords; `--web`
offers the search tool with the other corpora too, to check that it does not change their results.
`--compare-beginnings` generates nothing: it computes the beginning of the conversations (the system prompt with its
tools) as the app does (in float32, then rounded: the same state at load and after a tools change), then in bfloat16 as
it was computed before and with every weight in float32 as a reference, compares the model's memory after each, and
gives every request's chance of a call at its first token from each (a request whose decision moves with mere rounding
is one the model hesitates on). One search, made as the app makes it (the password, if any, in `SEARXNG_PASSWORD`):

```bash
.build/xcode/Build/Products/Release/voice-cli web-search --searxng https://search.example.org horaires piscine Pontoise
```

Short conversations, as the app has them: the dialogues of `Tests/Fixtures/dialogues-fr.json` (here, a request for a
moment already gone, then the user's new moment) are sent turn after turn, text only and with nothing created: each call
goes through the app's checks and second try, and is carried out on a calendar kept in memory that answers as the app
would. The model samples its answers, so each dialogue runs several times, and the report says what the model did at
each turn and how often the item the user wanted was saved:

```bash
.build/xcode/Build/Products/Release/voice-cli dialogue-bench --repeats 10
```

How much of each request the language model finds in its memory (its KV cache), in the sequences of requests the app
sends: plain turns, an action, two actions in one request, a refused call and its second try, a long result summed up
(as after a web search), a turn dropped after a second try, a speculative or interrupted answer, an answer in
paragraphs, a speculative answer abandoned after an answer cut off, the tools changing, the history shortened, a new
conversation. Text only, nothing is created; run it again after any change to `MLXChatModel`. With `VOICE_DEBUG=1`, it
also shows where each request stops matching that memory, and what differs:

```bash
.build/xcode/Build/Products/Release/voice-cli cache-check
```

Hand a task to Claude Code the way the app does, without the app or a language model (it uses the Claude Code
signed in on this Mac; `--check` only says whether it is installed and signed in):

```bash
.build/xcode/Build/Products/Release/voice-cli delegate --instruction "Crée un fichier bonjour.txt qui dit bonjour."
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
iPhone/                      the iPhone app (SwiftUI), generated from iPhone/project.yml; it shares the design
                             files of App/Sources/Design and the live transcript with the Mac app
Package.swift                the voice engine, as a Swift package:
Sources/VoiceCore/             conversation logic, end-of-turn detection, text clean-up for the voice,
                               hardware tiers, model catalog and downloader, extension point
Sources/VoiceEngineApple/      the Apple implementations: Silero, Parakeet and Pocket TTS (CoreML),
                               Gemma 4 (MLX), microphone and speakers (AVAudioEngine)
Sources/OpenMaeLink/           the link with the iPhone: keys, pairing, Noise, direct and relayed connections,
                               the voice's codec and jitter buffer (both apps use it)
Sources/VoiceCLI/              voice-cli
Tests/VoiceCoreTests/          unit tests of the core
Tests/OpenMaeLinkTests/        tests of the link (Noise test vectors, frames, jitter buffer, end to end)
Tests/Fixtures/                requests for the actions benchmark, Noise test vectors, recorded Claude Code
                               reports
relay/                       the OpenMaé relay (Go, Docker), its protocol and how to host one
scripts/                     build scripts, test phrases
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
