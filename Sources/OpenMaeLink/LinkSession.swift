import Foundation
import VoiceCore

/// An open session between the iPhone and the Mac, over one transport: encrypted messages on the reliable channel,
/// sound in encrypted datagrams. Either side keeps it alive with a ping every 25 s, and gives up after 60 s
/// without hearing anything. The iPhone also checks that the Mac answers (`checkRoundTrips`), to see within seconds
/// that its network went or changed under the session; as those pings come every second, the Mac can tell as quickly
/// that the iPhone's network went (`peerChecksRoundTrips`, `silence`: see `LinkHost.watchSilence`).
public final class LinkSession: @unchecked Sendable {
    /// How the iPhone checks that the Mac still answers on its session: a ping every `every`, which the Mac answers with
    /// a pong (any version of it does). Hearing the Mac is not enough: its voice may still reach the iPhone while
    /// nothing the iPhone sends reaches the Mac.
    ///
    /// No answer for `giveUpAfter`: the network went (airplane mode, a tunnel) or changed under the session, and the
    /// session is closed, so that a new one is opened as soon as the network is back, rather than a minute later. A
    /// session that lived through a long cut does not come back reliably (heard again for a second, then lost again),
    /// and the Mac may close its end only after a minute without hearing anything (while the iPhone has the
    /// conversation; after a few seconds otherwise, `LinkHost.connectionLost`).
    ///
    /// After a change of network (Wi-Fi back, another address, Wi-Fi to cellular), the Mac must answer a ping sent then
    /// within `afterNetworkChange`, or the session is closed.
    public struct RoundTrips: Sendable, Equatable {
        public var every: Duration
        public var giveUpAfter: Duration
        public var afterNetworkChange: Duration

        public init(every: Duration, giveUpAfter: Duration, afterNetworkChange: Duration) {
            self.every = every
            self.giveUpAfter = giveUpAfter
            self.afterNetworkChange = afterNetworkChange
        }

        /// A round trip through the relay over a cellular network takes well under a second, retransmissions
        /// included, and the Mac answers at once, whatever its engine is doing (the session's own task does). The Mac
        /// itself takes the iPhone as out of reach after a second without its microphone.
        public static let standard = RoundTrips(every: .seconds(1), giveUpAfter: .seconds(4),
                                                afterNetworkChange: .milliseconds(1500))
    }

    public let path: LinkPath
    /// The peer's Noise static key.
    public let peerKey: Data
    /// What the Mac said about itself in the handshake (its name and relay), for the iPhone.
    public let peerMac: HandshakePayload.Mac?
    /// What the iPhone said about itself when it opened the session (the optional events it understands), for the Mac.
    public let peerPhone: HandshakePayload.Session?
    public let messages: AsyncStream<LinkMessage>
    public let audio: AsyncStream<AudioPacket>
    private let messageSink: AsyncStream<LinkMessage>.Continuation
    private let audioSink: AsyncStream<AudioPacket>.Continuation
    private let transport: any LinkTransport
    private let lock = NSLock()
    private var keys: SessionKeys
    private var lastSent = ContinuousClock.now
    private var lastHeard = ContinuousClock.now
    private var isClosed = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var tasks: [Task<Void, Never>] = []
    // The round trips (iPhone): pings sent and pongs heard, which answer them in order on the reliable channel.
    private var roundTrips: RoundTrips?
    private var pingsSent = 0
    private var pongsHeard = 0
    private var lastPong = ContinuousClock.now
    /// After a change of network: the pongs needed (up to that of the ping sent then), and by when.
    private var awaitedPong: (count: Int, by: ContinuousClock.Instant)?
    // The peer's pings (Mac): when the last one came (the session's start, before any), and whether it checks its round
    // trips.
    private var lastPingHeard = ContinuousClock.now
    private var pingsEverySecond = false

    /// A ping this soon after the session opened, or after the peer's previous one: the peer checks its round trips
    /// (`checkRoundTrips` pings at once, then every second). One that does not, an app from before them, pings only once
    /// it has sent nothing for 25 s (`keepAlive`).
    static let roundTripPings = Duration.seconds(5)

    init(transport: any LinkTransport, inbox: FrameInbox, keys: SessionKeys, peerKey: Data,
         peerMac: HandshakePayload.Mac?, peerPhone: HandshakePayload.Session? = nil) {
        self.transport = transport
        self.keys = keys
        self.peerKey = peerKey
        self.peerMac = peerMac
        self.peerPhone = peerPhone
        path = transport.path
        (messages, messageSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (audio, audioSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(100))
        tasks = [
            Task { [weak self] in await self?.read(inbox) },
            Task { [weak self] in await self?.keepAlive() },
        ]
    }

    public var isOpen: Bool { lock.withLock { !isClosed } }

    /// Mac: whether the peer checks its round trips (`checkRoundTrips`), as the app does since they exist: it pings
    /// every second, so that a few seconds without hearing it mean that its network went. False for an app from before
    /// them (a ping every 25 s): only a minute without hearing it says so (`keepAlive`).
    public var peerChecksRoundTrips: Bool { lock.withLock { pingsEverySecond } }

    /// How long nothing has come from the peer: no message, no sound, no ping or pong.
    public var silence: Duration { lock.withLock { ContinuousClock.now - lastHeard } }

    public func send(_ message: LinkMessage) {
        lock.withLock { _ = sendLocked(message) }
    }

    /// With the lock held. Whether it went out.
    private func sendLocked(_ message: LinkMessage) -> Bool {
        guard !isClosed, let frame = try? keys.seal(message) else { return false }
        lastSent = .now
        if case .ping = message { pingsSent += 1 }
        transport.send(Frame.encode(frame))
        return true
    }

    public func send(_ packet: AudioPacket) {
        lock.withLock {
            guard !isClosed, let datagram = try? keys.sendDatagrams.seal(packet.encoded) else { return }
            transport.sendDatagram(datagram)
        }
    }

    public func close() {
        let (waiters, tasks): ([CheckedContinuation<Void, Never>], [Task<Void, Never>]) = lock.withLock {
            guard !isClosed else { return ([], []) }
            isClosed = true
            defer {
                closeWaiters = []
                self.tasks = []
            }
            return (closeWaiters, self.tasks)
        }
        tasks.forEach { $0.cancel() }
        transport.close()
        messageSink.finish()
        audioSink.finish()
        waiters.forEach { $0.resume() }
    }

    /// Returns once the session is closed, by either side.
    public func waitUntilClosed() async {
        await withCheckedContinuation { continuation in
            let closed = lock.withLock {
                if isClosed { return true }
                closeWaiters.append(continuation)
                return false
            }
            if closed { continuation.resume() }
        }
    }

    private func read(_ inbox: FrameInbox) async {
        while true {
            switch await inbox.next() {
            case .frame(let frame):
                let message: Result<LinkMessage, Error>? = lock.withLock {
                    lastHeard = .now
                    return keys.read(frame)
                }
                switch message {
                case .success(.ping)?:
                    lock.withLock {
                        if ContinuousClock.now - lastPingHeard < Self.roundTripPings { pingsEverySecond = true }
                        lastPingHeard = .now
                    }
                    send(.pong)
                case .success(.pong)?:
                    lock.withLock {
                        pongsHeard += 1
                        lastPong = .now
                        if let awaited = awaitedPong, pongsHeard >= awaited.count { awaitedPong = nil }
                    }
                case .success(let message)?: messageSink.yield(message)
                case .failure?:
                    // A newer peer's message of a kind this version does not know: the channel is fine, it is skipped.
                    DebugLog.log("link: a message of an unknown kind, ignored")
                case nil:
                    // A frame that does not decrypt breaks the channel (its nonces are now out of step).
                    DebugLog.log("link: undecryptable message, closing the session")
                    close()
                    return
                }
            case .datagram(let datagram):
                let packet: AudioPacket? = lock.withLock {
                    guard let plaintext = keys.receiveDatagrams.open(datagram) else { return nil }
                    lastHeard = .now
                    return AudioPacket(plaintext)
                }
                if let packet { audioSink.yield(packet) }
            case .closed(let reason):
                if let reason { DebugLog.log("link: session closed (\(reason))") }
                close()
                return
            }
        }
    }

    private func keepAlive() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            let (silentFor, quietFor) = lock.withLock { (ContinuousClock.now - lastHeard, ContinuousClock.now - lastSent) }
            if silentFor > .seconds(60) {
                DebugLog.log("link: nothing heard for a minute, closing the session")
                close()
                return
            }
            if quietFor > .seconds(25) { send(.ping) }
        }
    }

    // MARK: Round trips (iPhone)

    /// iPhone: from now on, checks that the Mac answers (`RoundTrips`), and closes the session when it does not.
    public func checkRoundTrips(_ policy: RoundTrips) {
        let task = Task<Void, Never> { [weak self] in await self?.watchRoundTrips(policy) }
        let started: Bool = lock.withLock {
            guard !isClosed, roundTrips == nil else { return false }
            roundTrips = policy
            lastPong = .now
            tasks.append(task)
            return true
        }
        if !started { task.cancel() }
    }

    /// iPhone: the device's network changed. The session may not live through it (a new address, another interface):
    /// the Mac must answer a ping sent now within `RoundTrips.afterNetworkChange`, or the session is closed. Again at
    /// each change.
    public func networkChanged() {
        lock.withLock {
            guard let roundTrips, sendLocked(.ping) else { return }
            awaitedPong = (pingsSent, .now + roundTrips.afterNetworkChange)
        }
    }

    private func watchRoundTrips(_ policy: RoundTrips) async {
        let tick = min(policy.every, .milliseconds(250))
        var nextPing = ContinuousClock.now
        while !Task.isCancelled {
            let now = ContinuousClock.now
            if now >= nextPing {
                send(.ping)
                nextPing = now + policy.every
            }
            let (unanswered, awaited) = lock.withLock { (now - lastPong, awaitedPong) }
            if unanswered > policy.giveUpAfter {
                DebugLog.log("link: the Mac has not answered for \(Self.seconds(unanswered)), closing the session")
                close()
                return
            }
            if let awaited, now >= awaited.by {
                DebugLog.log("link: the Mac did not answer after the network changed, closing the session")
                close()
                return
            }
            try? await Task.sleep(for: tick)
        }
    }

    static func seconds(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.1f s", seconds)
    }
}

extension LinkSession {
    /// iPhone: opens a session with the paired Mac over `transport`.
    public static func open(over transport: any LinkTransport, macKey: Data,
                            identity: DeviceIdentity) async throws -> LinkSession
    {
        let inbox = FrameInbox(transport)
        let deadline = closeAfter(transport, seconds: 10)
        defer { deadline.cancel() }
        do {
            let (keys, mac) = try await PhoneHandshake.openSession(over: transport, inbox: inbox, macKey: macKey,
                                                                   identity: identity)
            return LinkSession(transport: transport, inbox: inbox, keys: keys, peerKey: macKey, peerMac: mac)
        } catch {
            transport.close()
            throw error
        }
    }

    /// iPhone: pairs with the Mac of `link` over `transport`; returns the Mac's name.
    public static func pair(over transport: any LinkTransport, link: PairingLink, identity: DeviceIdentity,
                            phone: HandshakePayload.Phone) async throws -> String
    {
        let inbox = FrameInbox(transport)
        let deadline = closeAfter(transport, seconds: 15)
        defer {
            deadline.cancel()
            transport.close()
        }
        return try await PhoneHandshake.pair(over: transport, inbox: inbox, link: link, identity: identity, phone: phone)
    }

    /// Closes the transport if the handshake has not ended by then.
    static func closeAfter(_ transport: any LinkTransport, seconds: Double) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { transport.close() }
        }
    }
}
