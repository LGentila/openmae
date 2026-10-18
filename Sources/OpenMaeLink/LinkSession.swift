import Foundation
import VoiceCore

/// An open session between the iPhone and the Mac, over one transport: encrypted messages on the reliable channel,
/// sound in encrypted datagrams. Either side keeps it alive with a ping every 25 s, and gives up after 60 s
/// without hearing anything.
public final class LinkSession: @unchecked Sendable {
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

    public func send(_ message: LinkMessage) {
        lock.withLock {
            guard !isClosed, let frame = try? keys.seal(message) else { return }
            lastSent = .now
            transport.send(Frame.encode(frame))
        }
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
                case .success(.ping)?: send(.pong)
                case .success(.pong)?: break
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
