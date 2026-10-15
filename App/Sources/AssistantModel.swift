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
    /// The user is speaking and their words are not transcribed yet.
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
    /// The user is talking with the talk key: the space bar or the button held down, or the global shortcut
    /// pressed once (and not yet a second time).
    private(set) var talkKeyDown = false
    /// The exchange in progress was started with the global shortcut: the capsule follows it to its end.
    private(set) var isShortcutExchange = false

    var settings: AssistantSettings {
        didSet {
            guard settings != oldValue else { return }
            Self.save(settings)
            connection.send(.updateSettings(engineSettings))
        }
    }

    /// The conversation window is open. Once it is closed, OpenMaé stays in the menu bar and only listens after
    /// the global shortcut, even in hands-free mode.
    var isWindowOpen = true {
        didSet {
            guard isWindowOpen != oldValue else { return }
            connection.send(.updateSettings(engineSettings))
        }
    }

    /// The settings as the engine gets them: with the window closed, push-to-talk.
    private var engineSettings: AssistantSettings {
        var engine = settings
        if !isWindowOpen { engine.pushToTalk = true }
        return engine
    }

    var isReady: Bool { phase == .ready }

    var isLoading: Bool {
        if case .loading = phase { return true }
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
        case .deleteUnusedModels: deleteUnusedModels()
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

    func newConversation() {
        transcript.removeAll()
        answerIndex = nil
        connection.send(.newConversation)
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

    func deleteUnusedModels() {
        connection.send(.deleteUnusedModels)
    }

    // MARK: - Events

    private func apply(_ event: AssistantEvent) {
        #if DEBUG
        switch event {
        case .levels, .diagnostics: break
        case .downloadProgress(let p) where p.doneBytes % 20 != 0: break  // about one in twenty
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
            self.state = state
            updateTranscript(for: state)
            if state == .listening, !talkKeyDown { isShortcutExchange = false }
        case .userTranscript(let text, let language):
            setUserText(text, language: language)
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
        case .levels(let input, let output):
            inputLevel = input
            outputLevel = output
        case .diagnostics(let diagnostics):
            self.diagnostics = diagnostics
        case .warning(let message):
            lastWarning = message
        }
    }

    private func updateTranscript(for state: PipelineState) {
        switch state {
        case .userSpeaking:
            if transcript.last.map({ $0.speaker == .user && $0.pending }) != true {
                transcript.append(TranscriptEntry(speaker: .user, text: "", pending: true))
            }
        case .listening:
            // Speech that turned out to be noise (nothing was transcribed).
            while let last = transcript.last, last.speaker == .user, last.pending { transcript.removeLast() }
        case .thinking, .speaking:
            break
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

    private static let settingsKey = "settings"

    private static func loadSettings() -> AssistantSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AssistantSettings.self, from: data)
        else { return AssistantSettings() }
        return settings
    }

    private static func save(_ settings: AssistantSettings) {
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: settingsKey)
    }
}
