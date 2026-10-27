// voice-cli — measures the voice engine without any user interface, and manages its models.
//
//   voice-cli conversation [options] <phrase.wav>...    one turn per recording; latency of each stage
//   voice-cli interruption [options] <question.wav> <interruption.wav>
//                                                       talks over the assistant; time to silence it
//   voice-cli endurance --minutes N [--new-conversation-every N] [options] <phrase.wav>...
//                                                       loops a conversation; memory after every turn
//   voice-cli announce-drop [--repeats 5] [--on-mac] [--mute-first | --mute-station] [--chime-wait 0.3] [options]
//                                                       an announcement cut by a home station's drop, said again
//                                                       on the Mac (--on-mac: said on the Mac from the start); the
//                                                       pace of each utterance of the voice, when the chime rings
//                                                       and the gaps after it (see AnnounceDrop.swift)
//   voice-cli voice-onset [--voices a,b] [--temperatures 0.7,0.5] [--repeats 3] [--parallel 1] [--with-llm]
//                                                       silence the voice produces before speaking
//   voice-cli voice-gaps [--repeats 1] [options]        long answers to typed questions: the silence heard between
//                                                       two sentences (see VoiceGaps.swift)
//   voice-cli voice-pace [--repeats 5] [--with-llm [--model-writes n]] [--fingerprint]
//                                                       the voice alone, answer after answer: its time per frame by
//                                                       second (see VoicePace.swift)
//   voice-cli actions-bench [--now 2026-10-15T18:42] [--corpus file.json] [--web] [--searxng <address>] [--sources]
//                           [--news]
//                                                       does the model pick the right action, or search? (text
//                                                       only, nothing carried out; see ActionsBench.swift)
//   voice-cli dialogue-bench [--repeats 10] [--corpus file.json]
//                                                       the model in short conversations, turn after turn, as the
//                                                       app has them (text only; see DialogueBench.swift)
//   voice-cli cache-check [--scenario name] [--agents]  how much of each request the model finds in its memory,
//                                                       in the app's sequences of requests (text only; see
//                                                       CacheCheck.swift)
//   voice-cli read-sizes [--from 32] [--to 96] [--runs 5] [--compare-padding]
//                                                       how long the model takes to read a request's new tokens, by
//                                                       their number (text only; see ReadSizes.swift)
//   voice-cli memory-bench [--corpus Tests/Fixtures/memory-fr.json] [--out folder]
//                                                       how well the memory's journal finds past exchanges: recall@4
//                                                       and MRR per kind of query, speed and size on 20,000 exchanges
//                                                       (no model; see MemoryBench.swift)
//   voice-cli journal-bench [--repeats 3] [--corpus Tests/Fixtures/journal-fr.json] [--request "…"]… [--watch-calls]
//                                                       the journal switched on for the run: does the model search it
//                                                       when asked about a past conversation, find the exchange and
//                                                       use it? (text only; see JournalBench.swift)
//   voice-cli cut-off-bench [--repeats 10] [--cut-off ahead|after-user-words|marker|none]
//                           [--drop written|heard|cut-off|none|whole]
//                                                       answers cut off one after the other: does the model write
//                                                       the cut-off mark itself? Answers cut by a drop: does it
//                                                       shorten its own? (text only; see CutOffBench.swift)
//   voice-cli story-bench [--repeats 20] [--request "…"] [--actions] [--reread] [--speed]
//                                                       stories: does the model write words French spelling does
//                                                       not have (« constru-ée »)? With the chance of every token
//                                                       (text only; see StoryBench.swift)
//   voice-cli delegate --instruction "…"               hands a task to Claude Code as the app does (no model;
//                                                       see Delegate.swift)
//   voice-cli web-search --searxng <address> keywords…  one search as the app makes it (see WebSearch.swift)
//   voice-cli download | verify | catalog               the models (see ModelCommands.swift)
//   voice-cli link-client [--pair "<link>"] [--relay-only | --direct-only] <phrase.wav>...
//                                                       a fake iPhone: latency through the link (LinkClient.swift)
//   voice-cli inbound --relay <home relay> [--name Essai] [--seconds 600]
//   voice-cli inbound --public-relay <relay> [--acme <directory> [--acme-root <PEM>]] [--name Essai] [--seconds 600]
//                                                       received information through a home relay, printed instead
//                                                       of said (no model; see InboundListen.swift)
// Options:
//   --tier <name>            minimum, standard, comfort or max (default: this Mac's tier)
//   --llm <folder>           another language model folder (default: the tier's)
//   --tts gpu|cpu            where the voice runs (default gpu)
//   --no-speculative         disable speculative start (for comparison)
//   --silence-ms <n>         end-of-turn silence (default 500)
//   --history-budget <n>     history size in tokens before the oldest exchanges are dropped
//   --actions                the actions as in the app, the calendar and reminders kept in memory (nothing saved),
//                            the timers running in voice-cli (they ring nowhere)
//   --racing-voices <n>      voices starting each answer at once, the first audible one says it (default 1)
//   --no-voice-restart       never start the voice again after a long near-silent opening (the app does, after 1.2 s)
//   --voice-restart-after <s> seconds of near-silent opening before the voice starts again (default 1.2)
//   --no-sentence-restart    after an answer's first sound, never start a sentence said as near-silence again (the
//                            app does)
//   --sentence-restart-after <s> after an answer's first sound, start a sentence again once its opening has been
//                            near-silent this long (seconds of its audio; the app never does)
//   --no-voice-lead          after an answer's first sound, the language model never waits for the voice (the app
//                            has it wait while the voice opens a sentence with near-silence, or has under 0.5 s ready)
//   --voice-lead <s>         after an answer's first sound, the model waits while the voice has less than this ready
//                            ahead of the speakers (seconds; default 0.5)
//   --no-wait-openings       after an answer's first sound, the model no longer waits while the voice opens a sentence
//                            with near-silence (only for the lead)
//   --chime-wait <s>         seconds an announcement's chime waits at most for the voice's first sound (default 0.3;
//                            0: at once)
//   --slower-voice <f>       voice-gaps: as if the voice (and the model) were this fraction slower than speech (0.1:
//                            10 %): the simulated speaker plays the voice that much faster than real time
//   --wake-word              only sentences that start with « OK Maé » are answered, as in the app's wake-word mode
//   --follow-up <s>          with --wake-word: seconds Maé listens to any voice after an answer (default 8)
//   --no-partials            the user's words are not transcribed while they speak (the app shows them; for comparison)
//   --talk-key               conversation: the talk key is held while each phrase is said, released after it
//   --release-after <s>      with --talk-key: seconds between the end of the recording and the release (default 0.25)
//   --gaps <min>-<max>       conversation: seconds of silence between two turns, drawn in that range (the same at every
//                            run), as when the user asks for something now and then (default: 0.5 s)
//   --max-calls <n>          the most actions carried out in one request (default: the tier's, 3 or 1)
//   --barge-in mac|iphone    what it takes to interrupt Maé: the Mac's (default), or an iPhone's as the app has it while
//                            an iPhone has the conversation (BargeInProfile; VOICE_BARGE_IN_IPHONE_DB/_MS apply)
//   --out <folder>           where reports and audio go (default ./measurements)
//
// The recordings are played into the engine in real time, as a microphone would, and the assistant's
// voice is "played" in real time by a silent simulated speaker, so timings match the real app
// (minus the ~10–20 ms of the audio device itself).

import FluidAudio
import Foundation
import VoiceCore
import VoiceEngineApple

struct Options {
    var command = ""
    var tier: String?
    var all = false
    var llm: String?
    var ttsOnCPU = false
    var speculative = true
    var silenceMs = 500.0
    var minutes = 10.0
    var newConversationEvery: Int?
    var historyBudget: Int?
    var actions = false
    /// actions-bench: the actions left out, as the app has Claude Code, the web search or the sources on their own.
    var noActions = false
    var wakeWord = false
    var followUp: Double?
    /// The user's words are not transcribed while they speak (`PipelineConfig.partialTranscriptSeconds`).
    var noPartials = false
    /// conversation: the talk key held while each phrase is said (as ⌥ Space in the app), released this long after it.
    var talkKey = false
    var releaseAfter = 0.25
    /// conversation: seconds of silence between two turns, drawn in this range (the same draws at every run), as when
    /// the user asks for something now and then; none: half a second.
    var gaps: ClosedRange<Double>?
    /// What it takes to interrupt Maé (`PipelineConfig.bargeIn`).
    var bargeIn = BargeInProfile.mac
    var voices = ["estelle"]
    var temperatures: [Float] = [0.7]
    /// voice-onset: 3 by default; dialogue-bench: 10; journal-bench: 3; voice-gaps: 1 (each question once).
    var repeats: Int?
    /// voice-onset: voices speaking each sentence at once (the first audible one counts).
    var parallel = 1
    /// voice-onset: the language model loaded too, writing an answer while the voice opens, as in a turn.
    var withLLM = false
    /// voice-onset --with-llm: the voice's session made before the language model writes, as the pipeline does.
    var earlySession = false
    /// voice-pace --with-llm: the pieces the model writes at the start of each answer (none: it is only loaded).
    var modelWrites: Int?
    /// voice-pace: a fingerprint of the voice's samples with a fixed seed, to compare builds.
    var fingerprint = false
    /// announce-drop: the Mac's first utterance of the announcement taken for near-silence, so that the voice starts
    /// it again.
    var muteFirst = false
    /// announce-drop: the same for the station's first utterance of it, which then starts again after the drop.
    var muteStation = false
    /// announce-drop: no home station: the announcement is said on the Mac from the start.
    var onMac = false
    /// Seconds an announcement's chime waits at most for the voice's first sound (`chimeWaitsForVoiceSeconds`).
    var chimeWait: Double?
    /// Voices racing for each answer's first sound (`PipelineConfig.racingVoices`).
    var racingVoices: Int?
    /// The voice is never started again after a long near-silent opening (`PipelineConfig.voiceRestartAfterSeconds`).
    var noVoiceRestart = false
    /// Seconds of near-silent opening before the voice starts again (default: the app's).
    var voiceRestartAfter: Double?
    /// After the first sound, sentences are never started again (`PipelineConfig.sentenceRestarts`).
    var noSentenceRestart = false
    /// Seconds of near-silent opening of a later sentence before it starts again (`sentenceRestartAfterSeconds`).
    var sentenceRestartAfter: Double?
    /// After the first sound, the language model never waits for the voice (`PipelineConfig.voiceLeadSeconds` and
    /// `modelWaitsDuringOpenings`).
    var noVoiceLead = false
    /// The voice's lead below which the model waits (`PipelineConfig.voiceLeadSeconds`; default: the app's).
    var voiceLead: Double?
    /// The model no longer waits while the voice opens a sentence with near-silence (`modelWaitsDuringOpenings`).
    var noWaitOpenings = false
    /// voice-gaps: as if the voice and the model were this fraction slower than speech (`GapSynthesizer`).
    var slowerVoice: Double?
    /// voice-gaps: the first questions only.
    var questions: Int?
    var now: String?
    var corpus: String?
    var showPrompt = false
    var watchCalls = false
    /// The most calls the model writes, and the app carries out, in one request (default: the tier's,
    /// `ActionCatalog.actionsPerRequest`).
    var maxCalls: Int?
    var compareBeginnings = false
    /// actions-bench: each request's first token from the kept beginning in several ways, against a float32 reference.
    var compareRequests = false
    /// actions-bench, cache-check: the requests' new tokens and the history computed in bfloat16, as before they were
    /// computed in float32 (`MLXChatModel.computePromptsInFloat32`), for comparisons in one build.
    var bfloat16Prompts = false
    /// actions-bench, cache-check: a mixture-of-experts model's experts' products computed in bfloat16 as the requests and
    /// the history are computed in float32 (`MLXChatModel.computeExpertsInHalfPrecision`), for comparisons in one build.
    var bfloat16Experts = false
    /// cache-check, read-sizes: a mixture-of-experts model's experts never pad their rows, as before
    /// (`MLXChatModel.padExpertRows`), for comparisons in one build.
    var unpaddedExperts = false
    /// actions-bench, journal-bench, cache-check: Gemma 4 26B may write thought blocks of its own in its answers, as before
    /// it was kept from it (`MLXChatModel.allowOwnThoughts`), for comparisons in one build.
    var ownThoughts = false
    var addendum: String?
    /// actions-bench: the web search's part of the system prompt, read from this file.
    var webAddendum: String?
    /// actions-bench: the delegation's part of the system prompt, read from this file.
    var agentsAddendum: String?
    var examples: String?
    var web = false
    /// dialogue-bench: Claude Code's tools offered too (cache-check reads its own --agents).
    var agents = false
    /// actions-bench, dialogue-bench, cache-check: the memory's tool offered too (`memoire`), with the journal of past
    /// exchanges only as the app offers it (`MemorySettings.journalOffered`) or with --journal.
    var memory = false
    var journal = false
    var searxng: String?
    var searxngUser: String?
    var record: String?
    /// actions-bench: the built-in sources' tools offered with any corpus; their real services asked instead of the
    /// corpus's recorded answers; what they answered written to a file.
    var sources = false
    var liveSources = false
    var recordSources: String?
    /// actions-bench: the news' tool (lire_nouvelles) offered with any corpus; its part of the system prompt, read from
    /// this file.
    var news = false
    var newsAddendum: String?
    /// story-bench: these requests only, instead of the corpus's; journal-bench: only the corpus's requests that hold one
    /// of these texts.
    var requests: [String] = []
    /// story-bench: the model held this many seconds after each piece of an answer, as while the voice needs the GPU.
    var hold: Double?
    /// story-bench: each answer read again in one pass, in the model's own type and in float32, for comparison.
    var reread = false
    /// story-bench: the sampling's min-p instead of the app's (`MLXChatModel.sampleWithMinP`), for comparisons in one build.
    var minP: Float?
    /// story-bench: the tokens are not watched (it slows the writing), and each answer's time to its first word and
    /// writing speed are measured.
    var speed = false
    var out = URL(fileURLWithPath: "measurements")
    var files: [URL] = []

    static func parse(_ args: [String]) -> Options? {
        var o = Options()
        var it = args.dropFirst().makeIterator()
        guard let command = it.next() else { return nil }
        o.command = command
        while let a = it.next() {
            switch a {
            case "--tier": o.tier = it.next()
            case "--all": o.all = true
            case "--llm": o.llm = it.next()
            case "--tts": o.ttsOnCPU = it.next() == "cpu"
            case "--no-speculative": o.speculative = false
            case "--silence-ms": o.silenceMs = Double(it.next() ?? "") ?? o.silenceMs
            case "--minutes": o.minutes = Double(it.next() ?? "") ?? o.minutes
            case "--new-conversation-every": o.newConversationEvery = Int(it.next() ?? "")
            case "--history-budget": o.historyBudget = Int(it.next() ?? "")
            case "--actions": o.actions = true
            case "--no-actions": o.noActions = true
            case "--wake-word": o.wakeWord = true
            case "--follow-up": o.followUp = Double(it.next() ?? "")
            case "--no-partials": o.noPartials = true
            case "--talk-key": o.talkKey = true
            case "--release-after": o.releaseAfter = Double(it.next() ?? "") ?? o.releaseAfter
            case "--gaps":
                let bounds = (it.next() ?? "").split(separator: "-").compactMap { Double($0) }
                if bounds.count == 2, bounds[0] <= bounds[1] { o.gaps = bounds[0]...bounds[1] }
            case "--barge-in":
                switch it.next() {
                case "mac": o.bargeIn = .mac
                case "iphone": o.bargeIn = BargeInProfile.iPhone.adjusted(prefix: "VOICE_BARGE_IN_IPHONE")
                default: return nil
                }
            case "--out": o.out = URL(fileURLWithPath: it.next() ?? "measurements")
            case "--voices": o.voices = (it.next() ?? "").split(separator: ",").map(String.init)
            case "--temperatures": o.temperatures = (it.next() ?? "").split(separator: ",").compactMap { Float($0) }
            case "--repeats": o.repeats = Int(it.next() ?? "")
            case "--parallel": o.parallel = max(1, Int(it.next() ?? "") ?? 1)
            case "--with-llm": o.withLLM = true
            case "--early-session": o.earlySession = true
            case "--model-writes": o.modelWrites = Int(it.next() ?? "")
            case "--fingerprint": o.fingerprint = true
            case "--mute-first": o.muteFirst = true
            case "--mute-station": o.muteStation = true
            case "--on-mac": o.onMac = true
            case "--chime-wait": o.chimeWait = Double(it.next() ?? "")
            case "--racing-voices": o.racingVoices = Int(it.next() ?? "")
            case "--no-voice-restart": o.noVoiceRestart = true
            case "--voice-restart-after": o.voiceRestartAfter = Double(it.next() ?? "")
            case "--no-sentence-restart": o.noSentenceRestart = true
            case "--sentence-restart-after": o.sentenceRestartAfter = Double(it.next() ?? "")
            case "--no-voice-lead": o.noVoiceLead = true
            case "--voice-lead": o.voiceLead = Double(it.next() ?? "")
            case "--no-wait-openings": o.noWaitOpenings = true
            case "--slower-voice": o.slowerVoice = Double(it.next() ?? "")
            case "--questions": o.questions = Int(it.next() ?? "")
            case "--now": o.now = it.next()
            case "--corpus": o.corpus = it.next()
            case "--show-prompt": o.showPrompt = true
            case "--watch-calls": o.watchCalls = true
            case "--max-calls": o.maxCalls = Int(it.next() ?? "")
            case "--compare-beginnings": o.compareBeginnings = true
            case "--compare-requests": o.compareRequests = true
            case "--bfloat16-prompts": o.bfloat16Prompts = true
            case "--bfloat16-experts": o.bfloat16Experts = true
            case "--unpadded-experts": o.unpaddedExperts = true
            case "--own-thoughts": o.ownThoughts = true
            case "--addendum": o.addendum = it.next()
            case "--web-addendum": o.webAddendum = it.next()
            case "--agents-addendum": o.agentsAddendum = it.next()
            case "--examples": o.examples = it.next()
            case "--web": o.web = true
            case "--agents": o.agents = true
            case "--memory": o.memory = true
            case "--journal": o.journal = true
            case "--searxng": o.searxng = it.next()
            case "--searxng-user": o.searxngUser = it.next()
            case "--record": o.record = it.next()
            case "--sources": o.sources = true
            case "--news": o.news = true
            case "--news-addendum": o.newsAddendum = it.next()
            case "--live-sources": o.liveSources = true
            case "--record-sources": o.recordSources = it.next()
            case "--request": o.requests.append(it.next() ?? "")
            case "--hold": o.hold = Double(it.next() ?? "")
            case "--reread": o.reread = true
            case "--min-p": o.minP = Float(it.next() ?? "")
            case "--speed": o.speed = true
            default: o.files.append(URL(fileURLWithPath: a))
            }
        }
        return o
    }
}

/// Collects what the pipeline reports.
actor EventLog {
    var diagnostics: MLXChatModel?
    func attach(_ model: MLXChatModel) { diagnostics = model }
    var turns: [TurnMetrics] = []
    var bargeIns: [(stopMs: Double, detectionMs: Double)] = []
    var state = PipelineState.listening
    var failures: [String] = []
    /// The user's words shown while they spoke, in all.
    var partials = 0

    func record(_ event: PipelineEvent) async {
        switch event {
        case .state(let s):
            state = s
            if s == .speaking, let model = diagnostics {
                let p = await model.lastPrefill
                print("  · model: \(p.reused) tokens reused, \(p.computed) computed in \(fmt(p.ms))")
            }
        case .partialTranscript(let text):
            partials += 1
            print("  …  \(text)")
        case .userTranscript(let text, let language):
            print("  🗣  [\(language.rawValue)] \(text)")
        case .assistantPiece(let piece):
            print("  🔊 \(piece)")
        case .turnFinished(let m):
            turns.append(m)
            if m.interrupted {
                print("  ✋ interrupted after: “\(m.assistantText)”")
            } else {
                print("  ⏱  end of speech → first sound: \(fmt(m.latencyMs))"
                      + (m.firstConfirmationMs.map { " · → first action's sentence: \(fmt($0))" } ?? "")
                      + (m.tool.map { " (\($0))" } ?? "")
                      + "  [silence \(fmt(m.endOfTurnMs)) · transcription \(fmt(m.transcriptionMs))"
                      + " · first word \(fmt(m.firstTokenMs)) · first piece \(fmt(m.firstPieceMs))"
                      + " · voice \(fmt(m.synthesisFirstAudioMs))]"
                      + (m.speculative ? " (prepared speculatively)" : "")
                      + String(format: " · memory %.2f GB", ProcessMemory.footprintGB))
            }
        case .bargeIn(let stopMs, let detectionMs):
            bargeIns.append((stopMs, detectionMs))
            print("  ✋ interruption: voice cut \(fmt(stopMs)) after the start of speech"
                  + " (detection: \(fmt(detectionMs)))")
        case .awake(let awake):
            print(awake ? "  👂 awake: any voice starts a turn" : "  💤 asleep: waiting for the wake phrase")
        case .wakeDecision(let decision):
            print("  🔎 \(decision.moment.rawValue), \(decision.accepted ? "for Maé" : "ignored"): \(decision.heard)")
        case .conversationCleared:
            print("  🆕 new conversation")
        case .failure(let message):
            failures.append(message)
            print("  ⚠️  \(message)")
        }
    }

    var completedTurns: Int { turns.filter { !$0.interrupted }.count }
}

func fmt(_ ms: Double?) -> String { ms.map { String(format: "%.0f ms", $0) } ?? "—" }

func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let s = values.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

// MARK: - Engine

struct Engine {
    let pipeline: VoicePipeline
    let speaker: SimulatedSpeaker
    let log: EventLog
    let model: MLXChatModel
}

/// `voice`: what the pipeline gets of the voice (announce-drop and voice-gaps measure it); `logPlays`: the speaker keeps
/// what it plays, and when (voice-gaps, announce-drop).
func buildEngine(_ o: Options, logPlays: Bool = false,
                 voice: (PocketSpeechSynthesizer) -> any SpeechSynthesizer = { $0 }) async throws -> Engine
{
    let hw = HardwareProfile.current
    let tier = try tierOption(o)
    print("Mac: \(hw.chipName), \(Int(hw.memoryGiB.rounded())) GB → tier “\(tier.rawValue)”"
          + (tier.isTested ? "" : " (UNTESTED)"))
    let store = ModelStore()
    let packs = ModelCatalog.packs(for: tier).filter { o.llm == nil || $0.role != .languageModel }
    guard let languageModel = ModelCatalog.languageModel(for: tier), store.isComplete(packs) else {
        throw CLIError("models missing or incomplete: run “voice-cli download"
                       + (o.tier.map { " --tier \($0)" } ?? "") + "” first")
    }
    let llmURL = o.llm.map { URL(fileURLWithPath: $0) } ?? store.folder(languageModel)
    guard let vadURL = ModelLocator.voiceActivity() else { throw CLIError("silero_vad.mlmodelc not found") }

    let clock = ContinuousClock()
    var t = clock.now
    let detector = try SileroSpeechDetector(modelURL: vadURL)
    let transcriber = try await ParakeetTranscriber.load(directory: store.folder(ModelCatalog.speechRecognition))
    print("loaded: voice detection + transcription in \(clock.now - t)")
    t = clock.now
    let model = try await MLXChatModel.load(directory: llmURL)
    print("loaded: \(llmURL.lastPathComponent) in \(clock.now - t)")
    // In the app's order (`AssistantHost.start`): the conversations' beginning, then the voice.
    let synthesizer = PocketSpeechSynthesizer(
        computeUnits: o.ttsOnCPU ? .uniform(.cpuOnly) : .avoidNeuralEngine, store: store)

    var config = PipelineConfig()
    config.speculativeStart = o.speculative
    config.turn.endOfTurnSilenceMs = o.silenceMs
    if let budget = o.historyBudget {
        config.historyTokenBudget = budget
        config.historyTrimTarget = budget * 2 / 3
    }
    config.actionExamples = ActionCatalog.showsExamples(on: tier)
    config.cutOffPlacement = Conversation.cutOffPlacement(on: tier)
    config.actionsPerRequest = o.maxCalls ?? ActionCatalog.actionsPerRequest(on: tier)
    if let voices = o.racingVoices { config.racingVoices = max(1, voices) }
    if let seconds = o.voiceRestartAfter { config.voiceRestartAfterSeconds = seconds }
    if o.noVoiceRestart { config.voiceRestartAfterSeconds = nil }
    if let seconds = o.sentenceRestartAfter { config.sentenceRestartAfterSeconds = seconds }
    if o.noSentenceRestart { config.sentenceRestarts = 0 }
    if let seconds = o.voiceLead { config.voiceLeadSeconds = seconds }
    if o.noWaitOpenings { config.modelWaitsDuringOpenings = false }
    if o.noVoiceLead {
        config.voiceLeadSeconds = nil
        config.modelWaitsDuringOpenings = false
    }
    if let seconds = o.chimeWait { config.chimeWaitsForVoiceSeconds = seconds }
    if o.wakeWord { config.listening = .wakeWord }
    if let followUp = o.followUp { config.wakeFollowUpSeconds = followUp }
    if o.noPartials { config.partialTranscriptSeconds = nil }
    config.bargeIn = o.bargeIn
    print("barge-in: \(o.bargeIn.summary) to interrupt Maé")
    let speaker = SimulatedSpeaker(logsPlays: logPlays)
    let pipeline = VoicePipeline(detector: detector, transcriber: transcriber, model: model,
                                 synthesizer: voice(synthesizer), output: speaker,
                                 tools: o.actions
                                     ? ToolRunner(providers: [MemoryCalendar(movingItems: ActionCatalog.movesItems(on: tier)),
                                                              TimerTools()])
                                     : nil,
                                 config: config)
    let log = EventLog()
    await log.attach(model)
    Task { for await event in pipeline.events { await log.record(event) } }
    t = clock.now
    try await pipeline.start()
    print("computed: the conversations' beginning in \(clock.now - t)")
    t = clock.now
    try await synthesizer.preload([.french, .english])
    print("loaded: voice (\(o.ttsOnCPU ? "CPU" : "GPU")) in \(clock.now - t)")
    model.wakeUp()  // what loading the voice pushed out of memory comes back, as in the app
    print(String(format: "memory after loading: %.2f GB", ProcessMemory.footprintGB))
    print("ready: \(secondsSinceLaunch().map { String(format: "%.2f s", $0) } ?? "—") after launch\n")
    return Engine(pipeline: pipeline, speaker: speaker, log: log, model: model)
}

/// How long ago the kernel started this process: the launch, as `buildEngine`'s "ready" line counts from it.
func secondsSinceLaunch() -> Double? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var request: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&request, UInt32(request.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let start = info.kp_proc.p_starttime
    return Date().timeIntervalSince1970 - (Double(start.tv_sec) + Double(start.tv_usec) / 1e6)
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Exits once every language model this process loaded computes nothing (`MLXChatModel.windDownAll`): at exit, MLX's
/// objects for the whole process are destroyed, and a model still computing then crashed voice-cli, as the history it
/// computes ahead after a `conversation`'s last answer did.
func exitOnceIdle(_ status: Int32) async -> Never {
    await MLXChatModel.windDownAll()
    exit(status)
}

// MARK: - Commands

func waitForAnswer(_ e: Engine, mic: SimulatedMicrophone, after count: Int, timeout: Double = 60) async {
    await mic.silence(until: {
        let done = await e.log.completedTurns > count
        let idle = await e.log.state == .listening
        return done && idle
    }, timeout: timeout)
}

func runConversation(_ o: Options, _ e: Engine) async throws {
    let mic = SimulatedMicrophone(pipeline: e.pipeline)
    try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
    var draws = SplitMix64(seed: 131)
    for (i, file) in o.files.enumerated() {
        if i > 0, let gaps = o.gaps {
            let gap = gaps.lowerBound + (gaps.upperBound - gaps.lowerBound) * Double(draws.next() >> 11) / Double(1 << 53)
            print(String(format: "  … %.0f s of silence", gap))
            await mic.silence(gap)
        }
        print("■ turn \(i + 1) — \(file.lastPathComponent)")
        let before = await e.log.completedTurns
        if o.talkKey {
            await e.pipeline.setTalkKey(pressed: true)
            await mic.say(try WAV.read16kMono(file))
            await mic.silence(o.releaseAfter)
            await e.pipeline.setTalkKey(pressed: false)
        } else {
            await mic.say(try WAV.read16kMono(file))
        }
        // With the wake word, a sentence without the phrase gets no answer: no need to wait a minute for one.
        await waitForAnswer(e, mic: mic, after: before, timeout: o.wakeWord ? 20 : 60)
        if await e.log.completedTurns == before { print("  (no answer)") }
        await mic.silence(0.5)
        let audio = await e.speaker.takeRecording()
        try WAV.write(audio, sampleRate: await e.speaker.sampleRate,
                      to: o.out.appendingPathComponent("answer-\(i + 1).wav"))
    }
    let turns = await e.log.turns.filter { !$0.interrupted }
    let latencies = turns.compactMap(\.latencyMs)
    print("\n=== Summary: \(turns.count) turns ===")
    print("end of speech → first sound: median \(fmt(median(latencies)))"
          + "  min \(fmt(latencies.min()))  max \(fmt(latencies.max()))")
    let confirmations = turns.compactMap(\.firstConfirmationMs)
    if !confirmations.isEmpty {
        print("end of speech → first action's sentence: median \(fmt(median(confirmations)))"
              + "  min \(fmt(confirmations.min()))  max \(fmt(confirmations.max()))")
    }
    for (label, values) in [("waiting for silence", turns.compactMap(\.endOfTurnMs)),
                            ("transcription", turns.compactMap(\.transcriptionMs)),
                            ("model's first word", turns.compactMap(\.firstTokenMs)),
                            ("first piece of text", turns.compactMap(\.firstPieceMs)),
                            ("voice's first sound", turns.compactMap(\.synthesisFirstAudioMs))]
    {
        print("  \(label): median \(fmt(median(values)))")
    }
    print("the user's words shown while they spoke: \(await e.log.partials)")
    print(String(format: "memory: %.2f GB · cache rebuilds: %d · back to a snapshot: %d",
                 ProcessMemory.footprintGB, await e.model.cacheRebuilds, await e.model.snapshotRestores))
    try save(turns, name: "conversation", options: o)
}

/// Pseudo-random numbers from a seed, the same at every run (`--gaps`).
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func runInterruption(_ o: Options, _ e: Engine) async throws {
    guard o.files.count == 2 else { throw CLIError("interruption expects 2 files: question, interruption") }
    let mic = SimulatedMicrophone(pipeline: e.pipeline)
    let question = try WAV.read16kMono(o.files[0])
    let interruption = try WAV.read16kMono(o.files[1])
    for round in 1...3 {
        print("■ attempt \(round)")
        let before = await e.log.completedTurns
        await mic.say(question)
        await mic.silence(until: { await e.log.state == .speaking }, timeout: 30)
        await mic.silence(1.5)  // let the assistant talk for a moment
        await mic.say(interruption)
        await waitForAnswer(e, mic: mic, after: before, timeout: o.wakeWord ? 20 : 60)  // « OK Maé, stop »: no answer
        await mic.silence(0.5)
        _ = await e.speaker.takeRecording()
    }
    let stops = await e.log.bargeIns.map(\.stopMs)
    print("\n=== Summary: \(stops.count) interruptions ===")
    print("voice cut after the start of speech: median \(fmt(median(stops)))  max \(fmt(stops.max()))")
    try save(await e.log.turns, name: "interruption", options: o)
}

func runEndurance(_ o: Options, _ e: Engine) async throws {
    let mic = SimulatedMicrophone(pipeline: e.pipeline)
    let phrases = try o.files.map(WAV.read16kMono)
    let clock = ContinuousClock()
    let end = clock.now + .seconds(o.minutes * 60)
    var samples: [(minute: Double, gb: Double, gpuGB: Double)] = []
    var newConversations: [Double] = []
    let start = clock.now
    var i = 0
    print("turn;minute;memory_GB;GPU_GB;latency_ms")
    while clock.now < end {
        if let every = o.newConversationEvery, i > 0, i % every == 0 {
            // As "Nouvelle conversation" in the app; the next answer would wait for it.
            let reset = clock.now
            try await e.pipeline.resetConversation()
            let d = clock.now - reset
            newConversations.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
            print("new conversation;\(fmt(newConversations.last))")
        }
        let before = await e.log.completedTurns
        await mic.say(phrases[i % phrases.count])
        await waitForAnswer(e, mic: mic, after: before)
        await mic.silence(0.5)
        _ = await e.speaker.takeRecording()
        let minute = Double((clock.now - start).components.seconds) / 60
        let gb = ProcessMemory.footprintGB
        let gpuGB = MLXChatModel.activeMemoryGB
        samples.append((minute, gb, gpuGB))
        print(String(format: "%d;%.1f;%.3f;%.3f;%@", i + 1, minute, gb, gpuGB, fmt(await e.log.turns.last?.latencyMs)))
        i += 1
    }
    if let first = samples.first, let last = samples.last {
        print(String(format: "\n=== %d turns in %.0f min · memory %.2f → %.2f GB · GPU memory in use %.2f → %.2f GB"
                     + " (max %.2f) ===", samples.count, last.minute, first.gb, last.gb, first.gpuGB, last.gpuGB,
                     samples.map(\.gpuGB).max() ?? 0))
    }
    if !newConversations.isEmpty {
        print("new conversations: \(newConversations.count), median \(fmt(median(newConversations)))"
              + ", max \(fmt(newConversations.max()))")
    }
    try save(await e.log.turns, name: "endurance", options: o)
}

func save(_ turns: [TurnMetrics], name: String, options: Options) throws {
    try FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let url = options.out.appendingPathComponent("\(name)-\(stamp).json")
    try encoder.encode(turns).write(to: url)
    print("report: \(url.path)")
}

/// Pocket TTS often opens with near-silence before the first word (seen in the app: up to 2 s). This
/// measures it per voice and temperature, on typical first sentences, without the language model (`--with-llm`: with it
/// writing an answer meanwhile).
func runVoiceOnset(_ o: Options) async throws {
    // First sentences of answers, as Gemma 4 26B writes them in `voice-cli conversation`.
    let sentences = [
        "Le ciel est bleu à cause de la lumière.", "Bonjour, je vais t'aider avec plaisir.",
        "Tu pourrais faire une randonnée en forêt.", "Oui, ça marche parfaitement sans four.",
        "Tu voulais cuisiner des courgettes ce soir.", "Salut, je peux t'aider avec plaisir.",
        "C'est une question vraiment fascinante.", "Tu voulais cuisiner des courgettes.",
        "Oui, ça fonctionne très bien sans four.", "Tu veux cuisiner des courgettes.",
    ]
    // Only "estelle" is downloaded with the app: other voices are fetched by FluidAudio into its own cache.
    let directory = o.voices == ["estelle"] ? ModelStore().voiceBaseFolder : nil
    let manager = PocketTtsManager(defaultVoice: o.voices[0], language: .french24L, directory: directory,
                                   computeUnits: o.ttsOnCPU ? .uniform(.cpuOnly) : .avoidNeuralEngine)
    try await manager.initialize()
    var llm: MLXChatModel?
    if o.withLLM {
        guard let languageModel = ModelCatalog.languageModel(for: try tierOption(o)) else {
            throw CLIError("no language model for this tier")
        }
        let url = o.llm.map { URL(fileURLWithPath: $0) } ?? ModelStore().folder(languageModel)
        llm = try await MLXChatModel.load(directory: url)
        print("loaded: \(url.lastPathComponent)")
    }
    let clock = ContinuousClock()
    print("voice;temperature;leading_silence_median_ms;leading_silence_p90_ms;leading_silence_max_ms;"
          + "first_audible_median_ms;first_audible_p90_ms;first_audible_max_ms;within_600_ms;mute")
    for voice in o.voices {
        _ = try await speak("Bonjour.", manager: manager, voice: voice, temperature: 0.7, clock: clock)  // load + warm up
        for temperature in o.temperatures {
            var silences: [Double] = []
            var firstAudible: [Double] = []
            var mute = 0
            for _ in 0..<(o.repeats ?? 3) {
                for sentence in sentences {
                    let early = !o.earlySession ? nil
                        : try await manager.makeSession(voice: voice, temperature: temperature)
                    let writing = if let llm { await writeFirstSentence(llm) } else { Task<Void, Never> {} }
                    let all = try await withThrowingTaskGroup(of: (leadingMs: Double, firstAudibleMs: Double?).self) {
                        group in
                        for runner in 0..<o.parallel {
                            group.addTask {
                                try await speak(sentence, manager: manager, voice: voice, temperature: temperature,
                                                clock: clock, session: runner == 0 ? early : nil)
                            }
                        }
                        var all: [(leadingMs: Double, firstAudibleMs: Double?)] = []
                        for try await r in group { all.append(r) }
                        return all
                    }
                    llm?.holdGeneration(false)
                    writing.cancel()
                    await writing.value
                    // Several voices at once: the first audible one counts.
                    let r = all.min { ($0.firstAudibleMs ?? .infinity) < ($1.firstAudibleMs ?? .infinity) }!
                    silences.append(r.leadingMs)
                    if let audible = r.firstAudibleMs { firstAudible.append(audible) } else { mute += 1 }
                    let each = all.map { "\(fmt($0.firstAudibleMs)) after \(fmt($0.leadingMs))" }
                    let others = all.count > 1 ? " [" + each.joined(separator: ", ") + "]" : ""
                    print("  \(fmt(r.firstAudibleMs)) (near-silence \(fmt(r.leadingMs)))\(others): \(sentence)")
                }
            }
            print(String(format: "  memory: %.2f GB", ProcessMemory.footprintGB))
            let within = firstAudible.filter { $0 <= 600 }.count
            print("\(voice);\(temperature);\(fmt(median(silences)));\(fmt(percentile(silences, 0.9)));"
                  + "\(fmt(silences.max()));\(fmt(median(firstAudible)));\(fmt(percentile(firstAudible, 0.9)));"
                  + "\(fmt(firstAudible.max()));\(within)/\(silences.count);\(mute)")
        }
    }
}

/// `voice-onset --with-llm`: the language model writes a long answer and pauses once its first sentence is written, as
/// in a turn while the voice opens (`YieldsToVoice`: 1.5 s at most). Returns the task writing, once paused.
func writeFirstSentence(_ model: MLXChatModel) async -> Task<Void, Never> {
    let (paused, signal) = AsyncStream.makeStream(of: Void.self)
    let task = Task {
        var text = ""
        var paused = false
        do {
            let request = [ChatMessage(.user, "Raconte-moi une longue histoire de pirates.")]
            for try await output in model.reply(to: request) {
                guard case .text(let piece) = output, !paused else { continue }
                text += piece
                if text.contains(". ") || text.contains("! ") {
                    paused = true
                    model.holdGeneration(true)
                    signal.yield()
                }
            }
        } catch {}
        signal.finish()
    }
    for await _ in paused { break }
    return task
}

/// The value below which `fraction` of the values lie (nearest rank).
func percentile(_ values: [Double], _ fraction: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let s = values.sorted()
    return s[min(s.count - 1, max(0, Int((fraction * Double(s.count)).rounded(.up)) - 1))]
}

/// Speaks `text` until its first audible frame (then stops): the near-silence before it, and the time it took.
func speak(_ text: String, manager: PocketTtsManager, voice: String, temperature: Float, clock: ContinuousClock,
           session ready: PocketTtsSession? = nil) async throws -> (leadingMs: Double, firstAudibleMs: Double?)
{
    let start = clock.now
    let session = if let ready { ready } else { try await manager.makeSession(voice: voice, temperature: temperature) }
    session.enqueue(text)
    session.finish()
    var leading = 0
    var firstAudible: Double?
    for try await frame in session.frames {
        let meanSquare = frame.samples.reduce(0) { $0 + $1 * $1 } / Float(max(frame.samples.count, 1))
        if 10 * log10(max(meanSquare, 1e-12)) < -45 {
            leading += frame.samples.count
        } else {
            let d = clock.now - start
            firstAudible = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            break
        }
    }
    await session.cancel()
    return (Double(leading) / 24, firstAudible)
}

// MARK: - Entry point

setvbuf(stdout, nil, _IOLBF, 0)  // one line at a time, even into a file: a crash keeps the lines printed before it

if let options = Options.parse(CommandLine.arguments),
   ["voice-onset", "voice-pace", "download", "verify", "catalog", "actions-bench", "dialogue-bench", "cache-check",
    "cut-off-bench", "story-bench", "read-sizes", "memory-bench", "journal-bench", "link-client", "delegate",
    "web-search", "inbound"].contains(options.command)
{
    do {
        switch options.command {
        case "download": try await runDownload(options)
        case "verify": try runVerify(options)
        case "catalog": try await runCatalog(options)
        case "actions-bench": try await runActionsBench(options)
        case "dialogue-bench": try await runDialogueBench(options)
        case "cache-check": try await runCacheCheck(options, arguments: CommandLine.arguments)
        case "cut-off-bench": try await runCutOffBench(options, arguments: CommandLine.arguments)
        case "story-bench": try await runStoryBench(options)
        case "read-sizes": try await runReadSizes(options, arguments: CommandLine.arguments)
        case "memory-bench": try await runMemoryBench(options)
        case "journal-bench": try await runJournalBench(options)
        case "link-client": try await runLinkClient()
        case "delegate": try await runDelegate(CommandLine.arguments)
        case "web-search": try await runWebSearch(CommandLine.arguments)
        case "inbound": try await runInbound(CommandLine.arguments)
        case "voice-pace": try await runVoicePace(options)
        default: try await runVoiceOnset(options)
        }
    } catch {
        print("\nERROR: \(error)")
        await exitOnceIdle(1)
    }
    await exitOnceIdle(0)
}
if let options = Options.parse(CommandLine.arguments), options.command == "voice-gaps" {
    do {
        let voice = GapVoice()
        let engine = try await buildEngine(options, logPlays: true) { voice.wrap($0, slower: options.slowerVoice ?? 0) }
        try await runVoiceGaps(options, engine, voice: voice)
    } catch {
        print("ERROR: \(error)")
        await exitOnceIdle(1)
    }
    await exitOnceIdle(0)
}
if let options = Options.parse(CommandLine.arguments), options.command == "announce-drop" {
    do {
        var measuring: MeasuringSynthesizer?
        let engine = try await buildEngine(options, logPlays: true) { voice in
            let wrapped = MeasuringSynthesizer(voice)
            measuring = wrapped
            return wrapped
        }
        try await runAnnounceDrop(options, engine, voice: measuring!)
    } catch {
        print("ERROR: \(error)")
        await exitOnceIdle(1)
    }
    await exitOnceIdle(0)
}
guard let options = Options.parse(CommandLine.arguments), !options.files.isEmpty else {
    print("""
        usage: voice-cli conversation|interruption|endurance [--tier tier] [--llm folder] [--tts gpu|cpu] [--actions]
                         [--no-speculative] [--silence-ms 500] [--minutes 10] [--new-conversation-every n]
                         [--barge-in mac|iphone] [--out folder] files.wav…
               voice-cli download [--tier minimum|standard|comfort|max]
               voice-cli verify [--tier tier | --all]
               voice-cli voice-onset [--voices a,b] [--temperatures 0.7,0.5] [--repeats 3] [--parallel 1]
                                     [--with-llm]
               voice-cli voice-pace [--tier tier] [--repeats 5] [--with-llm [--model-writes n]] [--tts gpu|cpu]
                                    [--fingerprint]
               voice-cli announce-drop [--tier tier] [--repeats 5] [--on-mac] [--mute-first | --mute-station]
                                       [--voice-restart-after s] [--chime-wait s]
               voice-cli voice-gaps [--tier tier] [--repeats 1] [--questions n] [--no-sentence-restart]
                                    [--sentence-restart-after s] [--no-voice-lead] [--voice-lead s]
                                    [--no-wait-openings] [--slower-voice f] [--out folder]
               voice-cli actions-bench [--tier tier] [--llm folder] [--now 2026-10-15T18:42] [--corpus file.json]
                                       [--web] [--searxng <address> [--searxng-user name]] [--record file.json]
                                       [--no-actions] [--addendum file] [--web-addendum file]
                                       [--agents-addendum file] [--sources] [--live-sources]
                                       [--record-sources file.json] [--news] [--news-addendum file]
                                       [--compare-beginnings] [--compare-requests] [--bfloat16-prompts] [--bfloat16-experts]
               voice-cli dialogue-bench [--tier tier] [--llm folder] [--now 2026-10-15T18:42] [--corpus file.json]
                                        [--repeats 10] [--agents] [--web] [--examples app|none|file] [--addendum file]
                                        [--watch-calls]
               voice-cli cache-check [--tier tier] [--llm folder] [--scenario name] [--agents]
                                     [--cut-off ahead|after-user-words] [--bfloat16-prompts] [--bfloat16-experts]
                                     [--unpadded-experts]
               voice-cli read-sizes [--tier tier] [--llm folder] [--from 32] [--to 96] [--runs 5] [--compare-padding]
                                    [--unpadded-experts]
               voice-cli cut-off-bench [--tier tier] [--llm folder] [--corpus file.json] [--repeats 10] [--actions]
                                       [--cut-off ahead|after-user-words|marker|none] [--note "(…)"]
                                       [--note-role system|user] [--drop written|heard|cut-off|none|whole]
                                       [--dialogue name]
               voice-cli story-bench [--tier tier] [--llm folder] [--corpus file.json] [--request "…"]… [--repeats 20]
                                     [--actions] [--agents] [--web] [--sources] [--news] [--memory] [--hold s]
                                     [--reread] [--min-p 0.05] [--bfloat16-prompts] [--speed]
               voice-cli web-search --searxng <address> [--searxng-user name] [--language fr|en] keywords…
               voice-cli link-client [--pair "<link>"] [--relay-only | --direct-only] [--out folder] files.wav…
               voice-cli delegate --check | --instruction "…" [--title "…"] [--folder dir] [--mode acceptEdits|auto]
                                  [--follow-up "…"] [--stop-after seconds]
               voice-cli inbound --relay <home relay> [--name Essai] [--seconds 600]
               voice-cli inbound --public-relay <relay> [--acme <directory> [--acme-root <PEM>]] [--name Essai] [--seconds 600]
        """)
    exit(2)
}
do {
    let engine = try await buildEngine(options)
    switch options.command {
    case "conversation": try await runConversation(options, engine)
    case "interruption": try await runInterruption(options, engine)
    case "endurance": try await runEndurance(options, engine)
    default: throw CLIError("unknown command: \(options.command)")
    }
} catch {
    print("ERROR: \(error)")
    await exitOnceIdle(1)
}
await exitOnceIdle(0)
