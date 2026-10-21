import Foundation

/// When the language model waits for the voice, once an answer's first sound was heard (`YieldsToVoice`).
///
/// The voice and the language model share the GPU. While the model writes the rest of the answer, the voice is barely
/// faster than real time: measured with `voice-cli voice-gaps` on the reference Mac (Gemma 4 26B, answers of five
/// sentences), what the speakers still had to play when the voice was done with a sentence was 0.10 s in the median at
/// the first boundary between two sentences, 0.41 s at the second, 0.65 s later. Each sentence then opens with a
/// near-silent breath of random length, which the voice takes time to produce while the speakers have nothing to play
/// beyond 0.3 s of it (`PipelineConfig.maxVoicePauseMs`): that is the silence heard between two sentences, 1 s or more
/// before 1 to 2.5 % of them. The model is 4 to 5 times faster than speech: it can wait a little. So it waits:
/// - while the voice opens a sentence with near-silence (`duringOpenings`): the voice has that sentence to say anyway;
/// - while the speakers have less than `minimum` left to play (the voice's lead), as long as the voice has another text
///   after the one it says: the model, a sentence ahead, never leaves the voice without text by waiting.
///
/// Before the first sound, the pipeline holds the model on its own, as before (`VoicePipeline.deliver`).
///
/// The model's pause is bounded (1.5 s, `MLXChatModel`): the pipeline says it again at every chunk of the voice while
/// the model should wait (a heartbeat), so that the model waits for the whole of a long opening (one token at most
/// slips through each time its pause runs out). Said only when a sentence started or was heard, a long opening could
/// outlast the pause, and the model wrote during the rest of it. If the voice produces nothing for half a second
/// meanwhile, the pipeline lets the model go (`VoicePipeline.watchVoice`).
struct VoiceLead {
    /// The model waits while the speakers have less than this left to play; nil = never for that.
    let minimum: Duration?
    /// The model waits while the voice opens a sentence with near-silence.
    let duringOpenings: Bool
    let sampleRate: Double

    /// When the speakers will be done with what they were given, playing it in real time.
    private var playhead: ContinuousClock.Instant?
    /// The text the voice says (`VoiceAudio.text`), and whether something of it was heard yet.
    private var sentence: Int?
    private var heard = false

    init(minimum: Duration?, duringOpenings: Bool, sampleRate: Double) {
        self.minimum = minimum
        self.duringOpenings = duringOpenings
        self.sampleRate = sampleRate
    }

    /// Whether it ever has the model wait.
    var isOn: Bool { minimum != nil || duringOpenings }

    /// `count` samples went to the speakers at `now`: they play them in real time, after what they still had.
    mutating func played(_ count: Int, at now: ContinuousClock.Instant) {
        playhead = max(now, playhead ?? now) + .seconds(Double(count) / sampleRate)
    }

    /// What the speakers still have to play at `now`.
    func lead(at now: ContinuousClock.Instant) -> Duration {
        guard let playhead, playhead > now else { return .zero }
        return playhead - now
    }

    /// The voice produced a chunk of `text` after the first sound (played or left out), the voice having been given
    /// `texts` texts so far: whether the model should wait now. A voice that cannot tell which text it says never has
    /// the model wait.
    mutating func update(text: Int?, audible: Bool, texts: Int, at now: ContinuousClock.Instant) -> Bool {
        guard let text else { return false }
        if text != sentence {
            sentence = text
            heard = false
        }
        if audible { heard = true }
        let opening = duringOpenings && !heard
        let short = minimum.map { text < texts - 1 && lead(at: now) < $0 } ?? false
        return opening || short
    }
}
