import Foundation

// Delegation: a long or heavy request ("lance le développement d'un site pour la boulangerie de ma sœur") is handed
// to an agent the user installed — Claude Code — which works on its own, usually with an online model: that such a
// task leaves the Mac is the point. Maé reads the task back and waits for the user's "oui", follows it, says where it
// stands when asked, and a notification (never the voice) tells when it is over.
//
// The tasks and the tools that hand them over live here (AgentTools.swift); each kind of agent is reached through
// an `AgentConnector` (Claude Code's runs its command, in VoiceEngineApple).

/// A task handed to an agent. Saved as JSON, one file per task, at every change.
public struct AgentTask: Sendable, Codable, Identifiable, Equatable {
    public enum Status: String, Sendable, Codable {
        /// Read back to the user, waiting for their "oui": nothing was sent yet.
        case awaitingConfirmation
        case running
        case finished
        case failed
        /// Stopped at the user's request.
        case cancelled
        /// OpenMaé quit while the agent was working: the task stopped with it.
        case interrupted

        /// Over, one way or another.
        public var isOver: Bool { self != .awaitingConfirmation && self != .running }
    }

    public enum Failure: Sendable, Codable, Equatable {
        /// The agent's command could not be started.
        case couldNotStart(String)
        /// The agent is not signed in to its account.
        case notLoggedIn
        /// The agent reported an error: its message.
        case agent(String)
        /// The agent stopped without giving a result.
        case stoppedWithoutResult
    }

    public var id: UUID
    /// Gives the reference the model uses ("d3"), shown nowhere else.
    public var number: Int
    public var agentID: String
    /// "Claude Code": shown and said.
    public var agentName: String
    /// Four to six words, written by the model: "site de la boulangerie".
    public var title: String
    /// What the agent was asked, written by the model so that it stands on its own (the agent does not see the
    /// conversation).
    public var instruction: String
    /// What was added afterwards (completer_tache), in order.
    public var followUps: [String]
    /// Added while the agent was still working: sent once its current run is over.
    public var queuedFollowUps: [String]
    /// Where the agent works.
    public var folder: String?
    /// The language of the conversation the task came from: notifications and answers about it use it.
    public var language: SpeechLanguage
    public var status: Status
    public var createdAt: Date
    public var updatedAt: Date
    /// When the agent started (the user's "oui"): "il y travaille depuis 12 minutes".
    public var startedAt: Date?
    public var endedAt: Date?
    /// What the agent is doing now.
    public var lastStep: AgentStep?
    /// The agent's final message, in full.
    public var resultText: String?
    public var failure: Failure?
    /// What the agent tried to do and was not allowed to (mostly commands: "npm install").
    public var permissionDenials: [String]
    /// The agent's own reference: Claude Code's session, which a follow-up resumes.
    public var externalRef: String?
    /// What the agent says it cost, in dollars (Claude Code's estimate), over all its runs.
    public var costUSD: Double?

    public init(id: UUID = UUID(), number: Int, agentID: String, agentName: String, title: String, instruction: String,
                folder: String? = nil, language: SpeechLanguage = .french, status: Status, createdAt: Date)
    {
        self.id = id
        self.number = number
        self.agentID = agentID
        self.agentName = agentName
        self.title = title
        self.instruction = instruction
        self.followUps = []
        self.queuedFollowUps = []
        self.folder = folder
        self.language = language
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.permissionDenials = []
    }

    /// How the model refers to the task: "d3".
    public var reference: String { "d\(number)" }
}

/// What an agent is doing, as its reports tell it (read from the tools it uses).
public enum AgentStep: Sendable, Codable, Equatable {
    /// Writes a new file (its name).
    case creates(String)
    /// Changes a file.
    case edits(String)
    /// Reads a file.
    case reads(String)
    /// Runs a command in the terminal.
    case runsCommand
    /// Looks through the files.
    case searchesFiles
    /// Looks something up on the web, or reads a page.
    case browsesWeb
    /// The step of its to-do list it is on, in its own words ("Création de la page d'accueil").
    case step(String)
}

/// Whether an agent can take a task now.
public enum AgentAvailability: Sendable, Codable, Equatable {
    case ready(version: String?)
    case notInstalled
    case notLoggedIn
}

/// What an agent reports while it works.
public enum AgentUpdate: Sendable, Equatable {
    /// The agent's reference for the task (Claude Code's session id).
    case session(String)
    case step(AgentStep)
    /// The end of a run.
    case result(AgentResult)
}

/// How a run ended.
public struct AgentResult: Sendable, Equatable {
    /// The agent's final message (or its error message).
    public var text: String
    /// nil when it succeeded.
    public var failure: AgentTask.Failure?
    public var costUSD: Double?
    public var permissionDenials: [String]

    public init(text: String, failure: AgentTask.Failure? = nil, costUSD: Double? = nil, permissionDenials: [String] = []) {
        self.text = text
        self.failure = failure
        self.costUSD = costUSD
        self.permissionDenials = permissionDenials
    }
}

/// One kind of agent: Claude Code today; agents speaking ACP (OpenClaw, Hermes…) and Hermes's own API later.
public protocol AgentConnector: Sendable {
    /// Stable identifier, e.g. "claude-code".
    var agentID: String { get }
    /// "Claude Code".
    var displayName: String { get }
    /// Whether it is installed and signed in.
    func availability() async -> AgentAvailability
    /// Starts the task: the agent gets its instruction. The stream ends after the run's `.result`, or throws when
    /// the agent cannot be started.
    func start(_ task: AgentTask) -> AsyncThrowingStream<AgentUpdate, Error>
    /// Sends a follow-up to a task whose previous run is over: the agent takes its work up where it left it.
    func followUp(_ task: AgentTask, message: String) -> AsyncThrowingStream<AgentUpdate, Error>
    /// Stops the task's run, if it has one; returns once it is stopped.
    func cancel(_ task: AgentTask) async
}

/// The tasks on disk: ~/Library/Application Support/OpenMaé/Tasks/<id>.json.
public struct TaskStore: Sendable {
    public let folder: URL

    public init(folder: URL = AppIdentity.tasksDirectory) {
        self.folder = folder
    }

    /// Every saved task, the oldest first. A task still running was cut off when the app quit: it is marked
    /// interrupted. One still waiting for its "oui" was never sent: it is forgotten.
    public func load(now: Date = Date()) -> [AgentTask] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        var tasks: [AgentTask] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), var task = try? Self.decoder.decode(AgentTask.self, from: data)
            else { continue }
            switch task.status {
            case .awaitingConfirmation:
                delete(task.id)
                continue
            case .running:
                task.status = .interrupted
                task.endedAt = now
                task.updatedAt = now
                save(task)
            default: break
            }
            tasks.append(task)
        }
        return tasks.sorted { $0.createdAt < $1.createdAt }
    }

    public func save(_ task: AgentTask) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.encoder.encode(task).write(to: file(task.id), options: .atomic)
        } catch {
            DebugLog.log("tasks: could not save \(task.reference): \(error)")
        }
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
    }

    private func file(_ id: UUID) -> URL {
        folder.appending(path: id.uuidString + ".json", directoryHint: .notDirectory)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
