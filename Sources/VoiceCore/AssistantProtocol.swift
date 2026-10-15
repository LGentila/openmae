import Foundation

// The contract between the app's interface and the engine.
//
// The interface never calls the engine directly: it sends `AssistantCommand`s and displays the
// `AssistantEvent`s it receives. Everything here is plain data (Codable), so the engine could later
// run in a separate process — for instance behind a Windows/Linux interface written with another
// toolkit — by carrying these values over a pipe as JSON, without changing either side.

/// How the sound comes out, which decides whether echo cancellation is needed.
public enum AudioMode: String, Sendable, Codable, CaseIterable {
    /// Speakers: Apple's voice processing removes the assistant's own voice from the microphone.
    case speakers
    /// Headphones: no echo to remove, so the raw microphone is used (no ducking of other apps).
    case headphones
}

/// The few settings the interface can change.
public struct AssistantSettings: Sendable, Codable, Equatable {
    public var audioMode = AudioMode.speakers
    /// The user holds a key (or a button) while speaking, instead of the engine detecting the end of
    /// their sentence.
    public var pushToTalk = false
    public init() {}
}

public enum AssistantCommand: Sendable, Codable, Equatable {
    /// Load the models and start listening.
    case start(AssistantSettings)
    case updateSettings(AssistantSettings)
    /// Push-to-talk key (or button) pressed or released.
    case talkKey(pressed: Bool)
    /// Silence the assistant (click on the indicator, Escape key).
    case stopSpeaking
    /// Forget the conversation.
    case newConversation
    /// Release the microphone and the speakers (the app is quitting).
    case shutdown
}

/// What the engine is loading, shown during start-up.
public enum LoadingStep: String, Sendable, Codable {
    case microphone, speechRecognition, languageModel, voice
}

/// Problems that stop the assistant; the interface explains them and offers a way out.
public enum AssistantProblem: Sendable, Codable, Equatable {
    /// The user refused access to the microphone (or it is restricted by the administrator).
    case microphoneDenied
    /// Not an Apple Silicon Mac, or less than 8 GB of memory.
    case unsupportedMac(chip: String, memoryGiB: Double)
    /// A model is not on disk.
    case modelMissing(String)
    /// The microphone or the speakers could not be opened.
    case audioDevice(String)
    case engine(String)
}

/// What the engine runs on, shown in the debug panel and the settings.
public struct EngineInfo: Sendable, Codable, Equatable {
    public var chip: String
    public var memoryGiB: Double
    public var tier: HardwareTier
    public var languageModel: String
    public var speechRecognition: String
    public var voice: String

    public init(chip: String, memoryGiB: Double, tier: HardwareTier, languageModel: String,
                speechRecognition: String, voice: String)
    {
        self.chip = chip
        self.memoryGiB = memoryGiB
        self.tier = tier
        self.languageModel = languageModel
        self.speechRecognition = speechRecognition
        self.voice = voice
    }
}

/// Live measurements for the debug panel.
public struct EngineDiagnostics: Sendable, Codable, Equatable {
    /// Memory used by the whole app, in GB.
    public var memoryGB: Double?
    /// Last answer: tokens of the conversation the model already had in memory / had to compute.
    public var reusedTokens: Int?
    public var computedTokens: Int?
    public var prefillMs: Double?
    /// Times the model had to recompute the whole conversation in the foreground (should stay at 0).
    public var cacheRebuilds = 0
    /// Times the speakers ran out of audio in the middle of an answer (audible gaps).
    public var audioUnderruns = 0
    public var audioMode = AudioMode.speakers
    public var inputDevice: String?
    public var outputDevice: String?
    /// Microphone format as delivered by the system, e.g. "48 kHz · 3 canaux".
    public var inputSampleRate: Double?
    public var inputChannels: Int?
    public init() {}
}

public enum AssistantEvent: Sendable, Codable {
    case loading(LoadingStep)
    case ready(EngineInfo)
    case state(PipelineState)
    /// What the user said (sent once their turn is over).
    case userTranscript(String, SpeechLanguage)
    /// A piece of the answer, sent when it goes to the voice.
    case assistantPiece(String)
    case turnFinished(TurnMetrics)
    case bargeIn(stopMs: Double, detectionMs: Double)
    /// Sound levels (0…1), about 20 times per second, for the animated indicator.
    case levels(input: Float, output: Float)
    case diagnostics(EngineDiagnostics)
    case problem(AssistantProblem)
    /// Something went wrong for one turn; the assistant keeps going.
    case warning(String)
}

/// One way to reach the engine: in the same process today (`AssistantHost`), possibly a separate
/// process later. The interface only knows this protocol.
public protocol AssistantConnection: Sendable {
    /// Single consumer: the interface.
    var events: AsyncStream<AssistantEvent> { get }
    /// Commands are handled in the order they are sent.
    func send(_ command: AssistantCommand)
}
