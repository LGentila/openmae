import Foundation
import Network
import VoiceCore

/// The Mac an iPhone is paired with.
public struct PairedMac: Codable, Sendable, Equatable {
    public var id: String
    /// Its Noise static key.
    public var publicKey: Data
    public var name: String
    /// nil: no relay, reachable at home only.
    public var relay: URL?

    public init(id: String, publicKey: Data, name: String, relay: URL?) {
        self.id = id
        self.publicKey = publicKey
        self.name = name
        self.relay = relay
    }
}

/// What the iPhone's player gets: the voice's frames and what the Mac says about its streams.
public enum VoiceInput: Sendable {
    case packet(AudioPacket)
    /// The stream has that many frames in all.
    case end(stream: UInt32, frames: UInt32)
    /// The user interrupted: stop playing that stream now.
    case stop(stream: UInt32)
    /// The Mac took the conversation back.
    case released
}

/// The iPhone's side of the link: finds the Mac (directly at home, through the relay elsewhere, whichever answers
/// first, the direct way preferred), keeps the session open, and comes back on its own after a cut. It is the
/// iPhone interface's `AssistantConnection`: the screens are built from the same events as the Mac's.
public actor PhoneLink: AssistantConnection {
    public enum Status: Sendable, Equatable {
        case connecting
        case connected(LinkPath)
        /// The connection was lost; trying again, the conversation is kept.
        case reconnecting
        /// The Mac does not answer: asleep, off, or out of reach. Tried again regularly.
        case unreachable
        /// The Mac no longer knows this iPhone (it was removed from its settings).
        case forgotten
    }

    public nonisolated let events: AsyncStream<AssistantEvent>
    private nonisolated let eventSink: AsyncStream<AssistantEvent>.Continuation
    public nonisolated let status: AsyncStream<Status>
    private nonisolated let statusSink: AsyncStream<Status>.Continuation
    public nonisolated let voice: AsyncStream<VoiceInput>
    private nonisolated let voiceSink: AsyncStream<VoiceInput>.Continuation
    /// The Mac, each time it says it has a new name or relay: to be kept for the next launches.
    public nonisolated let macChanges: AsyncStream<PairedMac>
    private nonisolated let macSink: AsyncStream<PairedMac>.Continuation
    private nonisolated let current = SessionBox()

    public private(set) var mac: PairedMac
    private let identity: DeviceIdentity
    private let ways: Set<LinkPath>
    private let browser: DirectBrowser
    private var loop: Task<Void, Never>?
    private var upgrade: Task<Void, Never>?
    private var wakeUp: AsyncStream<Void>.Continuation?
    private var audioWanted = false
    /// An iPad: whether it is a home station now (nil: it never said, as on an iPhone).
    private var station: Bool?
    private var settings: AssistantSettings?
    private var pipelineState = PipelineState.listening
    private var currentStatus = Status.connecting
    /// A direct session that replaces the relayed one (see `watchForDirectWay`).
    private var pendingSwitch: LinkSession?
    /// The Mac said it removed this iPhone.
    private var forgotten = false

    /// `ways`: both by default; one only for tests (`voice-cli link-client --relay-only`).
    public init(mac: PairedMac, identity: DeviceIdentity, ways: Set<LinkPath> = [.direct, .relay]) {
        self.mac = mac
        self.identity = identity
        self.ways = ways
        browser = DirectBrowser(macID: mac.id)
        (events, eventSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (status, statusSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (voice, voiceSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(500))
        (macChanges, macSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: - Commands

    public nonisolated func send(_ command: AssistantCommand) {
        Task { await self.handle(command) }
    }

    private func handle(_ command: AssistantCommand) {
        if case .updateSettings(let settings) = command { self.settings = settings }
        current.session?.send(.command(command))
    }

    /// The conversation's sound: on, the Mac hands over its microphone and speakers to this iPhone.
    public func setAudio(_ on: Bool) {
        guard on != audioWanted else { return }
        audioWanted = on
        current.session?.send(.audio(on ? .start : .stop))
    }

    /// An iPad: whether it is a home station now (station mode on, plugged in, the app in the foreground). Told to the
    /// Mac at once, and again on each new session.
    public func setStation(_ on: Bool) {
        guard on != station else { return }
        station = on
        if let session = current.session, let message = Self.deviceMessage(station: on, to: session.peerMac) {
            session.send(message)
        }
    }

    /// The `device` message for a Mac: only to one that understands it, since a Mac from before closes the session on
    /// a message it does not know (and the device would reconnect again and again).
    public static func deviceMessage(station: Bool?, to mac: HandshakePayload.Mac?) -> LinkMessage? {
        guard let station, mac?.understands(LinkMessage.deviceFeature) == true else { return nil }
        return .device(station: station)
    }

    /// The microphone's frames, sent as they come (no hop through the actor).
    public nonisolated func sendMicrophone(_ packet: AudioPacket) {
        current.session?.send(packet)
    }

    /// The player played everything of `stream`, or stopped it.
    public nonisolated func finished(stream: UInt32) {
        current.session?.send(.audio(.finished(stream: stream)))
    }

    public var isConnected: Bool { current.session != nil }

    // MARK: - Connection

    public func connect() {
        guard loop == nil else {
            wakeUp?.yield()  // "Try again": no more waiting
            return
        }
        browser.start()
        loop = Task { await run() }
    }

    public func disconnect() {
        loop?.cancel()
        loop = nil
        upgrade?.cancel()
        upgrade = nil
        browser.stop()
        current.session?.close()
        current.session = nil
    }

    private func setStatus(_ status: Status) {
        currentStatus = status
        statusSink.yield(status)
    }

    private func run() async {
        setStatus(.connecting)
        var failures = 0
        while !Task.isCancelled {
            let session: LinkSession
            if let pending = pendingSwitch, pending.isOpen {
                pendingSwitch = nil
                session = pending
            } else {
                pendingSwitch = nil
                do {
                    session = try await attempt()
                    failures = 0
                } catch HandshakeFailure.refused("unknown_device") {
                    setStatus(.forgotten)
                    return
                } catch {
                    if Task.isCancelled { return }
                    failures += 1
                    DebugLog.log("link: cannot reach the Mac (\(error))")
                    // After a second failure the Mac is said not to answer; the attempts go on, further apart.
                    if failures >= 2 { setStatus(.unreachable) }
                    await pause(seconds: min(30, failures < 3 ? 1 : pow(2, Double(failures - 2))))
                    continue
                }
            }
            await use(session)
            if Task.isCancelled { return }
            if forgotten {
                setStatus(.forgotten)
                return
            }
            if pendingSwitch == nil {
                setStatus(.reconnecting)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// Waits before the next attempt; "Try again" or the Mac appearing on the local network cut it short.
    private func pause(seconds: Double) async {
        let (signal, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakeUp = continuation
        browser.onChange = { endpoint in if endpoint != nil { continuation.yield() } }
        await withTaskGroup(of: Void.self) { tasks in
            tasks.addTask { for await _ in signal { return } }
            tasks.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            await tasks.next()
            tasks.cancelAll()
        }
        browser.onChange = nil
        wakeUp = nil
    }

    /// Both ways at once, the direct one preferred: the relay's tube is opened meanwhile, but its session only once
    /// the direct way gave up (the Mac keeps the newest session of an iPhone, so two sessions must not race).
    private func attempt() async throws -> LinkSession {
        let mac = mac, identity = identity, browser = browser
        let direct = DirectOutcome()
        return try await withThrowingTaskGroup(of: LinkSession?.self) { tasks in
            if ways.contains(.direct) {
                tasks.addTask {
                    do {
                        // The Mac is usually found on the local network within a second, if it is there.
                        for _ in 0..<15 {
                            if let endpoint = browser.endpoint {
                                let transport = try await DirectBrowser.connect(to: endpoint)
                                let session = try await LinkSession.open(over: transport, macKey: mac.publicKey,
                                                                         identity: identity)
                                await direct.settle(won: true)
                                return session
                            }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                        await direct.settle(won: false)
                        return nil
                    } catch {
                        await direct.settle(won: false)
                        throw error
                    }
                }
            } else {
                await direct.settle(won: false)
            }
            if let relay = mac.relay, ways.contains(.relay) {
                tasks.addTask {
                    let transport = try await RelayClient.connect(relay: relay, to: mac.id)
                    if await direct.won() {
                        transport.close()
                        return nil
                    }
                    return try await LinkSession.open(over: transport, macKey: mac.publicKey, identity: identity)
                }
            }
            var winner: LinkSession?
            var failure: Error?
            while let result = await tasks.nextResult() {
                switch result {
                case .success(let session?):
                    if winner == nil {
                        winner = session
                        tasks.cancelAll()
                    } else {
                        session.close()  // the slower way answered too
                    }
                case .success(nil):
                    break
                case .failure(let error):
                    // A refusal from the Mac is the most telling failure.
                    if failure == nil || error is HandshakeFailure { failure = error }
                }
            }
            if let winner { return winner }
            throw failure ?? TransportError.timeout
        }
    }

    /// Runs a session until it closes.
    private func use(_ session: LinkSession) async {
        current.session = session
        if let about = session.peerMac { learn(about) }
        setStatus(.connected(session.path))
        if let settings { session.send(.command(.updateSettings(settings))) }
        if let message = Self.deviceMessage(station: station, to: session.peerMac) { session.send(message) }
        if audioWanted { session.send(.audio(.start)) }
        if session.path == .relay, ways.contains(.direct) { watchForDirectWay() }
        await withTaskGroup(of: Void.self) { tasks in
            tasks.addTask {
                for await message in session.messages { await self.received(message) }
            }
            tasks.addTask { [voiceSink] in
                for await packet in session.audio { voiceSink.yield(.packet(packet)) }
            }
            await tasks.waitForAll()
        }
        if current.session === session { current.session = nil }
        upgrade?.cancel()
        upgrade = nil
    }

    private func received(_ message: LinkMessage) {
        switch message {
        case .event(let event):
            if case .state(let state) = event { pipelineState = state }
            eventSink.yield(event)
        case .audio(.end(let stream, let frames)): voiceSink.yield(.end(stream: stream, frames: frames))
        case .audio(.stopPlayback(let stream)): voiceSink.yield(.stop(stream: stream))
        case .audio(.released):
            audioWanted = false
            voiceSink.yield(.released)
        case .removed:
            forgotten = true
        case .mac(let about):
            learn(about)
        default:
            break
        }
    }

    /// What the Mac says about itself now. The iPhone follows the relay its Mac chose: the pairing link only gave
    /// the one of that day.
    private func learn(_ about: HandshakePayload.Mac) {
        var updated = mac
        updated.name = about.name
        updated.relay = about.relay
        guard updated != mac else { return }
        if updated.relay != mac.relay {
            DebugLog.log("link: the Mac's relay is now \(updated.relay?.absoluteString ?? "none")")
        }
        mac = updated
        macSink.yield(updated)
    }

    /// On the relay while the Mac appears on the local network: the session moves to the direct way at the next
    /// silence (a moment of sound may be lost, never a word in the middle of a sentence).
    private func watchForDirectWay() {
        upgrade?.cancel()
        let mac = mac, identity = identity, browser = browser
        upgrade = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let endpoint = browser.endpoint, self.pipelineState == .listening,
                      self.current.session?.path == .relay
                else { continue }
                do {
                    let transport = try await DirectBrowser.connect(to: endpoint)
                    let session = try await LinkSession.open(over: transport, macKey: mac.publicKey, identity: identity)
                    DebugLog.log("link: moving to the direct way")
                    self.switchTo(session)
                    return
                } catch {
                    try? await Task.sleep(for: .seconds(10))
                }
            }
        }
    }

    private func switchTo(_ session: LinkSession) {
        // The run loop's `use` ends with the previous session and picks up this one at once.
        pendingSwitch = session
        current.session?.close()
    }
}

/// Whether the direct way won the race to the Mac, once it is known.
private actor DirectOutcome {
    private var outcome: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func settle(won: Bool) {
        guard outcome == nil else { return }
        outcome = won
        waiters.forEach { $0.resume(returning: won) }
        waiters = []
    }

    func won() async -> Bool {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

/// The current session, readable from any thread (the microphone's frames do not wait for the actor).
final class SessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LinkSession?

    var session: LinkSession? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

// MARK: - Pairing

public enum PhonePairing {
    /// Pairs with the Mac of the QR code, directly if it is on the same network, or through its relay. Whichever
    /// way answers first wins; the code then refuses the other. `ways`: both, except in tests.
    public static func pair(link: PairingLink, identity: DeviceIdentity, phone: HandshakePayload.Phone,
                            ways: Set<LinkPath> = [.direct, .relay]) async throws -> PairedMac
    {
        let browser = DirectBrowser(macID: link.macID)
        if ways.contains(.direct) { browser.start() }
        defer { browser.stop() }
        let name: String = try await withThrowingTaskGroup(of: String?.self) { tasks in
            if ways.contains(.direct) {
                tasks.addTask {
                    for _ in 0..<30 {
                        if let endpoint = browser.endpoint {
                            let transport = try await DirectBrowser.connect(to: endpoint)
                            return try await LinkSession.pair(over: transport, link: link, identity: identity,
                                                              phone: phone)
                        }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    return nil
                }
            }
            if let relay = link.relay, ways.contains(.relay) {
                tasks.addTask {
                    let transport = try await RelayClient.connect(relay: relay, to: link.macID)
                    return try await LinkSession.pair(over: transport, link: link, identity: identity, phone: phone)
                }
            }
            var failure: Error?
            while let result = await tasks.nextResult() {
                switch result {
                case .success(let name?):
                    tasks.cancelAll()
                    return name
                case .success(nil):
                    DebugLog.log("link: pairing: the Mac was not found on the local network")
                case .failure(let error):
                    DebugLog.log("link: pairing attempt failed (\(error))")
                    if failure == nil || error is HandshakeFailure { failure = error }
                }
            }
            throw failure ?? TransportError.timeout
        }
        return PairedMac(id: link.macID, publicKey: link.macKey, name: name, relay: link.relay)
    }
}
