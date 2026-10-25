import Foundation

/// The delegation tools — deleguer_tache, etat_taches, completer_tache, annuler_tache — and the tasks they handle.
///
/// The tasks are kept here and on disk (`TaskStore`); each agent does the work through its `AgentConnector`. Nothing
/// is sent to an agent without the user's "oui", unless they turned the read-back off (then "annule", right after,
/// stops the task). An agent's own requests for permission are never granted here: Claude Code refuses what its
/// permission mode does not allow, and the refusals are reported at the end.
///
/// Offered with the actions or without them. Kept for the app's whole life, like the timers: a task goes on when
/// Claude Code or the actions are switched off or the tier changes, and only stops when the app quits.
public actor AgentTools: ToolProvider {
    public nonisolated let identifier = "agents"

    /// An agent Maé may hand tasks to.
    public struct Agent: Sendable {
        public var connector: any AgentConnector
        /// What it is good at: goes into the tool's description, so the model knows when to hand it something.
        public var description: String
        /// Read the task back and wait for the user's "oui" before sending it.
        public var review: Bool

        public init(connector: any AgentConnector, description: String = AgentCatalog.claudeCodeDescription,
                    review: Bool = true)
        {
            self.connector = connector
            self.description = description
            self.review = review
        }
    }

    /// How long an agent found ready is trusted to stay so: checking takes about a second for Claude Code, too long
    /// to repeat at every request. An agent found not ready is checked again each time (the user may have just fixed it).
    static let availabilityLifetime: TimeInterval = 300
    /// How much of an agent's final message the model gets to sum up.
    static let resultLimit = 1500

    private var agents: [Agent] = []
    /// Every connector ever set up, so that a task keeps its agent when the settings change while it runs.
    private var connectors: [String: any AgentConnector] = [:]
    /// The user's folders an agent may work in, named by the model; otherwise each task gets a new one in `workspace`.
    private var folders: [URL] = []
    private let workspace: URL
    private let store: TaskStore
    private let now: @Sendable () -> Date
    private var tasks: [AgentTask]
    /// The tasks this conversation handed over, followed up or asked about: a reference that shares a single word with
    /// one of them names it (`match`). Forgotten at a new conversation; none at the app's start.
    private var inConversation: Set<UUID> = []
    private var runs: [UUID: Task<Void, Never>] = [:]
    /// Tasks being stopped at the user's request.
    private var stopping: Set<UUID> = []
    private var availabilities: [String: (value: AgentAvailability, at: Date)] = [:]
    /// The tasks read back to the user, waiting for their "oui" (several when one request hands over several): shown on
    /// screen meanwhile, each sent by `perform`.
    private var drafts: [(call: ToolCall, id: UUID)] = []
    private var onChange: @Sendable ([AgentTask]) -> Void = { _ in }
    private var onEnd: @Sendable (AgentTask) -> Void = { _ in }
    private var onFirstTask: @Sendable () async -> Void = {}
    private var onRunning: @Sendable (Bool) -> Void = { _ in }
    /// What `onRunning` was last told.
    private var reportedRunning = false
    private var startedOne = false

    public init(store: TaskStore = TaskStore(), workspace: URL = AppIdentity.agentWorkspace,
                now: @escaping @Sendable () -> Date = { Date() })
    {
        self.store = store
        self.workspace = workspace
        self.now = now
        tasks = store.load(now: now())
    }

    /// `onChange`: the tasks to show (the most recent last). `onEnd`: a task finished or failed on its own (the app
    /// shows a notification and tells the conversation, `AgentPhrases.historyNote`; a task the user stopped gets
    /// neither). `onFirstTask`: once, when the first task starts
    /// (the app asks for notifications then; not awaited, so macOS's dialog does not hold up the answer).
    /// `onRunning`: true when a first task starts running, false once none runs any more (each ended, failed or was
    /// stopped), in that order; a task that goes on with a follow-up queued meanwhile does not end in between. The app
    /// keeps the Mac awake meanwhile: an agent's run pauses while the Mac sleeps.
    public func observe(onChange: @escaping @Sendable ([AgentTask]) -> Void,
                        onEnd: @escaping @Sendable (AgentTask) -> Void = { _ in },
                        onFirstTask: @escaping @Sendable () async -> Void = {},
                        onRunning: @escaping @Sendable (Bool) -> Void = { _ in })
    {
        self.onChange = onChange
        self.onEnd = onEnd
        self.onFirstTask = onFirstTask
        self.onRunning = onRunning
        reportedRunning = false
        publish()
    }

    /// The agents and folders of the settings. Returns true when what the model sees changed: the system prompt
    /// has to be computed again.
    @discardableResult
    public func configure(agents: [Agent], folders: [URL]) -> Bool {
        let before = (specs(), currentAddendum)
        self.agents = agents
        for agent in agents { connectors[agent.connector.agentID] = agent.connector }
        var seen = Set<String>()
        self.folders = folders.filter { seen.insert($0.lastPathComponent).inserted }
        return specs() != before.0 || currentAddendum != before.1
    }

    /// The tasks to show, the most recent last.
    public var visibleTasks: [AgentTask] { Array(tasks.suffix(30)) }

    /// Some task is still running (quitting the app would stop it).
    public var hasRunningTask: Bool { tasks.contains { $0.status == .running } }

    // MARK: - ToolProvider
    //
    // `async` even when there is nothing to wait for: a synchronous method would lose, in async callers, to the
    // protocol's default implementation.

    public func tools() async -> [ToolSpec] { specs() }

    public func promptAddendum() async -> String? { currentAddendum }

    /// Without the actions, the delegation's part says how to call its tool, with an example call
    /// (`AgentCatalog.promptAddendumWithoutActions`); with them, it is `promptAddendum()`.
    public func promptAddendum(actions: Bool, writeCall: @Sendable (ToolCall) async -> String?) async -> String? {
        guard !actions, currentAddendum != nil else { return currentAddendum }
        return AgentCatalog.promptAddendumWithoutActions(exampleCall: await writeCall(AgentCatalog.example.call))
    }

    private var currentAddendum: String? { agents.isEmpty ? nil : AgentCatalog.promptAddendum }

    /// Without the actions, a call to these tools written after words of the model's own that it did not mean from the
    /// start (`AgentCatalog.ignoredAfterWords`).
    public func ignoresAfterWords(_ tool: String, actions: Bool, callChanceAtStart: Double?) async -> Bool {
        AgentCatalog.ignoredAfterWords(tool, actions: actions, callChanceAtStart: callChanceAtStart)
    }

    /// `AgentCatalog.examples`, with the agent's name and its read-back setting; none for several agents (their calls
    /// would need the agent's name, which the examples do not show).
    public func exampleExchanges(now: Date) async -> [ChatMessage] {
        guard let agent = agents.first, agents.count == 1 else { return [] }
        return AgentCatalog.examples(now: now, agent: agent.connector.displayName, review: agent.review)
    }

    public func risk(of call: ToolCall) async -> ToolRisk {
        switch call.name {
        case AgentCatalog.delegateName: agent(for: call)?.review == false ? .undoable : .sensitive
        case AgentCatalog.statusName: .read
        default: .sensitive
        }
    }

    public func check(_ call: ToolCall, context: ToolContext) async throws {
        try AgentCatalog.check(call, context: context, agents: agents.map(\.connector.displayName),
                               folders: folderNames)
        let language = context.language
        switch call.name {
        case AgentCatalog.delegateName:
            guard let agent = agent(for: call) else {
                throw ToolRefusal(forModel: "Aucun agent n'est disponible.", spoken: AgentPhrases.notUnderstood(language),
                                  retryable: false)
            }
            let name = agent.connector.displayName
            switch await availability(of: agent) {
            case .ready: break
            case .notInstalled:
                throw ToolRefusal(forModel: "\(name) n'est pas installé sur ce Mac.",
                                  spoken: AgentPhrases.notInstalled(name, language), retryable: false)
            case .notLoggedIn:
                throw ToolRefusal(forModel: "\(name) n'est pas connecté au compte de l'utilisateur.",
                                  spoken: AgentPhrases.notLoggedIn(name, language), retryable: false)
            }
        case AgentCatalog.statusName:
            if let reference = call.text("reference"), !Self.meansLatest(reference) {
                _ = try find(reference, for: call.name, language)
            }
        default:
            _ = try find(call.text("reference"), for: call.name, language)
        }
    }

    public func summary(of call: ToolCall, context: ToolContext) async -> String {
        let language = context.language
        switch call.name {
        case AgentCatalog.delegateName:
            // Shown on screen while it waits for the "oui": the whole instruction can be read there.
            let task = newTask(call, status: .awaitingConfirmation, language: language)
            // The same call read back again replaces its draft; other drafts wait with it (the runner drops them when a
            // new request comes).
            for previous in drafts where previous.call == call { tasks.removeAll { $0.id == previous.id } }
            drafts.removeAll { $0.call == call }
            drafts.append((call, task.id))
            tasks.append(task)
            publish()
            return AgentPhrases.review(agent: task.agentName, title: task.title, folder: call.text("dossier"), language)
        case AgentCatalog.followUpName:
            guard let task = try? find(call.text("reference"), for: call.name, language) else {
                return AgentPhrases.unknownTask(language)
            }
            return AgentPhrases.followUpReview(agent: task.agentName, title: task.title, language)
        default:
            guard let task = try? find(call.text("reference"), for: call.name, language) else {
                return AgentPhrases.unknownTask(language)
            }
            return AgentPhrases.cancelReview(agent: task.agentName, title: task.title, language)
        }
    }

    public func dropped(_ call: ToolCall) async {
        guard let index = drafts.firstIndex(where: { $0.call == call }) else { return }
        let draft = drafts.remove(at: index)
        tasks.removeAll { $0.id == draft.id }
        publish()
    }

    public func perform(_ call: ToolCall, context: ToolContext) async throws -> ToolOutcome {
        switch call.name {
        case AgentCatalog.delegateName: try delegate(call, context)
        case AgentCatalog.statusName: try status(call, context)
        case AgentCatalog.followUpName: try followUp(call, context)
        default: try await cancel(call, context)
        }
    }

    public func undoneName(_ token: UndoToken, language: SpeechLanguage) async -> String? {
        guard let id = UUID(uuidString: token.id), let task = task(id), task.status == .running else { return nil }
        return AgentPhrases.undoneName(agent: task.agentName, language)
    }

    public func undo(_ token: UndoToken, context: ToolContext) async throws -> String {
        guard let id = UUID(uuidString: token.id), let task = task(id) else { return ActionPhrases.cannotUndo(context.language) }
        guard task.status == .running else { return AgentPhrases.alreadyOver(context.language) }
        await stop(id)
        return AgentPhrases.undone(agent: task.agentName, context.language)
    }

    /// A new conversation: the tasks the last one dealt with are an earlier conversation's now (`inConversation`).
    public func resetConversation() async {
        inConversation = []
    }

    // MARK: - The four tools

    private func delegate(_ call: ToolCall, _ context: ToolContext) throws -> ToolOutcome {
        let language = context.language
        var task: AgentTask
        if let index = drafts.firstIndex(where: { $0.call == call }), let drafted = self.task(drafts[index].id) {
            task = drafted
            drafts.remove(at: index)
        } else {
            drafts.removeAll { $0.call == call }
            task = newTask(call, status: .awaitingConfirmation, language: language)
            tasks.append(task)
        }
        let folder: URL
        do {
            if let name = call.text("dossier"), let named = folders.first(where: { $0.lastPathComponent == name }) {
                folder = named
            } else {
                folder = try newFolder(for: task)
            }
        } catch {
            tasks.removeAll { $0.id == task.id }
            publish()
            throw ToolRefusal(forModel: "Le dossier de la tâche n'a pas pu être créé : \(error.localizedDescription)",
                              spoken: AgentPhrases.couldNotStart(task.agentName, language), retryable: false)
        }
        let date = now()
        task.folder = folder.path
        task.status = .running
        task.startedAt = date
        task.updatedAt = date
        update(task)
        inConversation.insert(task.id)
        if !startedOne {
            startedOne = true
            let first = onFirstTask
            Task { await first() }
        }
        launch(task.id, message: nil)
        DebugLog.log("agents: \(task.reference) handed to \(task.agentName) in \(folder.path)")
        return ToolOutcome(
            spoken: AgentPhrases.started(language),
            forModel: ["tache": .string(task.reference), "statut": "en cours", "agent": .string(task.agentName),
                       "dossier": .string(folder.lastPathComponent)],
            undo: UndoToken(provider: identifier, id: task.id.uuidString))
    }

    private func status(_ call: ToolCall, _ context: ToolContext) throws -> ToolOutcome {
        let language = context.language
        let handed = tasks.filter { $0.status != .awaitingConfirmation }
        guard !handed.isEmpty else {
            return ToolOutcome(spoken: AgentPhrases.noTask(language), forModel: ["taches": []])
        }
        let task: AgentTask
        if let reference = call.text("reference"), !Self.meansLatest(reference) {
            task = try find(reference, for: call.name, language)
        } else {
            let running = handed.filter { $0.status == .running }
            if running.count > 1, let agent = running.first?.agentName {
                return ToolOutcome(spoken: AgentPhrases.severalRunning(agent: agent, titles: running.map(\.title), language),
                                   forModel: ["taches": .array(running.map { .object(describeForModel($0)) })])
            }
            task = running.first ?? handed.last!
        }
        inConversation.insert(task.id)
        return answer(about: task, language)
    }

    /// What to say about a task. A result (or an agent's error message) is summed up by the model: it came from
    /// outside, so the pipeline carries out nothing the model writes then.
    private func answer(about task: AgentTask, _ language: SpeechLanguage) -> ToolOutcome {
        let date = now()
        var forModel = describeForModel(task)
        switch task.status {
        case .running:
            let since = date.timeIntervalSince(task.startedAt ?? task.createdAt)
            return ToolOutcome(spoken: AgentPhrases.running(agent: task.agentName, for: since, step: task.lastStep, language),
                               forModel: .object(forModel))
        case .finished:
            forModel["resultat"] = .string(String((task.resultText ?? "").prefix(Self.resultLimit)))
            if !task.permissionDenials.isEmpty {
                forModel["refus"] = .array(task.permissionDenials.map(JSONValue.string))
            }
            let ago = date.timeIntervalSince(task.endedAt ?? task.updatedAt)
            return ToolOutcome(spoken: AgentPhrases.finished(agent: task.agentName, title: task.title, ago: ago, language),
                               forModel: .object(forModel), modelSpeaks: true)
        case .failed:
            if case .agent(let message) = task.failure {
                forModel["erreur"] = .string(String(message.prefix(Self.resultLimit)))
                return ToolOutcome(spoken: AgentPhrases.failed(agent: task.agentName, title: task.title, task.failure, language),
                                   forModel: .object(forModel), modelSpeaks: true)
            }
            return ToolOutcome(spoken: AgentPhrases.failed(agent: task.agentName, title: task.title, task.failure, language),
                               forModel: .object(forModel))
        case .cancelled:
            return ToolOutcome(spoken: AgentPhrases.stoppedByUser(title: task.title, language), forModel: .object(forModel))
        case .interrupted:
            return ToolOutcome(spoken: AgentPhrases.interrupted(title: task.title, language), forModel: .object(forModel))
        case .awaitingConfirmation:
            return ToolOutcome(spoken: AgentPhrases.awaitingYes(title: task.title, language), forModel: .object(forModel))
        }
    }

    private func followUp(_ call: ToolCall, _ context: ToolContext) throws -> ToolOutcome {
        let language = context.language
        var task = try find(call.text("reference"), for: call.name, language)
        inConversation.insert(task.id)
        let message = call.text("message") ?? ""
        task.followUps.append(message)
        if task.status == .running {
            task.queuedFollowUps.append(message)
            update(task)
            return ToolOutcome(spoken: AgentPhrases.followUpQueued(agent: task.agentName, language),
                               forModel: ["tache": .string(task.reference),
                                          "statut": "en cours : la demande lui sera envoyée dès qu'il aura fini"])
        }
        guard connectors[task.agentID] != nil else {
            throw ToolRefusal(forModel: "L'agent de cette tâche n'est plus configuré.",
                              spoken: AgentPhrases.couldNotStart(task.agentName, language), retryable: false)
        }
        let date = now()
        task.status = .running
        task.startedAt = date
        task.endedAt = nil
        task.failure = nil
        task.lastStep = nil
        task.updatedAt = date
        update(task)
        launch(task.id, message: message)
        return ToolOutcome(spoken: AgentPhrases.followUpSent(agent: task.agentName, title: task.title, language),
                           forModel: ["tache": .string(task.reference), "statut": "en cours"])
    }

    private func cancel(_ call: ToolCall, _ context: ToolContext) async throws -> ToolOutcome {
        let language = context.language
        let task = try find(call.text("reference"), for: call.name, language)
        guard task.status == .running else {
            return ToolOutcome(spoken: AgentPhrases.alreadyOver(language), forModel: .object(describeForModel(task)))
        }
        await stop(task.id)
        return ToolOutcome(spoken: AgentPhrases.cancelled(agent: task.agentName, title: task.title, language),
                           forModel: ["tache": .string(task.reference), "statut": "arrêtée"])
    }

    // MARK: - Running tasks

    /// Stops a task (the Stop button of the task list, "annule", annuler_tache); returns once it is stopped.
    public func stop(_ id: UUID) async {
        guard let task = task(id), task.status == .running, let connector = connectors[task.agentID] else { return }
        stopping.insert(id)
        DebugLog.log("agents: stopping \(task.reference)")
        await connector.cancel(task)
        await runs[id]?.value
    }

    /// Checks again whether each agent is installed and signed in (the app came back to the front).
    public func refreshAvailability() async -> [String: AgentAvailability] {
        var result: [String: AgentAvailability] = [:]
        for agent in agents {
            availabilities[agent.connector.agentID] = nil
            result[agent.connector.agentID] = await availability(of: agent)
        }
        return result
    }

    private func launch(_ id: UUID, message: String?) {
        guard let task = task(id), let connector = connectors[task.agentID] else { return }
        let updates: AsyncThrowingStream<AgentUpdate, Error>
        switch (message, task.externalRef) {
        case (let message?, _?):
            updates = connector.followUp(task, message: message)
        case (_?, nil):
            // The agent never got as far as opening a session (it was not signed in, say): start again, with
            // everything it was asked.
            var whole = task
            whole.instruction = ([task.instruction] + task.followUps).joined(separator: "\n\n")
            updates = connector.start(whole)
        case (nil, _):
            updates = connector.start(task)
        }
        runs[id] = Task {
            var failure: Error?
            do {
                for try await update in updates { self.apply(update, to: id) }
            } catch {
                failure = error
            }
            self.runEnded(id, error: failure)
        }
    }

    private func apply(_ update: AgentUpdate, to id: UUID) {
        guard var task = task(id) else { return }
        switch update {
        case .session(let reference):
            task.externalRef = reference
        case .step(let step):
            task.lastStep = step
        case .result(let result):
            if let cost = result.costUSD { task.costUSD = (task.costUSD ?? 0) + cost }
            for denial in result.permissionDenials where !task.permissionDenials.contains(denial) {
                task.permissionDenials.append(denial)
            }
            if stopping.contains(id), result.failure != nil {
                // Stopped by the user: Claude Code reports the interruption as an error, which it is not.
                task.status = .cancelled
            } else {
                if result.failure == nil { task.resultText = result.text }
                task.failure = result.failure
                task.status = result.failure == nil ? .finished : .failed
            }
            task.endedAt = now()
            DebugLog.log("agents: \(task.reference) \(task.status.rawValue)")
        }
        task.updatedAt = now()
        self.update(task)
    }

    private func runEnded(_ id: UUID, error: Error?) {
        runs[id] = nil
        let stopped = stopping.remove(id) != nil
        guard var task = task(id) else { return reportRunning() }
        let date = now()
        if stopped {  // no notification: the user asked for it
            if task.status == .running {
                task.status = .cancelled
                task.endedAt = date
            }
            task.queuedFollowUps = []
            task.updatedAt = date
            update(task)
            return
        }
        if task.status == .running {  // no result came
            task.status = .failed
            task.failure = error.map { .couldNotStart("\($0)") } ?? .stoppedWithoutResult
            task.endedAt = date
            task.updatedAt = date
            DebugLog.log("agents: \(task.reference) ended without a result\(error.map { ": \($0)" } ?? "")")
        }
        if !task.queuedFollowUps.isEmpty, task.status == .finished || task.status == .failed {
            let message = task.queuedFollowUps.joined(separator: "\n\n")
            task.queuedFollowUps = []
            task.status = .running
            task.failure = nil
            task.endedAt = nil
            task.lastStep = nil
            task.updatedAt = date
            update(task)
            launch(id, message: message)
            return
        }
        update(task)
        if task.status == .finished || task.status == .failed { onEnd(task) }
    }

    // MARK: - Helpers

    private func specs() -> [ToolSpec] {
        AgentCatalog.tools(agents: agents.map { ($0.connector.displayName, $0.description) }, folders: folderNames)
    }

    private var folderNames: [String] { folders.map(\.lastPathComponent) }

    private func agent(for call: ToolCall) -> Agent? {
        guard let name = call.text("agent") else { return agents.first }
        return agents.first { $0.connector.displayName == name } ?? agents.first
    }

    private func availability(of agent: Agent) async -> AgentAvailability {
        let id = agent.connector.agentID
        if let known = availabilities[id], case .ready = known.value,
           now().timeIntervalSince(known.at) < Self.availabilityLifetime
        {
            return known.value
        }
        let value = await agent.connector.availability()
        availabilities[id] = (value, now())
        return value
    }

    private func task(_ id: UUID) -> AgentTask? { tasks.first { $0.id == id } }

    private func newTask(_ call: ToolCall, status: AgentTask.Status, language: SpeechLanguage) -> AgentTask {
        let agent = agent(for: call)?.connector
        let number = (tasks.filter { $0.status != .awaitingConfirmation }.map(\.number).max() ?? 0) + 1
        return AgentTask(number: number, agentID: agent?.agentID ?? "", agentName: agent?.displayName ?? "",
                         title: call.text("titre") ?? "", instruction: call.text("consigne") ?? "", language: language,
                         status: status, createdAt: now())
    }

    /// A new folder for the task, in the workspace: "2026-10-16-site-de-la-boulangerie".
    private func newFolder(for task: AgentTask) throws -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let day = calendar.dateComponents([.year, .month, .day], from: task.createdAt)
        let base = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
            + (Self.slug(task.title).map { "-" + $0 } ?? "")
        var folder = workspace.appending(path: base, directoryHint: .isDirectory)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = workspace.appending(path: "\(base)-\(n)", directoryHint: .isDirectory)
            n += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// "Site de la boulangerie !" → "site-de-la-boulangerie": plain letters, digits and dashes.
    static func slug(_ title: String) -> String? {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        let words = folded.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        let slug = String(words.joined(separator: "-").prefix(48))
        return slug.isEmpty ? nil : slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func update(_ task: AgentTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task } else { tasks.append(task) }
        if task.status != .awaitingConfirmation { store.save(task) }
        publish()
    }

    private func publish() {
        onChange(visibleTasks)
        reportRunning()
    }

    /// Tells `onRunning` when it changed. An agent's run is over once its process has ended (`runEnded`), a little
    /// after the task got its result.
    private func reportRunning() {
        let running = hasRunningTask || !runs.isEmpty
        guard running != reportedRunning else { return }
        reportedRunning = running
        onRunning(running)
    }

    private func describeForModel(_ task: AgentTask) -> [String: JSONValue] {
        let date = now()
        var description: [String: JSONValue] = [
            "tache": .string(task.reference), "titre": .string(task.title), "agent": .string(task.agentName),
            "statut": .string(Self.statusWord(task)),
        ]
        if task.status == .running {
            description["depuis_minutes"] = .int(Int(date.timeIntervalSince(task.startedAt ?? task.createdAt) / 60))
            if let step = task.lastStep { description["derniere_etape"] = .string(AgentPhrases.describe(step, .french)) }
        } else if let end = task.endedAt {
            description["fini_il_y_a_minutes"] = .int(Int(date.timeIntervalSince(end) / 60))
        }
        if let folder = task.folder { description["dossier"] = .string(URL(fileURLWithPath: folder).lastPathComponent) }
        return description
    }

    private static func statusWord(_ task: AgentTask) -> String {
        switch task.status {
        case .awaitingConfirmation: "en attente du oui de l'utilisateur"
        case .running: "en cours"
        case .finished: "terminée"
        case .failed: task.failure == .notLoggedIn ? "échouée : l'agent n'est pas connecté au compte de l'utilisateur"
            : "échouée"
        case .cancelled: "arrêtée à la demande de l'utilisateur"
        case .interrupted: "interrompue : OpenMaé a été quitté pendant qu'elle tournait"
        }
    }

    // MARK: - Finding a task

    /// The task a reference names (`match`), for a call to `tool`. None: the model gets the list of tasks and one more
    /// try; for completer_tache, the new request it may have taken for a follow-up is handed over then, by a call to
    /// deleguer_tache (`ToolRefusal.correctedBy`).
    ///
    /// In voice-cli actions-bench, actions off, with « Poème et recette de crêpes » on disk, « Ajoute des tests
    /// automatiques à mon application de recettes » taken for a follow-up of « application de recettes »: with this
    /// sentence about deleguer_tache, Gemma 4 26B handed it over on its second try each time (it took it for a follow-up
    /// in 1 run of 10); Gemma 4 E4B, which takes it for one in every run, asked which application the user meant or said
    /// nothing, with this sentence or two others (0 of 10 each). With no task at all, the refusal stays as it was, without
    /// a second try: the 26B, actions off, takes « Ajoute un rendez-vous à la gare de Lyon vendredi à 10 h » for a
    /// follow-up in each of 10 runs, and with such a sentence it handed the appointment to Claude Code in each.
    private func find(_ reference: String?, for tool: String, _ language: SpeechLanguage) throws -> AgentTask {
        let handed = tasks.filter { $0.status != .awaitingConfirmation }
        guard !handed.isEmpty else {
            throw ToolRefusal(forModel: "Aucune tâche n'a été confiée.", spoken: AgentPhrases.noTask(language),
                              retryable: false)
        }
        if let task = Self.match(reference, in: handed, current: inConversation) { return task }
        let known = handed.suffix(8).map { "\($0.reference) « \($0.title) »" }.joined(separator: ", ")
        var refusal = ToolRefusal(forModel: "Aucune tâche ne correspond à « \(reference ?? "") ». Tâches : \(known).",
                                  spoken: AgentPhrases.unknownTask(language))
        if tool == AgentCatalog.followUpName {
            refusal.forModel += " Si l'utilisateur demande un nouveau travail pour l'agent (code, site, application, "
                + "recherche, fichiers, document), confie-le avec \(AgentCatalog.delegateName), sans poser de question ; "
                + "sinon, réponds-lui sans appel."
            refusal.correctedBy = [AgentCatalog.delegateName]
        }
        throw refusal
    }

    /// The task a reference names: its identifier ("d3"); "dernière" (the most recent one); or words of its title or
    /// instruction ("le site", "la boulangerie"): most of the reference's words, or at least one for a task of this
    /// conversation (`current`). Not a task that shares one ordinary word with it, as « Poème et recette de crêpes », a
    /// task of an earlier launch, did with « application de recette », a new request the model took for a follow-up.
    /// The best fit (a word of the title counts twice); when several fit equally, one of this conversation, then the
    /// most recent one.
    static func match(_ reference: String?, in tasks: [AgentTask], current: Set<UUID> = []) -> AgentTask? {
        let latest = tasks.max { $0.createdAt < $1.createdAt }
        guard let reference, !meansLatest(reference) else { return latest }
        let words = keywords(reference).uniqued()
        if words.count == 1, let word = words.first, word.hasPrefix("d"), let number = Int(word.dropFirst()) {
            return tasks.first { $0.number == number }
        }
        var best: (task: AgentTask, score: Int, current: Bool)?
        for task in tasks {  // the oldest first
            let title = Set(keywords(task.title))
            let instruction = Set(keywords(task.instruction))
            let found = words.filter { title.contains($0) || instruction.contains($0) }.count
            let isCurrent = current.contains(task.id)
            guard found * 2 > words.count || (found > 0 && isCurrent) else { continue }
            let score = words.reduce(0) { $0 + (title.contains($1) ? 2 : instruction.contains($1) ? 1 : 0) }
            guard let previous = best else {
                best = (task, score, isCurrent)
                continue
            }
            if score > previous.score || (score == previous.score && (isCurrent || !previous.current)) {
                best = (task, score, isCurrent)
            }
        }
        return best?.task
    }

    /// "", "dernière", "la dernière tâche", "celle-là": the most recent task.
    static func meansLatest(_ reference: String) -> Bool {
        let words = keywords(reference)
        return words.isEmpty || words.allSatisfy { ["dernier", "derniere", "last", "latest", "celle", "cette", "ca"].contains($0) }
    }

    private static let stopWords: Set<String> = [
        "le", "la", "les", "l", "de", "du", "des", "d", "un", "une", "et", "ou", "a", "au", "aux", "en", "pour", "par",
        "sur", "dans", "avec", "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses", "ce", "cet", "cette", "ces",
        "que", "qui", "tache", "taches", "travail", "truc", "chose", "the", "of", "for", "my", "task", "claude", "code",
    ]

    /// Lower case, no accents, no small words, no plural mark: "Les sites de ma sœur" → ["site", "soeur"].
    static func keywords(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
            .replacingOccurrences(of: "œ", with: "oe").replacingOccurrences(of: "æ", with: "ae")
        return folded.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
            .filter { !stopWords.contains($0) }
            .map { $0.count > 3 && ($0.hasSuffix("s") || $0.hasSuffix("x")) ? String($0.dropLast()) : $0 }
    }
}
