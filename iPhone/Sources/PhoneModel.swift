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

/// Everything the iPhone's (and iPad's) screens show: the paired Mac, the link with it, and the conversation, rebuilt
/// from the Mac's events as the Mac's own screens are.
///
/// On an iPad, *station mode* (a setting, off by default) makes it a home station while it is plugged in and the app
/// is in the foreground: the screen stays on, the link stays open without the conversation, a tap on the orb takes
/// the conversation and it is given back to the Mac a minute after the exchange (never in hands-free); what Maé says
/// on her own is spoken on it (`LinkMessage.device`).
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

    typealias TalkMode = DeviceTalkMode

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
    /// Maé's voice is playing here: an answer, or an announcement on the station without the conversation.
    private(set) var voicePlaying = false
    var showsSettings = false

    /// An iPad (station mode, and a wider layout).
    let isPad: Bool
    /// Plugged in (charging or full).
    private(set) var isPluggedIn = false
    private(set) var isInForeground = false
    /// The station's screen dimmed to the minimum after a while at rest (`watchDimming`).
    private(set) var isDimmed = false

    /// iPad: a home station while plugged in and in the foreground.
    var stationMode: Bool {
        didSet {
            guard stationMode != oldValue else { return }
            UserDefaults.standard.set(stationMode, forKey: Keys.stationMode)
            // "Tap to talk" is the station's way of talking (the user may choose another one afterwards).
            if stationMode { talkMode = .tap }
            updateStation()
        }
    }

    /// Station mode is on and takes effect now: an iPad, plugged in, the app in the foreground.
    var isStation: Bool { isPad && stationMode && isPluggedIn && isInForeground }

    var microphoneMuted = false {
        didSet { audio?.setMuted(microphoneMuted) }
    }

    var talkMode: TalkMode {
        didSet {
            guard talkMode != oldValue else { return }
            UserDefaults.standard.set(talkMode.rawValue, forKey: Keys.talkMode)
            if talkKeyDown { setTalkKey(false) }
            sendSettings()
            watchSilence()
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
    @ObservationIgnored private var dimWatch: Task<Void, Never>?
    @ObservationIgnored private var brightnessBeforeDimming: CGFloat?
    @ObservationIgnored private var taps = TapToTalk()
    /// A station at the last `updateStation`: the silence that closes the conversation is timed again only when this
    /// changes (its delay changes with it), not each time the app comes to the front or the battery fills up.
    @ObservationIgnored private var wasStation = false
    @ObservationIgnored private var answerIndex: Int?
    @ObservationIgnored private var batteryObserver: NSObjectProtocol?
    @ObservationIgnored private let identityStore = KeychainIdentityStore(service: "OpenMaé link")

    private enum Keys {
        static let mac = "pairedMac"
        static let talkMode = "talkMode"
        static let autoEnd = "autoEndMinutes"
        static let stationMode = "stationMode"
    }

    /// The station's screen dims to the minimum after this long at rest; a touch or an announcement brings it back.
    static let dimAfter = Duration.seconds(5 * 60)

    init() {
        talkMode = UserDefaults.standard.string(forKey: Keys.talkMode).flatMap(TalkMode.init) ?? .handsFree
        autoEndMinutes = UserDefaults.standard.object(forKey: Keys.autoEnd) as? Int ?? 2
        stationMode = UserDefaults.standard.bool(forKey: Keys.stationMode)
        isPad = UIDevice.current.userInterfaceIdiom == .pad
        if isPad {
            UIDevice.current.isBatteryMonitoringEnabled = true
            isPluggedIn = Self.pluggedIn
            batteryObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.batteryChanged() }
            }
        }
        #if DEBUG
        if let screen = PhoneScreenshots.requested {
            PhoneScreenshots.prepare(self, screen)
            return
        }
        #endif
        if let data = UserDefaults.standard.data(forKey: Keys.mac),
           let mac = try? JSONDecoder().decode(PairedMac.self, from: data)
        {
            self.mac = mac
            connect()
        }
    }

    private static var pluggedIn: Bool {
        #if targetEnvironment(simulator)
        return true  // the simulator has no battery: as if plugged in, to try the station
        #else
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
        #endif
    }

    private func batteryChanged() {
        isPluggedIn = Self.pluggedIn
        updateStation()
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
        audio.onPlaying = { [weak self] playing in Task { @MainActor in self?.voicePlayingChanged(playing) } }
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
        updateStation()
    }

    private func disconnect() {
        closeConversation(nil)
        tasks.forEach { $0.cancel() }
        tasks = []
        // A station that leaves says so first: the Mac then stops counting on it at once.
        if let phoneLink {
            let isPad = isPad
            Task {
                if isPad { await phoneLink.setStation(false) }
                await phoneLink.disconnect()
            }
        }
        audio?.stopPlayback()  // a station's speaker
        phoneLink = nil
        audio = nil
        link = nil
        phase = .unknown
        voicePlaying = false
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
    /// made, the orb goes to rest"). A station opens the link only: it waits for a tap on the orb.
    func becameActive() {
        isInForeground = true
        updateStation()
        guard mac != nil else { return }
        if phoneLink == nil { connect() } else { retry() }
        if !isConversationOpen, pause == nil, !isStation { openConversation() }
    }

    /// The app went to the background: without a conversation, the link closes (the battery). Station mode only
    /// works in the foreground.
    func wentToBackground() {
        isInForeground = false
        updateStation()
        guard !isConversationOpen else { return }
        disconnect()
        pause = nil
    }

    // MARK: - Station

    /// What follows from being a station or not: the screen kept on, the Mac told, Maé's voice playable without the
    /// conversation, the silence that gives the conversation back.
    private func updateStation() {
        let station = isStation
        UIApplication.shared.isIdleTimerDisabled = station
        tellStation()
        if !isConversationOpen {
            if station {
                startPlaybackOnly()
            } else {
                audio?.stopPlayback()
                voicePlaying = false  // what was playing was stopped with it
            }
        }
        if station != wasStation {
            wasStation = station
            watchSilence()  // the station's delay, or the iPhone's
        }
        watchDimming()
    }

    /// The Mac is told whether this iPad is a station: the value of the moment, whatever the order the tasks run in.
    /// An iPhone never says (`LinkMessage.device`).
    private func tellStation() {
        guard isPad else { return }
        Task { [weak self] in
            guard let self, let phoneLink = self.phoneLink else { return }
            await phoneLink.setStation(self.isStation)
        }
    }

    /// A station without the conversation still plays Maé's voice: what she says on her own.
    private func startPlaybackOnly() {
        guard let audio, !isConversationOpen else { return }
        do {
            try audio.startPlayback()
        } catch {
            DebugLog.log("audio: cannot start the station's speaker (\(error))")
        }
    }

    private func voicePlayingChanged(_ playing: Bool) {
        voicePlaying = playing
        if playing { wake() }
        watchDimming()
    }

    /// A touch on the station's screen: back to full brightness, and the dimming waits again.
    func touched() {
        wake()
        watchDimming()
    }

    /// The station's screen dims to the minimum after a while at rest (the night): not while Maé speaks or listens.
    private func watchDimming() {
        dimWatch?.cancel()
        guard isStation, !voicePlaying, !isConversationOpen || state == .listening else {
            wake()
            return
        }
        dimWatch = Task { [weak self] in
            try? await Task.sleep(for: Self.dimAfter)
            guard !Task.isCancelled else { return }
            self?.dim()
        }
    }

    private func dim() {
        guard let screen = Self.screen, !isDimmed else { return }
        brightnessBeforeDimming = screen.brightness
        screen.brightness = 0
        isDimmed = true
    }

    private func wake() {
        guard isDimmed else { return }
        isDimmed = false
        if let screen = Self.screen, let brightness = brightnessBeforeDimming { screen.brightness = brightness }
        brightnessBeforeDimming = nil
    }

    private static var screen: UIScreen? {
        (UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)?.screen
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
            watchDimming()
        }
    }

    /// The conversation closes: the Mac takes its microphone back. A station keeps its link, and its speaker for what
    /// Maé says on her own.
    func closeConversation(_ reason: Pause?) {
        guard isConversationOpen else { return }
        isConversationOpen = false
        pause = reason
        silenceWatch?.cancel()
        if talkKeyDown { setTalkKey(false) }
        taps.reset()
        audio?.stop()
        // What was playing was stopped with it, and the Mac sends no more of it (it took the sound back): otherwise
        // the orb would go on showing the Mac's conversation.
        voicePlaying = false
        if let phoneLink { Task { await phoneLink.setAudio(false) } }
        if isStation { startPlaybackOnly() }
        watchDimming()
    }

    /// The main button, in hands-free mode: talk (and finish), cancel the answer being prepared, interrupt Maé. In
    /// "Tap to talk", the same as a tap on the orb.
    func mainButton() {
        if talkMode == .tap {
            tapOrb()
            return
        }
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

    /// A tap on the orb. "Tap to talk": talk, then finish, as ⌥ Space on the Mac (the first tap takes the
    /// conversation). In any mode, while Maé thinks or speaks here (an answer, or an announcement on the station), a tap
    /// stops her.
    func tapOrb() {
        touched()
        guard isConnected, phase == .ready else { return }
        if displayedState == .thinking || displayedState == .speaking {
            phoneLink?.send(.stopSpeaking)
            return
        }
        switch talkMode {
        case .tap:
            if !taps.isPressed, !isConversationOpen { openConversation() }
            if case .talkKey(let pressed) = taps.tap() { setTalkKey(pressed) }
        case .handsFree, .hold:
            // The station's orb takes the conversation; on an iPhone, the "Talk" button does.
            if isStation, !isConversationOpen { openConversation() }
        }
    }

    /// What the orb shows: the conversation's state while it is here, or while Maé's voice plays here (an
    /// announcement on the station); at rest otherwise, and while the link is down.
    var displayedState: PipelineState {
        let reconnecting = link == .reconnecting || link == .connecting
        guard !reconnecting, isConversationOpen || voicePlaying else { return .listening }
        return state
    }

    private func setTalkKey(_ down: Bool) {
        guard down != talkKeyDown else { return }
        talkKeyDown = down
        if !down { taps.reset() }
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
        settings.listening = talkMode.listening
        phoneLink?.send(.updateSettings(settings))
    }

    /// The conversation closes after a silence: `autoEndMinutes` without anyone talking; a station gives it back one
    /// minute after the exchange in "Tap to talk" or "Hold", and keeps it in hands-free (`ConversationRelease`).
    private func watchSilence() {
        silenceWatch?.cancel()
        guard isConversationOpen, state == .listening, !talkKeyDown,
              let delay = ConversationRelease.delay(station: isStation, mode: talkMode, autoEndMinutes: autoEndMinutes)
        else { return }
        silenceWatch = Task { [weak self] in
            try? await Task.sleep(for: delay)
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
            if state == .listening {
                talkKeyDown = false
                taps.reset()
            }
            watchSilence()
            watchDimming()
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

    /// "iPhone17,3", "iPad14,1". In the simulator, the simulated device's.
    static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    #if DEBUG
    /// Still pictures of the screens (`PhoneScreenshots`): the state they show, without a Mac.
    func showForScreenshot(mac: PairedMac, link: PhoneLink.Status, state: PipelineState, open: Bool,
                           transcript: [TranscriptEntry], voicePlaying: Bool = false, foreground: Bool = true)
    {
        self.mac = mac
        self.link = link
        phase = .ready
        self.state = state
        isConversationOpen = open
        self.transcript = transcript
        self.voicePlaying = voicePlaying
        isInForeground = foreground
        isPluggedIn = true
    }
    #endif
}
