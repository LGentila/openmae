import CryptoKit
import Foundation
import VoiceCore

/// An iPhone or an iPad paired with this Mac.
public struct PairedDevice: Codable, Sendable, Equatable, Identifiable {
    /// Derived from its Noise key.
    public var id: String
    public var name: String
    /// The model identifier, e.g. "iPhone17,3" or "iPad14,1".
    public var model: String
    public var publicKey: Data
    public var added: Date

    public init(publicKey: Data, name: String, model: String, added: Date = Date()) {
        id = Base32.encode(Data(SHA256.hash(data: publicKey).prefix(16)))
        self.name = name
        self.model = model
        self.publicKey = publicKey
        self.added = added
    }

    /// "iPhone 16" rather than the generic name iOS gives apps ("iPhone").
    public var displayName: String { DeviceModels.marketingName(model) ?? name }

    public var kind: DeviceKind { DeviceKind(model: model) }
}

/// Which relay the Mac goes through, chosen in its settings; the iPhone follows (the relay is in the pairing link).
public enum RelayChoice: Codable, Sendable, Equatable {
    /// The OpenMaé relay, relay.openmae.com.
    case official
    /// A relay of one's own.
    case custom(URL)
    /// No relay: the iPhone reaches the Mac at home only.
    case none

    public var url: URL? {
        switch self {
        case .official: RelayClient.official
        case .custom(let url): url
        case .none: nil
        }
    }
}

/// What the Mac's iPhone settings show.
public struct LinkStatus: Sendable, Equatable {
    public enum Pairing: Sendable, Equatable {
        case idle
        /// The QR code is shown, valid until `expires`.
        case waiting(PairingLink, expires: Date)
        case expired
        case added(PairedDevice)
    }

    public enum Relay: Sendable, Equatable {
        /// No relay chosen, or nothing to relay (no iPhone).
        case off
        case connecting
        case registered
        /// Cannot be reached for now; tried again on its own.
        case unreachable
    }

    /// The iPhone or iPad that has the conversation.
    public struct Hand: Sendable, Equatable {
        public var device: PairedDevice
        public var path: LinkPath

        public init(device: PairedDevice, path: LinkPath) {
            self.device = device
            self.path = path
        }
    }

    public var devices: [PairedDevice] = []
    public var pairing = Pairing.idle
    public var relayChoice = RelayChoice.official
    public var relay = Relay.off
    /// Announced on the local network.
    public var local = false
    public var keepAwake = true
    public var hand: Hand?
    /// The iPads connected now as home stations (`LinkMessage.device`).
    public var stations: Set<PairedDevice.ID> = []

    public init() {}
}

/// The Mac's side of the link: pairing, the local listener, the relay registration, the iPhones' sessions, and the
/// bridge with the engine.
///
/// It sits between the Mac's interface and the engine: the interface talks to it as to the engine (it is an
/// `AssistantConnection`), and it passes everything on, sending the engine's events to the iPhones as well and the
/// iPhones' commands to the engine. When an iPhone takes the conversation, the engine's microphone and voice are
/// switched to it (`RemoteAudioRouting`); the last one to speak, on the Mac or on an iPhone, has the conversation.
///
/// An iPad left at home can be a *station* (`LinkMessage.device`): linked without having the conversation. What Maé
/// says on her own (a timer that rings) is then spoken on it rather than where the conversation is
/// (`RemoteAudioRouting.announceThrough`, see `updateAnnouncements`).
public actor LinkHost: AssistantConnection {
    public nonisolated let events: AsyncStream<AssistantEvent>
    private nonisolated let emit: AsyncStream<AssistantEvent>.Continuation
    public nonisolated let status: AsyncStream<LinkStatus>
    private nonisolated let statusSink: AsyncStream<LinkStatus>.Continuation
    private nonisolated let macCommands: AsyncStream<AssistantCommand>.Continuation

    private let engine: any AssistantConnection
    private let audio: (any RemoteAudioRouting)?
    private let identityStore: any IdentityStore
    private let storeURL: URL
    private let macName: String
    private let gracePeriod: Duration
    private var identity: DeviceIdentity?
    private var state = LinkStatus()
    private var pairingCode: PairingCode?
    private var listener: DirectListener?
    private var registration: RelayRegistration?
    private var registrationTasks: [Task<Void, Never>] = []
    private var sessions: [Data: Peer] = [:]
    private var hand: Hand?
    private var conversationActivity: (any NSObjectProtocol)?
    #if os(macOS)
    private let keepAwake = KeepAwake(reason: "OpenMaé: reachable from your iPhone")
    #endif

    // What the engine runs with, and what the iPhones are told when they connect.
    private var macSettings: AssistantSettings?
    /// Each device's way of talking (push-to-talk or not), applied while it has the conversation.
    private var phonePushToTalk: [Data: Bool] = [:]
    private var phase: AssistantEvent?
    private var pipelineState = PipelineState.listening

    private struct Peer {
        var session: LinkSession
        var device: PairedDevice
        var tasks: [Task<Void, Never>]
        /// It said it is a home station, on this session.
        var station = false
    }

    /// A home station, for what Maé says on her own while it does not have the conversation.
    private struct Station {
        /// Its voice, kept across its sessions: it follows the station when it comes back by another way.
        let output: RemoteVoiceOutput
        /// Its session closed: it has the grace period to come back, and announcements wait for it meanwhile.
        var grace: Task<Void, Never>?
    }

    private var stations: [Data: Station] = [:]
    /// When each device last took the conversation or sent a command: with several stations, the most recently used
    /// one speaks.
    private var lastUsed: [Data: ContinuousClock.Instant] = [:]
    /// What the engine was last told about announcements (see `updateAnnouncements`): the station they go to (nil:
    /// where the conversation is), and whether it hears them now.
    private var announcementsTold: (station: Data?, reachable: Bool) = (nil, true)

    /// The iPhone that has the conversation's sound.
    private struct Hand {
        var key: Data
        var microphone: RemoteMicrophone
        var output: RemoteVoiceOutput
        var feeding: Task<Void, Never>?
        /// The iPhone's connection dropped: it has a few seconds to come back before the Mac takes the sound back.
        var grace: Task<Void, Never>?
        /// When its microphone was last heard on its current session (nil: not since that session opened).
        var heard: ContinuousClock.Instant?
        /// When its microphone was last heard, on any session: the voice sent to it before then reached it.
        var lastHeard: ContinuousClock.Instant
        /// What the engine was last told: whether the iPhone hears the voice (see `updateReach`).
        var reachable = true
        /// Checks a few times a second that the iPhone is still heard.
        var watch: Task<Void, Never>?
    }

    /// The iPhone sends its microphone all the time it has the conversation (silence when muted). Nothing from it for
    /// this long: its connection is down (Wi-Fi off, a tunnel), even though its session may only be seen to close a
    /// minute later (when the iPhone could not say so), or its sound stopped (a phone call). Either way it does not hear
    /// the voice for now.
    static let silenceLimit = Duration.seconds(1)

    /// The voice sent this long before the iPhone was last heard may still have been on its way when its connection
    /// dropped: it is taken as not heard (a round trip through the relay over a cellular network, with room to spare).
    static let inFlight = Duration.milliseconds(300)

    /// A new session from the iPhone that has the conversation, heard on the one it replaces this recently: it changes
    /// its way (from the relay to the local network, at a silence) rather than coming back from a drop, which takes
    /// longer (it has to notice the drop, then look for the Mac both ways).
    static let changeOfWay = Duration.milliseconds(300)

    /// A device that checks its round trips pings every second (`LinkSession.peerChecksRoundTrips`): nothing from it for
    /// this long, its network went (airplane mode, its Wi-Fi gone at the router) without a word reaching the Mac, whose
    /// session with it would only close a minute later. See `watchSilence`.
    static let connectionLost = Duration.seconds(3)

    /// `audio`: nil when the engine cannot switch its sound (a demonstration engine): the iPhones then see and
    /// command the conversation without sound. `gracePeriod`: how long an iPhone whose connection dropped keeps the
    /// conversation, to come back by another way, before the Mac takes the sound back.
    public init(engine: any AssistantConnection, audio: (any RemoteAudioRouting)?, identityStore: any IdentityStore,
                storeURL: URL, macName: String, gracePeriod: Duration = .seconds(15))
    {
        self.engine = engine
        self.audio = audio
        self.identityStore = identityStore
        self.storeURL = storeURL
        self.macName = macName
        self.gracePeriod = gracePeriod
        (events, emit) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (status, statusSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (commandStream, commands) = AsyncStream<AssistantCommand>.makeStream(bufferingPolicy: .unbounded)
        macCommands = commands
        Task { [weak self] in
            for await command in commandStream { await self?.handleMac(command) }
        }
        Task { [weak self, engine] in
            for await event in engine.events { await self?.forward(event) }
        }
        Task { await self.load() }
    }

    /// Where the link keeps its iPhones and settings, next to the models.
    public static var defaultStoreURL: URL {
        AppIdentity.modelsDirectory.deletingLastPathComponent().appending(path: "Link/link.json")
    }

    // MARK: - The Mac's interface

    public nonisolated func send(_ command: AssistantCommand) {
        macCommands.yield(command)
    }

    private func handleMac(_ command: AssistantCommand) async {
        switch command {
        case .start(let settings):
            macSettings = settings
            engine.send(.start(effective(settings)))
        case .updateSettings(let settings):
            macSettings = settings
            engine.send(.updateSettings(effective(settings)))
        case .talkKey(pressed: true) where hand != nil:
            // Someone speaks on the Mac: the Mac takes the conversation back.
            await releaseHand(notifyPhone: true)
            engine.send(command)
        default:
            engine.send(command)
        }
    }

    /// The settings as the engine gets them: while an iPhone has the conversation, its own way of talking
    /// (hands-free or hold to talk; never the wake word, which the iPhone does not offer).
    private func effective(_ settings: AssistantSettings) -> AssistantSettings {
        var settings = settings
        if let hand, let phonePushToTalk = phonePushToTalk[hand.key] {
            settings.listening = phonePushToTalk ? .pushToTalk : .handsFree
        } else if hand != nil, settings.listening == .wakeWord {
            settings.listening = .handsFree
        }
        return settings
    }

    private func sendEngineSettings() {
        guard let macSettings else { return }
        engine.send(.updateSettings(effective(macSettings)))
    }

    /// "Reprendre ici": the Mac takes the conversation back.
    public func takeBack() async {
        await releaseHand(notifyPhone: true)
    }

    // MARK: - Pairing, devices, settings

    public func startPairing() async {
        if identity == nil {
            // The Mac's keys are made the first time an iPhone is added.
            do {
                identity = try identityStore.loadOrCreate()
            } catch {
                DebugLog.log("link: cannot make the Mac's keys (\(error))")
            }
        }
        guard let identity else { return }
        let code = PairingCode()
        pairingCode = code
        let link = PairingLink(macID: identity.id, macKey: identity.publicKey, relay: state.relayChoice.url,
                               code: code.code, macName: macName)
        state.pairing = .waiting(link, expires: code.expires)
        updateNetwork()
        publish()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(PairingCode.lifetime))
            await self?.pairingExpired(code)
        }
    }

    public func cancelPairing() {
        pairingCode = nil
        state.pairing = .idle
        updateNetwork()
        publish()
    }

    private func pairingExpired(_ code: PairingCode) {
        guard pairingCode?.code == code.code, case .waiting = state.pairing else { return }
        pairingCode = nil
        state.pairing = .expired
        updateNetwork()
        publish()
    }

    public func remove(_ deviceID: String) async {
        guard let device = state.devices.first(where: { $0.id == deviceID }) else { return }
        state.devices.removeAll { $0.id == deviceID }
        save()
        if hand?.key == device.publicKey { await releaseHand(notifyPhone: false) }
        if let station = stations.removeValue(forKey: device.publicKey) {
            station.grace?.cancel()
            station.output.detach()
        }
        lastUsed[device.publicKey] = nil
        phonePushToTalk[device.publicKey] = nil
        if let peer = sessions.removeValue(forKey: device.publicKey) {
            peer.tasks.forEach { $0.cancel() }
            // Told, so that it shows it must be paired again rather than "the Mac does not answer".
            peer.session.send(.removed)
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                peer.session.close()
            }
        }
        DebugLog.log("link: iPhone removed")
        updateNetwork()
        publish()
        await updateAnnouncements()
    }

    public func setRelay(_ choice: RelayChoice) {
        guard choice != state.relayChoice else { return }
        state.relayChoice = choice
        save()
        stopRegistration()
        updateNetwork()
        if case .waiting = state.pairing { Task { await startPairing() } }  // the QR code carries the relay
        // The iPhones follow: those connected now, and the others when they next connect (the handshake says it).
        for peer in sessions.values { peer.session.send(.mac(aboutThisMac)) }
        publish()
    }

    /// What the Mac tells the iPhones about itself: its name, the relay to reach it by, and the optional messages it
    /// understands.
    private var aboutThisMac: HandshakePayload.Mac {
        HandshakePayload.Mac(name: macName, relay: state.relayChoice.url, features: [LinkMessage.deviceFeature])
    }

    public func setKeepAwake(_ on: Bool) {
        state.keepAwake = on
        save()
        updateKeepAwake()
        publish()
    }

    // MARK: - Storage

    private struct Stored: Codable {
        var devices: [PairedDevice] = []
        var relay = RelayChoice.official
        var keepAwake = true
    }

    private func load() {
        do {
            identity = try identityStore.load()
        } catch {
            DebugLog.log("link: cannot read the Mac's keys (\(error)); iPhone access is off")
        }
        if let data = try? Data(contentsOf: storeURL), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            state.devices = stored.devices
            state.relayChoice = stored.relay
            state.keepAwake = stored.keepAwake
        }
        updateNetwork()
        updateKeepAwake()
        publish()
    }

    private func save() {
        let stored = Stored(devices: state.devices, relay: state.relayChoice, keepAwake: state.keepAwake)
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: storeURL, options: .atomic)
        } catch {
            DebugLog.log("link: cannot save the iPhones (\(error))")
        }
    }

    private func publish() {
        state.stations = Set(sessions.values.filter(\.station).map(\.device.id))
        updateActivity()
        statusSink.yield(state)
    }

    /// While an iPhone has the conversation, the Mac's own sound is off and its window often hidden: macOS would
    /// then slow the app down (App Nap: its timers stretched threefold in a test) and could put the Mac to sleep in
    /// the middle of an answer.
    private func updateActivity() {
        if state.hand != nil, conversationActivity == nil {
            conversationActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical], reason: "An iPhone is in a conversation with OpenMaé")
        } else if state.hand == nil, let activity = conversationActivity {
            ProcessInfo.processInfo.endActivity(activity)
            conversationActivity = nil
        }
    }

    // MARK: - Network

    /// Listening and registered with the relay while there is an iPhone to serve, or one being paired.
    private func updateNetwork() {
        let needed = identity != nil && (!state.devices.isEmpty || pairingCode != nil)
        if needed, listener == nil, let identity {
            let listener = DirectListener(macID: identity.id)
            listener.onReadyChange = { [weak self] ready in Task { await self?.setLocal(ready) } }
            self.listener = listener
            listener.start()
            Task { [weak self] in
                for await transport in listener.connections {
                    Task { await self?.handle(transport) }
                }
            }
        } else if !needed, let listener {
            listener.stop()
            self.listener = nil
            state.local = false
        }
        if needed, registration == nil, let relay = state.relayChoice.url, let identity {
            let registration = RelayRegistration(relay: relay, identity: identity)
            self.registration = registration
            registrationTasks = [
                Task { [weak self] in
                    for await status in registration.status { await self?.setRelay(status) }
                },
                Task { [weak self] in
                    for await tube in registration.tubes {
                        Task { [weak self] in
                            do {
                                let transport = try await RelayClient.accept(relay: relay, tube: tube)
                                await self?.handle(transport)
                            } catch {
                                DebugLog.log("link: could not accept a tube (\(error))")
                            }
                        }
                    }
                },
            ]
            Task { await registration.start() }
        } else if !needed || state.relayChoice.url == nil {
            stopRegistration()
        }
        updateKeepAwake()
    }

    /// The port of the local listener, once it listens (for the tests).
    var directPort: UInt16? { listener?.port }

    private func stopRegistration() {
        registrationTasks.forEach { $0.cancel() }
        registrationTasks = []
        if let registration { Task { await registration.stop() } }
        registration = nil
        state.relay = .off
    }

    private func setLocal(_ ready: Bool) {
        state.local = ready
        publish()
    }

    private func setRelay(_ status: RelayRegistration.Status) {
        guard registration != nil else { return }
        switch status {
        case .connecting:
            if state.relay == .off { state.relay = .connecting }
        case .registered: state.relay = .registered
        case .unreachable, .inboundOff: state.relay = .unreachable  // the second only for an inbound registration
        }
        publish()
    }

    private func updateKeepAwake() {
        #if os(macOS)
        keepAwake.set(state.keepAwake && !state.devices.isEmpty)
        #endif
    }

    // MARK: - Connections

    /// A connection arrived, directly or through the relay: Noise says who it is.
    private func handle(_ transport: any LinkTransport) async {
        guard let identity else {
            transport.close()
            return
        }
        let inbox = FrameInbox(transport)
        let deadline = LinkSession.closeAfter(transport, seconds: 10)
        defer { deadline.cancel() }
        do {
            let outcome = try await HostHandshake.respond(
                over: transport, inbox: inbox, identity: identity, mac: aboutThisMac,
                pairingCode: { await self.currentPairingCode() },
                completePairing: { key, phone in await self.completePairing(key: key, phone: phone) },
                isPaired: { key in await self.isPaired(key) })
            switch outcome {
            case .paired:
                // Let the verdict reach the iPhone before closing.
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    transport.close()
                }
            case .session(let keys, let key, let phone):
                guard let device = state.devices.first(where: { $0.publicKey == key }) else {
                    transport.close()
                    return
                }
                deadline.cancel()
                let session = LinkSession(transport: transport, inbox: inbox, keys: keys, peerKey: key, peerMac: nil,
                                          peerPhone: phone)
                await open(session, device: device)
            }
        } catch let HandshakeFailure.refused(code) {
            // Let the refusal reach the iPhone before closing (a closed connection drops what is still on its way).
            DebugLog.log("link: handshake refused (\(code))")
            Task {
                try? await Task.sleep(for: .seconds(1))
                transport.close()
            }
        } catch {
            DebugLog.log("link: handshake ended (\(error))")
            transport.close()
        }
    }

    private func currentPairingCode() -> Data? {
        guard let pairingCode, pairingCode.isValid() else { return nil }
        return pairingCode.code
    }

    /// The pairing handshake succeeded: the iPhone is added, unless the code was used meanwhile.
    private func completePairing(key: Data, phone: HandshakePayload.Phone) -> Bool {
        guard var code = pairingCode, code.isValid() else { return false }
        code.use()
        pairingCode = nil
        let device = PairedDevice(publicKey: key, name: phone.name, model: phone.model)
        state.devices.removeAll { $0.publicKey == key }
        state.devices.append(device)
        state.pairing = .added(device)
        save()
        DebugLog.log("link: iPhone added")
        updateNetwork()
        publish()
        return true
    }

    private func isPaired(_ key: Data) -> Bool {
        state.devices.contains { $0.publicKey == key }
    }

    /// A paired iPhone's session is open (internal for the tests, which open sessions over memory).
    func open(_ session: LinkSession, device: PairedDevice) async {
        let key = device.publicKey
        let previous = sessions.removeValue(forKey: key)
        if let previous {
            // The same iPhone again (another network, another path): the new connection replaces the old one.
            previous.tasks.forEach { $0.cancel() }
            previous.session.close()
        }
        // A station back on a new connection, or within its grace period, is one until it says otherwise (it says it
        // right away, `LinkMessage.device`): its voice follows it at once.
        let station = stations[key] != nil && (previous?.station == true || stations[key]?.grace != nil)
        if station, var known = stations[key] {
            known.grace?.cancel()
            known.grace = nil
            known.output.bind(session)
            stations[key] = known
        }
        DebugLog.log("link: iPhone connected (\(session.path.rawValue))")
        // What the iPhone needs to show the conversation at once.
        if let phase { session.send(.event(phase)) }
        session.send(.event(.state(pipelineState)))
        if var hand, hand.key == key {
            hand.grace?.cancel()
            hand.grace = nil
            hand.output.bind(session)
            // Heard again once its microphone is, on this session: then its end of it is surely up. Not after a change of
            // way: it is not out of reach meanwhile, which would cut a sentence the user is starting.
            let changesWay = previous != nil && hand.heard.map { ContinuousClock.now - $0 < Self.changeOfWay } == true
            if !changesWay { hand.heard = nil }
            self.hand = hand
            state.hand = LinkStatus.Hand(device: device, path: session.path)
        }
        let tasks = [
            Task { [weak self] in
                for await message in session.messages { await self?.received(message, from: key) }
            },
            Task { [weak self] in
                for await packet in session.audio { await self?.received(packet, from: key) }
            },
            Task { [weak self] in
                await session.waitUntilClosed()
                await self?.closed(session, key: key)
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, await self.watchSilence(session, key: key) else { return }
                }
            },
        ]
        sessions[key] = Peer(session: session, device: device, tasks: tasks, station: station)
        publish()
        await updateReach()
        await updateAnnouncements()
    }

    private func closed(_ session: LinkSession, key: Data) async {
        guard let peer = sessions[key], peer.session === session else { return }
        sessions.removeValue(forKey: key)
        peer.tasks.forEach { $0.cancel() }
        DebugLog.log("link: iPhone disconnected")
        if peer.station, hand?.key != key, var station = stations[key] {
            // A station's Wi-Fi drops, or the Mac's: it has the grace period to come back; what Maé says on her own
            // waits for it meanwhile, rather than being said to nobody. (One that has the conversation is waited for
            // as the conversation's device is, below.) A drop nobody told the Mac of is seen within seconds
            // (`watchSilence`).
            station.output.bind(nil)
            station.grace?.cancel()
            station.grace = Task { [weak self, gracePeriod] in
                try? await Task.sleep(for: gracePeriod)
                guard !Task.isCancelled else { return }
                await self?.stationGraceOver(key)
            }
            stations[key] = station
        }
        if var hand, hand.key == key, hand.grace == nil {
            // Wi-Fi to 4G, a tunnel: the iPhone has a few seconds to come back by another way. A sentence the user was
            // saying is cut, not ended as if they had stopped talking: the engine is told it is out of reach, below.
            hand.grace = Task { [weak self, gracePeriod] in
                try? await Task.sleep(for: gracePeriod)
                guard !Task.isCancelled else { return }
                await self?.graceOver(key)
            }
            self.hand = hand
        }
        publish()
        await updateReach()  // meanwhile its voice reaches nobody
        await updateAnnouncements()
    }

    /// A device that pings every second, not heard for `connectionLost`: its network went without a word reaching the
    /// Mac. Its session is closed as if it had said so (`closed`): a home station has its grace period to come back, and
    /// what Maé says on her own waits for it meanwhile, rather than going into the dead session for a minute. Not the
    /// device that has the conversation: it is out of reach after a second without its microphone (`hears`), and
    /// waited for as before, its session closing after a minute of silence, then its grace period. A device that does
    /// not ping every second (an app from before) is not judged on a few seconds of silence. False once the session is
    /// over or replaced.
    private func watchSilence(_ session: LinkSession, key: Data) -> Bool {
        guard sessions[key]?.session === session, session.isOpen else { return false }
        let silence = session.silence
        guard hand?.key != key, session.peerChecksRoundTrips, silence > Self.connectionLost else { return true }
        DebugLog.log("link: nothing heard for \(LinkSession.seconds(silence)) from a device that pings every second, "
                     + "closing its session")
        session.close()
        return false
    }

    private func graceOver(_ key: Data) async {
        guard hand?.key == key, sessions[key] == nil else { return }
        DebugLog.log("link: the iPhone did not come back, the Mac takes the sound back")
        await releaseHand(notifyPhone: false)
    }

    // MARK: - What the iPhones say

    private func received(_ message: LinkMessage, from key: Data) async {
        switch message {
        case .command(let command):
            guard RemoteCommandPolicy.isAllowed(command) else {
                DebugLog.log("link: refused a command reserved to the Mac")
                return
            }
            switch command {
            case .updateSettings(let settings):
                // Only the way of talking is the iPhone's to choose.
                phonePushToTalk[key] = settings.listening == .pushToTalk
                if hand?.key == key { sendEngineSettings() }
            case .talkKey(pressed: true):
                lastUsed[key] = .now
                await takeHand(key)
                engine.send(command)
            default:
                lastUsed[key] = .now
                engine.send(command)
            }
        case .audio(.start):
            await takeHand(key)
        case .audio(.stop):
            if hand?.key == key { await releaseHand(notifyPhone: false) }
        case .audio(.finished(let stream)):
            if hand?.key == key { hand?.output.markFinished(stream) }
            stations[key]?.output.markFinished(stream)  // an announcement it played without the conversation
        case .device(let station):
            await deviceSaid(station: station, key: key)
        case .audio, .event, .ping, .pong, .paired, .removed, .mac:
            break
        }
    }

    /// An iPad says whether it is a home station now: station mode on, plugged in, the app in the foreground.
    private func deviceSaid(station: Bool, key: Data) async {
        guard var peer = sessions[key], peer.station != station else { return }
        peer.station = station
        sessions[key] = peer
        if station {
            if var known = stations[key] {
                known.grace?.cancel()
                known.grace = nil
                known.output.bind(peer.session)
                stations[key] = known
            } else {
                stations[key] = Station(output: RemoteVoiceOutput(session: peer.session))
            }
            if lastUsed[key] == nil { lastUsed[key] = .now }
            DebugLog.log("link: an iPad is a home station")
        } else if let known = stations.removeValue(forKey: key) {
            known.grace?.cancel()
            known.output.detach()
            DebugLog.log("link: the iPad is no longer a home station")
        }
        publish()
        await updateAnnouncements()
    }

    private func stationGraceOver(_ key: Data) async {
        guard let station = stations[key], station.grace != nil, sessions[key]?.station != true else { return }
        DebugLog.log("link: the station did not come back, announcements go where the conversation is")
        stations[key] = nil
        station.output.detach()
        await updateAnnouncements()
    }

    /// Where what Maé says on her own goes, following the rule "the last one who speaks has the conversation":
    ///
    /// - a home station connected (with several, the most recently used one): on it, through its own voice
    ///   output, wherever the conversation is (the Mac keeps its microphone, an iPhone away keeps the conversation);
    ///   unless that station has the conversation: then like an answer, through the conversation's output;
    /// - a station whose session just closed, within its grace period, and no other connected: nowhere yet, the
    ///   announcements wait for it to come back (as for the device that has the conversation, `updateReach`);
    /// - otherwise, as without stations: on the device that has the conversation, or on the Mac.
    private func updateAnnouncements() async {
        // Again after telling: a station may have come or gone meanwhile.
        while true {
            let wanted = announcementsWanted
            guard wanted != announcementsTold else { return }
            announcementsTold = wanted
            let output = wanted.station.flatMap { stations[$0]?.output }
            switch (output, wanted.reachable) {
            case (nil, _): DebugLog.log("link: announcements go where the conversation is")
            case (_?, true): DebugLog.log("link: announcements go to the home station")
            case (_?, false): DebugLog.log("link: announcements wait for the home station to come back")
            }
            await audio?.announceThrough(output, reachable: wanted.reachable)
        }
    }

    private var announcementsWanted: (station: Data?, reachable: Bool) {
        func mostRecent(_ keys: [Data]) -> Data? {
            keys.max { (lastUsed[$0] ?? .now) < (lastUsed[$1] ?? .now) }
        }
        let connected = sessions.filter { $0.value.station && stations[$0.key] != nil }.map(\.key)
        let waiting = stations.filter { $0.value.grace != nil && $0.key != hand?.key }.map(\.key)
        if let station = mostRecent(connected) {
            return station == hand?.key ? (nil, true) : (station, true)
        }
        if let station = mostRecent(waiting) { return (station, false) }
        return (nil, true)
    }

    private func received(_ packet: AudioPacket, from key: Data) async {
        guard let hand, hand.key == key else { return }
        hand.microphone.receive(packet)
        self.hand?.heard = .now
        self.hand?.lastHeard = .now
        if !hand.reachable { await updateReach() }
    }

    /// The iPhone `key` takes the conversation: the engine's microphone and voice go to it.
    private func takeHand(_ key: Data) async {
        guard hand?.key != key, let peer = sessions[key] else { return }
        if hand != nil { await releaseHand(notifyPhone: true, toLocal: false) }
        let microphone = RemoteMicrophone()
        let output = RemoteVoiceOutput(session: peer.session)
        let watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, await self.hand?.key == key else { return }  // it let go
                await self.updateReach()
            }
        }
        // It just asked for the conversation: it is heard.
        hand = Hand(key: key, microphone: microphone, output: output, heard: .now, lastHeard: .now, watch: watch)
        lastUsed[key] = .now
        state.hand = LinkStatus.Hand(device: peer.device, path: peer.session.path)
        DebugLog.log("link: the iPhone has the conversation")
        await audio?.useRemoteAudio(microphone: microphone.samples, output: output, bargeIn: peer.device.kind.bargeIn)
        sendEngineSettings()
        publish()
        await updateAnnouncements()
    }

    /// The Mac takes the sound back (or another iPhone takes it: `toLocal: false`).
    private func releaseHand(notifyPhone: Bool, toLocal: Bool = true) async {
        guard let hand else { return }
        self.hand = nil
        state.hand = nil
        hand.grace?.cancel()
        hand.watch?.cancel()
        // What it was saying, it will not say it played (an announcement is then said again): that waits for the
        // voice's next output, the Mac's speakers or another iPhone's, rather than going into this one meanwhile.
        if hand.reachable { await audio?.setRemoteAudioReachable(false, reachedUntil: hand.lastHeard - Self.inFlight) }
        hand.microphone.finish()
        hand.output.detach()
        if notifyPhone { sessions[hand.key]?.session.send(.audio(.released)) }
        if toLocal {
            DebugLog.log("link: the Mac has the conversation again")
            await audio?.useLocalAudio()
            sendEngineSettings()
        }
        publish()
        if toLocal { await updateAnnouncements() }  // otherwise the next device's `takeHand` does
    }

    /// Whether the iPhone that has the conversation hears the voice now: its session is open and its microphone was
    /// heard on it a moment ago.
    private func hears(_ hand: Hand) -> Bool {
        guard sessions[hand.key] != nil, let heard = hand.heard else { return false }
        return ContinuousClock.now - heard < Self.silenceLimit
    }

    /// Tells the engine when the iPhone that has the conversation stops hearing the voice (its session closed, or
    /// nothing came from it for a moment) and when it hears it again, so that what the app says on its own (a timer
    /// that rings) waits for it rather than being said to nobody, and what Maé or the user was saying is cut there (an
    /// answer is said again from the sentence that was cut once it is back, a sentence of the user's is asked again).
    /// If it does not come back, its session ends (at once, or after a minute of silence when the iPhone could not say
    /// so), then the grace period, and the Mac takes the sound back and says the announcements.
    private func updateReach() async {
        // Again after telling: the iPhone may have come and gone meanwhile.
        while let hand, hand.reachable != hears(hand) {
            let reachable = !hand.reachable
            self.hand?.reachable = reachable
            DebugLog.log(reachable ? "link: the iPhone hears the voice again"
                : "link: the iPhone is out of reach, what Maé says on her own waits")
            // What was sent to it before it was last heard reached it.
            let reachedUntil = reachable ? nil : hand.lastHeard - Self.inFlight
            await audio?.setRemoteAudioReachable(reachable, reachedUntil: reachedUntil)
        }
    }

    // MARK: - The engine's events

    private func forward(_ event: AssistantEvent) {
        emit.yield(event)
        switch event {
        case .ready, .loading, .setupNeeded, .problem: phase = event
        case .state(let state): pipelineState = state
        default: break
        }
        guard let relayed = RemoteCommandPolicy.relayed(event), !sessions.isEmpty else { return }
        // An optional event only to the devices that understand it: one from before it would close the session on it.
        let feature = RemoteCommandPolicy.neededFeature(relayed)
        for peer in sessions.values where feature.map({ peer.session.peerPhone?.understands($0) == true }) ?? true {
            peer.session.send(.event(relayed))
        }
    }
}

/// Marketing names of the recent iPhones and iPads, from their model identifiers.
enum DeviceModels {
    static func marketingName(_ model: String) -> String? {
        let names: [String: String] = [
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro",
            "iPhone13,4": "iPhone 12 Pro Max", "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
            "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,6": "iPhone SE",
            "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max", "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max", "iPhone17,3": "iPhone 16",
            "iPhone17,4": "iPhone 16 Plus", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,5": "iPhone 16e", "iPhone18,3": "iPhone 17", "iPhone18,1": "iPhone 17 Pro",
            "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,4": "iPhone Air",
            // iPads, Wi-Fi and cellular.
            "iPad11,1": "iPad mini 5", "iPad11,2": "iPad mini 5", "iPad14,1": "iPad mini 6", "iPad14,2": "iPad mini 6",
            "iPad16,1": "iPad mini (A17 Pro)", "iPad16,2": "iPad mini (A17 Pro)",
            "iPad11,6": "iPad 8", "iPad11,7": "iPad 8", "iPad12,1": "iPad 9", "iPad12,2": "iPad 9",
            "iPad13,18": "iPad 10", "iPad13,19": "iPad 10", "iPad15,7": "iPad (A16)", "iPad15,8": "iPad (A16)",
            "iPad11,3": "iPad Air 3", "iPad11,4": "iPad Air 3", "iPad13,1": "iPad Air 4", "iPad13,2": "iPad Air 4",
            "iPad13,16": "iPad Air 5", "iPad13,17": "iPad Air 5",
            "iPad14,8": "iPad Air (M2)", "iPad14,9": "iPad Air (M2)", "iPad14,10": "iPad Air (M2)",
            "iPad14,11": "iPad Air (M2)", "iPad15,3": "iPad Air (M3)", "iPad15,4": "iPad Air (M3)",
            "iPad15,5": "iPad Air (M3)", "iPad15,6": "iPad Air (M3)",
            "iPad13,4": "iPad Pro (M1)", "iPad13,5": "iPad Pro (M1)", "iPad13,6": "iPad Pro (M1)",
            "iPad13,7": "iPad Pro (M1)", "iPad13,8": "iPad Pro (M1)", "iPad13,9": "iPad Pro (M1)",
            "iPad13,10": "iPad Pro (M1)", "iPad13,11": "iPad Pro (M1)",
            "iPad14,3": "iPad Pro (M2)", "iPad14,4": "iPad Pro (M2)", "iPad14,5": "iPad Pro (M2)",
            "iPad14,6": "iPad Pro (M2)", "iPad16,3": "iPad Pro (M4)", "iPad16,4": "iPad Pro (M4)",
            "iPad16,5": "iPad Pro (M4)", "iPad16,6": "iPad Pro (M4)",
        ]
        return names[model]
    }
}
