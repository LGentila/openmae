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
        case ready
        case problem(AssistantProblem)
    }

    private(set) var phase = Phase.loading(nil)
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
    private(set) var talkKeyDown = false

    var settings: AssistantSettings {
        didSet {
            guard settings != oldValue else { return }
            Self.save(settings)
            if !settings.pushToTalk { talkKeyDown = false }
            connection.send(.updateSettings(settings))
        }
    }

    var isReady: Bool { phase == .ready }

    @ObservationIgnored private let connection: any AssistantConnection
    /// Where the pieces of the current answer go in the transcript.
    @ObservationIgnored private var answerIndex: Int?

    init(connection: any AssistantConnection) {
        self.connection = connection
        self.settings = Self.loadSettings()
        Task { [weak self] in
            for await event in connection.events { self?.apply(event) }
        }
    }

    // MARK: - Commands

    func start() {
        guard phase != .ready else { return }
        phase = .loading(nil)
        connection.send(.start(settings))
    }

    func setTalkKey(_ down: Bool) {
        guard settings.pushToTalk, isReady, down != talkKeyDown else { return }
        talkKeyDown = down
        connection.send(.talkKey(pressed: down))
    }

    func stopSpeaking() {
        connection.send(.stopSpeaking)
    }

    func newConversation() {
        transcript.removeAll()
        answerIndex = nil
        connection.send(.newConversation)
    }

    // MARK: - Events

    private func apply(_ event: AssistantEvent) {
        switch event {
        case .loading(let step):
            phase = .loading(step)
        case .ready(let info):
            self.info = info
            phase = .ready
        case .problem(let problem):
            phase = .problem(problem)
        case .state(let state):
            self.state = state
            updateTranscript(for: state)
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
