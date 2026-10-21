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

/// How the user starts talking to Maé.
public enum ListeningMode: String, Sendable, Codable, CaseIterable {
    /// Maé answers whoever speaks; the end of a sentence is detected from the silence that follows it.
    case handsFree
    /// Maé sleeps until a sentence starts with the wake phrase (« OK Maé »), then listens to any voice for a few
    /// seconds after each answer.
    case wakeWord
    /// The user holds a key (or a button) while speaking, instead of the engine detecting the end of their sentence.
    case pushToTalk
}

/// The few settings the interface can change.
public struct AssistantSettings: Sendable, Codable, Equatable {
    public var audioMode = AudioMode.speakers
    public var listening = ListeningMode.handsFree
    /// In the wake-word mode, the interface writes what Maé heard and made of it in a file on this Mac, for the user's
    /// tests (see `WakeDecision`).
    public var wakeLog = false
    /// Tier forced in Settings › Advanced; nil = the tier recommended for this Mac.
    public var tierOverride: HardwareTier?
    /// Actions: reminders, calendar, timers and shortcuts. Off by default for now; the default of each tier
    /// is to be set from the benchmark (`voice-cli actions-bench`).
    public var actionsEnabled = false
    /// Shortcuts (of the "OpenMaé" folder) that Maé reads out and runs only after the user's "oui".
    public var shortcutsToConfirm: [String] = []
    /// Handing long tasks to Claude Code (with the actions on or off).
    public var claudeCode = AgentSettings()
    /// Searching the internet, through Brave Search or the user's SearXNG (with the actions on or off).
    public var webSearch = WebSearchSettings()
    /// The built-in sources (the weather, currencies and cryptos, travel times; with the actions on or off). Off by
    /// default: a place, a currency or a crypto leaves the Mac for Open-Meteo, Apple, the ECB's rates or CoinGecko.
    public var builtInSources = false
    /// What Maé remembers when the user asks her to, and the journal of past exchanges (`MemorySettings`).
    public var memory = MemorySettings()
    public init() {}

    /// `pushToTalk`: how earlier versions, which only knew hands-free and push-to-talk, saved the way of talking. It is
    /// still written, so that an earlier version (on this Mac, or the iPhone app) keeps push-to-talk.
    private enum CodingKeys: String, CodingKey {
        case audioMode, listening, pushToTalk, wakeLog, tierOverride, actionsEnabled, shortcutsToConfirm, claudeCode,
             webSearch, builtInSources, memory
    }

    /// Settings saved by an earlier version lack the newer fields: they get their default value.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audioMode = try c.decodeIfPresent(AudioMode.self, forKey: .audioMode) ?? .speakers
        if let listening = try? c.decodeIfPresent(ListeningMode.self, forKey: .listening) {
            self.listening = listening
        } else {
            listening = try c.decodeIfPresent(Bool.self, forKey: .pushToTalk) == true ? .pushToTalk : .handsFree
        }
        wakeLog = try c.decodeIfPresent(Bool.self, forKey: .wakeLog) ?? false
        tierOverride = try c.decodeIfPresent(HardwareTier.self, forKey: .tierOverride)
        actionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .actionsEnabled) ?? false
        shortcutsToConfirm = try c.decodeIfPresent([String].self, forKey: .shortcutsToConfirm) ?? []
        claudeCode = try c.decodeIfPresent(AgentSettings.self, forKey: .claudeCode) ?? AgentSettings()
        webSearch = (try? c.decodeIfPresent(WebSearchSettings.self, forKey: .webSearch)) ?? WebSearchSettings()
        builtInSources = try c.decodeIfPresent(Bool.self, forKey: .builtInSources) ?? false
        memory = (try? c.decodeIfPresent(MemorySettings.self, forKey: .memory)) ?? MemorySettings()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(audioMode, forKey: .audioMode)
        try c.encode(listening, forKey: .listening)
        try c.encode(listening == .pushToTalk, forKey: .pushToTalk)
        try c.encode(wakeLog, forKey: .wakeLog)
        try c.encodeIfPresent(tierOverride, forKey: .tierOverride)
        try c.encode(actionsEnabled, forKey: .actionsEnabled)
        try c.encode(shortcutsToConfirm, forKey: .shortcutsToConfirm)
        try c.encode(claudeCode, forKey: .claudeCode)
        try c.encode(webSearch, forKey: .webSearch)
        try c.encode(builtInSources, forKey: .builtInSources)
        try c.encode(memory, forKey: .memory)
    }
}

/// How long the journal keeps past exchanges.
public enum MemoryRetention: String, Sendable, Codable, CaseIterable {
    case thirtyDays, oneYear, unlimited

    /// nil: kept until the user erases them.
    public var days: Int? {
        switch self {
        case .thirtyDays: 30
        case .oneYear: 365
        case .unlimited: nil
        }
    }
}

/// Maé's memory, kept on this Mac only (Application Support/<name>/Memory), never sent anywhere: a sheet of what the user
/// asked her to remember, which goes into the beginning of each conversation, and, with its own switch, a journal of past
/// exchanges she can search when asked ("qu'est-ce que je t'avais dit sur…").
public struct MemorySettings: Sendable, Codable, Equatable {
    /// Off by default. On, the sheet is on.
    public var enabled = false
    /// The journal of past exchanges, off by default even with the memory on.
    public var journal = false
    public var retention = MemoryRetention.thirtyDays
    /// Searching the journal by meaning too (embeddings): off, and not built while the plain search is enough.
    public var semanticSearch = false
    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled, journal, retention, semanticSearch }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        journal = try c.decodeIfPresent(Bool.self, forKey: .journal) ?? false
        retention = (try? c.decodeIfPresent(MemoryRetention.self, forKey: .retention)) ?? .thirtyDays
        semanticSearch = try c.decodeIfPresent(Bool.self, forKey: .semanticSearch) ?? false
    }

    /// The journal is written and searched: the memory and the journal both switched on.
    public var journalOn: Bool { enabled && journal }
}

/// What the memory page shows (`AssistantEvent.memory`).
public struct MemoryOverview: Sendable, Codable, Equatable {
    /// The sheet, one entry per line, in the order they were added.
    public var entries: [String]
    /// Characters the sheet takes, and its limit (`MemorySheet.capacity`).
    public var characters: Int
    public var capacity: Int
    /// Exchanges in the journal.
    public var exchanges: Int
    /// The memory's folder, shown to the user.
    public var folder: String

    public init(entries: [String], characters: Int, capacity: Int, exchanges: Int, folder: String) {
        self.entries = entries
        self.characters = characters
        self.capacity = capacity
        self.exchanges = exchanges
        self.folder = folder
    }
}

/// Where the searches go, in the order the settings offer them: Brave Search first.
public enum WebSearchSource: String, Sendable, Codable, CaseIterable {
    /// Brave Search's API, with the user's own key (`BraveSearchProvider`).
    case brave
    /// The user's own SearXNG (`SearXNGProvider`).
    case searxng
}

/// Searching the internet. Only the keywords the model writes leave the Mac, to Brave Search, or to the user's SearXNG
/// and from there to the search engines. Brave's key and the password of the protection in front of the SearXNG are
/// kept in the keychain, never here.
public struct WebSearchSettings: Sendable, Codable, Equatable {
    /// Off by default: what is searched leaves the Mac.
    public var enabled = false
    public var source = WebSearchSource.brave
    /// A Brave Search key is in the keychain (the key itself is never here).
    public var braveKeySaved = false
    /// The user's SearXNG, as typed: "https://search.example.org".
    public var address = ""
    /// The user name of the password protection in front of it, if any.
    public var username = ""
    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled, source, braveKeySaved, address, username }

    /// Settings of a version that only knew SearXNG keep it when it has an address.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        braveKeySaved = try c.decodeIfPresent(Bool.self, forKey: .braveKeySaved) ?? false
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        source = (try? c.decodeIfPresent(WebSearchSource.self, forKey: .source)) ?? (address.isEmpty ? .brave : .searxng)
    }

    /// The search can be offered to the model: switched on, with its source set up (a key saved for Brave Search, an
    /// address that can be one for SearXNG).
    public var isReady: Bool {
        guard enabled else { return false }
        switch source {
        case .brave: return braveKeySaved
        case .searxng: return SearXNGProvider.address(address) != nil
        }
    }
}

/// What the settings' "Test" button found: how many results, how fast, or why it failed.
public enum WebSearchTest: Sendable, Codable, Equatable {
    case works(results: Int, seconds: Double)
    case failed(WebSearchError)
    /// The source is not set up: no key saved for Brave Search, no address that can be one for SearXNG.
    case notSetUp
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
    /// Look again at what actions can use, and at Claude Code (the app came back to the front: a shortcut may have
    /// been added to the folder, a permission granted in System Settings, Claude Code installed or signed in).
    case refreshActions
    /// Stop a task handed to an agent (the Stop button of the task list).
    case stopTask(UUID)
    /// Search once with the web search's settings and the key or password in the keychain (the "Test" button),
    /// switched on or not; answered by `.webSearchTested`.
    case testWebSearch
    /// Read the memory again for its settings page; answered by `.memory`.
    case refreshMemory
    /// Forget one entry of the sheet (the memory page's delete button); answered by `.memory`.
    case forgetMemoryEntry(String)
    /// Erase the journal of past exchanges ("Clear history"); answered by `.memory`.
    case clearMemoryJournal
    /// Erase the sheet and the journal ("Erase everything"); answered by `.memory`.
    case eraseMemory
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

    public init(calendar: Access, reminders: Access, shortcuts: [String]) {
        self.calendar = calendar
        self.reminders = reminders
        self.shortcuts = shortcuts
    }
}

/// In the wake-word mode, what Maé made of a sentence she heard, for the log the user keeps while trying the mode.
public struct WakeDecision: Sendable, Codable, Equatable {
    public enum Moment: String, Sendable, Codable {
        /// She was waiting for the phrase.
        case asleep
        /// She was thinking or speaking: only the phrase interrupts her.
        case busy
        /// She was listening to any voice: after the phrase alone, or after an answer.
        case awake
    }

    public var date: Date
    public var moment: Moment
    /// The start of what speech recognition wrote.
    public var heard: String
    /// Taken as meant for Maé: it started with the phrase, or Maé was awake.
    public var accepted: Bool

    public init(date: Date = Date(), moment: Moment, heard: String, accepted: Bool) {
        self.date = date
        self.moment = moment
        self.heard = Self.excerpt(heard)
        self.accepted = accepted
    }

    /// The first twelve words: enough to tell the user's sentence from the TV's.
    static func excerpt(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.prefix(12).joined(separator: " ") + (words.count > 12 ? "…" : "")
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
    /// What the user has said so far, while they speak (about twice a second): shown in place of the words before it,
    /// until `userTranscript` replaces it. Never kept in the history.
    case partialTranscript(String)
    /// What the user said (sent once their turn is over).
    case userTranscript(String, SpeechLanguage)
    /// A piece of the answer, sent when it goes to the voice.
    case assistantPiece(String)
    case turnFinished(TurnMetrics)
    case bargeIn(stopMs: Double, detectionMs: Double)
    /// Wake-word mode: Maé listens to any voice (true: after the phrase alone, and for a few seconds after each
    /// answer), or waits for the phrase (false).
    case awake(Bool)
    /// Wake-word mode: what Maé made of a sentence she heard.
    case wakeDecision(WakeDecision)
    /// The engine started a new conversation, whoever asked for it: an interface's `newConversation` (the Mac's or an
    /// iPhone's: each one clears its transcript at once too), the tools that came or went (the actions switched on or
    /// off, or, with them off, Claude Code, the web search or the built-in sources, only when the model sees the change:
    /// not for the sources on a tier that does not offer them, nor for a search without its key), or another language
    /// model loaded in place of the one that had the conversation (another tier chosen, the models deleted and
    /// downloaded again: sent once the new one is ready). The interfaces clear their transcript, whose exchanges the
    /// model no longer has; nothing of them comes after this event, and everything of the new conversation does.
    /// Relayed only to the iPhones and iPads that list it (`LinkMessage.conversationClearedFeature`).
    case conversationCleared
    /// Sound levels (0…1), about 20 times per second, for the animated indicator.
    case levels(input: Float, output: Float)
    case diagnostics(EngineDiagnostics)
    /// What the actions can use; sent when the actions are on and whenever it changes.
    case actions(ActionsStatus)
    /// Whether Claude Code is installed and signed in, whatever the actions; sent while the engine runs: once it is
    /// ready, when the app comes back to the front, and when Claude Code is switched on or off. Switched off, only
    /// whether it is installed is looked at: nil when it is.
    case claudeCode(AgentAvailability?)
    /// The tasks handed to agents, the most recent last; sent at start-up and at every change.
    case tasks([AgentTask])
    /// What `.testWebSearch` found.
    case webSearchTested(WebSearchTest)
    /// What Maé remembers, for the memory page: sent at start-up, after `.refreshMemory` and after every change.
    case memory(MemoryOverview)
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
