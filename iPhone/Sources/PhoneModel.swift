import AVFoundation
import Foundation
import Observation
import OpenMaeLink
import UIKit
import VoiceCore

/// One line of the live transcript (the Mac app has the same).
struct TranscriptEntry: Identifiable, Equatable {
    enum Speaker { case user, assistant }
    let id = UUID()
    let speaker: Speaker
    var text: String
    var language: SpeechLanguage?
    var pending = false
    var interrupted = false
}

/// Everything the iPhone's screens show: the paired Mac, the link with it, and the conversation, rebuilt from the
/// Mac's events as the Mac's own screens are.
@MainActor
@Observable
final class PhoneModel {
    enum Pairing: Equatable {
        case scanning
        /// A code was read: talking to the Mac.
        case contacting
        case done(macName: String)
        /// The code was used, or is more than 5 minutes old.
        case expired
        /// The Mac could not be reached to pair.
        case unreachable
    }

    /// What the Mac's engine is doing.
    enum Phase: Equatable {
        case unknown
        case ready
        case loading(LoadingStep?)
        /// Models to download first: on the Mac.
        case setup
        case problem
    }

    enum TalkMode: String, Codable, CaseIterable {
        case handsFree
        /// One big button, held while talking.
        case hold
    }

    /// Why the conversation is closed while the app is open.
    enum Pause: Equatable {
        /// Two minutes (by default) without anyone talking.
        case silence
        /// Someone used OpenMaé on the Mac.
        case macTookOver
    }

    private(set) var mac: PairedMac?
    private(set) var pairing = Pairing.scanning
    /// The Mac removed this iPhone from its settings.
    private(set) var forgotten = false
    private(set) var link: PhoneLink.Status?
    private(set) var phase = Phase.unknown
    private(set) var state = PipelineState.listening
    private(set) var transcript: [TranscriptEntry] = []
    private(set) var isConversationOpen = false
    private(set) var pause: Pause?
    private(set) var talkKeyDown = false
    private(set) var microphoneDenied = false
    private(set) var inputLevel: Float = 0
    private(set) var outputLevel: Float = 0
    var showsSettings = false

    var microphoneMuted = false {
        didSet { audio?.setMuted(microphoneMuted) }
    }

    var talkMode: TalkMode {
        didSet {
            guard talkMode != oldValue else { return }
            UserDefaults.standard.set(talkMode.rawValue, forKey: Keys.talkMode)
            sendSettings()
        }
    }

    /// Minutes of silence after which the conversation closes on its own (battery); 0: never.
    var autoEndMinutes: Int {
        didSet {
            UserDefaults.standard.set(autoEndMinutes, forKey: Keys.autoEnd)
            watchSilence()
        }
    }

    static let autoEndChoices = [1, 2, 5, 10, 0]

    @ObservationIgnored private var phoneLink: PhoneLink?
    @ObservationIgnored private var audio: PhoneAudio?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var silenceWatch: Task<Void, Never>?
    @ObservationIgnored private var answerIndex: Int?
    @ObservationIgnored private let identityStore = KeychainIdentityStore(service: "OpenMaé link")

    private enum Keys {
        static let mac = "pairedMac"
        static let talkMode = "talkMode"
        static let autoEnd = "autoEndMinutes"
    }

    init() {
        talkMode = UserDefaults.standard.string(forKey: Keys.talkMode).flatMap(TalkMode.init) ?? .handsFree
        autoEndMinutes = UserDefaults.standard.object(forKey: Keys.autoEnd) as? Int ?? 2
        if let data = UserDefaults.standard.data(forKey: Keys.mac),
           let mac = try? JSONDecoder().decode(PairedMac.self, from: data)
        {
            self.mac = mac
            connect()
        }
    }

    var isConnected: Bool {
        if case .connected = link { return true }
        return false
    }

    // MARK: - Pairing

    /// A QR code was read (by the app's scanner, or the link opened the app).
    func scanned(_ text: String) {
        guard pairing == .scanning || pairing == .expired || pairing == .unreachable,
              let link = PairingLink(string: text)
        else { return }
        pairing = .contacting
        Task {
            do {
                let identity = try identityStore.loadOrCreate()
                let phone = HandshakePayload.Phone(name: UIDevice.current.name, model: Self.modelIdentifier)
                let mac = try await PhonePairing.pair(link: link, identity: identity, phone: phone)
                save(mac)
                forgotten = false
                pairing = .done(macName: mac.name)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch HandshakeFailure.refused(let code) where code == "expired" {
                pairing = .expired
            } catch HandshakeFailure.wrongMac {
                pairing = .expired
            } catch {
                DebugLog.log("pairing failed: \(error)")
                pairing = .unreachable
            }
        }
    }

    func scanAgain() {
        pairing = .scanning
    }

    /// "Talk to Maé", after pairing.
    func finishPairing() {
        pairing = .scanning
        connect()
        openConversation()
    }

    func forgetMac() {
        disconnect()
        mac = nil
        UserDefaults.standard.removeObject(forKey: Keys.mac)
        pairing = .scanning
        showsSettings = false
    }

    private func save(_ mac: PairedMac) {
        disconnect()
        remember(mac)
    }

    /// Kept for the next launches: after a pairing, and when the Mac changes its name or relay.
    private func remember(_ mac: PairedMac) {
        self.mac = mac
        UserDefaults.standard.set(try? JSONEncoder().encode(mac), forKey: Keys.mac)
    }

    // MARK: - Link

    private func connect() {
        guard phoneLink == nil, let mac, let identity = try? identityStore.load() else { return }
        let phoneLink = PhoneLink(mac: mac, identity: identity)
        self.phoneLink = phoneLink
        let audio = PhoneAudio(link: phoneLink)
        audio.onReleased = { [weak self] in Task { @MainActor in self?.closeConversation(.macTookOver) } }
        audio.onLevels = { [weak self] input, output in
            Task { @MainActor in
                self?.inputLevel = input
                self?.outputLevel = output
            }
        }
        self.audio = audio
        tasks = [
            Task { [weak self] in
                for await status in phoneLink.status { self?.linkChanged(status) }
            },
            Task { [weak self] in
                for await event in phoneLink.events { self?.apply(event) }
            },
            Task { [weak self] in
                for await mac in phoneLink.macChanges { self?.remember(mac) }
            },
        ]
        Task { await phoneLink.connect() }
        sendSettings()
    }

    private func disconnect() {
        closeConversation(nil)
        tasks.forEach { $0.cancel() }
        tasks = []
        if let phoneLink { Task { await phoneLink.disconnect() } }
        phoneLink = nil
        audio = nil
        link = nil
        phase = .unknown
    }

    /// "Try again": now rather than at the next attempt.
    func retry() {
        if phoneLink == nil { connect() } else if let phoneLink { Task { await phoneLink.connect() } }
    }

    private func linkChanged(_ status: PhoneLink.Status) {
        link = status
        if status == .forgotten {
            forgotten = true
            disconnect()
            mac = nil
            UserDefaults.standard.removeObject(forKey: Keys.mac)
            pairing = .scanning
        }
    }

    /// The app came to the front: the link and the conversation open on their own ("you open the app, the link is
    /// made, the orb goes to rest").
    func becameActive() {
        guard mac != nil else { return }
        if phoneLink == nil { connect() } else { retry() }
        if !isConversationOpen, pause == nil { openConversation() }
    }

    /// The app went to the background: without a conversation, the link closes (the battery).
    func wentToBackground() {
        guard !isConversationOpen else { return }
        disconnect()
        pause = nil
    }

    // MARK: - Conversation

    func openConversation() {
        guard !isConversationOpen, let phoneLink, let audio else { return }
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                microphoneDenied = true
                return
            }
            microphoneDenied = false
            do {
                try audio.start()
            } catch {
                DebugLog.log("audio: cannot start (\(error))")
                return
            }
            isConversationOpen = true
            pause = nil
            audio.setMuted(microphoneMuted)
            await phoneLink.setAudio(true)
            watchSilence()
        }
    }

    func closeConversation(_ reason: Pause?) {
        guard isConversationOpen else { return }
        isConversationOpen = false
        pause = reason
        silenceWatch?.cancel()
        if talkKeyDown { setTalkKey(false) }
        audio?.stop()
        if let phoneLink { Task { await phoneLink.setAudio(false) } }
    }

    /// The main button, in hands-free mode: talk (and finish), cancel the answer being prepared, interrupt Maé.
    func mainButton() {
        guard isConnected, phase == .ready else { return }
        if !isConversationOpen {
            openConversation()
            return
        }
        switch state {
        case .thinking, .speaking: phoneLink?.send(.stopSpeaking)
        case .listening, .userSpeaking: setTalkKey(!talkKeyDown)
        }
    }

    /// The big button of hold-to-talk.
    func hold(_ pressed: Bool) {
        guard isConnected, phase == .ready else { return }
        if pressed, !isConversationOpen { openConversation() }
        if pressed, state == .thinking || state == .speaking { phoneLink?.send(.stopSpeaking) }
        setTalkKey(pressed)
    }

    private func setTalkKey(_ down: Bool) {
        guard down != talkKeyDown else { return }
        talkKeyDown = down
        phoneLink?.send(.talkKey(pressed: down))
        if down { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }

    func newConversation() {
        transcript.removeAll()
        answerIndex = nil
        phoneLink?.send(.newConversation)
    }

    private func sendSettings() {
        var settings = AssistantSettings()
        settings.listening = talkMode == .hold ? .pushToTalk : .handsFree
        phoneLink?.send(.updateSettings(settings))
    }

    /// The conversation closes after `autoEndMinutes` without anyone talking.
    private func watchSilence() {
        silenceWatch?.cancel()
        guard isConversationOpen, autoEndMinutes > 0, state == .listening, !talkKeyDown else { return }
        let minutes = autoEndMinutes
        silenceWatch = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled else { return }
            self?.closeConversation(.silence)
        }
    }

    // MARK: - The Mac's events

    private func apply(_ event: AssistantEvent) {
        switch event {
        case .ready: phase = .ready
        case .loading(let step): phase = .loading(step)
        case .setupNeeded: phase = .setup
        case .problem: phase = .problem
        case .state(let state):
            self.state = state
            updateTranscript(for: state)
            if state == .listening { talkKeyDown = false }
            watchSilence()
        case .userTranscript(let text, let language):
            answerIndex = nil
            if let i = transcript.lastIndex(where: { $0.speaker == .user && $0.pending }) {
                transcript[i].text = text
                transcript[i].language = language
                transcript[i].pending = false
            } else {
                transcript.append(TranscriptEntry(speaker: .user, text: text, language: language))
            }
        case .assistantPiece(let piece):
            if let answerIndex, transcript.indices.contains(answerIndex) {
                transcript[answerIndex].text += " " + piece
            } else {
                transcript.append(TranscriptEntry(speaker: .assistant, text: piece))
                answerIndex = transcript.count - 1
            }
        case .turnFinished(let metrics):
            if metrics.interrupted, let answerIndex, transcript.indices.contains(answerIndex) {
                transcript[answerIndex].interrupted = true
            }
        default:
            break
        }
        if transcript.count > 200 { transcript.removeFirst(transcript.count - 200) }
    }

    private func updateTranscript(for state: PipelineState) {
        switch state {
        case .userSpeaking:
            if transcript.last.map({ $0.speaker == .user && $0.pending }) != true {
                transcript.append(TranscriptEntry(speaker: .user, text: "", pending: true))
            }
        case .listening:
            while let last = transcript.last, last.speaker == .user, last.pending { transcript.removeLast() }
            answerIndex = nil
        case .thinking, .speaking:
            break
        }
    }

    /// The exchange in progress, or the last one.
    var currentExchange: (user: TranscriptEntry?, answer: TranscriptEntry?) {
        guard let last = transcript.last else { return (nil, nil) }
        guard last.speaker == .assistant else { return (last, nil) }
        let previous = transcript.dropLast().last
        return (previous?.speaker == .user ? previous : nil, last)
    }

    /// "iPhone17,3".
    static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
