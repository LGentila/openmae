import Foundation
import Observation
import VoiceCore

/// One line of the live transcript.
struct TranscriptEntry: Identifiable, Equatable {
    enum Speaker { case user, assistant }
    let id = UUID()
    let speaker: Speaker
    var text: String
    var language: SpeechLanguage?
    /// The user is speaking: their words are not transcribed yet, or only provisionally (`text` holds what they have
    /// said so far, replaced once their turn is over).
    var pending = false
    /// The assistant was cut off.
    var interrupted = false
}

/// Everything the screens show, rebuilt from the engine's events. The screens never talk to the engine
/// directly: they call the methods below, which send commands.
@MainActor
@Observable
final class AssistantModel {
    enum Phase: Equatable {
        case loading(LoadingStep?)
        /// Models to download first (first launch, another tier, models deleted).
        case setup(ModelSetup)
        case ready
        case problem(AssistantProblem)
    }

    private(set) var phase = Phase.loading(nil) {
        didSet {
            guard phase != .ready else { return }
            talkKeyDown = false
            isShortcutExchange = false
            isAwake = false
        }
    }
    /// The download in progress, or where it stopped (pause, failure); nil before it starts.
    private(set) var download: DownloadProgress?
    private(set) var isDownloading = false
    private(set) var downloadFailure: DownloadFailure?
    /// Space taken by the models (Settings › Advanced).
    private(set) var storage: ModelStorage?
    /// The tier this Mac would get on its own (the "Automatic" choice of Settings › Advanced).
    private(set) var recommendedTier: HardwareTier?
    private(set) var state = PipelineState.listening
    private(set) var transcript: [TranscriptEntry] = []
    /// Completed turns, for the debug panel (the most recent last).
    private(set) var turns: [TurnMetrics] = []
    /// Barge-ins: start of the user's speech → assistant silent, in ms.
    private(set) var bargeIns: [Double] = []
    private(set) var info: EngineInfo?
    private(set) var diagnostics = EngineDiagnostics()
    private(set) var inputLevel: Float = 0
    private(set) var outputLevel: Float = 0
    private(set) var lastWarning: String?
    /// What the actions can use (access to the calendar and reminders, shortcuts); nil while they are off.
    private(set) var actions: ActionsStatus?
    /// Whether Claude Code is installed and signed in, whatever the actions; nil until the engine checked it, and while
    /// Claude Code is off but installed (only whether it is installed is looked at then).
    private(set) var claudeCode: AgentAvailability?
    /// The tasks handed to Claude Code, the most recent last.
    private(set) var tasks: [AgentTask] = []
    /// What the web search's "Test" button found; nil before a test, or after a change of its settings.
    private(set) var webSearchTest: WebSearchTest?
    private(set) var isTestingWebSearch = false
    /// What Maé remembers and how many exchanges the journal holds (the memory page); nil until the engine said.
    private(set) var memory: MemoryOverview?
    /// The download of the model that finds a past conversation asked about in other words, while it runs (the memory
    /// page); nil otherwise, and once the model is in place.
    private(set) var journalSearchDownload: DownloadProgress?
    /// The connected tools: where each stands after its last action or test, its last test, its log (the most recent
    /// first, kept across launches).
    private(set) var connectedToolStates: [UUID: ConnectedToolState] = [:]
    private(set) var connectedToolTests: [UUID: ConnectedToolTest] = [:]
    private(set) var connectedToolLogs: [UUID: [ConnectedToolLogEntry]] = AssistantModel.loadToolLogs()
    /// The connected tools' actions of the request under way, for the cards under Maé's sentence (`ToolActionCards`):
    /// those that wait for the user's "oui", then what came of them. They stay until the user's next request; one that
    /// still waits stays until it is carried out, refused or dropped.
    private(set) var toolActions: [ConnectedToolAction] = []
    /// The card's "Oui" or "Non" was clicked: its buttons wait for what comes of it.
    private(set) var isAnsweringToolAction = false
    /// An action waits for the user's "oui" on a card.
    var toolActionWaits: Bool { toolActions.contains { $0.status == .waiting } }
    /// Quitting would stop a task.
    var hasRunningTask: Bool { tasks.contains { $0.status == .running } }
    /// The user is talking with the talk key: the space bar or the button held down, or the global shortcut
    /// pressed once (and not yet a second time).
    private(set) var talkKeyDown = false
    /// The exchange in progress was started with the global shortcut: the capsule follows it to its end.
    private(set) var isShortcutExchange = false
    /// Wake-word mode: Maé listens to any voice for a few seconds (after « OK Maé » alone, and after each answer).
    private(set) var isAwake = false

    var settings: AssistantSettings {
        didSet {
            guard settings != oldValue else { return }
            Self.save(settings)
            connection.send(.updateSettings(engineSettings))
            // When the tools come or go (they are part of the model's instructions), the engine starts a new
            // conversation and says so: the transcript goes then (`conversationCleared`), not here.
            if settings.actionsEnabled != oldValue.actionsEnabled, !settings.actionsEnabled { actions = nil }
            if settings.webSearch != oldValue.webSearch { webSearchTest = nil }
            if settings.listening != .wakeWord { isAwake = false }
        }
    }

    /// The conversation window is open. Once it is closed, OpenMaé stays in the menu bar and only listens after
    /// the global shortcut, even in hands-free mode; in the wake-word mode it still waits for « OK Maé ».
    var isWindowOpen = true {
        didSet {
            guard isWindowOpen != oldValue else { return }
            connection.send(.updateSettings(engineSettings))
        }
    }

    /// The global shortcut to talk from another app: ⌥ Space, or the one the user recorded in Settings › Voice and sound
    /// (`DesktopPresence.setTalkShortcut`, which saves it).
    var talkShortcut = TalkShortcut.saved

    /// The global shortcut is registered: macOS 15.0 and 15.1 refuse ⌥ Space, and another app may hold the one the user
    /// recorded. The window and the capsule only mention it then; the settings say why it does not work.
    var hasTalkShortcut = false
    /// Why the shortcut does not work, or why the one just pressed while recording another could not replace it.
    var talkShortcutRefusal: TalkShortcut.Refusal?
    /// Settings › Voice and sound records another shortcut: the current one is set aside meanwhile.
    var isRecordingTalkShortcut = false

    /// The settings as the engine gets them: with the window closed, push-to-talk instead of hands-free.
    private var engineSettings: AssistantSettings {
        var engine = settings
        if !isWindowOpen, engine.listening == .handsFree { engine.listening = .pushToTalk }
        return engine
    }

    /// Maé waits for « OK Maé » (window open or closed).
    var listensForWakeWord: Bool { settings.listening == .wakeWord }

    /// The state the screens show: listening while Maé is awake in the wake-word mode, though nobody speaks yet.
    var shownState: PipelineState {
        state == .listening && isAwake && listensForWakeWord ? .userSpeaking : state
    }

    var isReady: Bool { phase == .ready }

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    /// The first-launch screen shows and no download runs (none yet, or paused, or failed).
    private var isSetupWaiting: Bool {
        if case .setup = phase { return !isDownloading }
        return false
    }

    /// The exchange in progress, or the last one: what the user said and Maé's answer so far.
    var currentExchange: (user: TranscriptEntry?, answer: TranscriptEntry?) {
        guard let last = transcript.last else { return (nil, nil) }
        guard last.speaker == .assistant else { return (last, nil) }
        let previous = transcript.dropLast().last
        return (previous?.speaker == .user ? previous : nil, last)
    }

    /// The tier in use, or about to be.
    var tier: HardwareTier? {
        switch phase {
        case .setup(let setup): setup.tier
        default: info?.tier ?? settings.tierOverride ?? recommendedTier
        }
    }

    @ObservationIgnored private let connection: any AssistantConnection
    /// Where the pieces of the current answer go in the transcript.
    @ObservationIgnored private var answerIndex: Int?
    /// The web search's settings when its "Test" button was clicked: a result that comes back after they changed
    /// (another source chosen meanwhile) is not shown.
    @ObservationIgnored private var testedWebSearch: WebSearchSettings?
    /// Those waiting for a connected tool's test, by its id.
    @ObservationIgnored private var toolTestWaiters: [UUID: [CheckedContinuation<ConnectedToolTest, Never>]] = [:]

    init(connection: any AssistantConnection) {
        self.connection = connection
        self.settings = Self.loadSettings()
        Task { [weak self] in
            for await event in connection.events { self?.apply(event) }
        }
        #if DEBUG
        DebugCommands.listen { [weak self] command in self?.debugCommand(command) }
        #endif
    }

    #if DEBUG
    /// A command from a test script (DebugTools.swift), handled as if a button had been clicked.
    private func debugCommand(_ command: AssistantCommand) {
        DebugLog.log("debug command: \(command)")
        switch command {
        case .downloadModels: downloadModels()
        case .pauseDownload: pauseDownload()
        case .deleteModels: deleteModels()
        case .deleteModel(let id): deleteModel(id)
        case .updateSettings(let settings): self.settings = settings
        case .newConversation: newConversation()
        case .talkKey(let pressed): setTalkKey(pressed)
        default: connection.send(command)
        }
    }
    #endif

    // MARK: - Commands

    func start() {
        guard phase != .ready else { return }
        phase = .loading(nil)
        connection.send(.start(engineSettings))
    }

    func setTalkKey(_ down: Bool) {
        guard isReady, down != talkKeyDown else { return }
        talkKeyDown = down
        connection.send(.talkKey(pressed: down))
    }

    /// The global shortcut: a first press starts the user's turn (and silences Maé), a second one ends it.
    func toggleTalk() {
        guard isReady else { return }
        if !talkKeyDown { isShortcutExchange = true }
        setTalkKey(!talkKeyDown)
    }

    func stopSpeaking() {
        connection.send(.stopSpeaking)
    }

    /// The screen clears at once; the engine says it started the new conversation (`conversationCleared`) once the turn
    /// under way has stopped, and before anything of the next one.
    func newConversation() {
        clearTranscript()
        connection.send(.newConversation)
    }

    private func clearTranscript() {
        transcript.removeAll()
        answerIndex = nil
        toolActions.removeAll()
        isAnsweringToolAction = false
    }

    /// The "Oui" or "Non" of a card: the engine takes it as if the user had said it.
    func answerToolAction(_ yes: Bool) {
        guard isReady, toolActionWaits, !isAnsweringToolAction else { return }
        isAnsweringToolAction = true
        connection.send(.answerAction(yes))
    }

    /// The app is in front again: a shortcut may have been added, an access granted in System Settings, Claude Code
    /// installed or signed in (on or off: switched off, it can only be switched on once installed); or the web search's
    /// key or password was just saved.
    func refreshActions() {
        guard isReady else { return }
        connection.send(.refreshActions)
    }

    /// The web search's key or password was just saved or removed. It is in the keychain, not in the settings: the
    /// engine reads it again, and the last test no longer tells anything.
    func webSearchSecretChanged() {
        webSearchTest = nil
        refreshActions()
    }

    /// The web search's "Test" button: one search with its settings, as they are now.
    func testWebSearch() {
        webSearchTest = nil
        isTestingWebSearch = true
        testedWebSearch = settings.webSearch
        connection.send(.testWebSearch)
    }

    /// The memory page opened: the engine reads the sheet and the journal again.
    func refreshMemory() {
        connection.send(.refreshMemory)
    }

    /// The memory page's delete button on one entry.
    func forgetMemoryEntry(_ entry: String) {
        connection.send(.forgetMemoryEntry(entry))
    }

    /// "Erase past conversations": the journal of past exchanges, erased (what Maé remembers stays).
    func clearMemoryJournal() {
        connection.send(.clearMemoryJournal)
    }

    /// "Erase everything": the sheet and the journal.
    func eraseMemory() {
        connection.send(.eraseMemory)
    }

    /// Connects to a connected tool and lists its actions, with the token the keychain keeps for its id. For a tool of the
    /// settings, the list found replaces the one they keep (each action keeping its switch).
    func testConnectedTool(_ tool: ConnectedToolSettings) async -> ConnectedToolTest {
        await withCheckedContinuation { continuation in
            toolTestWaiters[tool.id, default: []].append(continuation)
            connection.send(.testConnectedTool(tool))
        }
    }

    /// A tool's connection was changed after a trial that connected (`ConnectedToolsAccess.add`).
    func reconnected(_ id: UUID) {
        connectedToolStates[id] = .connected
        connectedToolTests[id] = nil
    }

    /// A tool removed: its state, test and log go with it.
    func forgetConnectedTool(_ id: UUID) {
        connectedToolStates[id] = nil
        connectedToolTests[id] = nil
        connectedToolLogs[id] = nil
        Self.saveToolLogs(connectedToolLogs)
    }

    /// The Stop button of a task.
    func stopTask(_ id: UUID) {
        connection.send(.stopTask(id))
    }

    func downloadModels() {
        downloadFailure = nil
        isDownloading = true
        connection.send(.downloadModels)
    }

    func pauseDownload() {
        connection.send(.pauseDownload)
    }

    func deleteModels() {
        info = nil
        phase = .loading(nil)
        connection.send(.deleteModels)
    }

    /// Settings › Advanced: one model, by its id (the engine refuses one in use and says what is left in `.storage`).
    func deleteModel(_ id: String) {
        connection.send(.deleteModel(id))
    }

    // MARK: - Events

    private func apply(_ event: AssistantEvent) {
        #if DEBUG
        switch event {
        case .levels, .diagnostics: break
        case .downloadProgress(let p) where p.doneBytes % 20 != 0: break  // about one in twenty
        case .journalSearchDownload(let p?) where p.doneBytes % 20 != 0: break
        default: DebugLog.log("event: \(event)")
        }
        #endif
        switch event {
        case .setupNeeded(let setup):
            phase = .setup(setup)
            recommendedTier = setup.recommendedTier
            info = nil
            download = nil
            isDownloading = false
            downloadFailure = nil
        case .downloadProgress(let progress):
            download = progress
            isDownloading = true
            downloadFailure = nil
        case .downloadStopped(let failure):
            isDownloading = false
            downloadFailure = failure
        case .storage(let storage):
            self.storage = storage
        case .loading(.microphone) where isSetupWaiting:
            // On the first-launch screen with no download running, the engine only starts again because another
            // tier was chosen: it checks the microphone (already allowed) before it says what that tier needs. The
            // screen stays meanwhile, rather than flash the loading screen.
            break
        case .loading(let step):
            phase = .loading(step)
            download = nil
            isDownloading = false
        case .ready(let info):
            self.info = info
            recommendedTier = info.recommendedTier
            phase = .ready
        case .problem(let problem):
            phase = .problem(problem)
        case .state(let state):
            let before = self.state
            self.state = state
            updateTranscript(for: state)
            if state == .listening, !talkKeyDown { isShortcutExchange = false }
            // The turn of a card's answer is over: if the action still waits (the answer came too late, or was cut), its
            // buttons work again.
            if state == .listening, before != .listening { isAnsweringToolAction = false }
        case .partialTranscript(let text):
            setPartialUserText(text)
        case .userTranscript(let text, let language):
            setUserText(text, language: language)
            // A new turn: what the request before did goes; what still waits for the "oui" stays (this may be the answer).
            toolActions.removeAll { $0.status != .waiting }
        case .assistantPiece(let piece):
            appendToAnswer(piece)
        case .turnFinished(let metrics):
            if metrics.interrupted {
                if let answerIndex, transcript.indices.contains(answerIndex) {
                    transcript[answerIndex].interrupted = true
                }
            } else {
                turns.append(metrics)
                if turns.count > 500 { turns.removeFirst() }
            }
        case .bargeIn(let stopMs, _):
            bargeIns.append(stopMs)
        case .awake(let awake):
            isAwake = awake
        case .wakeDecision(let decision):
            if settings.wakeLog { WakeLog.append(decision) }
        case .conversationCleared:
            // The engine started a new conversation (an iPhone's « New conversation », the tools that came or went,
            // another model ready after a change of tier; after the Mac's own « New conversation », a second time,
            // before anything of the next turn): the screen no longer shows what the model no longer has.
            clearTranscript()
        case .levels(let input, let output):
            inputLevel = input
            outputLevel = output
        case .diagnostics(let diagnostics):
            self.diagnostics = diagnostics
        case .actions(let status):
            actions = status
        case .claudeCode(let availability):
            claudeCode = availability
        case .tasks(let tasks):
            self.tasks = tasks
        case .memory(let overview):
            memory = overview
        case .journalSearchDownload(let progress):
            journalSearchDownload = progress
        case .webSearchTested(let test):
            if testedWebSearch.map({ $0 == settings.webSearch }) ?? true { webSearchTest = test }
            isTestingWebSearch = false
        case .connectedToolTested(let id, let test):
            connectedToolTests[id] = test
            if let i = settings.connectedTools.firstIndex(where: { $0.id == id }) {
                switch test {
                case .works(let tools, _):
                    connectedToolStates[id] = .connected
                    let actions = settings.connectedTools[i].merging(tools)
                    if actions != settings.connectedTools[i].actions { settings.connectedTools[i].actions = actions }
                case .failed(.unauthorized): connectedToolStates[id] = .needsReconnect
                case .failed: connectedToolStates[id] = .unreachable
                }
            }
            for waiter in toolTestWaiters.removeValue(forKey: id) ?? [] { waiter.resume(returning: test) }
        case .connectedToolLog(let id, let entry):
            var log = connectedToolLogs[id] ?? []
            log.insert(entry, at: 0)
            connectedToolLogs[id] = Array(log.prefix(Self.toolLogLength))
            Self.saveToolLogs(connectedToolLogs)
        case .connectedToolState(let id, let state):
            connectedToolStates[id] = state
        case .connectedToolAction(let action):
            showToolAction(action)
        case .warning(let message):
            lastWarning = message
        }
    }

    /// A card's new status, or a new card: an action of the same request joins those shown, one of a new request
    /// replaces what the one before left.
    private func showToolAction(_ action: ConnectedToolAction) {
        if let i = toolActions.firstIndex(where: { $0.id == action.id }) {
            if action.status == .dropped { toolActions.remove(at: i) } else { toolActions[i] = action }
        } else if action.status != .dropped {
            if action.status == .waiting { toolActions.removeAll { $0.status != .waiting } }
            toolActions.append(action)
        }
        if action.status == .waiting || !toolActionWaits { isAnsweringToolAction = false }
    }

    private func updateTranscript(for state: PipelineState) {
        switch state {
        case .userSpeaking:
            if transcript.last.map({ $0.speaker == .user && $0.pending }) != true {
                transcript.append(TranscriptEntry(speaker: .user, text: "", pending: true))
            }
        case .listening:
            // Speech that turned out to be noise (nothing was transcribed), or that ended without a turn (« OK Maé »
            // alone): its provisional words go too.
            while let last = transcript.last, last.speaker == .user, last.pending { transcript.removeLast() }
            // What Maé says next on her own (a timer that rang) is a new line, not the end of her last answer.
            answerIndex = nil
        case .thinking, .speaking:
            break
        }
    }

    /// What the user has said so far, while they speak: in their line, still pending (the history shows "…" for it),
    /// until the whole sentence replaces it in place.
    private func setPartialUserText(_ text: String) {
        guard state == .userSpeaking else { return }
        if let last = transcript.indices.last, transcript[last].speaker == .user, transcript[last].pending {
            transcript[last].text = text
        } else {
            transcript.append(TranscriptEntry(speaker: .user, text: text, pending: true))
        }
    }

    private func setUserText(_ text: String, language: SpeechLanguage) {
        answerIndex = nil
        if let i = transcript.lastIndex(where: { $0.speaker == .user && $0.pending }) {
            transcript[i].text = text
            transcript[i].language = language
            transcript[i].pending = false
        } else {
            transcript.append(TranscriptEntry(speaker: .user, text: text, language: language))
        }
    }

    private func appendToAnswer(_ piece: String) {
        if let answerIndex, transcript.indices.contains(answerIndex) {
            transcript[answerIndex].text += " " + piece
        } else {
            transcript.append(TranscriptEntry(speaker: .assistant, text: piece))
            answerIndex = transcript.count - 1
        }
    }

    // MARK: - Measurements

    /// Median end-of-speech → first-sound latency over the session, in ms.
    var medianLatencyMs: Double? { Self.median(turns.compactMap(\.latencyMs)) }
    var medianBargeInMs: Double? { Self.median(bargeIns) }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// All measurements as JSON (the "Copy" button of the debug panel).
    func measurementsJSON() -> String {
        struct Export: Encodable {
            var info: EngineInfo?
            var diagnostics: EngineDiagnostics
            var turns: [TurnMetrics]
            var bargeInsMs: [Double]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try? encoder.encode(Export(info: info, diagnostics: diagnostics, turns: turns, bargeInsMs: bargeIns))
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: - Saved settings

    nonisolated static let settingsKey = "settings"
    private static let toolLogsKey = "connectedToolsLog"
    /// Lines kept in each connected tool's log.
    static let toolLogLength = 20

    private static func loadToolLogs() -> [UUID: [ConnectedToolLogEntry]] {
        guard let data = AppDefaults.store.data(forKey: toolLogsKey),
              let logs = try? JSONDecoder().decode([UUID: [ConnectedToolLogEntry]].self, from: data)
        else { return [:] }
        return logs
    }

    private static func saveToolLogs(_ logs: [UUID: [ConnectedToolLogEntry]]) {
        AppDefaults.store.set(try? JSONEncoder().encode(logs), forKey: toolLogsKey)
    }

    private static func loadSettings() -> AssistantSettings {
        guard let data = AppDefaults.store.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AssistantSettings.self, from: data)
        else { return AssistantSettings() }
        return settings
    }

    private static func save(_ settings: AssistantSettings) {
        AppDefaults.store.set(try? JSONEncoder().encode(settings), forKey: settingsKey)
    }
}
