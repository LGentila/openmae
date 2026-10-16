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
    /// Tier forced in Settings › Advanced; nil = the tier recommended for this Mac.
    public var tierOverride: HardwareTier?
    /// Actions: reminders, calendar, timers and shortcuts. Off by default for now; the default of each tier
    /// is to be set from the benchmark (`voice-cli actions-bench`).
    public var actionsEnabled = false
    /// Shortcuts (of the "OpenMaé" folder) that Maé reads out and runs only after the user's "oui".
    public var shortcutsToConfirm: [String] = []
    /// Handing long tasks to Claude Code (with the actions on).
    public var claudeCode = AgentSettings()
    /// Searching the internet through the user's SearXNG (with the actions on or off).
    public var webSearch = WebSearchSettings()
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case audioMode, pushToTalk, tierOverride, actionsEnabled, shortcutsToConfirm, claudeCode, webSearch
    }

    /// Settings saved by an earlier version lack the newer fields: they get their default value.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audioMode = try c.decodeIfPresent(AudioMode.self, forKey: .audioMode) ?? .speakers
        pushToTalk = try c.decodeIfPresent(Bool.self, forKey: .pushToTalk) ?? false
        tierOverride = try c.decodeIfPresent(HardwareTier.self, forKey: .tierOverride)
        actionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .actionsEnabled) ?? false
        shortcutsToConfirm = try c.decodeIfPresent([String].self, forKey: .shortcutsToConfirm) ?? []
        claudeCode = try c.decodeIfPresent(AgentSettings.self, forKey: .claudeCode) ?? AgentSettings()
        webSearch = (try? c.decodeIfPresent(WebSearchSettings.self, forKey: .webSearch)) ?? WebSearchSettings()
    }
}

/// Searching the internet. Only the keywords the model writes leave the Mac, to the user's SearXNG and from there to
/// the search engines; the password of the protection in front of it is kept in the keychain, never here.
public struct WebSearchSettings: Sendable, Codable, Equatable {
    /// Off by default: what is searched leaves the Mac.
    public var enabled = false
    /// The user's SearXNG, as typed: "https://search.example.org".
    public var address = ""
    /// The user name of the password protection in front of it, if any.
    public var username = ""
    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled, address, username }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
    }

    /// The search can be offered to the model: switched on, with an address that can be one.
    public var isReady: Bool { enabled && SearXNGProvider.address(address) != nil }
}

/// What the settings' "Test" button found: how many results, how fast, or why it failed.
public enum WebSearchTest: Sendable, Codable, Equatable {
    case works(results: Int, seconds: Double)
    case failed(WebSearchError)
    /// The address cannot be one.
    case noAddress
}

/// The settings of an agent Maé hands tasks to.
public struct AgentSettings: Sendable, Codable, Equatable {
    /// How much the agent may do on its own.
    public enum PermissionMode: String, Sendable, Codable, CaseIterable {
        /// It changes the files of its folder; anything else (installing, running a command) is refused and
        /// reported at the end.
        case acceptEdits
        /// It decides for itself what is safe to do (Claude Code's "auto" mode).
        case auto
    }

    /// Off by default: what is handed to an agent leaves the Mac.
    public var enabled = false
    /// Read the task back and wait for the user's "oui" before sending it.
    public var review = true
    public var permissionMode = PermissionMode.acceptEdits
    /// Folders of the user's the agent may work in (paths), when they name one. Otherwise each task gets a new
    /// folder in ~/OpenMae.
    public var folders: [String] = []
    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled, review, permissionMode, folders }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        review = try c.decodeIfPresent(Bool.self, forKey: .review) ?? true
        permissionMode = (try? c.decodeIfPresent(PermissionMode.self, forKey: .permissionMode)) ?? .acceptEdits
        folders = try c.decodeIfPresent([String].self, forKey: .folders) ?? []
    }
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
    /// Download the missing models (after `.setupNeeded`), or resume after a pause or a failure.
    case downloadModels
    /// Pause the download: what is downloaded stays on disk.
    case pauseDownload
    /// Delete every model (Settings › Advanced): the assistant stops and offers to download them again.
    case deleteModels
    /// Delete the language models of the tiers not in use.
    case deleteUnusedModels
    /// Look again at what actions can use (the app came back to the front: a shortcut may have been added
    /// to the folder, a permission granted in System Settings, Claude Code signed in).
    case refreshActions
    /// Stop a task handed to an agent (the Stop button of the task list).
    case stopTask(UUID)
    /// Search once with the web search's settings and the password in the keychain (the "Test" button), switched on
    /// or not; answered by `.webSearchTested`.
    case testWebSearch
    /// A turn typed instead of spoken (debug tools).
    case typedTurn(String)
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
    /// A model that ships inside the app is missing (damaged app).
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
    /// The tier this Mac would get without the override of Settings › Advanced.
    public var recommendedTier: HardwareTier
    public var languageModel: String
    public var speechRecognition: String
    public var voice: String

    public init(chip: String, memoryGiB: Double, tier: HardwareTier, recommendedTier: HardwareTier,
                languageModel: String, speechRecognition: String, voice: String)
    {
        self.chip = chip
        self.memoryGiB = memoryGiB
        self.tier = tier
        self.recommendedTier = recommendedTier
        self.languageModel = languageModel
        self.speechRecognition = speechRecognition
        self.voice = voice
    }
}

/// What the first-launch screen shows before anything is downloaded.
public struct ModelSetup: Sendable, Codable, Equatable {
    public struct Item: Sendable, Codable, Equatable {
        public var role: ModelRole
        public var displayName: String
        public var license: String
        public var totalBytes: Int64
        /// Still to download (0 when already on disk).
        public var missingBytes: Int64

        public init(role: ModelRole, displayName: String, license: String, totalBytes: Int64, missingBytes: Int64) {
            self.role = role
            self.displayName = displayName
            self.license = license
            self.totalBytes = totalBytes
            self.missingBytes = missingBytes
        }
    }

    public var chip: String
    public var memoryGiB: Double
    public var tier: HardwareTier
    public var recommendedTier: HardwareTier
    public var items: [Item]
    /// What is left to download, in bytes (a download interrupted earlier counts for what it got).
    public var bytesToDownload: Int64
    /// What the download needs on disk (with a safety margin), and what is free.
    public var neededBytes: Int64
    public var availableBytes: Int64?
    /// The models folder, shown to the user.
    public var folder: String

    public init(chip: String, memoryGiB: Double, tier: HardwareTier, recommendedTier: HardwareTier, items: [Item],
                bytesToDownload: Int64, neededBytes: Int64, availableBytes: Int64?, folder: String)
    {
        self.chip = chip
        self.memoryGiB = memoryGiB
        self.tier = tier
        self.recommendedTier = recommendedTier
        self.items = items
        self.bytesToDownload = bytesToDownload
        self.neededBytes = neededBytes
        self.availableBytes = availableBytes
        self.folder = folder
    }

    public var hasEnoughSpace: Bool { availableBytes.map { $0 >= neededBytes } ?? true }
}

/// Space taken by the models (Settings › Advanced).
public struct ModelStorage: Sendable, Codable, Equatable {
    public var usedBytes: Int64
    /// Language models of the tiers not in use, which can be deleted.
    public var unusedBytes: Int64
    public var folder: String

    public init(usedBytes: Int64, unusedBytes: Int64, folder: String) {
        self.usedBytes = usedBytes
        self.unusedBytes = unusedBytes
        self.folder = folder
    }
}

/// What the actions can use, for the settings.
public struct ActionsStatus: Sendable, Codable, Equatable {
    public enum Access: String, Sendable, Codable { case notAsked, granted, denied }
    public var calendar: Access
    public var reminders: Access
    /// The shortcuts of the "OpenMaé" folder of the Shortcuts app.
    public var shortcuts: [String]
    /// Whether Claude Code is installed and signed in; nil until it was checked.
    public var claudeCode: AgentAvailability?

    public init(calendar: Access, reminders: Access, shortcuts: [String], claudeCode: AgentAvailability? = nil) {
        self.calendar = calendar
        self.reminders = reminders
        self.shortcuts = shortcuts
        self.claudeCode = claudeCode
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
    /// Models are missing (first launch, another tier chosen, models deleted): what has to be downloaded.
    /// The engine waits for `.downloadModels`.
    case setupNeeded(ModelSetup)
    case downloadProgress(DownloadProgress)
    /// The download stopped: nil when paused, otherwise why it failed.
    case downloadStopped(DownloadFailure?)
    /// Space taken by the models, sent when the assistant is ready and after a deletion.
    case storage(ModelStorage)
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
    /// What the actions can use; sent when the actions are on and whenever it changes.
    case actions(ActionsStatus)
    /// The tasks handed to agents, the most recent last; sent at start-up and at every change.
    case tasks([AgentTask])
    /// What `.testWebSearch` found.
    case webSearchTested(WebSearchTest)
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
