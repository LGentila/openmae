import Foundation

public struct PipelineConfig: Sendable {
    public var turn = TurnDetectorConfig()
    /// Prepare the answer during short pauses (transcription + first words), and only *play* it once
    /// the turn is really over. Saves ~0.3 s; work is thrown away if the user resumes speaking.
    public var speculativeStart = true
    /// Audio kept from just before speech is detected, so the first syllable is not cut off.
    public var preRollMs: Double = 320
    /// When the history exceeds this many tokens, the oldest exchanges are dropped down to the target.
    /// Keeping a long history is cheap (Gemma 4 26B: ~20 KB per token, ~300 MB for an hour of talk);
    /// shortening it is expensive (everything after the cut must be recomputed), so it is rare and
    /// done in the background.
    public var historyTokenBudget = 12_000
    public var historyTrimTarget = 8_000
    /// Push-to-talk: the turn ends when the talk key is released instead of on silence. Wake word: only sentences that
    /// start with the phrase count, except for a few seconds after each answer.
    public var listening = ListeningMode.handsFree
    /// Wake-word mode: how long Maé listens to any voice after the phrase alone, and after each answer.
    public var wakeFollowUpSeconds: Double = 8
    /// Wake-word mode: a sentence not meant for Maé longer than this without a pause (the TV, music) is no longer
    /// kept; what is said after its next pause is checked on its own.
    public var maxUncheckedSpeechSeconds: Double = 20
    /// Wake-word mode: what was said up to a pause, shorter than this (pre-roll and pause included), is no verdict on
    /// the start of the sentence: speech recognition, without the rest, often mishears the phrase ("Cookie May" for
    /// « OK Maé »). The sentence is checked again whole, with what follows.
    public var wakeVerdictMinSeconds: Double = 2
    /// The voice often starts an answer with up to 0.7 s of near-silence (measured on Pocket TTS):
    /// audio quieter than this (dB) is skipped until the first audible sound, so the answer starts
    /// sooner and the latency measures what the user actually hears. nil = keep everything.
    public var leadingSilenceThresholdDB: Float? = -45
    /// The voice's opening of an answer still near-silent after this long (seconds of its audio: 1.2 s takes it 0.6 to
    /// 0.9 s on the reference Mac) starts again in a new utterance, which draws its breath again (see
    /// `VoiceRestart`), at most `voiceRestarts` times. nil = never. Needs `leadingSilenceThresholdDB`.
    public var voiceRestartAfterSeconds: Double? = 1.2
    public var voiceRestarts = 2
    /// After the answer's first sound, a sentence said as near-silence starts again in a new utterance, from that
    /// sentence on (see `VoiceRestart`), at most this many times per sentence: otherwise it was never heard. 0 = never.
    /// Needs `leadingSilenceThresholdDB`, and a single voice (`racingVoices`).
    public var sentenceRestarts = 2
    /// After the answer's first sound, a sentence whose opening is still near-silent after this long (seconds of its
    /// audio) starts again the same way. nil (the default) = never: it does not shorten the silences heard between
    /// sentences. Measured with `voice-cli voice-gaps` on the reference Mac (30 answers of four or five sentences, Gemma 4
    /// 26B; the silence heard before each sentence after the first): without it, 2 of 120 silences of 1 s or more (the
    /// longest 1.28 s); after 0.8 s, 6 of 112 (1.70 s); after 1.2 s, 3 of 117 (1.74 s); after 1.6 s, 3 of 120 (3.55 s).
    /// A long opening belongs mostly to its text: started again, a sentence opened as long again in 50 %, 29 % and 2 of
    /// 3 cases (2 to 14 % of all sentences open that long), and starting again costs about 0.2 s more.
    public var sentenceRestartAfterSeconds: Double?
    /// After the answer's first sound, the language model waits (`YieldsToVoice`) while the speakers have less than this
    /// left to play of the voice (seconds), as long as the voice has another text after the one it says (see
    /// `VoiceLead`); while it should wait, its pause is said again at every chunk of the voice. nil = never. Measured
    /// with `voice-cli voice-gaps` on the reference Mac (30 answers of four or five sentences a run, Gemma 4 26B), with
    /// `modelWaitsDuringOpenings`, against the model never waiting, while the Mac was quiet: silences of 1 s or more
    /// before a later sentence 4 of 236 instead of 8 of 223, 90th percentile 240 ms instead of 397 ms; the speakers had
    /// 0.49 s left at the first boundary instead of 0.31 s (median), and no opening under 2.5 s of near-silence was
    /// heard as a silence of 1 s or more any more. Longer openings (1.3 % of later sentences) still are: the voice needs
    /// about 56 ms a frame later in an answer, model waiting or not. With a voice 10 % slower (`--slower-voice 0.1`): 8 of
    /// 240 instead of 12 of 240.
    public var voiceLeadSeconds: Double? = 0.5
    /// After the answer's first sound, the language model also waits while the voice opens a sentence with near-silence.
    public var modelWaitsDuringOpenings = true
    /// Voices that start each answer at once, each with its own random draws: the first one to be audible says the
    /// answer, the others stop (see `VoiceRace`). With two, on the reference Mac (`voice-cli voice-onset`, typical
    /// first sentences): first sound 208 ms instead of 372 ms in the median, 537 ms instead of 855 ms for the slowest
    /// tenth, 1.0 s instead of 2.2 s at worst; but the voice then takes 1.2 GB more memory (2.3 GB instead of 1.1 GB),
    /// which is why it is off. 1 = a single voice (then `voiceRestartAfterSeconds` applies). Needs
    /// `leadingSilenceThresholdDB`.
    public var racingVoices = 1
    /// Pauses of the voice longer than this (between sentences, each one starting with near-silence)
    /// are shortened to it. nil = keep them.
    public var maxVoicePauseMs: Double? = 300
    /// What it takes for a voice heard while Maé talks to interrupt her rather than be taken for her echo, on the device
    /// that has the conversation (`BargeInProfile`): the Mac's at first; `VoicePipeline.setBargeIn` changes it while
    /// another device has the conversation (an iPhone).
    public var bargeIn = BargeInProfile.mac
    /// While nobody speaks, the models are used briefly every this many seconds so that macOS keeps
    /// them in memory (see `KeepsWarm`). 0 = never.
    public var keepWarmSeconds: Double = 30
    /// While the model writes a tool call (no voice until it is complete: about 1.5 s with Gemma 4 26B on the
    /// reference Mac), say "Un instant, je m'en occupe tout de suite." so the user is not left in silence; or the
    /// tool's own phrase ("Je regarde ça sur internet, un instant."), once its name is read.
    public var toolCallFiller = true
    /// With actions on, every conversation starts with `ActionCatalog.examples` (see `ActionCatalog.showsExamples`).
    public var actionExamples = false
    /// Where the history tells the model that an answer was cut off: a setting of the tier
    /// (`Conversation.cutOffPlacement(on:)`).
    public var cutOffPlacement = Conversation.CutOffPlacement.ahead
    /// While the user speaks to Maé, what they said so far is transcribed again with the same speech recognition, once
    /// this much of their audio (seconds) has come after the previous pass ended, so that their words show as they speak
    /// (`PipelineEvent.partialTranscript`). It reads a 3–5 s phrase in 0.1–0.15 s on the reference Mac. nil = never.
    public var partialTranscriptSeconds: Double? = 0.5
    /// The first pass waits for this much of the utterance: speech recognition pads anything shorter with silence.
    public var partialTranscriptMinSeconds: Double = 1
    /// The device that has the conversation (an iPhone) went out of reach while Maé answered, or while the user spoke
    /// (`setOutputReachable`). Back within this long, it hears the rest of the answer from the sentence that was cut, or
    /// is asked to say the user's sentence again; later, the rest is dropped (an old answer is not said), as it is when the
    /// voice goes to another device meanwhile. The same as the time the link gives the iPhone to come back
    /// (`LinkHost`'s grace period) before the Mac takes the sound back.
    public var outOfReachPatienceSeconds: Double = 15
    public init() {}
}

public enum PipelineState: String, Sendable, Codable {
    case listening, userSpeaking, thinking, speaking
}

/// Latency breakdown of one turn (the debug panel of the app shows these).
public struct TurnMetrics: Sendable, Codable {
    public var userText = ""
    public var assistantText = ""
    public var language = SpeechLanguage.french
    /// The answer was being prepared before the end of the user's turn.
    public var speculative = false
    public var interrupted = false
    /// End of the user's speech → end-of-turn decision (silence wait).
    public var endOfTurnMs: Double?
    public var transcriptionMs: Double?
    /// Request to the language model → first token.
    public var firstTokenMs: Double?
    /// Request to the language model → first piece of text sent to the voice.
    public var firstPieceMs: Double?
    /// First piece of text → first audio produced.
    public var synthesisFirstAudioMs: Double?
    /// THE number: end of the user's speech → first audio sent to the speakers.
    public var latencyMs: Double?
    public var historyTokens: Int?
    /// The tool the model called, if any.
    public var tool: String?
    public init() {}
}

public enum PipelineEvent: Sendable {
    case state(PipelineState)
    /// What the user has said so far, while they speak to Maé: replaced by the next one, then by `userTranscript` once
    /// their turn is over. Display only: never in the history.
    case partialTranscript(String)
    case userTranscript(String, SpeechLanguage)
    case assistantPiece(String)
    case turnFinished(TurnMetrics)
    /// The user interrupted: time from the start of their speech to the assistant falling silent.
    case bargeIn(stopMs: Double, detectionMs: Double)
    /// Wake-word mode: Maé listens to any voice (true), or waits for the phrase (false).
    case awake(Bool)
    /// Wake-word mode: what Maé made of a sentence she heard.
    case wakeDecision(WakeDecision)
    /// A new conversation started (`resetConversation`, whoever asked for it, or `setTools`, the tools came or went):
    /// the model no longer has the earlier exchanges, and the interfaces stop showing them. Sent once the turn under way
    /// has stopped, so that nothing of the earlier conversation comes after it, and before anything of the new one (the
    /// state at rest, an announcement said in it, the user's next turn).
    case conversationCleared
    case failure(String)
}

/// The conversation engine: microphone audio in, assistant voice out.
///
///     mic ─▶ SpeechDetector ─▶ TurnDetector ─▶ Transcriber ─▶ LanguageModel ─▶ SentenceChunker
///                                                                              ─▶ SpeechSynthesizer ─▶ AudioOutput
///
/// Feed microphone audio with `push(_:)` (16 kHz mono) and observe `events`. Everything is async and
/// cancellable; one `VoicePipeline` = one conversation.
///
/// In the wake-word mode, speech is first a *candidate*: nothing shows while what was said up to each pause is
/// transcribed and read by the `WakeWordDetector`. A candidate that starts with the phrase becomes the user's turn
/// (and silences Maé if she was speaking); the others are dropped. After the phrase alone, and after each answer,
/// Maé is *awake* for a few seconds: any voice then starts a turn, as in the hands-free mode.
///
/// While the user speaks to Maé, what they said so far is transcribed again about every half second, to show their words
/// as they speak (`partialTranscript`). Those passes are for the screen only: the turn transcribes the whole utterance
/// again, as it would without them.
public actor VoicePipeline {
    public nonisolated let events: AsyncStream<PipelineEvent>
    private let emit: AsyncStream<PipelineEvent>.Continuation

    private let detector: any SpeechDetector
    private let transcriber: any Transcriber
    private let model: any LanguageModel
    private let synthesizer: any SpeechSynthesizer
    private let output: any AudioOutput
    private let wakeWord: any WakeWordDetector
    private let extensions: [any ConversationExtension]
    /// Actions (reminders, calendar…); nil when they are off.
    private var tools: ToolRunner?
    public private(set) var config: PipelineConfig

    private var conversation: Conversation
    private var turnDetector: TurnDetector
    private var language = SpeechLanguage.french
    private var state = PipelineState.listening
    private let clock = ContinuousClock()

    // Audio bookkeeping.
    private var pendingSamples: [Float] = []
    private var preRoll: [Float] = []
    private var utterance: [Float] = []
    private var utteranceOpen = false
    private var talkKeyPressed = false
    /// The speaker paused (short silence), and has not resumed yet.
    private var inPause = false
    private var lastSpeechEnd: ContinuousClock.Instant?
    private var voicedRunStart: ContinuousClock.Instant?
    /// Level (dB) of the last chunks, to tell the user's voice from an echo of the assistant's.
    private var recentLevels: [Float] = []
    private var overVoice = OverVoice()

    /// For the debug log: the voice heard over Maé's while an answer plays where the conversation is (her echo, unless
    /// someone interrupts her), what the barge-in profile is checked against (`BargeInProfile`). Said once the answer is
    /// over: its bursts of voice (chunks taken for speech in a row), however short.
    private struct OverVoice {
        /// The turn whose voice plays (nil: none).
        var turn: Int?
        var since: ContinuousClock.Instant?
        /// The levels (dB) of the burst being heard, chunk by chunk.
        var burst: [Float] = []
        var bursts = 0
        var longestMs = 0.0
        /// The loudest burst's mean level.
        var loudestDB: Float?
        /// Bursts long enough to be judged, and taken for her echo by their level (each one in the log too).
        var ignored = 0
    }
    /// Chunks heard since the last one with speech (0: the last one has speech).
    private var quietChunks = 0
    private var partials = Partials()
    private var partialPasses = 0

    /// The passes over what the user said so far (`partialTranscriptSeconds`), for the utterance being heard.
    private struct Partials {
        /// The pass running: one at a time.
        var pass: Task<Void, Never>?
        /// The running pass's number: a result whose number is no longer this one is dropped (its utterance is over,
        /// or starts again).
        var passID = 0
        /// The next pass starts once `utterance` is this long.
        var nextAt = 0
        /// How much of the utterance the last pass that ended had read.
        var readUpTo = 0
        /// With the talk key: how far into the utterance the user last spoke.
        var speechUpTo = 0
        /// How much of the utterance the words shown come from, and the words: an older result never replaces them.
        var shownSamples = 0
        var shown = ""
    }

    // Wake-word mode.
    /// The utterance being heard is meant for Maé: always outside the wake-word mode; in it, when it began while she
    /// was awake, or once the phrase was found at its start.
    private var utteranceAddressed = true
    /// The utterance began while Maé was awake (no phrase needed): its transcript goes to the wake log.
    private var utteranceWhileAwake = false
    private var candidate = Candidate()
    private var wakeChecks = 0
    /// Until when Maé listens to any voice; nil while she waits for the phrase.
    private var awakeUntil: ContinuousClock.Instant?
    private var awakeTimer: Task<Void, Never>?

    /// Wake-word mode: an utterance not meant for Maé so far. What was said up to each pause is transcribed and read
    /// for the phrase; nothing shows meanwhile.
    private struct Candidate {
        var check: Task<Void, Never>?
        var checkID = 0
        /// Another pause came while the check ran: check again once it is done.
        var checkAgain = false
        /// Where speech resumed in `utterance` after the part being checked: what is kept if the check finds nothing.
        var resumedAt: Int?
        /// The check found nothing and nobody spoke since (or the speech went on too long without a pause): nothing is
        /// kept until the next words, which start a new candidate.
        var dead = false
        /// The end-of-turn silence came while the check ran.
        var ended = false
        /// Whether Maé was asleep or busy when it began, for the wake log.
        var moment = WakeDecision.Moment.asleep
        /// When the voice started, for the interruption's measurements.
        var onset: ContinuousClock.Instant?
    }

    private var shorteningInProgress = false
    private var warmTask: Task<Void, Never>?
    /// The model catching up with the history just recorded (`LanguageModel.catchUp`), after the one before.
    private var catchUpTask: Task<Void, Never>?
    /// Telling the model whether it may work in the background (`LanguageModel.allowBackgroundWork`), after the call
    /// before: it gets them in the order the states came.
    private var backgroundPermission: Task<Void, Never>?

    // The turn being prepared or spoken (at most one).
    private var turn: Turn?
    private var nextTurnID = 0

    /// What the app has to say on its own (a timer that rings), as soon as nobody speaks.
    ///
    /// One the user did not hear goes back to the head of the queue, to be said at the next quiet moment (after the
    /// user's turn, or once the voice's output is back): stopped before any of its sound, or during its chime by the
    /// user taking the floor (speaking, the talk key, a typed turn, the wake phrase); or said without the device that
    /// has the conversation saying it played it (`PlaybackEnd.unconfirmed`), or stopped while that device was out of
    /// reach, and then once more at most, so that it never loops. Said without that device saying it played it, its
    /// voice had been produced to its end: it is said again from that recording (`RecordedVoice`), at once.
    private struct Announcement {
        var text: String
        var note: String
        var language: SpeechLanguage
        var chime: Bool
        /// Said once already without reaching the user for sure: the next time is the last.
        var retried = false
        /// Lets `withdrawAnnouncement` take it back while it waits.
        var id: UUID?
        /// Its voice, produced to its end the time before: said again from it rather than by the voice.
        var recording: [VoiceAudio]?
    }
    private var announcements: [Announcement] = []

    /// A piece of an answer as the turn gave it to the voice (`deliver`): what it takes to say it again, and to record it.
    private struct SpokenPiece: Sendable {
        var text: String
        /// The white space the model wrote before it (`SpeakableText.record`).
        var separator: String
        /// Part of the answer the model sees afterwards: false for the phrase said while it writes a tool call.
        var inHistory: Bool

        /// The answer as the history keeps these pieces.
        static func answer(_ pieces: some Sequence<SpokenPiece>) -> String {
            var answer = ""
            for piece in pieces where piece.inHistory {
                SpeakableText.record(piece.text, after: piece.separator, in: &answer)
            }
            return answer
        }
    }

    /// The device that has the conversation went out of reach before it heard all of an answer.
    private struct Cut: Sendable {
        /// The first piece (`Turn.pieces`) it may not have heard whole: the answer is said again from there.
        var from: Int
        var at: ContinuousClock.Instant
    }

    /// An answer cut by a drop, to be said again from piece `from`, and its exchange: recorded whole once said, or as cut
    /// after what was heard once it is given up.
    private struct Resume: Sendable {
        var userText: String
        var userMessage: ChatMessage
        var steps: [ChatMessage]
        var language: SpeechLanguage
        var pieces: [SpokenPiece]
        var from: Int

        /// What is said again: the pieces from the cut on, without the phrase said while the model wrote a tool call
        /// (the tool's result is known by then).
        var rest: [SpokenPiece] { pieces[from...].filter(\.inHistory) }
        /// The answer as the history keeps what was heard of it: the pieces before the cut.
        var heard: String { SpokenPiece.answer(pieces[..<from]) }
    }

    /// What waits for the device that has the conversation to be back in reach (`setOutputReachable`): the rest of an
    /// answer it did not hear, or the request to say again a sentence of the user's that the drop cut. Said where the
    /// conversation is (never on a home station), before the announcements, as soon as it is back and nobody speaks; given
    /// up at `expires` (`outOfReachPatienceSeconds`), when the conversation goes on without it (someone speaks, a typed
    /// turn, the stop button, a new conversation), or when the voice goes to another device (`voiceOutputChanged`). An
    /// answer given up goes into the history as cut after what was heard.
    private struct Unheard: Sendable {
        enum Kind: Sendable {
            case answer(Resume)
            /// « Ta phrase a été coupée, tu peux répéter ? » (`OutOfReachPhrases`): not in the history, which never had
            /// the cut sentence either.
            case repeatRequest
        }
        var kind: Kind
        var language: SpeechLanguage
        var expires: ContinuousClock.Instant
        var id: Int
    }
    private var unheard: Unheard?
    private var unheardTimer: Task<Void, Never>?
    private var unheardCount = 0

    /// The voice's output can be out of reach for a moment (see `setOutputReachable`): announcements wait meanwhile.
    private var outputReachable = true
    /// Where announcements are spoken when it is not where the conversation is: a home station's speaker (see
    /// `announceThrough`), and whether it hears them now.
    private var announcementOutput: (any AudioOutput)?
    private var announcementOutputReachable = true

    private final class Turn: @unchecked Sendable {
        // Mutated only from the pipeline actor.
        let id: Int
        let gate = Gate()
        var task: Task<Void, Never>?
        var stream: (any SynthesisStream)?
        var player: Task<Void, Never>?
        var committed = false
        var audioStarted = false
        /// A barge-in is silencing it: from then on only `interruptAssistant` ends it, and what its task still does on
        /// the way out (the model's next words, the end of the playback) is neither said nor recorded.
        var interrupted = false
        var userText = ""
        var answer = ""
        var speechEnd: ContinuousClock.Instant?
        var commitTime: ContinuousClock.Instant?
        var audioStartTime: ContinuousClock.Instant?
        var firstPieceTime: ContinuousClock.Instant?
        /// Pieces of a speculative answer, announced only if the turn is committed.
        var unannouncedPieces: [String] = []
        var language = SpeechLanguage.french
        /// The user's message as sent to the model (with the date line when actions are on).
        var userMessage: ChatMessage?
        /// Tool calls and their results, between the user's message and the answer, for the history.
        var steps: [ChatMessage] = []
        /// What the app says on its own in this turn (`announce`); nil in the user's turns.
        var announcement: Announcement?
        var isAnnouncement: Bool { announcement != nil }
        /// An announcement's chime: when it is over. The output plays the words after it.
        var chimeEnd: ContinuousClock.Instant?
        /// When the turn's voice (not a chime) first went to the output.
        var voiceStart: ContinuousClock.Instant?
        /// The voice's output went out of reach while the announcement was said (`setOutputReachable`): stopped, it is
        /// said again.
        var outputLost = false
        /// Where the turn's voice goes: the pipeline's output, or the announcements' own (`announceThrough`).
        var output: any AudioOutput
        /// Spoken through the announcements' own output: somewhere else than where the microphone is.
        var elsewhere = false
        /// A turn typed instead of spoken: no transcription.
        var typedText: String?
        /// Wake-word mode: the request, already read by the check of the whole sentence: no transcription.
        var request: String?
        /// Wake-word mode: the turn says nothing (the phrase alone, or "stop"): no "thinking" on screen. Known from its
        /// start when the check of the sentence read it (`promoteCandidate`), otherwise once it is transcribed.
        var isSilent = false
        /// Wake-word mode: what Maé made of the sentence, for the log once the turn is the user's for sure.
        var wakeDecision: WakeDecision?
        /// The sentence began while Maé was awake: its transcript goes to the wake log.
        var whileAwake = false
        // What the device that plays the voice heard, should it go out of reach (`setOutputReachable`).
        /// The pieces given to the voice (`deliver`), in order; after a cut, the rest of the answer, kept for later.
        var pieces: [SpokenPiece] = []
        /// Where the current voice's texts are in `pieces`: its text number (`VoiceAudio.text`) → piece.
        var voicePieces: [Int: Int] = [:]
        /// Texts given to the current voice so far.
        var voiceTexts = 0
        /// The first piece given to the current voice (the pieces before it were said before a cut).
        var firstVoiced = 0
        /// The chunks of the voice the player read, in order: the piece each one says, and when it went to the output
        /// (nil: near-silence skipped).
        var chunks: [(piece: Int?, sent: ContinuousClock.Instant?)] = []
        /// After the first sound, the language model waits for the voice (`VoiceLead`); when the voice last produced a
        /// chunk, and what lets the model go once the voice produces nothing (`watchVoice`).
        var modelWaits = false
        var lastVoiceChunk: ContinuousClock.Instant?
        var voiceWatch: Task<Void, Never>?
        /// The player read the voice to its end.
        var voiceEnded = false
        /// An announcement's voice as the player read it, to say it again as it was (`Announcement.recording`).
        var recording: [VoiceAudio] = []
        /// The device went out of reach before it heard the whole answer: the voice stopped, the rest waits for it.
        var cut: Cut?
        /// Stopping the voice after the cut: the turn ends once it is done.
        var voiceStop: Task<Void, Never>?
        /// Said for the device that was out of reach (`Unheard`): the rest of an answer, or the request to repeat.
        var unheard: Unheard.Kind?
        init(id: Int, output: any AudioOutput) {
            self.id = id
            self.output = output
        }

        /// The first piece the device may not have heard whole when it went out of reach, the voice that went to it before
        /// `reachedUntil` having reached it; nil when it heard all of the answer.
        func firstUnheardPiece(reachedUntil: ContinuousClock.Instant) -> Int? {
            // A voice that cannot tell which text it says: all of it again.
            if let lost = chunks.first(where: { $0.sent.map { $0 >= reachedUntil } ?? false }) {
                return lost.piece ?? firstVoiced
            }
            if voiceEnded { return nil }
            // All that went to it reached it, but the voice was not done: from the piece it was on (if that piece was
            // over, it is heard twice rather than not at all).
            return chunks.last.map { $0.piece ?? firstVoiced } ?? firstVoiced
        }

        /// The answer as the history keeps what was heard of it: all of it, or the pieces before the cut.
        var answerHeard: String { cut.map { SpokenPiece.answer(pieces[..<$0.from]) } ?? answer }
    }

    public init(
        detector: any SpeechDetector, transcriber: any Transcriber, model: any LanguageModel,
        synthesizer: any SpeechSynthesizer, output: any AudioOutput, wakeWord: any WakeWordDetector = OKMaeWakeWord(),
        extensions: [any ConversationExtension] = [], tools: ToolRunner? = nil, config: PipelineConfig = .init(),
        systemPrompt: String = Conversation.defaultSystemPrompt
    ) {
        (events, emit) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.detector = detector
        self.transcriber = transcriber
        self.model = model
        self.synthesizer = synthesizer
        self.output = output
        self.wakeWord = wakeWord
        self.extensions = extensions
        self.tools = tools
        self.config = config
        self.turnDetector = TurnDetector(config: config.turn)
        var conversation = Conversation(systemPrompt: systemPrompt)
        conversation.systemAddenda = extensions.compactMap { $0.systemPromptAddendum(language: .french) }
        conversation.cutOffPlacement = config.cutOffPlacement
        self.conversation = conversation
    }

    /// The extensions' sentences, then the actions' part when they are on (its example call is written by the
    /// model itself, hence `async`) or, for the web search on its own, what it says of the date line; then what the
    /// tools' providers add (handing tasks to an agent, searching the web); and the actions' example exchanges when the
    /// config asks for them. Set with the tools, and kept for the conversations that follow, so the model's memory of
    /// them stays valid.
    private func updatePrompt() async {
        var addenda = extensions.compactMap { $0.systemPromptAddendum(language: .french) }
        if let tools {
            if tools.offersActions {
                addenda.append(ActionCatalog.promptAddendum(exampleCall: await model.toolCallText(ActionCatalog.example.call)))
            } else {
                addenda.append(ActionCatalog.dateLineRule)
            }
            addenda += await tools.promptAddenda()
        }
        conversation.systemAddenda = addenda
        conversation.examples = tools?.offersActions == true && config.actionExamples ? ActionCatalog.examples(now: Date()) : []
    }

    /// Call once after creation: pre-computes the system prompt so the first answer is fast.
    public func start() async throws {
        wakeModelsUp()  // what loading the other models pushed out of memory comes back meanwhile
        await updatePrompt()
        if let tools { await model.useTools(await tools.tools()) }
        try await model.prefillBeginning(conversation.beginning)
        emit.yield(.state(.listening))
        keepModelsWarm(true)  // from now on, not only after the first turn
    }

    /// Turns actions on (a runner) or off (nil). The tools are part of the system prompt, so a new
    /// conversation starts.
    public func setTools(_ runner: ToolRunner?) async throws {
        let stopped = await stopTurnForNewConversation()
        forgetUnheard()
        await tools?.resetConversation()  // an action waiting for its "oui" is dropped (its read-back leaves the screen)
        tools = runner
        await updatePrompt()
        conversation.clear()
        emit.yield(.conversationCleared)
        await runner?.resetConversation()
        await model.useTools(await runner?.tools() ?? [])
        if stopped { restAfterStoppedTurn() }
        try await model.prefillBeginning(conversation.beginning)
    }

    /// The list of tools changed (a shortcut was added to the folder, an agent set up): the model's prompt is
    /// computed again, the conversation goes on.
    public func toolsChanged() async throws {
        guard let tools else { return }
        await model.useTools(await tools.tools())
        await updatePrompt()
        // The new beginning first, which the model keeps for the next conversations, then the conversation on it.
        try await model.prefillBeginning(conversation.beginning)
        try await model.prefill(conversation.messages)
    }

    /// Says something on the app's own initiative (a timer rang), after a short chime, as soon as nobody
    /// speaks. `note` tells the model what happened; it stays in the history with what was said.
    /// `id` lets `withdrawAnnouncement` take it back while it waits (received information that must never be said late).
    public func announce(_ text: String, note: String, language: SpeechLanguage, chime: Bool = true, id: UUID? = nil) {
        announcements.append(Announcement(text: text, note: note, language: language, chime: chime, id: id))
        if !outputReachable { DebugLog.log("announcement: waits for the voice's output to be back") }
        startAnnouncementIfIdle()
    }

    /// Takes back an announcement that is still waiting. False when it has started, or is over.
    public func withdrawAnnouncement(_ id: UUID) -> Bool {
        guard let index = announcements.firstIndex(where: { $0.id == id }) else { return false }
        announcements.remove(at: index)
        return true
    }

    /// Whether an announcement is still waiting to be said (false once it has started).
    public func announcementWaits(_ id: UUID) -> Bool {
        announcements.contains { $0.id == id }
    }

    /// Whether the voice's output reaches the user right now. The device that has the conversation (an iPhone) can be
    /// out of reach for a moment: its connection dropped (Wi-Fi to 4G, a tunnel) and it may come back by another way.
    /// Meanwhile nothing is announced, since nobody would hear it; the announcements are said once the output is back,
    /// or once the voice is on the Mac's speakers again (`RemoteAudioRouting.setRemoteAudioReachable`).
    /// An announcement being said when the output goes out of reach, and stopped before the output says how it ended
    /// (the Mac taking the sound back stops what was playing), is said again once the output is back.
    ///
    /// Going out of reach also cuts what the user and Maé were saying to each other (`Unheard`):
    /// - Maé was answering: her voice stops there (what the device already has, it plays). `reachedUntil`: the voice that
    ///   went to the device before that instant reached it, what went since may be lost. Once it is back, the answer is
    ///   said again from the first sentence it may not have heard whole, and the exchange goes into the history once,
    ///   whole; if it does not come back in time, the history keeps what was heard, cut off.
    /// - The user was speaking: what was heard of the sentence may be incomplete. It is not answered (nor sent to the
    ///   model); once the device is back, Maé asks them to say it again.
    /// Meanwhile the microphone is not listened to: what still comes from it belongs to the cut sentence.
    public func setOutputReachable(_ reachable: Bool, reachedUntil: ContinuousClock.Instant? = nil) async {
        guard reachable != outputReachable else { return }
        outputReachable = reachable
        DebugLog.log(reachable ? "voice output: reachable again" : "voice output: out of reach, announcements wait")
        if reachable {
            startAnnouncementIfIdle()
            return
        }
        // What came from it last, it said before the drop.
        pendingSamples = []
        preRoll = []
        if let turn, turn.isAnnouncement {
            if !turn.elsewhere { turn.outputLost = true }
        } else if userSentenceInProgress {
            await cutUsersSentence()
        } else if let turn, turn.committed {
            cutAnswer(turn, reachedUntil: reachedUntil ?? clock.now)
        }
    }

    /// The voice now goes to another device: the Mac's speakers, or another iPhone (`RemoteAudioRouting`). What waited for
    /// the one that was out of reach is not said here; an answer still being written after its cut stops there. Either
    /// way the history keeps what was heard of the answer, cut off.
    public func voiceOutputChanged() async {
        giveUpUnheard("the voice went to another device")
        if let turn, turn.cut != nil { await interruptAssistant(askedForQuiet: true) }
    }

    /// The user is saying something to Maé that has not become a whole turn yet (an answer prepared during a pause may
    /// still be dropped).
    private var userSentenceInProgress: Bool {
        if talkKeyPressed { return true }
        guard utteranceAddressed, utteranceOpen || turnDetector.isInUtterance else { return false }
        return turn.map { !$0.committed } ?? true
    }

    /// The device went out of reach while the user spoke (`setOutputReachable`).
    private func cutUsersSentence() async {
        DebugLog.log("the user's sentence was cut by the drop: not answered, they will be asked to say it again")
        replaceUnheard(.repeatRequest, language: language)
        talkKeyPressed = false
        turnDetector.reset()
        inPause = false
        voicedRunStart = nil
        preRoll = []
        utterance = []
        utteranceOpen = false
        resetPartials()  // the cut sentence's words are not shown any more
        if let turn, !turn.committed { await cancelTurn(stopAudio: false) }  // the answer prepared during a pause
        if turn == nil { setState(.listening) }
    }

    /// The device went out of reach while Maé answered (`setOutputReachable`): her voice stops at once, the turn goes on
    /// (the model finishes writing, `deliver` keeps the rest) and ends with the rest waiting for the device (`endCut`).
    private func cutAnswer(_ turn: Turn, reachedUntil: ContinuousClock.Instant) {
        guard turn.cut == nil, !turn.interrupted else { return }
        guard let from = turn.firstUnheardPiece(reachedUntil: reachedUntil) else {
            DebugLog.log("turn \(turn.id): out of reach after the whole answer went to the device")
            return
        }
        DebugLog.log("turn \(turn.id): out of reach before the device heard piece \(from + 1): it will be said again")
        turn.cut = Cut(from: from, at: clock.now)
        voiceIsAudible()  // the model is not held for a voice that stopped
        let (player, stream, output) = (turn.player, turn.stream, turn.output)
        player?.cancel()
        turn.voiceStop = Task {
            await player?.value  // no chunk on its way to the output once it lets the stream go
            await output.abandon()
            await stream?.cancel()
        }
    }

    /// Where announcements are spoken: `output` (a home station's speaker, through the link), or nil for the
    /// pipeline's own output, where the conversation is. The microphone does not change: while an announcement plays
    /// elsewhere, what it hears does not interrupt it (the station may be in the same room, and Maé's voice would be
    /// taken for the user's); the talk key and `interrupt` still do. `reachable` false: that output is gone for a
    /// moment, the announcements wait for it. An announcement already playing goes on where it started; stopped while
    /// its station is out of reach, it is said again, as one where the conversation is (`setOutputReachable`).
    public func announceThrough(_ output: (any AudioOutput)?, reachable: Bool = true) {
        let wasReachable = announcementOutput == nil || announcementOutputReachable
        announcementOutput = output
        announcementOutputReachable = output == nil || reachable
        if announcementOutputReachable {
            startAnnouncementIfIdle()
        } else if wasReachable, let turn, turn.isAnnouncement, turn.elsewhere {
            turn.outputLost = true
        }
    }

    public func setListening(_ mode: ListeningMode) async {
        guard mode != config.listening else { return }
        let wasWakeWord = config.listening == .wakeWord
        config.listening = mode
        // What the turn detector was following belongs to the other mode: a sentence half-heard is dropped.
        turnDetector.reset()
        inPause = false
        resetPartials()
        if !utteranceAddressed { dropCandidate() }
        utteranceWhileAwake = false
        if wasWakeWord { fallAsleep() }  // tells the interface that the wake-word mode's attention is over
        if mode == .wakeWord { DebugLog.log("wake word: asleep, waiting for the phrase") }
        guard !talkKeyPressed else { return }
        if let turn, !turn.committed { await cancelTurn(stopAudio: false) }
        guard turn == nil else { return }
        utterance = []
        utteranceOpen = false
        if state == .userSpeaking { setState(.listening) }
    }

    /// What it takes to interrupt Maé from now on: the barge-in profile of the device that has the conversation (an
    /// iPhone's while it has it, the Mac's again once it lets go). A voice being heard over her is judged by it from its
    /// next chunk.
    public func setBargeIn(_ profile: BargeInProfile) {
        guard profile != config.bargeIn else { return }
        config.bargeIn = profile
        DebugLog.log("barge-in: \(profile.summary) to interrupt Maé")
    }

    /// Stops for good, before the models are released (another tier chosen, or the models deleted).
    public func stop() async {
        await cancelTurn(stopAudio: true, forgetting: true)
        forgetUnheard()
        catchUpTask?.cancel()  // what the model computes ahead stops at its next chunk
        await catchUpTask?.value  // the model is not released while it still computes
        warmTask?.cancel()
        warmTask = nil
        candidate.check?.cancel()
        resetPartials()
        awakeTimer?.cancel()
        emit.finish()
    }

    /// Forget the conversation (new session). The model starts again from the beginning it keeps. Reported
    /// (`conversationCleared`) whoever asked for it: the Mac's « New conversation », an iPhone's, the other interfaces
    /// clear their transcript too.
    public func resetConversation() async throws {
        let stopped = await stopTurnForNewConversation()
        resetPartials()  // the conversation is cleared: words found for it before are not shown
        forgetUnheard()
        conversation.clear()
        emit.yield(.conversationCleared)
        await tools?.resetConversation()
        if stopped { restAfterStoppedTurn() }
        try await model.prefillBeginning(conversation.beginning)
    }

    /// A new conversation starts (`resetConversation`, `setTools`): the turn under way stops, its sound with it, and is
    /// not recorded; what was heard of the user's sentence goes with it, as with `interrupt`. An announcement that made
    /// no sound yet goes back to the queue (`cancelTurn`). True when there was a turn: the caller goes back to rest
    /// (`restAfterStoppedTurn`) once the new conversation is set up.
    private func stopTurnForNewConversation() async -> Bool {
        guard turn != nil else { return false }
        await cancelTurn(stopAudio: true, forgetting: true)
        clearHeardSentence()
        return true
    }

    /// Back to rest after a turn stopped for a new conversation, as after `interrupt`: the interfaces no longer show the
    /// stopped answer's "thinking" or "speaking", the model may work in the background again and the models are kept
    /// warm; an announcement waiting (one stopped before any of its sound) starts now, in the new conversation. Once the
    /// conversation is cleared and the model has its tools, before it computes the new beginning
    /// (`LanguageModel.prefillBeginning`, seconds when the tools changed): at rest meanwhile, as when a new conversation
    /// starts with no turn. Nothing changes when another turn started meanwhile: it set the state itself.
    private func restAfterStoppedTurn() {
        guard turn == nil else { return }
        setState(someoneSpeaksToMae ? .userSpeaking : .listening)
    }

    // MARK: - Microphone input

    /// Feed microphone audio (16 kHz mono Float32), in chunks of any size, in real time. Not listened to while the device
    /// that has the conversation is out of reach (`setOutputReachable`).
    public func push(_ samples: [Float]) async {
        guard outputReachable else { return }
        pendingSamples += samples
        let n = detector.chunkSize
        while pendingSamples.count >= n {
            let chunk = Array(pendingSamples.prefix(n))
            pendingSamples.removeFirst(n)
            await process(chunk)
        }
    }

    private func process(_ chunk: [Float]) async {
        let p: Float
        do { p = try await detector.speechProbability(chunk) } catch {
            emit.yield(.failure("VAD: \(error)"))
            return
        }
        guard outputReachable else { return }  // it went out of reach meanwhile: this belongs to what the drop cut
        let now = clock.now
        let chunkDuration = Duration.milliseconds(config.turn.chunkMs)
        if p >= config.turn.speechThreshold {
            lastSpeechEnd = now
            if voicedRunStart == nil { voicedRunStart = now - chunkDuration }
        } else if p < config.turn.silenceThreshold {
            voicedRunStart = nil
        }
        quietChunks = p >= config.turn.speechThreshold ? 0 : quietChunks + 1

        let chunkLevel = Self.loudnessDB(chunk)
        recentLevels.append(chunkLevel)
        if recentLevels.count > 64 { recentLevels.removeFirst() }
        preRoll += chunk
        let preRollMax = Int(config.preRollMs / 1000 * EngineAudio.inputSampleRate)
        if preRoll.count > preRollMax { preRoll.removeFirst(preRoll.count - preRollMax) }

        if config.listening == .pushToTalk || talkKeyPressed {
            if talkKeyPressed {
                utterance += chunk
                if quietChunks == 0 { partials.speechUpTo = utterance.count }
                transcribeSoFarIfDue()
            }
            return
        }

        let assistantSpeaking = turn?.audioStarted == true
        let bargeIn = config.bargeIn
        watchOverVoice(assistantSpeaking && turn?.elsewhere != true ? turn?.id : nil,
                       voiced: p >= config.turn.speechThreshold, level: chunkLevel)
        var event = turnDetector.process(probability: p,
                                         bargeInMinSpeechMs: assistantSpeaking ? bargeIn.minSpeechMs : nil)
        if event == .speechStarted {
            // The mean level of the chunks that made the voice start, all of them taken for speech.
            let needed = assistantSpeaking ? bargeIn.minSpeechMs : config.turn.minSpeechMs
            let chunks = min(max(Int((needed / config.turn.chunkMs).rounded(.up)), 1), recentLevels.count)
            let level = recentLevels.suffix(chunks).reduce(0, +) / Float(max(chunks, 1))
            let heard = "level " + String(format: "%.1f", level) + " dB"
            if turn?.elsewhere == true {
                // An announcement plays on a home station, maybe in this very room: its voice is not the user's.
                DebugLog.log("ignored while an announcement plays on the home station (\(heard))")
                turnDetector.reset()
                event = nil
            } else if assistantSpeaking, let floor = bargeIn.minLevelDB, level < floor {
                overVoice.ignored += 1
                DebugLog.log("ignored while the assistant talks: probably its echo (\(heard); \(bargeIn.summary))")
                turnDetector.reset()
                event = nil
            } else {
                let over = assistantSpeaking ? ", over the assistant; \(bargeIn.summary)" : ""
                DebugLog.log("speech started (\(heard)\(over))")
                wakeModelsUp()
            }
        }
        switch event {
        case .pause: inPause = true
        case .speechStarted, .resumed, .endOfTurn: inPause = false
        case nil: break
        }
        if utteranceOpen, event != .speechStarted, turnDetector.isInUtterance || event == .endOfTurn,
           utteranceAddressed || !candidate.dead
        {
            utterance += chunk
        }
        if !utteranceAddressed {
            await candidateHeard(event, chunk: chunk)
        } else {
            switch event {
            case .speechStarted:
                if needsWakePhrase { startCandidate() } else { await userStartedSpeaking() }
            case .pause:
                DebugLog.log("pause → speculative start")
                if config.speculativeStart, turn == nil { startTurn(committed: false) }
            case .resumed:
                DebugLog.log("resumed → cancel speculative turn")
                if let turn, !turn.committed { await cancelTurn(stopAudio: false) }
            case .endOfTurn:
                DebugLog.log("end of turn")
                commitTurn()
            case nil: break
            }
        }
        if config.listening == .wakeWord, !(utteranceOpen && utteranceAddressed), await wakeWord.hears(chunk),
           utteranceOpen, !utteranceAddressed
        {
            DebugLog.log("wake phrase heard in the sound")
            await promoteCandidate(request: nil)
        }
        transcribeSoFarIfDue()
    }

    private func userStartedSpeaking() async {
        giveUpUnheard("the user speaks")
        utteranceWhileAwake = config.listening == .wakeWord
        if let turn {
            if turn.audioStarted {
                // Barge-in: the assistant is talking and the user speaks over it.
                DebugLog.log("barge-in: speech detected while the assistant talks")
                overVoice.burst = []  // the user's voice, not her echo
                let detected = clock.now
                await interruptAssistant()
                reportBargeIn(onset: voicedRunStart ?? detected, detected: detected)
                utterance = preRoll
            } else {
                // The user resumed before we answered: drop the answer, keep listening to the same utterance.
                await cancelTurn(stopAudio: false)
                utterance += preRoll
            }
        } else if !utteranceOpen {
            utterance = preRoll
        } else {
            utterance += preRoll
        }
        utteranceOpen = true
        resetPartials()  // the interfaces show these words in a new line
        setState(.userSpeaking)
    }

    /// A voice that started at `onset` was taken for the user's at `detected`, and Maé's voice has just been stopped.
    private func reportBargeIn(onset: ContinuousClock.Instant, detected: ContinuousClock.Instant) {
        let stopMs = ms(clock.now - onset)
        let detectionMs = ms(detected - onset)
        DebugLog.log("barge-in: voice cut \(Int(stopMs)) ms after the start of speech (detection: \(Int(detectionMs)) ms)")
        emit.yield(.bargeIn(stopMs: stopMs, detectionMs: detectionMs))
    }

    // MARK: - What is heard over Maé's voice (debug log)

    /// Follows the voice heard over Maé's (`OverVoice`), chunk by chunk. `turnID`: the turn whose voice plays where the
    /// conversation is, nil when none does; once it changes, what was heard over the previous one goes to the log.
    private func watchOverVoice(_ turnID: Int?, voiced: Bool, level: Float) {
        guard DebugLog.enabled else { return }
        if turnID != overVoice.turn {
            endOverVoiceBurst()
            logOverVoice()
            overVoice = OverVoice(turn: turnID, since: turnID == nil ? nil : clock.now)
        }
        guard turnID != nil else { return }
        if voiced {
            overVoice.burst.append(level)
        } else {
            endOverVoiceBurst()
        }
    }

    private func endOverVoiceBurst() {
        guard !overVoice.burst.isEmpty else { return }
        let level = overVoice.burst.reduce(0, +) / Float(overVoice.burst.count)
        overVoice.bursts += 1
        overVoice.longestMs = max(overVoice.longestMs, Double(overVoice.burst.count) * config.turn.chunkMs)
        overVoice.loudestDB = max(overVoice.loudestDB ?? level, level)
        overVoice.burst = []
    }

    /// "turn 13: heard over Maé's voice in 11.6 s: 4 bursts, the longest 320 ms, the loudest -33.2 dB; ignored 1 time
    /// as her echo (iPhone, -30 dB for 288 ms)": a burst's level is its mean; a burst is judged by its level once it
    /// lasts as long as the profile asks, then again after as long, and each time it is too quiet it is ignored (also
    /// in the log, as "ignored while the assistant talks").
    private func logOverVoice() {
        guard let turn = overVoice.turn, let since = overVoice.since else { return }
        let seconds = String(format: "%.1f", ms(clock.now - since) / 1000)
        guard let loudest = overVoice.loudestDB else {
            DebugLog.log("turn \(turn): nothing heard over Maé's voice in \(seconds) s (\(config.bargeIn.summary))")
            return
        }
        let (bursts, ignored) = (overVoice.bursts, overVoice.ignored)
        DebugLog.log("turn \(turn): heard over Maé's voice in \(seconds) s: \(bursts) burst\(bursts > 1 ? "s" : ""), "
                     + "the longest \(Int(overVoice.longestMs)) ms, the loudest " + String(format: "%.1f", loudest)
                     + " dB; ignored \(ignored) time\(ignored > 1 ? "s" : "") as her echo (\(config.bargeIn.summary))")
    }

    /// Silences the assistant on request (click on the indicator, Escape key). What it already said
    /// stays in the history. An announcement whose chime plays is dropped too; one that made no sound yet is said next.
    /// What waited for the device that has the conversation to be back (`Unheard`) is not said.
    public func interrupt() async {
        giveUpUnheard("asked to be quiet")
        guard let turn else { return }
        if turn.audioStarted {
            await interruptAssistant(askedForQuiet: true)
        } else {
            await cancelTurn(stopAudio: false)
        }
        clearHeardSentence()
        setState(someoneSpeaksToMae ? .userSpeaking : .listening)
    }

    /// The microphone was restarted (audio mode or device changed): forget any partial audio.
    public func resetAudioInput() async {
        await detector.reset()
        turnDetector.reset()
        inPause = false
        pendingSamples = []
        preRoll = []
        voicedRunStart = nil
        quietChunks = 0
        overVoice.burst = []  // heard by the microphone before
        resetPartials()
        if !utteranceAddressed { dropCandidate() }
        if turn == nil {
            utterance = []
            utteranceOpen = false
            if state == .userSpeaking { setState(.listening) }
        }
    }

    /// A turn typed instead of spoken (debug tools, tests): answered as if the user had just said it.
    public func submit(text: String) async {
        giveUpUnheard("a typed turn")
        if let turn, turn.audioStarted { await interruptAssistant() } else { await cancelTurn(stopAudio: false) }
        nextTurnID += 1
        let turn = Turn(id: nextTurnID, output: output)
        turn.typedText = text
        turn.speechEnd = clock.now
        self.turn = turn
        commit(turn)
        turn.task = Task { await self.runTurn(turn, audio: []) }
    }

    // MARK: - Talk key

    /// The talk key: the space bar or the button in push-to-talk mode, the global shortcut in either mode. While
    /// it is down, everything the microphone hears is the user's turn, which ends when it is released; in
    /// hands-free mode the key, not the silence, decides that one turn.
    public func setTalkKey(pressed: Bool) async {
        guard pressed != talkKeyPressed else { return }
        talkKeyPressed = pressed
        if pressed {
            wakeModelsUp()
            giveUpUnheard("the talk key")
            if !utteranceAddressed { dropCandidate() }  // the key decides: no wake phrase needed
            utteranceWhileAwake = false
            if let turn, turn.audioStarted { await interruptAssistant() } else { await cancelTurn(stopAudio: false) }
            turnDetector.reset()
            inPause = false
            utterance = preRoll
            utteranceOpen = true
            resetPartials()
            setState(.userSpeaking)
        } else {
            lastSpeechEnd = clock.now
            commitTurn()
            guard turn == nil else { return }
            // Nothing was heard: back to rest.
            utterance = []
            utteranceOpen = false
            setState(.listening)
        }
    }

    // MARK: - Wake word

    /// Speech starting now must begin with the wake phrase: Maé is asleep, or busy thinking or speaking.
    private var needsWakePhrase: Bool {
        guard config.listening == .wakeWord else { return false }
        guard turn == nil, let awakeUntil else { return true }
        return clock.now >= awakeUntil
    }

    private func startCandidate() {
        DebugLog.log(turn == nil ? "asleep: checking the sentence for the wake phrase"
            : "busy: checking the sentence for the wake phrase")
        utterance = preRoll
        utteranceOpen = true
        utteranceAddressed = false
        utteranceWhileAwake = false
        candidate = Candidate(moment: turn == nil ? .asleep : .busy, onset: voicedRunStart ?? clock.now)
    }

    /// What the turn detector says of a candidate: checked at each pause, dropped at the end if the phrase is not at
    /// its start. Speech that starts again while the last check runs is part of the same candidate.
    private func candidateHeard(_ event: TurnEvent?, chunk: [Float]) async {
        switch event {
        case .speechStarted, .resumed:
            if event == .speechStarted { DebugLog.log("speech again while the sentence is checked") }
            candidate.ended = false
            let preRollStart = utterance.count - (event == .resumed ? preRoll.count : 0)
            if event == .speechStarted { utterance += preRoll }
            if candidate.dead {
                // What was said before found nothing: these words start a sentence of their own.
                utterance = preRoll
                candidate.dead = false
                candidate.moment = turn == nil ? .asleep : .busy
                candidate.onset = voicedRunStart ?? clock.now
            } else if candidate.check != nil, candidate.resumedAt == nil {
                candidate.resumedAt = max(0, preRollStart)
            }
        case .pause:
            if !candidate.dead { checkCandidate() }
        case .endOfTurn:
            candidate.ended = true
            if candidate.check == nil { dropCandidate() }
        case nil:
            let longest = Int(config.maxUncheckedSpeechSeconds * EngineAudio.inputSampleRate)
            if !candidate.dead, candidate.check == nil, utterance.count > longest {
                DebugLog.log("a long sentence without a pause: not kept")
                candidate.dead = true
            }
        }
    }

    /// Transcribes what was said so far and reads it for the phrase.
    private func checkCandidate() {
        guard candidate.check == nil else {
            candidate.checkAgain = true
            return
        }
        wakeChecks += 1
        let id = wakeChecks
        let audio = utterance
        candidate.checkID = id
        candidate.checkAgain = false
        candidate.check = Task { [transcriber] in
            let heard = (try? await transcriber.transcribe(audio)) ?? ""
            await self.candidateChecked(id, heard: heard.trimmingCharacters(in: .whitespacesAndNewlines),
                                        samples: audio.count)
        }
    }

    private func candidateChecked(_ id: Int, heard: String, samples: Int) async {
        guard candidate.checkID == id, utteranceOpen, !utteranceAddressed else { return }  // dropped meanwhile
        candidate.check = nil
        var request: String?
        if heard.contains(where: \.isLetter) {
            request = wakeWord.request(in: heard)
            let moment = candidate.moment
            DebugLog.log("wake phrase \(request == nil ? "absent" : "found") (\(moment.rawValue)): \(heard)")
            emit.yield(.wakeDecision(WakeDecision(moment: moment, heard: heard, accepted: request != nil)))
        }
        if let request {
            // What follows the phrase is known only if nobody spoke again after the part checked.
            await promoteCandidate(request: candidate.resumedAt == nil ? request : nil)
            return
        }
        let verdict = Double(samples) / EngineAudio.inputSampleRate >= config.wakeVerdictMinSeconds
            && !wakeWord.mayStartWithPhrase(heard)
        if !verdict {
            // Maybe the phrase, misheard: the whole sentence is checked again with what follows (or dropped at its
            // end, if nothing followed).
            candidate.resumedAt = nil
            if candidate.checkAgain { checkCandidate() } else if candidate.ended { dropCandidate() }
            return
        }
        // Not for Maé. What was said after the part checked is a sentence of its own.
        if let resumedAt = candidate.resumedAt {
            utterance.removeFirst(min(resumedAt, utterance.count))
            candidate.resumedAt = nil
        } else {
            candidate.dead = true
        }
        if candidate.dead {
            if candidate.ended { dropCandidate() }
        } else if candidate.checkAgain || candidate.ended {
            checkCandidate()
        }
    }

    /// The candidate is meant for Maé (the phrase at its start, or heard in the sound): it becomes the user's turn, as
    /// if Maé had been awake when it began. If she was thinking or speaking, she stops. `request`: what followed the
    /// phrase, when the check covered everything said.
    private func promoteCandidate(request: String?) async {
        let onset = candidate.onset ?? clock.now
        candidate.check?.cancel()
        candidate = Candidate()
        utteranceAddressed = true
        giveUpUnheard("the user speaks")
        // « OK Maé, stop », unless it answers an action waiting for its "oui" (then the action is dropped, out loud).
        var onlyStops = false
        if let request, StopRequest.matches(request) {
            onlyStops = await tools?.interception(for: request, now: Date()) == nil
        }
        if let turn {
            if turn.audioStarted {
                DebugLog.log("barge-in: the wake phrase while the assistant talks")
                overVoice.burst = []  // the user's voice, not her echo
                let detected = clock.now
                await interruptAssistant(askedForQuiet: onlyStops)
                reportBargeIn(onset: onset, detected: detected)
            } else {
                await cancelTurn(stopAudio: false)
            }
        }
        // Meanwhile the sentence may have ended and its turn started, or the talk key taken over.
        guard turn == nil, !talkKeyPressed, utteranceOpen else { return }
        if turnDetector.isInUtterance {
            setState(.userSpeaking)
            guard inPause, config.speculativeStart else { return }
            if request?.isEmpty == true || onlyStops {
                // The phrase alone, or « stop »: the turn knows from the check that it asks for no answer, so the end
                // of the sentence shows no "thinking", however late its task runs.
                startTurn(committed: false, request: request, silent: true)
            } else {
                // The answer is prepared during the pause, from the request the check read (not transcribed again).
                startTurn(committed: false, request: request.flatMap { StopRequest.matches($0) ? nil : $0 })
            }
        } else if request?.isEmpty == true || onlyStops {
            endWithoutTurn(wakes: !onlyStops)
        } else {
            startTurn(committed: true, request: request)
        }
    }

    private func dropCandidate() {
        candidate.check?.cancel()
        candidate = Candidate()
        utterance = []
        utteranceOpen = false
        utteranceAddressed = true
        resetPartials()
    }

    /// The phrase alone, or a request to be quiet (unless it answers an action waiting for its "oui"): the turn ends
    /// without an answer once it is the user's for sure. True when it did.
    private func endsWithoutAnswer(_ request: String, _ turn: Turn) async throws -> Bool {
        let wakes = request.isEmpty
        guard wakes || StopRequest.matches(request) else { return false }
        if !wakes, await tools?.interception(for: request, now: Date()) != nil { return false }
        turn.isSilent = true
        try await waitForCommit(turn)
        endSilently(turn, wakes: wakes)
        return true
    }

    /// Maé listens to any voice for the next few seconds.
    private func stayAwake() {
        let seconds = config.wakeFollowUpSeconds
        let wasAsleep = awakeUntil == nil
        awakeUntil = clock.now + .seconds(seconds)
        awakeTimer?.cancel()
        awakeTimer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self.awakeTimeIsUp()
        }
        if wasAsleep {
            DebugLog.log("awake: listening to any voice for \(seconds) s")
            emit.yield(.awake(true))
        }
    }

    private func awakeTimeIsUp() {
        // A sentence meant for Maé, or her answer, is under way: she falls asleep once it is over (`setState`).
        guard turn == nil, !someoneSpeaksToMae else { return }
        fallAsleep()
    }

    /// Maé waits for the phrase again.
    private func fallAsleep() {
        awakeTimer?.cancel()
        awakeTimer = nil
        guard awakeUntil != nil else { return }
        awakeUntil = nil
        DebugLog.log("asleep: waiting for the wake phrase")
        emit.yield(.awake(false))
    }

    // MARK: - The user's words as they speak

    /// While the user speaks to Maé, transcribes what they said so far now and then (`partialTranscriptSeconds`), to
    /// show their words as they come. One pass at a time; none while they pause, nor once they have been quiet for a
    /// moment: their turn may be about to end, and its transcription would wait for the pass. With the talk key, their
    /// last words get one more pass as soon as they stop, since nothing else would show them before the key goes up
    /// (hands-free, the answer prepared at the pause transcribes them, and they show then).
    private func transcribeSoFarIfDue() {
        guard config.partialTranscriptSeconds != nil, partials.pass == nil, state == .userSpeaking, utteranceOpen,
              utteranceAddressed, turn == nil, !inPause,
              utterance.count >= Int(config.partialTranscriptMinSeconds * EngineAudio.inputSampleRate)
        else { return }
        if quietChunks < 2 {
            guard utterance.count >= partials.nextAt else { return }
        } else {
            let talkKey = config.listening == .pushToTalk || talkKeyPressed
            guard talkKey, quietChunks <= 4, partials.speechUpTo > partials.readUpTo else { return }
        }
        partialPasses += 1
        let id = partialPasses
        let audio = utterance
        partials.passID = id
        partials.pass = Task { [transcriber, clock] in
            let start = clock.now
            let heard = (try? await transcriber.transcribe(audio)) ?? ""
            await self.partialPassEnded(id, heard: heard, samples: audio.count, took: clock.now - start)
        }
    }

    private func partialPassEnded(_ id: Int, heard: String, samples: Int, took: Duration) {
        guard partials.passID == id, partials.pass != nil else { return }  // its utterance is over, or started again
        partials.pass = nil
        partials.readUpTo = samples
        partials.nextAt = utterance.count + Int((config.partialTranscriptSeconds ?? 0) * EngineAudio.inputSampleRate)
        DebugLog.log("partial transcript: \(Int(Double(samples) / EngineAudio.inputSampleRate * 1000)) ms of audio"
                     + " read in \(Int(ms(took))) ms")
        var text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.listening == .wakeWord { text = wakeWord.request(in: text) ?? text }  // as in the turn's transcript
        showPartial(text, samples: samples)
    }

    /// Shows the user's words so far, read from `samples` of the utterance: not when the words shown come from as much of
    /// it or more (a pass that ended late), nor once the utterance is over or has become a turn.
    private func showPartial(_ text: String, samples: Int) {
        guard config.partialTranscriptSeconds != nil, state == .userSpeaking, utteranceOpen, utteranceAddressed,
              turn?.committed != true, samples > partials.shownSamples, text.contains(where: \.isLetter)
        else { return }
        partials.shownSamples = samples
        guard text != partials.shown else { return }
        partials.shown = text
        emit.yield(.partialTranscript(text))
    }

    /// Stops the pass running, if any, and drops what it finds. A transcription that needs the speech recognition now
    /// (the turn's) does not wait for it to the end: it stops at its next step.
    private func stopPartialPass() {
        partials.pass?.cancel()
        partials.pass = nil
        partials.passID = 0
    }

    /// The utterance being heard is over, or starts again: a pass running is stopped, and the words shown start again
    /// from nothing.
    private func resetPartials() {
        stopPartialPass()
        partials = Partials()
    }

    // MARK: - Turns

    /// `silent`: wake-word mode, `request` is the phrase alone or « stop », as the check read it: no answer to prepare.
    private func startTurn(committed: Bool, request: String? = nil, silent: Bool = false) {
        guard utteranceOpen, !utterance.isEmpty else { return }
        // The turn's transcription would wait for it: it stops at its next step, and what it found is not needed.
        stopPartialPass()
        nextTurnID += 1
        let turn = Turn(id: nextTurnID, output: output)
        turn.speechEnd = lastSpeechEnd
        turn.whileAwake = utteranceWhileAwake
        turn.request = request
        turn.isSilent = silent
        self.turn = turn
        let audio = utterance
        if committed { commit(turn) }
        turn.task = Task { await self.runTurn(turn, audio: audio) }
    }

    private func commitTurn() {
        if let turn, !turn.committed {
            commit(turn)  // the speculative answer may now be played
        } else if turn == nil {
            startTurn(committed: true)
        }
    }

    private func commit(_ turn: Turn) {
        turn.committed = true
        turn.commitTime = clock.now
        Task { await turn.gate.open() }
        logWakeDecision(turn)
        guard !turn.isSilent else { return }
        if config.listening == .wakeWord { fallAsleep() }  // busy now: only the phrase interrupts her
        if !turn.userText.isEmpty { emit.yield(.userTranscript(turn.userText, turn.language)) }
        turn.unannouncedPieces.forEach { emit.yield(.assistantPiece($0)) }
        turn.unannouncedPieces = []
        if !turn.audioStarted { setState(.thinking) }
    }

    /// The wake log's entry of a sentence heard while Maé was awake, once the turn is the user's for sure (a
    /// speculative one may still be dropped).
    private func logWakeDecision(_ turn: Turn) {
        guard turn.committed, let decision = turn.wakeDecision else { return }
        turn.wakeDecision = nil
        emit.yield(.wakeDecision(decision))
    }

    private func runTurn(_ turn: Turn, audio: [Float]) async {
        var metrics = TurnMetrics()
        metrics.speculative = !turn.committed
        do {
            // Wake-word mode: the phrase alone or « stop », read by the check: nothing to transcribe or answer.
            if turn.isSilent, let request = turn.request {
                try await waitForCommit(turn)
                endSilently(turn, wakes: request.isEmpty)
                return
            }
            // 1. Speech → text.
            let t0 = clock.now
            let heard = if let typed = turn.typedText ?? turn.request { typed } else { try await transcriber.transcribe(audio) }
            var text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
            metrics.transcriptionMs = ms(clock.now - t0)
            try Task.checkCancellation()
            guard text.contains(where: \.isLetter) else {
                if turn.committed { finish(turn, metrics: nil) } else { self.turn = nil }
                return
            }
            if config.listening == .wakeWord, turn.typedText == nil {
                if turn.whileAwake {
                    turn.wakeDecision = WakeDecision(moment: .awake, heard: text, accepted: true)
                    logWakeDecision(turn)
                }
                // The phrase is not part of the request.
                text = wakeWord.request(in: text) ?? text
                if try await endsWithoutAnswer(text, turn) { return }
            }
            let lang = LanguageGuesser.guess(text, previous: language)
            turn.userText = text
            turn.language = lang
            metrics.userText = text
            metrics.language = lang
            if turn.committed {
                emit.yield(.userTranscript(text, lang))
            } else if self.turn === turn {
                // Prepared during a pause: the user may go on speaking, these are their words so far.
                showPartial(text, samples: audio.count)
            }
            let now = Date()
            turn.userMessage = conversation.nextUserMessage(
                text, language: lang, dateLine: tools == nil ? nil : ActionCatalog.dateLine(now))
            // "oui", "non", "annule": answered by the app, not the model.
            let interception = await tools?.interception(for: text, now: now)

            // 2. Voice: started now, so its set-up overlaps with the language model's first words.
            DebugLog.log("turn \(turn.id): STT done (\(metrics.transcriptionMs ?? 0) ms)")
            let stream = try await startVoice(language: lang)
            DebugLog.log("turn \(turn.id): TTS session ready")
            turn.stream = stream
            startPlayer(turn, stream)

            // 3. Text answer, streamed piece by piece into the voice.
            let t1 = clock.now
            var filter = ReasoningFilter()
            var chunker = SentenceChunker()
            let send: (SentenceChunker.Piece) -> Void = { self.deliver($0.text, after: $0.separator, to: turn) }
            if let local = await localAnswer(to: text, language: lang) {
                metrics.firstTokenMs = ms(clock.now - t1)
                deliver(local, to: turn)
            } else if let interception, let reply = try await resolve(interception, turn: turn, now: now) {
                metrics.firstTokenMs = ms(clock.now - t1)
                say(reply.spoken, to: turn)
            } else {
                var request = conversation.messages(adding: turn.userMessage!)
                /// Set once a call is refused for its arguments and the model gets its second try: what the app asks
                /// the user about that refusal (`ToolRefusal.spoken`), said if the second try says nothing.
                var refusalQuestion: String?
                /// The model asked for more than one call (two calls written, or `ModelOutput.moreToolCalls`), on its
                /// first try or its second. Only one call is handled per turn: however that call ends the turn (the
                /// app's sentence, the model's summary, a question after a refusal), the user then hears, once, that
                /// the app does one thing at a time.
                var askedForMore = false
                var fillerSaid = false
                /// Summing up a text that came from outside (an agent's report, search results, see
                /// `ToolOutcome.modelSpeaks`): what the model writes is said, but no call it writes then is carried
                /// out, since that text could carry instructions of its own. Holds what to say if the model says nothing.
                var summing: String?
                /// The model, summing up, wrote a call and nothing else, and was told to sum up once more.
                var summedUpAgain = false
                while true {
                    var calls: [ToolCall] = []
                    /// The model went on to another call after the first (`ModelOutput.moreToolCalls`).
                    var moreCalls = false
                    var unreadable = false
                    /// The first call written while summing up (not carried out).
                    var ignored: ToolCall?
                    let answered = turn.answer
                    DebugLog.log("turn \(turn.id): LLM request")
                    for try await output in model.reply(to: request) {
                        if metrics.firstTokenMs == nil { metrics.firstTokenMs = ms(clock.now - t1) }
                        switch output {
                        case .text(let raw): chunker.pieces(adding: filter.push(raw)).forEach(send)
                        case .toolCallStarted where summing == nil:
                            DebugLog.log("turn \(turn.id): tool call started")
                            if !fillerSaid, let phrase = await waitingPhrase(for: nil, turn) {
                                fillerSaid = true
                                // Not in the history: the model would start saying it in its own answers.
                                deliver(phrase, to: turn, inHistory: false)
                            }
                        case .toolCallNamed(let name) where summing == nil:
                            if !fillerSaid, let phrase = await waitingPhrase(for: name, turn) {
                                fillerSaid = true
                                deliver(phrase, to: turn, inHistory: false)
                            }
                        case .toolCall(let call) where summing == nil: calls.append(call)
                        case .moreToolCalls where summing == nil:
                            DebugLog.log("turn \(turn.id): the model went on to another call")
                            moreCalls = true
                        case .unreadableToolCall(let raw) where summing == nil:
                            DebugLog.log("turn \(turn.id): unreadable tool call: \(raw)")
                            unreadable = true
                        case .toolCallStarted, .toolCallNamed, .moreToolCalls: break
                        case .toolCall(let call):
                            DebugLog.log("turn \(turn.id): call ignored while summing up: \(call.name)")
                            if ignored == nil { ignored = call }
                        case .unreadableToolCall: break
                        }
                    }
                    chunker.pieces(adding: filter.flush()).forEach(send)
                    // Calls are only read outside a summing up (see above), so only those passes count.
                    if calls.count > 1 || moreCalls { askedForMore = true }
                    if let fallback = summing {
                        chunker.remainingPieces().forEach(send)
                        if turn.answer == answered, let ignored, !summedUpAgain {
                            // A call instead of a summary (often another search, when the results do not hold the
                            // answer): rather than the app's sentence, the model is told it is not carried out and
                            // sums up once more, still without any call carried out.
                            DebugLog.log("turn \(turn.id): a call instead of a summary, summing up once more")
                            summedUpAgain = true
                            turn.steps += [.call(ignored), .result(of: ignored,
                                                                   ["erreur": .string(ToolOutcome.noCallWhileSummingUp)])]
                            request = conversation.messages(adding: turn.userMessage!) + turn.steps
                            continue
                        }
                        if turn.answer == answered { say(fallback, to: turn) }
                        if askedForMore { say(ActionPhrases.oneThingAtATime(lang), to: turn) }
                        break
                    }
                    guard let tools, !calls.isEmpty || unreadable else {
                        if let question = refusalQuestion {
                            // The second try wrote no call. Unless the model said something itself, the user hears the
                            // app's question, not silence after the waiting phrase.
                            chunker.remainingPieces().forEach(send)
                            if turn.answer == answered {
                                DebugLog.log("turn \(turn.id): the second try said nothing, the app asks")
                                say(question, to: turn)
                            }
                            // The first call was handled (refused): the rest of the request was not carried out either.
                            if askedForMore { say(ActionPhrases.oneThingAtATime(lang), to: turn) }
                        }
                        break
                    }
                    // Nothing is ever carried out before the user's turn is really over.
                    try await waitForCommit(turn)
                    chunker.remainingPieces().forEach(send)
                    guard let written = calls.first else {
                        say(ActionPhrases.notUnderstood(lang), to: turn)
                        break
                    }
                    let call = await tools.named(written)  // a misspelled tool name, read as the tool's
                    DebugLog.log("turn \(turn.id): tool call \(call.name) \(call.arguments)")
                    metrics.tool = call.name
                    let reply = await tools.handle(call, context: toolContext(turn, now: now))
                    turn.steps += [.call(call), .result(of: call, reply.forModel)]
                    if reply.retryable, refusalQuestion == nil {
                        // The arguments were refused: the model sees why and gets one more try.
                        DebugLog.log("turn \(turn.id): tool call refused, second try: \(reply.forModel)")
                        refusalQuestion = reply.spoken
                        request = conversation.messages(adding: turn.userMessage!) + turn.steps
                        continue
                    }
                    if reply.modelSpeaks {
                        DebugLog.log("turn \(turn.id): the model sums up the result")
                        summing = reply.spoken
                        request = conversation.messages(adding: turn.userMessage!) + turn.steps
                        continue
                    }
                    say(reply.spoken, to: turn)
                    if askedForMore { say(ActionPhrases.oneThingAtATime(lang), to: turn) }
                    break
                }
            }
            chunker.remainingPieces().forEach(send)
            stream.finish()
            await turn.player?.value
            try Task.checkCancellation()
            if turn.cut == nil { await turn.output.waitUntilDone() }
            try Task.checkCancellation()
            if turn.cut != nil {
                // The device went out of reach before it heard all of it: the rest waits for it.
                await turn.voiceStop?.value
                endCut(turn)
                return
            }

            // 4. Done: record the exchange and the measurements.
            if let firstPiece = turn.firstPieceTime {
                metrics.firstPieceMs = ms(firstPiece - t1)
                if let start = turn.audioStartTime { metrics.synthesisFirstAudioMs = ms(start - firstPiece) }
            }
            if let speechEnd = turn.speechEnd {
                if let commit = turn.commitTime { metrics.endOfTurnMs = ms(commit - speechEnd) }
                if let start = turn.audioStartTime { metrics.latencyMs = ms(start - speechEnd) }
            }
            metrics.assistantText = turn.answer
            finish(turn, metrics: metrics)
        } catch is CancellationError {
            // Speculation abandoned or barge-in: handled by whoever cancelled.
        } catch {
            emit.yield(.failure("\(error)"))
            if self.turn === turn { finish(turn, metrics: nil) }
        }
    }

    /// The voice of an answer: one utterance, started again if its opening stays near-silent too long
    /// (`voiceRestartAfterSeconds`), or several racing for the first audible sound (`racingVoices`).
    private func startVoice(language: SpeechLanguage) async throws -> any SynthesisStream {
        guard let threshold = config.leadingSilenceThresholdDB else {
            return try await synthesizer.startUtterance(language: language)
        }
        let audible: @Sendable ([Float]) -> Bool = { Self.loudnessDB($0) >= threshold }
        if config.racingVoices > 1 {
            var runners: [any SynthesisStream] = []
            do {
                for _ in 0..<config.racingVoices {
                    runners.append(try await synthesizer.startUtterance(language: language))
                }
            } catch {
                for runner in runners { await runner.cancel() }
                throw error
            }
            return VoiceRace(runners, audible: audible)
        }
        let first = try await synthesizer.startUtterance(language: language)
        let (synthesizer, model) = (synthesizer, model)
        let rate = synthesizer.outputSampleRate
        var opening: Int?
        if let seconds = config.voiceRestartAfterSeconds, config.voiceRestarts > 0 { opening = Int(seconds * rate) }
        let later = config.sentenceRestartAfterSeconds.map { Int($0 * rate) }
        guard opening != nil || config.sentenceRestarts > 0 else { return first }
        // The language model's pause for the voice (`YieldsToVoice`, 1.5 s at most) starts again with the voice, and
        // ends once a sentence started again is heard (the first one: once the voice is audible, `voiceIsAudible`);
        // after the first sound, the player then decides whether it waits on (`VoiceLead`).
        return VoiceRestart(first, patience: opening ?? .max, restarts: opening == nil ? 0 : config.voiceRestarts,
                            laterPatience: later, laterRestarts: config.sentenceRestarts, audible: audible,
                            restarting: { (model as? any YieldsToVoice)?.holdGeneration(true) },
                            resumed: { (model as? any YieldsToVoice)?.holdGeneration(false) }) {
            try await synthesizer.startUtterance(language: language)
        }
    }

    /// Plays the voice as it is produced. A speculative answer waits for the end of the user's turn.
    private func startPlayer(_ turn: Turn, _ stream: any SynthesisStream) {
        let sampleRate = synthesizer.outputSampleRate
        let silenceThreshold = config.leadingSilenceThresholdDB
        let maxPauseSamples = config.maxVoicePauseMs.map { Int($0 / 1000 * sampleRate) }
        // After the first sound, the language model waits while the voice needs the GPU (`VoiceLead`). Not for an
        // announcement: its text is given at once, no model writes meanwhile.
        let (minimumLead, duringOpenings) = (config.voiceLeadSeconds.map { Duration.seconds($0) },
                                             config.modelWaitsDuringOpenings)
        let modelWaits = model is any YieldsToVoice && silenceThreshold != nil && !turn.isAnnouncement
        turn.player = Task { [output = turn.output, clock] in
            var voiceHeard = false
            var playing = false
            var quietSamples = 0
            var lead = VoiceLead(minimum: minimumLead, duringOpenings: duringOpenings, sampleRate: sampleRate)
            let leads = modelWaits && lead.isOn
            defer { self.modelWaitsForVoice(false, turn: turn) }  // the voice is over: nothing to wait for any more
            do {
                for try await chunk in stream.audio {
                    if turn.isAnnouncement { turn.recording.append(chunk) }
                    let samples = chunk.samples
                    // The piece it says, and when it went out: what the device heard, should it go out of reach.
                    let piece = chunk.text.flatMap { turn.voicePieces[$0] }
                    let quiet = silenceThreshold.map { Self.loudnessDB(samples) < $0 } ?? false
                    if !voiceHeard {
                        // The voice often opens with near-silence: skip it, so the answer starts (and
                        // the latency is measured) at the first sound the user can actually hear.
                        if quiet {
                            turn.chunks.append((piece, nil))
                            continue
                        }
                        voiceHeard = true
                        self.voiceIsAudible()
                    }
                    // Each sentence starts again with near-silence: cap the pauses between sentences.
                    quietSamples = quiet ? quietSamples + samples.count : 0
                    if let maxPauseSamples, quietSamples > maxPauseSamples {
                        turn.chunks.append((piece, nil))
                        if leads, playing, !Task.isCancelled {
                            self.voiceProduced(chunk, audible: !quiet, lead: &lead, turn: turn)
                        }
                        continue
                    }
                    await turn.gate.wait()  // a speculative answer waits for the end of the turn
                    if Task.isCancelled { break }
                    if !playing {
                        playing = true
                        self.audioStarted(turn, at: clock.now)
                    }
                    turn.chunks.append((piece, clock.now))
                    lead.played(samples.count, at: clock.now)
                    await output.play(samples, sampleRate: sampleRate)
                    if leads, !Task.isCancelled { self.voiceProduced(chunk, audible: !quiet, lead: &lead, turn: turn) }
                }
                if !Task.isCancelled { turn.voiceEnded = true }
            } catch {}
        }
    }

    /// After the first sound: the voice produced `chunk` (played, or left out as near-silence); the language model waits
    /// for it or goes on (`VoiceLead`).
    private func voiceProduced(_ chunk: VoiceAudio, audible: Bool, lead: inout VoiceLead, turn: Turn) {
        let now = clock.now
        turn.lastVoiceChunk = now
        let wait = lead.update(text: chunk.text, audible: audible, texts: turn.voiceTexts, at: now)
        if wait != turn.modelWaits {
            DebugLog.log(String(format: "turn %d: the model %@ (the speakers have %.2f s left to play)", turn.id,
                                wait ? "waits for the voice" : "goes on", ms(lead.lead(at: now)) / 1000))
        }
        modelWaitsForVoice(wait, turn: turn)
    }

    /// The language model waits for the voice (`YieldsToVoice`), or goes on. While it should wait, it is told so again
    /// at every chunk of the voice (a heartbeat): its pause is bounded in time (1.5 s, `MLXChatModel`), and a long
    /// opening would outlast it. Only the turn that has the conversation holds the model or lets it go: once it is
    /// over, whoever ended it let the model go (`voiceIsAudible`), and another turn may hold it.
    private func modelWaitsForVoice(_ wait: Bool, turn: Turn) {
        guard self.turn === turn, !turn.interrupted, turn.cut == nil else {
            turn.modelWaits = false
            return
        }
        guard wait || turn.modelWaits else { return }
        turn.modelWaits = wait
        (model as? any YieldsToVoice)?.holdGeneration(wait)
        if wait { watchVoice(turn) }
    }

    /// While the model waits for the voice after the first sound: it goes on once the voice produced nothing for half a
    /// second. The voice said all the text it had (a sentence it said as near-silence, the model waiting for its
    /// opening): waiting longer would leave it without any.
    private func watchVoice(_ turn: Turn) {
        guard turn.voiceWatch == nil else { return }
        turn.voiceWatch = Task { [clock] in
            while turn.modelWaits, !Task.isCancelled {
                try? await clock.sleep(for: .milliseconds(100))
                guard turn.modelWaits, let last = turn.lastVoiceChunk, clock.now - last >= .milliseconds(500) else {
                    continue
                }
                DebugLog.log("turn \(turn.id): the voice produces nothing, the model goes on")
                self.modelWaitsForVoice(false, turn: turn)
            }
            turn.voiceWatch = nil
        }
    }

    /// Sends a piece of the answer to the voice, and to the interface once the turn is committed. `separator`: the white
    /// space the model wrote before it, which the history keeps (`SpeakableText.record`). `inHistory`: whether the model
    /// will see it as part of its answer in the next turns.
    private func deliver(_ piece: String, after separator: String = "", to turn: Turn, inHistory: Bool = true) {
        guard self.turn === turn, !turn.interrupted, let stream = turn.stream else { return }
        let speakable = SpeakableText.clean(piece)
        guard !speakable.isEmpty else { return }
        // After a cut (`cutAnswer`), the rest of the answer is kept for the device, not spoken now.
        let voiced = turn.cut == nil
        if voiced, turn.firstPieceTime == nil {
            turn.firstPieceTime = clock.now
            DebugLog.log("turn \(turn.id): first piece")
            // Leave the GPU to the voice until it is audible (the model is far ahead of speech).
            (model as? any YieldsToVoice)?.holdGeneration(true)
        }
        if inHistory { SpeakableText.record(piece, after: separator, in: &turn.answer) }
        turn.pieces.append(SpokenPiece(text: piece, separator: separator, inHistory: inHistory))
        if voiced {
            turn.voicePieces[turn.voiceTexts] = turn.pieces.count - 1
            turn.voiceTexts += 1
            stream.enqueue(SpeakableText.forVoice(speakable, language: turn.language))
        }
        // A speculative answer may still be thrown away: the interface only sees it once committed.
        if turn.committed {
            emit.yield(.assistantPiece(speakable))
        } else {
            turn.unannouncedPieces.append(speakable)
        }
    }

    /// Sends the app's own sentences (confirmations, questions) to the voice, one sentence at a time: never cut
    /// at a colon or a comma, which could leave a few words alone (the voice renders those as silence).
    private func say(_ text: String, to turn: Turn) {
        var sentences = SentenceChunker()
        sentences.firstPieceMinCharacters = .max
        (sentences.push(text) + sentences.flush()).forEach { deliver($0, to: turn) }
    }

    /// What to say while the model writes a call (`ToolRunner.waitingPhrase`): nil when the config says nothing, when
    /// the model already said something, or when it is better to wait for the tool's name.
    private func waitingPhrase(for tool: String?, _ turn: Turn) async -> String? {
        guard config.toolCallFiller, turn.answer.isEmpty, let tools else { return nil }
        return await tools.waitingPhrase(for: tool, language: turn.language)
    }

    /// Returns once the user's turn is really over; throws if the turn was dropped meanwhile.
    private func waitForCommit(_ turn: Turn) async throws {
        await turn.gate.wait()
        try Task.checkCancellation()
        guard self.turn === turn, turn.committed else { throw CancellationError() }
    }

    private func resolve(_ interception: ToolRunner.Interception, turn: Turn, now: Date) async throws
        -> ToolRunner.Reply?
    {
        guard let tools else { return nil }
        try await waitForCommit(turn)
        DebugLog.log("turn \(turn.id): answered by the app (\(interception))")
        return await tools.resolve(interception, context: toolContext(turn, now: now))
    }

    private func toolContext(_ turn: Turn, now: Date) -> ToolContext {
        // The user's words, this turn's then the two before (their message without the date line; the examples' are
        // not theirs, and not in `exchanges`).
        let earlier = conversation.exchanges.filter { $0.role == .user }.suffix(2).reversed()
            .map { $0.content.components(separatedBy: "\n").first ?? "" }
        return ToolContext(now: now, language: turn.language, userSaid: [turn.userText] + earlier) {
            [weak self] sentence in
            await self?.deliver(sentence, to: turn)
        }
    }

    // MARK: - What the device out of reach did not hear

    /// The turn of an answer cut by a drop is over (`cutAnswer`): the rest waits for the device (`Unheard`), and the
    /// exchange goes into the history once it is said, or given up. The interfaces showed the answer as the model wrote
    /// it: that attempt is reported cut off, the rest shows again once said.
    private func endCut(_ turn: Turn) {
        guard self.turn === turn, !turn.interrupted, let cut = turn.cut else { return }
        var waiting: Unheard.Kind?
        if case .repeatRequest? = turn.unheard {
            waiting = .repeatRequest
        } else if let message = turn.userMessage, !turn.userText.isEmpty {
            let resume = Resume(userText: turn.userText, userMessage: message, steps: turn.steps,
                                language: turn.language, pieces: turn.pieces, from: cut.from)
            if !resume.rest.isEmpty { waiting = .answer(resume) }
        }
        guard let waiting else {
            // Nothing that matters was left to say (the phrase said while a tool call was written): heard.
            var metrics = TurnMetrics()
            metrics.userText = turn.userText
            metrics.assistantText = turn.answer
            metrics.language = turn.language
            finish(turn, metrics: turn.userMessage == nil ? nil : metrics)
            return
        }
        voiceIsAudible()
        self.turn = nil
        replaceUnheard(waiting, language: turn.language, since: cut.at)
        if case .answer = waiting {
            language = turn.language
            var metrics = TurnMetrics()
            metrics.userText = turn.userText
            metrics.assistantText = turn.answer
            metrics.language = turn.language
            metrics.interrupted = true
            emit.yield(.turnFinished(metrics))
        }
        if utteranceAddressed {
            utterance = []
            utteranceOpen = turnDetector.isInUtterance
        }
        setState(someoneSpeaksToMae ? .userSpeaking : .listening)
    }

    /// `kind` waits for the device from now on (`since`: when it went out of reach), instead of what waited before (an
    /// answer that waited goes into the history as heard).
    private func replaceUnheard(_ kind: Unheard.Kind, language: SpeechLanguage, since: ContinuousClock.Instant? = nil) {
        giveUpUnheard("something newer waits")
        unheardCount += 1
        let expires = (since ?? clock.now) + .seconds(config.outOfReachPatienceSeconds)
        let id = unheardCount
        unheard = Unheard(kind: kind, language: language, expires: expires, id: id)
        unheardTimer = Task {
            try? await Task.sleep(until: expires, clock: .continuous)
            guard !Task.isCancelled else { return }
            self.unheardExpired(id)
        }
    }

    private func unheardExpired(_ id: Int) {
        guard unheard?.id == id else { return }
        giveUpUnheard("the device was out of reach for too long")
    }

    /// What waited for the device is not said; an answer goes into the history as it was heard, cut off.
    private func giveUpUnheard(_ why: String) {
        guard let unheard else { return }
        DebugLog.log("not said for the device that was out of reach: \(why)")
        forgetUnheard()
        if case .answer(let resume) = unheard.kind { recordHeard(resume) }
    }

    /// A new conversation, or the end: what waited for the device goes with the conversation.
    private func forgetUnheard() {
        unheard = nil
        unheardTimer?.cancel()
        unheardTimer = nil
    }

    /// An answer cut by a drop and not said again: the history keeps what the device heard of it, cut off.
    private func recordHeard(_ resume: Resume) {
        conversation.record(user: resume.userMessage, steps: resume.steps, assistant: resume.heard, interrupted: true)
        language = resume.language
        letModelCatchUp()
    }

    /// Says what the device that has the conversation did not hear (`Unheard`), once it is back and nobody speaks: where
    /// the conversation is, never on a home station. True when it started.
    private func startUnheardIfIdle() -> Bool {
        let userSpeaks = utteranceAddressed && (utteranceOpen || turnDetector.isInUtterance)
        guard let unheard, turn == nil, !userSpeaks, !talkKeyPressed, outputReachable else { return false }
        guard clock.now < unheard.expires else {
            giveUpUnheard("the device was out of reach for too long")
            return false
        }
        forgetUnheard()
        nextTurnID += 1
        let turn = Turn(id: nextTurnID, output: output)
        turn.unheard = unheard.kind
        turn.language = unheard.language
        if case .answer(let resume) = unheard.kind {
            turn.userMessage = resume.userMessage
            turn.steps = resume.steps
            turn.pieces = Array(resume.pieces[..<resume.from])
            turn.firstVoiced = resume.from
            turn.answer = resume.heard
        }
        self.turn = turn
        commit(turn)
        // After `commit`, which would show the user's words again.
        if case .answer(let resume) = unheard.kind { turn.userText = resume.userText }
        turn.task = Task { await self.runUnheard(turn, unheard.kind) }
        return true
    }

    private func runUnheard(_ turn: Turn, _ kind: Unheard.Kind) async {
        do {
            let stream = try await startVoice(language: turn.language)
            turn.stream = stream
            guard !Task.isCancelled else {
                await stream.cancel()  // stopped while the voice got ready
                return
            }
            startPlayer(turn, stream)
            switch kind {
            case .answer(let resume):
                DebugLog.log("turn \(turn.id): the device is back, the answer again from piece \(resume.from + 1)")
                for piece in resume.rest { deliver(piece.text, after: piece.separator, to: turn) }
            case .repeatRequest:
                DebugLog.log("turn \(turn.id): the device is back, the user is asked to say their sentence again")
                say(OutOfReachPhrases.sentenceCut(turn.language), to: turn)
            }
            stream.finish()
            await turn.player?.value
            try Task.checkCancellation()
            if turn.cut == nil { await turn.output.waitUntilDone() }
            try Task.checkCancellation()
            if turn.cut != nil {
                await turn.voiceStop?.value  // out of reach again: what is left waits for it again
                endCut(turn)
                return
            }
            guard self.turn === turn, !turn.interrupted else { return }
            guard case .answer = kind else {
                finish(turn, metrics: nil)  // the request to repeat is not part of the conversation
                return
            }
            var metrics = TurnMetrics()
            metrics.userText = turn.userText
            metrics.assistantText = turn.answer
            metrics.language = turn.language
            finish(turn, metrics: metrics)  // the exchange, whole
        } catch is CancellationError {
        } catch {
            emit.yield(.failure("\(error)"))
            guard self.turn === turn else { return }
            if case .answer(let resume) = kind { recordHeard(resume) }
            finish(turn, metrics: nil)
        }
    }

    // MARK: - Announcements

    private func startAnnouncementIfIdle() {
        if startUnheardIfIdle() { return }  // what the device that was out of reach did not hear comes first
        // A sentence still being checked for the wake phrase does not hold it back.
        let userSpeaks = utteranceAddressed && (utteranceOpen || turnDetector.isInUtterance)
        // On a home station when there is one (`announceThrough`), otherwise where the conversation is; each waits while
        // its output is out of reach.
        let reachable = announcementOutput == nil ? outputReachable : announcementOutputReachable
        guard turn == nil, !userSpeaks, !talkKeyPressed, reachable, !announcements.isEmpty else { return }
        let announcement = announcements.removeFirst()
        nextTurnID += 1
        let turn = Turn(id: nextTurnID, output: announcementOutput ?? output)
        turn.elsewhere = announcementOutput != nil
        turn.announcement = announcement
        turn.language = announcement.language
        turn.userMessage = conversation.nextNoteMessage(announcement.note)
        self.turn = turn
        commit(turn)
        turn.task = Task { await self.runAnnouncement(turn, announcement) }
    }

    private func runAnnouncement(_ turn: Turn, _ announcement: Announcement) async {
        do {
            let stream: any SynthesisStream
            if let recording = announcement.recording {
                DebugLog.log("announcement: said again from its voice of the time before")
                stream = RecordedVoice(recording)
            } else {
                stream = try await startVoice(language: announcement.language)
            }
            turn.stream = stream
            guard !Task.isCancelled else {
                await stream.cancel()  // stopped while the voice got ready: it has nothing to stop yet
                return
            }
            if turn.elsewhere { DebugLog.log("announcement: on the home station") }
            if announcement.chime {
                let sampleRate = synthesizer.outputSampleRate
                let chime = Chime.samples(sampleRate: sampleRate)
                audioStarted(turn, at: clock.now, chime: .seconds(Double(chime.count) / sampleRate))
                await turn.output.play(chime, sampleRate: sampleRate)
            }
            startPlayer(turn, stream)
            say(announcement.text, to: turn)
            stream.finish()
            await turn.player?.value
            try Task.checkCancellation()
            let end = await turn.output.waitUntilDone()
            try Task.checkCancellation()
            guard self.turn === turn, !turn.interrupted else { return }  // stopped meanwhile: up to whoever stopped it
            if end == .unconfirmed {
                guard announcement.retried else {
                    DebugLog.log("announcement: it may not have reached the user, said again once the voice does")
                    sayAgainLater(turn, retried: true, recorded: true)
                    finish(turn, metrics: nil)
                    return
                }
                DebugLog.log("announcement: said twice without reaching the user for sure, not said again")
            }
            var metrics = TurnMetrics()
            metrics.language = announcement.language
            metrics.assistantText = turn.answer
            finish(turn, metrics: metrics)
        } catch is CancellationError {
        } catch {
            emit.yield(.failure("\(error)"))
            if self.turn === turn { finish(turn, metrics: nil) }
        }
    }

    private func voiceIsAudible() {
        (model as? any YieldsToVoice)?.holdGeneration(false)
    }

    /// `chime`: the sound is an announcement's chime, that long; otherwise it is the voice.
    private func audioStarted(_ turn: Turn, at time: ContinuousClock.Instant, chime: Duration? = nil) {
        guard self.turn === turn else { return }
        DebugLog.log("turn \(turn.id): first audio played")
        turn.audioStarted = true
        turn.audioStartTime = time
        if let chime {
            turn.chimeEnd = time + chime
        } else if turn.voiceStart == nil {
            turn.voiceStart = time
        }
        setState(.speaking)
    }

    /// Whether the user may have heard some of the turn's words: its voice went to the output, and the chime the output
    /// plays before it (an announcement's) is over.
    private func wordsMayBeHeard(_ turn: Turn) -> Bool {
        guard let voiceStart = turn.voiceStart else { return false }
        return clock.now >= max(voiceStart, turn.chimeEnd ?? voiceStart)
    }

    /// The turn's announcement did not reach the user: back to the head of the queue, for the next quiet moment. What
    /// the interfaces showed of it is reported cut off. `retried`: it may have been said to nobody (`Announcement`).
    /// `recorded`: its voice went to the output to its end, and is said again as it was.
    private func sayAgainLater(_ turn: Turn, retried: Bool = false, recorded: Bool = false) {
        guard var announcement = turn.announcement else { return }
        if retried { announcement.retried = true }
        if recorded, turn.voiceEnded, !turn.recording.isEmpty { announcement.recording = turn.recording }
        announcements.insert(announcement, at: 0)
        DebugLog.log("turn \(turn.id): the announcement is said again later")
        guard !turn.answer.isEmpty else { return }
        var metrics = TurnMetrics()
        metrics.language = announcement.language
        metrics.assistantText = turn.answer
        metrics.interrupted = true
        emit.yield(.turnFinished(metrics))
    }

    /// The turn's announcement was stopped and is not said again. Once its words may have been heard, the history keeps
    /// it as an answer cut off, after its note: the model knows what happened (a timer rang) and that the user may not
    /// have heard all of it. Stopped during its chime (asked to be quiet), none of its words was heard: the history does
    /// not keep it. Either way, what the interfaces showed of it is reported cut off.
    private func dropAnnouncement(_ turn: Turn, wordsHeard: Bool) {
        guard let announcement = turn.announcement, !turn.answer.isEmpty else { return }  // nothing shown or said
        DebugLog.log("turn \(turn.id): the announcement is stopped, not said again")
        if wordsHeard, let message = turn.userMessage {
            conversation.record(user: message, steps: [], assistant: turn.answer, interrupted: true)
            letModelCatchUp()  // the model never wrote it: it computes it once nobody speaks
        }
        var metrics = TurnMetrics()
        metrics.language = announcement.language
        metrics.assistantText = turn.answer
        metrics.interrupted = true
        emit.yield(.turnFinished(metrics))
    }

    private func finish(_ turn: Turn, metrics: TurnMetrics?) {
        guard self.turn === turn, !turn.interrupted else { return }
        voiceIsAudible()  // never leave the model paused
        self.turn = nil
        var recorded = false
        if let metrics, let message = turn.userMessage {
            conversation.record(user: message, steps: turn.steps, assistant: turn.answer, interrupted: false)
            recorded = true
            if !turn.isAnnouncement { language = metrics.language }
            Task { await self.keepHistoryInBudget(reporting: metrics) }
        }
        clearHeardSentence()
        // After an answer, Maé listens a few seconds more without the wake phrase.
        if config.listening == .wakeWord, metrics != nil { stayAwake() }
        setState(someoneSpeaksToMae ? .userSpeaking : .listening)
        // Once the state says whether someone speaks, or another announcement starts.
        if recorded { letModelCatchUp() }
    }

    /// Once an exchange is recorded, the model computes what of the history its memory no longer holds (an answer cut
    /// off, and the note after it when it is read ahead, or an answer kept otherwise than it wrote it) right away, while
    /// the user speaks or nobody does, rather than in the next answer's time; then a speculative answer abandoned, and the
    /// user's message heard in full after it, only cost that message (`LanguageModel.catchUp`). So does it what it never
    /// wrote (an announcement once said, a tool's result and the app's own sentences), if nobody speaks: it knows by then
    /// whether someone does (`backgroundPermission`). One after the other, in the order the exchanges were recorded.
    private func letModelCatchUp() {
        let messages = conversation.messages
        let (previous, permission) = (catchUpTask, backgroundPermission)
        catchUpTask = Task { [model] in
            await previous?.value
            await permission?.value
            await model.catchUp(with: messages)
        }
    }

    /// Wake-word mode: a turn without an answer, once it is the user's for sure.
    private func endSilently(_ turn: Turn, wakes: Bool) {
        guard self.turn === turn else { return }
        voiceIsAudible()
        self.turn = nil
        endWithoutTurn(wakes: wakes)
    }

    /// Wake-word mode: the phrase alone wakes Maé (a chime, then she listens to any voice for a few seconds); "stop"
    /// only silences her.
    private func endWithoutTurn(wakes: Bool) {
        clearHeardSentence()
        if wakes {
            DebugLog.log("the wake phrase alone → listening")
            let sampleRate = synthesizer.outputSampleRate
            Task { [output] in await output.play(Chime.samples(sampleRate: sampleRate), sampleRate: sampleRate) }
            stayAwake()
        } else {
            DebugLog.log("asked to be quiet")
            fallAsleep()
        }
        setState(someoneSpeaksToMae ? .userSpeaking : .listening)
    }

    /// Someone is speaking, and it is meant for Maé (always, outside the wake-word mode).
    private var someoneSpeaksToMae: Bool { turnDetector.isInUtterance && utteranceAddressed }

    /// A turn is over or stopped: what was heard of the user's sentence goes with it, and a sentence still going on
    /// starts again from the next audio. A sentence still being checked for the wake phrase goes on.
    private func clearHeardSentence() {
        guard utteranceAddressed else { return }
        utterance = []
        utteranceOpen = turnDetector.isInUtterance
        resetPartials()
    }

    /// Barge-in: silence the assistant immediately, keep what it already said in the history. An announcement whose
    /// words were not heard yet (its chime plays) is said after the user's turn, unless they asked to be quiet
    /// (`askedForQuiet`: the stop button, « OK Maé, stop »); one said while the voice's output was out of reach is
    /// said again either way. One that is not said again goes into the history cut off, once its words may have been
    /// heard (`dropAnnouncement`).
    private func interruptAssistant(askedForQuiet: Bool = false) async {
        guard let turn else { return }
        let wordsHeard = wordsMayBeHeard(turn)
        // Before anything that waits: once the voice stops, the turn's own wait for the end of the playback returns,
        // and it would take the answer for one said to its end (recording the exchange a second time, as complete).
        // Marked, it says, records and reports nothing more; the exchange is recorded once, below.
        turn.interrupted = true
        turn.player?.cancel()
        await turn.output.stopImmediately()  // silence at once…
        await turn.player?.value  // …and once the player is over, again: a frame may have been on its way
        await turn.output.stopImmediately()
        await cancelTurn(stopAudio: false)
        if let announcement = turn.announcement {
            if turn.outputLost, !announcement.retried {
                sayAgainLater(turn, retried: true)
            } else if !wordsHeard, !askedForQuiet {
                sayAgainLater(turn)
            } else {
                dropAnnouncement(turn, wordsHeard: wordsHeard)
            }
        }
        if !turn.userText.isEmpty, let message = turn.userMessage {
            // An answer cut by a drop before: what the device heard of it, not what was written meanwhile.
            conversation.record(user: message, steps: turn.steps, assistant: turn.answerHeard, interrupted: true)
            letModelCatchUp()  // the model's memory holds what it wrote, the history the answer cut off
            var metrics = TurnMetrics()
            metrics.userText = turn.userText
            metrics.assistantText = turn.answerHeard
            metrics.interrupted = true
            emit.yield(.turnFinished(metrics))
        }
    }

    /// `forgetting`: the conversation is forgotten (a new one starts, or the pipeline stops); otherwise the rest of an
    /// answer that the device that was out of reach did not hear, dropped before any sound, goes into the history as it
    /// was heard.
    private func cancelTurn(stopAudio: Bool, forgetting: Bool = false) async {
        guard let turn else { return }
        self.turn = nil
        voiceIsAudible()  // never leave the model paused
        DebugLog.log("turn \(turn.id): cancelling")
        if turn.isAnnouncement, !turn.audioStarted { sayAgainLater(turn) }  // nothing of it was heard yet
        if !forgetting, !turn.interrupted, case .answer(let resume)? = turn.unheard { recordHeard(resume) }
        turn.task?.cancel()
        turn.player?.cancel()
        await turn.gate.open()  // release a player waiting for the end of the turn
        await turn.stream?.cancel()
        DebugLog.log("turn \(turn.id): cancelled")
        if stopAudio, turn.audioStarted {
            await turn.player?.value  // no frame can reach the speakers after the stop
            await turn.output.stopImmediately()
        }
    }

    private func localAnswer(to text: String, language: SpeechLanguage) async -> String? {
        for ext in extensions {
            if let answer = await ext.answer(to: text, language: language) { return answer }
        }
        return nil
    }

    /// Context window: when the history grows too long, the oldest exchanges are dropped. The model
    /// prepares the shortened history in the background; until it is ready, requests keep using the
    /// full history (which its current memory serves instantly), then the switch happens.
    private func keepHistoryInBudget(reporting finished: TurnMetrics) async {
        var metrics = finished
        do {
            var tokens = try await model.tokenCount(conversation.messages)
            metrics.historyTokens = tokens
            emit.yield(.turnFinished(metrics))
            guard tokens > config.historyTokenBudget, !shorteningInProgress else { return }
            var shortened = conversation  // only used to decide how many exchanges to drop
            var dropped = 0
            while tokens > config.historyTrimTarget, shortened.dropOldestExchange() {
                dropped += 1
                tokens = try await model.tokenCount(shortened.messages)
            }
            guard dropped > 0 else { return }
            DebugLog.log("history: preparing a shortened version (\(tokens) tokens)")
            shorteningInProgress = true
            defer { shorteningInProgress = false }
            // Preparation only runs while nobody speaks, so the conversation may go on meanwhile:
            // keep extending the prepared version with the new exchanges until it has caught up,
            // so that switching to it never costs more than a normal turn.
            for _ in 0..<20 {
                let exchangesBefore = conversation.exchanges.count
                var target = conversation
                target.dropOldestExchanges(dropped)
                try await model.prepareShortenedHistory(target.messages)
                if conversation.exchanges.count == exchangesBefore { break }
            }
            conversation.dropOldestExchanges(dropped)
            DebugLog.log("history: shortened version in use")
        } catch {
            emit.yield(.turnFinished(metrics))
            emit.yield(.failure("history: \(error)"))
        }
    }

    private func setState(_ newState: PipelineState) {
        guard newState != state else { return }
        // The interfaces show the user's words in a new line each time they speak, until their turn is over.
        if newState == .userSpeaking || state == .userSpeaking { resetPartials() }
        state = newState
        // Back at rest after the few seconds of attention: Maé waits for the phrase again.
        if newState == .listening, let awakeUntil, clock.now >= awakeUntil { fallAsleep() }
        emit.yield(.state(newState))
        let quiet = newState == .listening
        let previous = backgroundPermission
        backgroundPermission = Task { [model] in
            await previous?.value
            await model.allowBackgroundWork(quiet)
        }
        keepModelsWarm(quiet)
        if quiet { startAnnouncementIfIdle() }
    }

    private func keepModelsWarm(_ quiet: Bool) {
        warmTask?.cancel()
        warmTask = nil
        let interval = config.keepWarmSeconds
        guard quiet, interval > 0 else { return }
        let stages = warmStages
        guard !stages.isEmpty else { return }
        warmTask = Task {
            while true {
                try? await Task.sleep(for: .seconds(interval))
                for stage in stages {
                    if Task.isCancelled { return }
                    await stage.keepWarm()
                }
            }
        }
    }

    private var warmStages: [any KeepsWarm] {
        ([model, synthesizer, transcriber] as [Any]).compactMap { $0 as? any KeepsWarm }
    }

    /// Someone speaks, or the conversation starts: what macOS pushed out of memory comes back meanwhile (see
    /// `KeepsWarm.wakeUp`).
    private func wakeModelsUp() {
        guard config.keepWarmSeconds > 0 else { return }
        for stage in warmStages { stage.wakeUp() }
    }

    /// Root-mean-square level in dB (0 dB = full scale).
    static func loudnessDB(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -120 }
        let meanSquare = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
        return 10 * log10(max(meanSquare, 1e-12))
    }

    private nonisolated func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}

/// A one-way door: tasks `wait()` until someone calls `open()`. Used to hold a speculative answer's
/// audio until the user's turn is really over.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
