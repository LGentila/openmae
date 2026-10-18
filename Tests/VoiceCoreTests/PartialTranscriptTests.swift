import Foundation
import Testing

@testable import VoiceCore

/// A speech recognition that takes its time, as Parakeet does (0.1–0.15 s), stops when its task is cancelled, as
/// Parakeet's decoder does, and records how many transcriptions run at once.
actor SlowTranscriber: Transcriber {
    private(set) var calls: [Int] = []
    private(set) var running = 0
    private(set) var mostAtOnce = 0
    private(set) var cancelled = 0
    let delay: Duration

    init(delay: Duration) { self.delay = delay }

    func transcribe(_ samples: [Float]) async throws -> String {
        calls.append(samples.count)
        running += 1
        mostAtOnce = max(mostAtOnce, running)
        defer { running -= 1 }
        do {
            try await Task.sleep(for: delay)
        } catch {
            cancelled += 1
            throw error
        }
        return "phrase de \(samples.count) échantillons"
    }
}

/// What the interface gets of the user's words: the states, the words so far, the whole sentence; in order.
actor WordsLog {
    enum Entry: Equatable {
        case state(PipelineState)
        case partial(String)
        case final(String)
    }

    private(set) var entries: [Entry] = []
    private(set) var wakeDecisions: [WakeDecision] = []

    func record(_ event: PipelineEvent) {
        switch event {
        case .state(let state): entries.append(.state(state))
        case .partialTranscript(let text): entries.append(.partial(text))
        case .userTranscript(let text, _): entries.append(.final(text))
        case .wakeDecision(let decision): wakeDecisions.append(decision)
        default: break
        }
    }

    var partials: [String] { entries.compactMap { if case .partial(let text) = $0 { text } else { nil } } }
    var finals: [String] { entries.compactMap { if case .final(let text) = $0 { text } else { nil } } }
    var states: [PipelineState] { entries.compactMap { if case .state(let state) = $0 { state } else { nil } } }
}

/// The number of samples in a fake transcript ("phrase de 16384 échantillons").
private func samples(_ transcript: String) -> Int? {
    transcript.split(separator: " ").compactMap { Int($0) }.first
}

@Suite("The user's words as they speak", .serialized)
struct PartialTranscriptTests {
    let speech = [Float](repeating: 0.5, count: 512)
    let silence = [Float](repeating: 0, count: 512)
    /// One second of audio, in chunks of 512 samples.
    let second = 32

    /// Pushes `count` chunks, leaving the pipeline's tasks a moment after each one (`pace`), as a microphone would.
    func push(_ pipeline: VoicePipeline, _ chunk: [Float], _ count: Int, pace: Duration = .milliseconds(1)) async {
        for _ in 0..<count {
            await pipeline.push(chunk)
            if pace > .zero { try? await Task.sleep(for: pace) }
        }
    }

    func waitFor(_ condition: () async -> Bool) async {
        for _ in 0..<400 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func make(transcriber: any Transcriber, model: ScriptedModel = ScriptedModel(), speaker: FakeSpeaker = FakeSpeaker(),
              config: PipelineConfig = .init()) -> (VoicePipeline, WordsLog)
    {
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: transcriber, model: model,
                                     synthesizer: FakeSynthesizer(), output: speaker, config: config)
        let log = WordsLog()
        Task { for await event in pipeline.events { await log.record(event) } }
        return (pipeline, log)
    }

    /// Hands-free: the words show while the user speaks, each pass reading more of the sentence (never less than a
    /// second), and the whole sentence replaces them at the end of the turn; the model only gets the whole sentence.
    @Test func wordsShowWhileTheUserSpeaks() async throws {
        let (model, stt) = (ScriptedModel(), CountingTranscriber())
        let (pipeline, log) = make(transcriber: stt, model: model)
        try await pipeline.start()
        await push(pipeline, speech, 3 * second)
        await waitFor { await log.partials.count >= 3 }
        let partials = await log.partials
        #expect(partials.count >= 3)
        let read = partials.compactMap(samples)
        #expect(read.allSatisfy { $0 >= 16_000 })
        #expect(read == read.sorted() && Set(read).count == read.count)  // each from more of the sentence
        #expect(await log.states.last == .userSpeaking)
        await push(pipeline, silence, 20)
        await waitFor { await model.requests.count == 1 }
        let final = try #require(await log.finals.first)
        #expect(await log.finals.count == 1)
        #expect(try #require(samples(final)) > read.last ?? 0)
        #expect(await model.requests.last?.last?.content == final)  // never the words so far
        let entries = await log.entries
        // Nothing shows of the words so far once the turn is over.
        let finalIndex = try #require(entries.firstIndex(of: .final(final)))
        let thinking = try #require(entries.firstIndex(of: .state(.thinking)))
        let lastPartial = try #require(entries.lastIndex { if case .partial = $0 { true } else { false } })
        #expect(lastPartial < finalIndex && lastPartial < thinking)
    }

    /// The talk key (or push-to-talk): the words show while it is down, the last ones as soon as the user stops talking
    /// (before the key goes up), and the turn's transcription still covers everything heard while it was down, once.
    @Test func wordsShowWithTheTalkKey() async throws {
        var config = PipelineConfig()
        config.listening = .pushToTalk
        let (model, stt) = (ScriptedModel(), CountingTranscriber())
        let (pipeline, log) = make(transcriber: stt, model: model, config: config)
        try await pipeline.start()
        await pipeline.setTalkKey(pressed: true)
        await push(pipeline, speech, 2 * second)
        await push(pipeline, silence, 8)  // the user stops talking, the key is still down
        try await Task.sleep(for: .milliseconds(50))
        let partials = await log.partials
        #expect(partials.count >= 2)
        // The last words: a pass after the speech stopped, which read all of it.
        #expect(try #require(partials.last.flatMap(samples)) >= 2 * second * 512)
        #expect(await log.finals.isEmpty)
        await pipeline.setTalkKey(pressed: false)
        await waitFor { await model.requests.count == 1 }
        #expect(await log.finals == ["phrase de \((2 * second + 8) * 512) échantillons"])
        #expect(await stt.calls.last == (2 * second + 8) * 512)
        #expect(await model.requests.last?.last?.content == "phrase de \((2 * second + 8) * 512) échantillons")
    }

    /// The user talks over Maé: their words show as they do.
    @Test func wordsShowWhenTheUserTalksOverMae() async throws {
        let long = (1...20).map { "Phrase numéro \($0) de la réponse. " }
        let (model, speaker) = (ScriptedModel(answer: long), FakeSpeaker())
        let (pipeline, log) = make(transcriber: CountingTranscriber(), model: model, speaker: speaker)
        try await pipeline.start()
        await push(pipeline, speech, 10, pace: .zero)
        await push(pipeline, silence, 20, pace: .zero)
        await waitFor { await speaker.played > 0 }
        let before = await log.partials.count
        await push(pipeline, speech, 2 * second)  // over her voice
        await waitFor { await log.partials.count > before }
        #expect(await speaker.stops >= 1)
        #expect(await log.partials.count > before)
        let entries = await log.entries
        let bargeIn = try #require(entries.lastIndex(of: .state(.speaking)))
        #expect(entries[(bargeIn + 1)...].first == .state(.userSpeaking))
        #expect(entries[(bargeIn + 1)...].contains { if case .partial = $0 { true } else { false } })
    }

    /// Wake-word mode: a sentence still checked for « OK Maé » (the TV) never shows, however long; one that starts with
    /// it shows once it is meant for Maé, without the phrase, as the turn's transcript has it.
    @Test func aSentenceShowsOnlyOnceItIsMeantForMae() async throws {
        var config = PipelineConfig()
        config.listening = .wakeWord
        let model = ScriptedModel()
        let (pipeline, log) = make(transcriber: LevelTranscriber(), model: model, config: config)
        try await pipeline.start()
        let tv = [Float](repeating: 0.2, count: 512)
        await push(pipeline, tv, 3 * second)  // the TV, three seconds without a pause
        await push(pipeline, silence, 24)
        await waitFor { await !log.wakeDecisions.isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await log.partials.isEmpty)
        #expect(await log.states == [.listening])
        // « OK Maé, quelle heure est-il ? », a pause (it is checked: meant for Maé), then the user goes on.
        let request = [Float](repeating: 0.3, count: 512)
        await push(pipeline, request, 10)
        await push(pipeline, silence, 8)
        await waitFor { await log.states.last == .userSpeaking }
        await push(pipeline, request, 2 * second)
        try await Task.sleep(for: .milliseconds(50))
        let partials = await log.partials
        #expect(!partials.isEmpty)
        #expect(partials.allSatisfy { $0 == "Quelle heure est-il ?" })
        let entries = await log.entries
        let addressed = try #require(entries.firstIndex(of: .state(.userSpeaking)))
        #expect(!entries[..<addressed].contains { if case .partial = $0 { true } else { false } })
        await push(pipeline, silence, 24)
        await waitFor { await !log.finals.isEmpty }
        #expect(await log.finals == ["Quelle heure est-il ?"])
        #expect(await model.requests.last?.last?.content == "Quelle heure est-il ?")
        // Only the sentences' own checks go to the wake log: the TV's, then the phrase's.
        #expect(await log.wakeDecisions.map(\.accepted) == [false, true])
    }

    /// However slow speech recognition is, one pass at a time: the next one starts only after the last one ended.
    @Test func onePassAtATime() async throws {
        let stt = SlowTranscriber(delay: .milliseconds(80))
        let (pipeline, log) = make(transcriber: stt)
        try await pipeline.start()
        await push(pipeline, speech, 6 * second, pace: .milliseconds(3))
        await waitFor { await stt.running == 0 }
        #expect(await stt.calls.count >= 2)
        #expect(await stt.mostAtOnce == 1)
        #expect(await !log.partials.isEmpty)
    }

    /// No pass while the user pauses: the answer prepared then transcribes what they said (its words show), and the
    /// passes start again if they go on.
    @Test func noPassDuringAPause() async throws {
        let (model, stt) = (ScriptedModel(), CountingTranscriber())
        let (pipeline, log) = make(transcriber: stt, model: model)
        try await pipeline.start()
        await push(pipeline, speech, 2 * second)
        await push(pipeline, silence, 7)  // 224 ms: the pause, the answer is prepared
        try await Task.sleep(for: .milliseconds(30))
        let atThePause = (2 * second + 7) * 512
        #expect(await stt.calls.last == atThePause)  // the answer prepared, from everything said
        #expect(await log.partials.last == "phrase de \(atThePause) échantillons")  // its words show
        let calls = await stt.calls.count
        await push(pipeline, silence, 5)  // still the pause, not yet the end of the turn (16)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await stt.calls.count == calls)  // no pass
        #expect(await log.finals.isEmpty)
        await push(pipeline, speech, second)  // the user goes on
        try await Task.sleep(for: .milliseconds(30))
        #expect(await stt.calls.count > calls)
        await push(pipeline, silence, 20)
        await waitFor { await !log.finals.isEmpty }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await log.finals.count == 1)
    }

    /// What a pass finds after the utterance was dropped (another way of talking chosen, the microphone restarted, a
    /// new conversation) never shows.
    @Test func nothingShowsOnceTheUtteranceIsDropped() async throws {
        let resets: [(String, @Sendable (VoicePipeline) async -> Void)] = [
            ("microphone restarted", { await $0.resetAudioInput() }),
            ("push-to-talk chosen", { await $0.setListening(.pushToTalk) }),
            ("new conversation", { try? await $0.resetConversation() }),
        ]
        for (name, reset) in resets {
            let stt = SlowTranscriber(delay: .milliseconds(150))
            let (pipeline, log) = make(transcriber: stt)
            try await pipeline.start()
            await push(pipeline, speech, second + 4, pace: .zero)  // a pass starts after a second
            await waitFor { await stt.running == 1 }
            #expect(await stt.running == 1, "\(name)")
            await reset(pipeline)
            try await Task.sleep(for: .milliseconds(250))  // the pass would have ended by now
            #expect(await log.partials.isEmpty, "\(name)")
            await pipeline.stop()
        }
    }

    /// The talk key goes up while a pass runs: the pass stops (the turn's transcription does not wait for it), and
    /// nothing it found shows once the turn has started.
    @Test func nothingShowsOnceTheUtteranceIsATurn() async throws {
        var config = PipelineConfig()
        config.listening = .pushToTalk
        let stt = SlowTranscriber(delay: .milliseconds(150))
        let model = ScriptedModel()
        let (pipeline, log) = make(transcriber: stt, model: model, config: config)
        try await pipeline.start()
        await pipeline.setTalkKey(pressed: true)
        await push(pipeline, speech, second + 4, pace: .zero)
        await waitFor { await stt.running == 1 }
        await pipeline.setTalkKey(pressed: false)
        await waitFor { await model.requests.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await stt.cancelled == 1)
        #expect(await log.partials.isEmpty)
        #expect(await log.finals == ["phrase de \((second + 4) * 512) échantillons"])
    }

    /// The same sentence, with and without the words shown as the user speaks: the same transcript of the turn, and the
    /// model gets exactly the same request.
    @Test func theTurnIsTheSameWithOrWithoutThem() async throws {
        var results: [(finals: [String], request: [ChatMessage])] = []
        for partials in [true, false] {
            var config = PipelineConfig()
            if !partials { config.partialTranscriptSeconds = nil }
            let (model, stt) = (ScriptedModel(), CountingTranscriber())
            let (pipeline, log) = make(transcriber: stt, model: model, config: config)
            try await pipeline.start()
            await push(pipeline, speech, 3 * second)
            await push(pipeline, silence, 20)
            await waitFor { await model.requests.count == 1 }
            #expect(await log.partials.isEmpty == !partials)
            results.append((await log.finals, try #require(await model.requests.last)))
            await pipeline.stop()
        }
        #expect(results[0].finals == results[1].finals)
        #expect(results[0].request == results[1].request)
    }
}
