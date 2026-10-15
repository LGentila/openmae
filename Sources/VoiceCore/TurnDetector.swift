import Foundation

/// Settings for deciding when the user has finished speaking.
public struct TurnDetectorConfig: Sendable, Codable {
    /// Speech probability above which a chunk counts as speech.
    public var speechThreshold: Float = 0.5
    /// Probability below which a chunk counts as silence (between the two: "no change", like Silero).
    public var silenceThreshold: Float = 0.35
    /// Speech shorter than this is ignored (clicks, breath, a cough).
    public var minSpeechMs: Double = 160
    /// The same while the assistant is talking: leftovers of its own voice that echo cancellation
    /// misses come in short bursts (170–260 ms measured in the app), so interrupting it takes a bit more.
    public var bargeInMinSpeechMs: Double = 224
    /// After this much silence the engine starts working on an answer *speculatively*: transcription
    /// and the first words of the answer are prepared, but nothing is played yet.
    public var speculativeSilenceMs: Double = 200
    /// After this much silence the turn is over and the prepared answer may be played.
    /// Too short cuts people off mid-sentence; too long feels sluggish. 500 ms is a common compromise.
    public var endOfTurnSilenceMs: Double = 500
    /// Duration of one detector chunk (512 samples at 16 kHz for Silero).
    public var chunkMs: Double = 32

    public init() {}
}

public enum TurnEvent: Sendable, Equatable {
    /// Someone started speaking (after `minSpeechMs` of continuous speech).
    case speechStarted
    /// Short silence: a good moment to start preparing an answer.
    case pause
    /// Speech came back after a `pause` — any speculative work must be thrown away.
    case resumed
    /// Long silence: the user's turn is over.
    case endOfTurn
}

/// Turns a stream of speech probabilities (one per 32 ms chunk) into turn events.
/// Pure logic, no audio, no clock: unit-tested in VoiceCoreTests.
public struct TurnDetector: Sendable {
    public var config: TurnDetectorConfig

    private enum State: Sendable { case idle(voicedMs: Double), speaking(silenceMs: Double, paused: Bool) }
    private var state = State.idle(voicedMs: 0)

    public init(config: TurnDetectorConfig = .init()) { self.config = config }

    /// True between `speechStarted` and `endOfTurn`.
    public var isInUtterance: Bool {
        if case .speaking = state { return true }
        return false
    }

    public mutating func reset() { state = .idle(voicedMs: 0) }

    /// Feed one chunk's probability; returns at most one event. `assistantSpeaking` raises the bar for
    /// speech to start (see `bargeInMinSpeechMs`).
    public mutating func process(probability p: Float, assistantSpeaking: Bool = false) -> TurnEvent? {
        let isSpeech = p >= config.speechThreshold
        let isSilence = p < config.silenceThreshold
        switch state {
        case .idle(let voicedMs):
            guard isSpeech else {
                state = .idle(voicedMs: 0)
                return nil
            }
            let total = voicedMs + config.chunkMs
            if total >= (assistantSpeaking ? config.bargeInMinSpeechMs : config.minSpeechMs) {
                state = .speaking(silenceMs: 0, paused: false)
                return .speechStarted
            }
            state = .idle(voicedMs: total)
            return nil

        case .speaking(let silenceMs, let paused):
            if isSpeech {
                state = .speaking(silenceMs: 0, paused: false)
                return paused ? .resumed : nil
            }
            guard isSilence else { return nil }  // in-between probability: keep waiting
            let total = silenceMs + config.chunkMs
            if total >= config.endOfTurnSilenceMs {
                state = .idle(voicedMs: 0)
                return .endOfTurn
            }
            if !paused, total >= config.speculativeSilenceMs {
                state = .speaking(silenceMs: total, paused: true)
                return .pause
            }
            state = .speaking(silenceMs: total, paused: paused)
            return nil
        }
    }
}
