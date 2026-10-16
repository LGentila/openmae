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
    /// Push-to-talk: the turn ends when the talk key is released instead of on silence.
    public var pushToTalk = false
    /// The voice often starts an answer with up to 0.7 s of near-silence (measured on Pocket TTS):
    /// audio quieter than this (dB) is skipped until the first audible sound, so the answer starts
    /// sooner and the latency measures what the user actually hears. nil = keep everything.
    public var leadingSilenceThresholdDB: Float? = -45
    /// Pauses of the voice longer than this (between sentences, each one starting with near-silence)
    /// are shortened to it. nil = keep them.
    public var maxVoicePauseMs: Double? = 300
    /// While the assistant talks, speech quieter than this at the microphone (dB, after echo
    /// cancellation) is taken for an echo of its own voice and does not interrupt it. nil = no check.
    public var bargeInMinLevelDB: Float? = -38
    /// While nobody speaks, the models are used briefly every this many seconds so that macOS keeps
    /// them in memory (see `KeepsWarm`). 0 = never.
    public var keepWarmSeconds: Double = 30
    /// While the model writes a tool call (no voice until it is complete: about 1.5 s with Gemma 4 26B on the
    /// reference Mac), say "Un instant, je m'en occupe tout de suite." so the user is not left in silence.
    public var toolCallFiller = true
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
    case userTranscript(String, SpeechLanguage)
    case assistantPiece(String)
    case turnFinished(TurnMetrics)
    /// The user interrupted: time from the start of their speech to the assistant falling silent.
    case bargeIn(stopMs: Double, detectionMs: Double)
    case failure(String)
}

/// The conversation engine: microphone audio in, assistant voice out.
///
///     mic ─▶ SpeechDetector ─▶ TurnDetector ─▶ Transcriber ─▶ LanguageModel ─▶ SentenceChunker
///                                                                              ─▶ SpeechSynthesizer ─▶ AudioOutput
///
/// Feed microphone audio with `push(_:)` (16 kHz mono) and observe `events`. Everything is async and
/// cancellable; one `VoicePipeline` = one conversation.
public actor VoicePipeline {
    public nonisolated let events: AsyncStream<PipelineEvent>
    private let emit: AsyncStream<PipelineEvent>.Continuation

    private let detector: any SpeechDetector
    private let transcriber: any Transcriber
    private let model: any LanguageModel
    private let synthesizer: any SpeechSynthesizer
    private let output: any AudioOutput
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
    private var lastSpeechEnd: ContinuousClock.Instant?
    private var voicedRunStart: ContinuousClock.Instant?
    /// Level (dB) of the last chunks, to tell the user's voice from an echo of the assistant's.
    private var recentLevels: [Float] = []

    private var shorteningInProgress = false
    private var warmTask: Task<Void, Never>?

    // The turn being prepared or spoken (at most one).
    private var turn: Turn?
    private var nextTurnID = 0

    /// What the app has to say on its own (a timer that rings), as soon as nobody speaks.
    private struct Announcement {
        var text: String
        var note: String
        var language: SpeechLanguage
        var chime: Bool
    }
    private var announcements: [Announcement] = []

    private final class Turn: @unchecked Sendable {
        // Mutated only from the pipeline actor.
        let id: Int
        let gate = Gate()
        var task: Task<Void, Never>?
        var stream: (any SynthesisStream)?
        var player: Task<Void, Never>?
        var committed = false
        var audioStarted = false
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
        var isAnnouncement = false
        /// A turn typed instead of spoken: no transcription.
        var typedText: String?
        init(id: Int) { self.id = id }
    }

    public init(
        detector: any SpeechDetector, transcriber: any Transcriber, model: any LanguageModel,
        synthesizer: any SpeechSynthesizer, output: any AudioOutput,
        extensions: [any ConversationExtension] = [], tools: ToolRunner? = nil, config: PipelineConfig = .init(),
        systemPrompt: String = Conversation.defaultSystemPrompt
    ) {
        (events, emit) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.detector = detector
        self.transcriber = transcriber
        self.model = model
        self.synthesizer = synthesizer
        self.output = output
        self.extensions = extensions
        self.tools = tools
        self.config = config
        self.turnDetector = TurnDetector(config: config.turn)
        var conversation = Conversation(systemPrompt: systemPrompt)
        conversation.systemAddenda = Self.addenda(extensions, actions: tools != nil)
        self.conversation = conversation
    }

    private static func addenda(_ extensions: [any ConversationExtension], actions: Bool) -> [String] {
        extensions.compactMap { $0.systemPromptAddendum(language: .french) } + (actions ? [ActionCatalog.promptAddendum] : [])
    }

    /// Call once after creation: pre-computes the system prompt so the first answer is fast.
    public func start() async throws {
        if let tools {
            await model.useTools(await tools.tools())
            conversation.systemAddenda = Self.addenda(extensions, actions: true) + (await tools.promptAddenda())
        }
        try await model.prefill(conversation.messages)
        emit.yield(.state(.listening))
    }

    /// Turns actions on (a runner) or off (nil). The tools are part of the system prompt, so a new
    /// conversation starts.
    public func setTools(_ runner: ToolRunner?) async throws {
        await cancelTurn(stopAudio: true)
        await tools?.resetConversation()  // an action waiting for its "oui" is dropped (its read-back leaves the screen)
        tools = runner
        conversation.systemAddenda = Self.addenda(extensions, actions: runner != nil) + (await runner?.promptAddenda() ?? [])
        conversation.clear()
        await runner?.resetConversation()
        await model.useTools(await runner?.tools() ?? [])
        try await model.prefill(conversation.messages)
    }

    /// The list of tools changed (a shortcut was added to the folder, an agent set up): the model's prompt is
    /// computed again, the conversation goes on.
    public func toolsChanged() async throws {
        guard let tools else { return }
        await model.useTools(await tools.tools())
        conversation.systemAddenda = Self.addenda(extensions, actions: true) + (await tools.promptAddenda())
        try await model.prefill(conversation.messages)
    }

    /// Says something on the app's own initiative (a timer rang), after a short chime, as soon as nobody
    /// speaks. `note` tells the model what happened; it stays in the history with what was said.
    public func announce(_ text: String, note: String, language: SpeechLanguage, chime: Bool = true) {
        announcements.append(Announcement(text: text, note: note, language: language, chime: chime))
        startAnnouncementIfIdle()
    }

    public func setPushToTalk(_ enabled: Bool) async {
        guard enabled != config.pushToTalk else { return }
        config.pushToTalk = enabled
        // What the turn detector was following belongs to the other mode: a sentence half-heard is dropped.
        turnDetector.reset()
        guard !talkKeyPressed else { return }
        if let turn, !turn.committed { await cancelTurn(stopAudio: false) }
        guard turn == nil else { return }
        utterance = []
        utteranceOpen = false
        if state == .userSpeaking { setState(.listening) }
    }

    /// Stops for good, before the models are released (another tier chosen, or the models deleted).
    public func stop() async {
        await cancelTurn(stopAudio: true)
        warmTask?.cancel()
        warmTask = nil
        emit.finish()
    }

    /// Forget the conversation (new session).
    public func resetConversation() async throws {
        await cancelTurn(stopAudio: true)
        conversation.clear()
        await tools?.resetConversation()
        try await model.prefill(conversation.messages)
    }

    // MARK: - Microphone input

    /// Feed microphone audio (16 kHz mono Float32), in chunks of any size, in real time.
    public func push(_ samples: [Float]) async {
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
        let now = clock.now
        let chunkDuration = Duration.milliseconds(config.turn.chunkMs)
        if p >= config.turn.speechThreshold {
            lastSpeechEnd = now
            if voicedRunStart == nil { voicedRunStart = now - chunkDuration }
        } else if p < config.turn.silenceThreshold {
            voicedRunStart = nil
        }

        recentLevels.append(Self.loudnessDB(chunk))
        if recentLevels.count > 16 { recentLevels.removeFirst() }
        preRoll += chunk
        let preRollMax = Int(config.preRollMs / 1000 * EngineAudio.inputSampleRate)
        if preRoll.count > preRollMax { preRoll.removeFirst(preRoll.count - preRollMax) }

        if config.pushToTalk || talkKeyPressed {
            if talkKeyPressed { utterance += chunk }
            return
        }

        let assistantSpeaking = turn?.audioStarted == true
        var event = turnDetector.process(probability: p, assistantSpeaking: assistantSpeaking)
        if event == .speechStarted {
            let chunks = Int(config.turn.bargeInMinSpeechMs / config.turn.chunkMs)
            let level = recentLevels.suffix(chunks).reduce(0, +) / Float(min(chunks, recentLevels.count))
            if assistantSpeaking, let floor = config.bargeInMinLevelDB, level < floor {
                DebugLog.log("ignored while the assistant talks: probably its echo (level \(Int(level)) dB)")
                turnDetector.reset()
                event = nil
            } else {
                let over = assistantSpeaking ? ", over the assistant" : ""
                DebugLog.log("speech started (level \(Int(level)) dB\(over))")
            }
        }
        if utteranceOpen, event != .speechStarted, turnDetector.isInUtterance || event == .endOfTurn {
            utterance += chunk
        }
        switch event {
        case .speechStarted: await userStartedSpeaking()
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

    private func userStartedSpeaking() async {
        if let turn {
            if turn.audioStarted {
                // Barge-in: the assistant is talking and the user speaks over it.
                DebugLog.log("barge-in: speech detected while the assistant talks")
                let detected = clock.now
                await interruptAssistant()
                let onset = voicedRunStart ?? detected
                emit.yield(.bargeIn(stopMs: ms(clock.now - onset), detectionMs: ms(detected - onset)))
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
        setState(.userSpeaking)
    }

    /// Silences the assistant on request (click on the indicator, Escape key). What it already said
    /// stays in the history.
    public func interrupt() async {
        guard let turn else { return }
        if turn.audioStarted { await interruptAssistant() } else { await cancelTurn(stopAudio: false) }
        utterance = []
        utteranceOpen = turnDetector.isInUtterance
        setState(turnDetector.isInUtterance ? .userSpeaking : .listening)
    }

    /// The microphone was restarted (audio mode or device changed): forget any partial audio.
    public func resetAudioInput() async {
        await detector.reset()
        turnDetector.reset()
        pendingSamples = []
        preRoll = []
        voicedRunStart = nil
        if turn == nil {
            utterance = []
            utteranceOpen = false
            if state == .userSpeaking { setState(.listening) }
        }
    }

    /// A turn typed instead of spoken (debug tools, tests): answered as if the user had just said it.
    public func submit(text: String) async {
        if let turn, turn.audioStarted { await interruptAssistant() } else { await cancelTurn(stopAudio: false) }
        nextTurnID += 1
        let turn = Turn(id: nextTurnID)
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
            if let turn, turn.audioStarted { await interruptAssistant() } else { await cancelTurn(stopAudio: false) }
            turnDetector.reset()
            utterance = preRoll
            utteranceOpen = true
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

    // MARK: - Turns

    private func startTurn(committed: Bool) {
        guard utteranceOpen, !utterance.isEmpty else { return }
        nextTurnID += 1
        let turn = Turn(id: nextTurnID)
        turn.speechEnd = lastSpeechEnd
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
        if !turn.userText.isEmpty { emit.yield(.userTranscript(turn.userText, turn.language)) }
        turn.unannouncedPieces.forEach { emit.yield(.assistantPiece($0)) }
        turn.unannouncedPieces = []
        if !turn.audioStarted { setState(.thinking) }
    }

    private func runTurn(_ turn: Turn, audio: [Float]) async {
        var metrics = TurnMetrics()
        metrics.speculative = !turn.committed
        do {
            // 1. Speech → text.
            let t0 = clock.now
            let heard = if let typed = turn.typedText { typed } else { try await transcriber.transcribe(audio) }
            let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
            metrics.transcriptionMs = ms(clock.now - t0)
            try Task.checkCancellation()
            guard text.contains(where: \.isLetter) else {
                if turn.committed { finish(turn, metrics: nil) } else { self.turn = nil }
                return
            }
            let lang = LanguageGuesser.guess(text, previous: language)
            turn.userText = text
            turn.language = lang
            metrics.userText = text
            metrics.language = lang
            if turn.committed { emit.yield(.userTranscript(text, lang)) }
            let now = Date()
            turn.userMessage = Conversation.userMessage(
                text, language: lang, dateLine: tools == nil ? nil : ActionCatalog.dateLine(now))
            // "oui", "non", "annule": answered by the app, not the model.
            let interception = await tools?.interception(for: text, now: now)

            // 2. Voice: started now, so its set-up overlaps with the language model's first words.
            DebugLog.log("turn \(turn.id): STT done (\(metrics.transcriptionMs ?? 0) ms)")
            let stream = try await synthesizer.startUtterance(language: lang)
            DebugLog.log("turn \(turn.id): TTS session ready")
            turn.stream = stream
            startPlayer(turn, stream)

            // 3. Text answer, streamed piece by piece into the voice.
            let t1 = clock.now
            var filter = ReasoningFilter()
            var chunker = SentenceChunker()
            let send: (String) -> Void = { self.deliver($0, to: turn) }
            if let local = await localAnswer(to: text, language: lang) {
                metrics.firstTokenMs = ms(clock.now - t1)
                send(local)
            } else if let interception, let reply = try await resolve(interception, turn: turn, now: now) {
                metrics.firstTokenMs = ms(clock.now - t1)
                say(reply.spoken, to: turn)
            } else {
                var request = conversation.messages(adding: turn.userMessage!)
                var secondTry = false
                var fillerSaid = false
                /// Summing up a text that came from outside (an agent's report, see `ToolOutcome.modelSpeaks`): what
                /// the model writes is said, but no call it writes then is carried out, since that text could carry
                /// instructions of its own. Holds what to say if the model says nothing.
                var summing: String?
                while true {
                    var calls: [ToolCall] = []
                    var unreadable = false
                    let answered = turn.answer
                    DebugLog.log("turn \(turn.id): LLM request")
                    for try await output in model.reply(to: request) {
                        if metrics.firstTokenMs == nil { metrics.firstTokenMs = ms(clock.now - t1) }
                        switch output {
                        case .text(let raw): chunker.push(filter.push(raw)).forEach(send)
                        case .toolCallStarted where summing == nil:
                            DebugLog.log("turn \(turn.id): tool call started")
                            if config.toolCallFiller, !fillerSaid, turn.answer.isEmpty {
                                fillerSaid = true
                                // Not in the history: the model would start saying it in its own answers.
                                deliver(ActionPhrases.oneMoment(lang), to: turn, inHistory: false)
                            }
                        case .toolCall(let call) where summing == nil: calls.append(call)
                        case .unreadableToolCall(let raw) where summing == nil:
                            DebugLog.log("turn \(turn.id): unreadable tool call: \(raw)")
                            unreadable = true
                        case .toolCallStarted: break
                        case .toolCall(let call):
                            DebugLog.log("turn \(turn.id): call ignored while summing up a report: \(call.name)")
                        case .unreadableToolCall: break
                        }
                    }
                    chunker.push(filter.flush()).forEach(send)
                    if let fallback = summing {
                        chunker.flush().forEach(send)
                        if turn.answer == answered { say(fallback, to: turn) }
                        break
                    }
                    guard let tools, !calls.isEmpty || unreadable else { break }
                    // Nothing is ever carried out before the user's turn is really over.
                    try await waitForCommit(turn)
                    chunker.flush().forEach(send)
                    guard let call = calls.first else {
                        say(ActionPhrases.notUnderstood(lang), to: turn)
                        break
                    }
                    DebugLog.log("turn \(turn.id): tool call \(call.name) \(call.arguments)")
                    metrics.tool = call.name
                    let reply = await tools.handle(call, context: toolContext(turn, now: now))
                    turn.steps += [.call(call), .result(of: call, reply.forModel)]
                    if reply.retryable, !secondTry {
                        // The arguments were refused: the model sees why and gets one more try.
                        DebugLog.log("turn \(turn.id): tool call refused, second try: \(reply.forModel)")
                        secondTry = true
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
                    if calls.count > 1 { say(ActionPhrases.oneThingAtATime(lang), to: turn) }
                    break
                }
            }
            chunker.flush().forEach(send)
            stream.finish()
            await turn.player?.value
            try Task.checkCancellation()
            await output.waitUntilDone()
            try Task.checkCancellation()

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

    /// Plays the voice as it is produced. A speculative answer waits for the end of the user's turn.
    private func startPlayer(_ turn: Turn, _ stream: any SynthesisStream) {
        let sampleRate = synthesizer.outputSampleRate
        let silenceThreshold = config.leadingSilenceThresholdDB
        let maxPauseSamples = config.maxVoicePauseMs.map { Int($0 / 1000 * sampleRate) }
        turn.player = Task { [output, clock] in
            var voiceHeard = false
            var playing = false
            var quietSamples = 0
            do {
                for try await samples in stream.audio {
                    let quiet = silenceThreshold.map { Self.loudnessDB(samples) < $0 } ?? false
                    if !voiceHeard {
                        // The voice often opens with near-silence: skip it, so the answer starts (and
                        // the latency is measured) at the first sound the user can actually hear.
                        if quiet { continue }
                        voiceHeard = true
                        self.voiceIsAudible()
                    }
                    // Each sentence starts again with near-silence: cap the pauses between sentences.
                    quietSamples = quiet ? quietSamples + samples.count : 0
                    if let maxPauseSamples, quietSamples > maxPauseSamples { continue }
                    await turn.gate.wait()  // a speculative answer waits for the end of the turn
                    if Task.isCancelled { break }
                    if !playing {
                        playing = true
                        self.audioStarted(turn, at: clock.now)
                    }
                    await output.play(samples, sampleRate: sampleRate)
                }
            } catch {}
        }
    }

    /// Sends a piece of the answer to the voice, and to the interface once the turn is committed. `inHistory`:
    /// whether the model will see it as part of its answer in the next turns.
    private func deliver(_ piece: String, to turn: Turn, inHistory: Bool = true) {
        guard self.turn === turn, let stream = turn.stream else { return }
        let speakable = SpeakableText.clean(piece)
        guard !speakable.isEmpty else { return }
        if turn.firstPieceTime == nil {
            turn.firstPieceTime = clock.now
            DebugLog.log("turn \(turn.id): first piece")
            // Leave the GPU to the voice until it is audible (the model is far ahead of speech).
            (model as? any YieldsToVoice)?.holdGeneration(true)
        }
        if inHistory { turn.answer += (turn.answer.isEmpty ? "" : " ") + speakable }
        stream.enqueue(SpeakableText.forVoice(speakable, language: turn.language))
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
        ToolContext(now: now, language: turn.language) { [weak self] sentence in
            await self?.deliver(sentence, to: turn)
        }
    }

    // MARK: - Announcements

    private func startAnnouncementIfIdle() {
        guard turn == nil, !utteranceOpen, !talkKeyPressed, !turnDetector.isInUtterance, !announcements.isEmpty
        else { return }
        let announcement = announcements.removeFirst()
        nextTurnID += 1
        let turn = Turn(id: nextTurnID)
        turn.isAnnouncement = true
        turn.language = announcement.language
        turn.userMessage = ChatMessage(.user, announcement.note)
        self.turn = turn
        commit(turn)
        turn.task = Task { await self.runAnnouncement(turn, announcement) }
    }

    private func runAnnouncement(_ turn: Turn, _ announcement: Announcement) async {
        do {
            let stream = try await synthesizer.startUtterance(language: announcement.language)
            turn.stream = stream
            if announcement.chime {
                let sampleRate = synthesizer.outputSampleRate
                audioStarted(turn, at: clock.now)
                await output.play(Chime.samples(sampleRate: sampleRate), sampleRate: sampleRate)
            }
            startPlayer(turn, stream)
            say(announcement.text, to: turn)
            stream.finish()
            await turn.player?.value
            try Task.checkCancellation()
            await output.waitUntilDone()
            try Task.checkCancellation()
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

    private func audioStarted(_ turn: Turn, at time: ContinuousClock.Instant) {
        guard self.turn === turn else { return }
        DebugLog.log("turn \(turn.id): first audio played")
        turn.audioStarted = true
        turn.audioStartTime = time
        setState(.speaking)
    }

    private func finish(_ turn: Turn, metrics: TurnMetrics?) {
        guard self.turn === turn else { return }
        voiceIsAudible()  // never leave the model paused
        self.turn = nil
        if let metrics, let message = turn.userMessage {
            conversation.record(user: message, steps: turn.steps, assistant: turn.answer, interrupted: false)
            if !turn.isAnnouncement { language = metrics.language }
            Task { await self.keepHistoryInBudget(reporting: metrics) }
        }
        utterance = []
        utteranceOpen = turnDetector.isInUtterance
        setState(turnDetector.isInUtterance ? .userSpeaking : .listening)
    }

    /// Barge-in: silence the assistant immediately, keep what it already said in the history.
    private func interruptAssistant() async {
        guard let turn else { return }
        turn.player?.cancel()
        await output.stopImmediately()  // silence at once…
        await turn.player?.value  // …and once the player is over, again: a frame may have been on its way
        await output.stopImmediately()
        await cancelTurn(stopAudio: false)
        if !turn.userText.isEmpty, let message = turn.userMessage {
            conversation.record(user: message, steps: turn.steps, assistant: turn.answer, interrupted: true)
            var metrics = TurnMetrics()
            metrics.userText = turn.userText
            metrics.assistantText = turn.answer
            metrics.interrupted = true
            emit.yield(.turnFinished(metrics))
        }
    }

    private func cancelTurn(stopAudio: Bool) async {
        guard let turn else { return }
        self.turn = nil
        voiceIsAudible()  // never leave the model paused
        DebugLog.log("turn \(turn.id): cancelling")
        turn.task?.cancel()
        turn.player?.cancel()
        await turn.gate.open()  // release a player waiting for the end of the turn
        await turn.stream?.cancel()
        DebugLog.log("turn \(turn.id): cancelled")
        if stopAudio, turn.audioStarted {
            await turn.player?.value  // no frame can reach the speakers after the stop
            await output.stopImmediately()
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
        state = newState
        emit.yield(.state(newState))
        let quiet = newState == .listening
        Task { [model] in await model.allowBackgroundWork(quiet) }
        keepModelsWarm(quiet)
        if quiet { startAnnouncementIfIdle() }
    }

    private func keepModelsWarm(_ quiet: Bool) {
        warmTask?.cancel()
        warmTask = nil
        let interval = config.keepWarmSeconds
        guard quiet, interval > 0 else { return }
        let stages = ([model, synthesizer, transcriber] as [Any]).compactMap { $0 as? any KeepsWarm }
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
