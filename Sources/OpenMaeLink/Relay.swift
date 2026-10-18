import CryptoKit
import Foundation
import Network
import VoiceCore

/// The relay's description, from `GET /v1/info` (relay/PROTOCOL.md).
public struct RelayInfo: Decodable, Sendable, Equatable {
    public struct QUICInfo: Decodable, Sendable, Equatable {
        public var port: UInt16
        public var alpn: String
        /// SHA-256 pins of the QUIC certificate's key, standard base64.
        public var spkiSHA256: [String]

        enum CodingKeys: String, CodingKey {
            case port, alpn
            case spkiSHA256 = "spki_sha256"
        }
    }

    public struct WebSocketInfo: Decodable, Sendable, Equatable {
        public var path: String
    }

    /// A relay that passes deliveries from the internet through to the Macs, unopened: their names are
    /// `<inbound name>.<domain>`.
    public struct InboundInfo: Decodable, Sendable, Equatable {
        public var domain: String
    }

    public var versions: [Int]
    public var quic: QUICInfo?
    public var websocket: WebSocketInfo?
    /// Whether this relay sends push notifications (only the official one can).
    public var push: Bool?
    /// Absent when the relay does not take deliveries from the internet.
    public var inbound: InboundInfo?
}

public enum RelayError: Error, Equatable, Sendable {
    /// The relay answered with an error code (`mac_offline`, `busy`…).
    case refused(String)
    case unsupported
    case unreachable(String)
}

/// The relay layer of relay/PROTOCOL.md, client side: discovery, the Mac's registration, tubes.
public enum RelayClient {
    /// The official relay.
    public static let official = URL(string: "https://relay.openmae.com")!

    static func info(_ relay: URL) async throws -> RelayInfo {
        var request = URLRequest(url: relay.appending(path: "v1/info"), timeoutInterval: 6)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RelayError.unreachable("info") }
            let info = try JSONDecoder().decode(RelayInfo.self, from: data)
            guard info.versions.contains(1) else { throw RelayError.unsupported }
            return info
        } catch let error as RelayError {
            throw error
        } catch {
            throw RelayError.unreachable("\(error.localizedDescription)")
        }
    }

    /// iPhone: a tube to the Mac `macID`.
    public static func connect(relay: URL, to macID: String) async throws -> any LinkTransport {
        try await open(relay: relay, request: ["op": "connect", "v": 1, "to": macID], answer: "connected",
                       timeout: .seconds(14))
    }

    /// Mac: the tube an iPhone asked for (the token came on the control connection).
    public static func accept(relay: URL, tube: String) async throws -> any LinkTransport {
        try await open(relay: relay, request: ["op": "accept", "v": 1, "tube": tube], answer: "accepted",
                       timeout: .seconds(8))
    }

    /// Opens a connection, sends `request`, waits for `answer`, then hands the connection over as the tube. QUIC
    /// first; WebSocket when QUIC cannot get through (UDP blocked on some networks), and straight away for a while
    /// after QUIC failed to reach that relay.
    private static func open(relay: URL, request: [String: Any], answer: String,
                             timeout: Duration) async throws -> any LinkTransport
    {
        let info = try await info(relay)
        var quicError: Error?
        if info.quic != nil, !QUICBlocked.shared.isBlocked(relay) {
            do {
                let channel = try await ControlChannel.quic(relay: relay, info: info)
                return try await channel.exchange(request, expecting: answer, timeout: timeout).tube()
            } catch let error as RelayError {
                if case .refused = error { throw error }  // the relay answered: no point trying again
                quicError = error
                QUICBlocked.shared.block(relay)
            } catch {
                quicError = error
                QUICBlocked.shared.block(relay)
            }
        }
        guard info.websocket != nil else { throw quicError ?? RelayError.unsupported }
        DebugLog.log("link: relay over QUIC failed (\(quicError.map { "\($0)" } ?? "blocked lately, or not offered")), trying WebSocket")
        let channel = try await ControlChannel.webSocket(relay: relay, info: info)
        return try await channel.exchange(request, expecting: answer, timeout: timeout).tube()
    }
}

/// Relays that QUIC could not reach lately: the network blocks UDP (some company or hotel Wi-Fi). WebSocket is used
/// at once for 10 minutes rather than waiting for QUIC to fail at every connection.
final class QUICBlocked: @unchecked Sendable {
    static let shared = QUICBlocked()
    private let lock = NSLock()
    private var until: [String: ContinuousClock.Instant] = [:]

    func isBlocked(_ relay: URL) -> Bool {
        lock.withLock { until[relay.host() ?? ""].map { $0 > .now } ?? false }
    }

    func block(_ relay: URL) {
        lock.withLock { until[relay.host() ?? ""] = .now + .seconds(600) }
    }

    func clear(_ relay: URL) {
        lock.withLock { until[relay.host() ?? ""] = nil }
    }
}

/// A connection to the relay while it is in control mode.
final class ControlChannel: @unchecked Sendable {
    private enum Kind {
        case quic(QUICTransport)
        case webSocket(URLSessionWebSocketTask)
    }

    private let kind: Kind

    private init(_ kind: Kind) {
        self.kind = kind
    }

    static func quic(relay: URL, info: RelayInfo) async throws -> ControlChannel {
        guard let quic = info.quic, let host = relay.host() else { throw RelayError.unsupported }
        let pins = quic.spkiSHA256.compactMap { Data(base64Encoded: $0) }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: quic.port)!)
        let transport = try await QUICTransport.connect(to: endpoint, alpn: quic.alpn, verification: .pinned(pins),
                                                        path: .relay, receiving: false, timeout: .seconds(4))
        return ControlChannel(.quic(transport))
    }

    static func webSocket(relay: URL, info: RelayInfo) async throws -> ControlChannel {
        guard var components = URLComponents(url: relay, resolvingAgainstBaseURL: false) else {
            throw RelayError.unsupported
        }
        components.scheme = relay.scheme == "http" ? "ws" : "wss"
        components.path = info.websocket?.path ?? "/v1/ws"
        guard let url = components.url else { throw RelayError.unsupported }
        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 1 << 20
        task.resume()
        return ControlChannel(.webSocket(task))
    }

    func send(_ message: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: message) else { return }
        switch kind {
        case .quic(let transport): transport.send(Frame.encode(json))
        case .webSocket(let task): task.send(.string(String(decoding: json, as: UTF8.self))) { _ in }
        }
    }

    /// The relay's next control message.
    func receive(timeout: Duration?) async throws -> [String: Any] {
        let data: Data = try await withThrowingTaskGroup(of: Data.self) { tasks in
            tasks.addTask { [kind] in
                switch kind {
                case .quic(let transport):
                    let header = try await transport.readExactly(4)
                    let length = header.reduce(0) { $0 << 8 | Int($1) }
                    guard length <= 4096 else { throw RelayError.unsupported }
                    return try await transport.readExactly(length)
                case .webSocket(let task):
                    switch try await task.receive() {
                    case .string(let text): return Data(text.utf8)
                    case .data(let data): return data
                    @unknown default: throw RelayError.unsupported
                    }
                }
            }
            if let timeout {
                tasks.addTask {
                    try await Task.sleep(for: timeout)
                    throw TransportError.timeout
                }
            }
            defer { tasks.cancelAll() }
            return try await tasks.next()!
        }
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RelayError.unsupported
        }
        if message["op"] as? String == "error" { throw RelayError.refused(message["code"] as? String ?? "error") }
        return message
    }

    /// Sends `request` and waits for the answer `op`.
    func exchange(_ request: [String: Any], expecting op: String, timeout: Duration) async throws -> ControlChannel {
        send(request)
        do {
            let answer = try await receive(timeout: timeout)
            guard answer["op"] as? String == op else { throw RelayError.unsupported }
        } catch {
            close()
            throw error
        }
        return self
    }

    /// Piping has started: the connection is now the tube.
    func tube() -> any LinkTransport {
        switch kind {
        case .quic(let transport):
            transport.startReceiving()
            return transport
        case .webSocket(let task):
            return WebSocketTransport(task: task)
        }
    }

    func close() {
        switch kind {
        case .quic(let transport): transport.close()
        case .webSocket(let task): task.cancel(with: .goingAway, reason: nil)
        }
    }
}

/// A tube over WebSocket: binary messages `0x01 | bytes` for the reliable stream, `0x02 | datagram`.
final class WebSocketTransport: LinkTransport, @unchecked Sendable {
    let path = LinkPath.relay
    let incoming: AsyncStream<TransportInput>
    private let sink: AsyncStream<TransportInput>.Continuation
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var isClosed = false

    init(task: URLSessionWebSocketTask) {
        self.task = task
        (incoming, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        receive()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.data(let data)):
                switch data.first {
                case 0x01: self.sink.yield(.bytes(Data(data.dropFirst())))
                case 0x02: self.sink.yield(.datagram(Data(data.dropFirst())))
                default: break
                }
                self.receive()
            case .success:
                self.receive()
            case .failure(let error):
                self.finish("\(error.localizedDescription)")
            }
        }
    }

    func send(_ bytes: Data) {
        guard lock.withLock({ !isClosed }) else { return }
        task.send(.data(Data([0x01]) + bytes)) { [weak self] error in
            if let error { self?.finish("\(error.localizedDescription)") }
        }
    }

    func sendDatagram(_ datagram: Data) {
        guard lock.withLock({ !isClosed }) else { return }
        task.send(.data(Data([0x02]) + datagram)) { _ in }
    }

    func close() {
        finish(nil)
    }

    private func finish(_ reason: String?) {
        let first: Bool = lock.withLock {
            defer { isClosed = true }
            return !isClosed
        }
        guard first else { return }
        task.cancel(with: .goingAway, reason: nil)
        sink.yield(.closed(reason))
        sink.finish()
    }
}

// MARK: - The Mac's registration

/// The Mac's control connection to its relay: registered with its Ed25519 key, it hears of the iPhones asking for
/// it. Reconnects on its own, waiting longer each time (1 s up to 30 s).
///
/// An inbound registration (`inbound: true`) is one more, for received information: with a relay in home mode on the
/// home network, or (`passthrough: true`) with the public relay, when it takes deliveries from the internet and passes
/// their TLS through unopened. It hears only of deliveries (`deliveries`), never of iPhones, and does not replace the
/// Mac's ordinary registration, even on the same relay. On the public relay it also leaves the answers to Let's
/// Encrypt's HTTP-01 challenge (`depositChallenge`).
public actor RelayRegistration {
    public enum Status: Sendable, Equatable {
        case connecting
        case registered
        /// The relay cannot be reached, or refused; it is tried again.
        case unreachable
        /// An inbound registration on a relay that does not take that kind of deliveries (not in home mode, or without
        /// an inbound domain for `passthrough`): tried again now and then.
        case inboundOff
    }

    /// A delivery waiting for the Mac on a relay in home mode: the tube to accept, and the caller's address.
    public struct Delivery: Sendable, Equatable {
        public var tube: String
        public var from: String
    }

    /// Tube tokens of the iPhones asking for this Mac.
    public nonisolated let tubes: AsyncStream<String>
    private nonisolated let tubeSink: AsyncStream<String>.Continuation
    public nonisolated let status: AsyncStream<Status>
    private nonisolated let statusSink: AsyncStream<Status>.Continuation
    /// Inbound registration only: the deliveries waiting for this Mac.
    public nonisolated let deliveries: AsyncStream<Delivery>
    private nonisolated let deliverySink: AsyncStream<Delivery>.Continuation
    public nonisolated let relay: URL
    public nonisolated let inbound: Bool
    /// An inbound registration with the public relay, whose deliveries are TLS connections passed through.
    public nonisolated let passthrough: Bool
    private let identity: DeviceIdentity
    private var loop: Task<Void, Never>?
    /// The control connection while registered.
    private var channel: ControlChannel?
    private let stored = ChallengeAcks()

    public init(relay: URL, identity: DeviceIdentity, inbound: Bool = false, passthrough: Bool = false) {
        self.relay = relay
        self.identity = identity
        self.inbound = inbound || passthrough
        self.passthrough = passthrough
        (tubes, tubeSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        (status, statusSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (deliveries, deliverySink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { await run() }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        tubeSink.finish()
        statusSink.finish()
        deliverySink.finish()
    }

    private func run() async {
        var wait = 1.0
        while !Task.isCancelled {
            statusSink.yield(.connecting)
            do {
                let channel = try await register()
                self.channel = channel
                statusSink.yield(.registered)
                DebugLog.log("link: registered with the relay\(passthrough ? " for deliveries from the internet" : "")")
                wait = 1
                defer {
                    self.channel = nil
                    stored.failAll()
                }
                try await listen(channel)
            } catch is CancellationError {
                return
            } catch RelayError.refused("inbound_off") {
                // A relay that is not in home mode will not be one in a few seconds.
                DebugLog.log(passthrough ? "link: the relay takes no deliveries from the internet"
                                         : "link: the home relay is not in home mode")
                statusSink.yield(.inboundOff)
                try? await Task.sleep(for: .seconds(60))
                continue
            } catch {
                DebugLog.log("link: relay registration lost (\(error))")
            }
            if Task.isCancelled { return }
            statusSink.yield(.unreachable)
            try? await Task.sleep(for: .seconds(wait))
            wait = min(wait * 2, 30)
        }
    }

    private func register() async throws -> ControlChannel {
        let info = try await RelayClient.info(relay)
        // Home deliveries come in clear, internet ones as TLS: each registration only with the relay that sends its
        // kind (a relay with an inbound domain is never in home mode).
        if inbound, (info.inbound != nil) != passthrough { throw RelayError.refused("inbound_off") }
        let channel: ControlChannel
        if info.quic != nil, !QUICBlocked.shared.isBlocked(relay),
           let quic = try? await ControlChannel.quic(relay: relay, info: info)
        {
            channel = quic
            QUICBlocked.shared.clear(relay)  // the network lets UDP through again
        } else if info.websocket != nil {
            if info.quic != nil { QUICBlocked.shared.block(relay) }
            channel = try await ControlChannel.webSocket(relay: relay, info: info)
        } else {
            throw RelayError.unsupported
        }
        do {
            var hello: [String: Any] = ["op": "hello", "v": 1, "role": "mac", "id": identity.id,
                                        "key": Base64URL.encode(identity.signingKey.publicKey.rawRepresentation)]
            if inbound { hello["inbound"] = true }
            channel.send(hello)
            let challenge = try await channel.receive(timeout: .seconds(8))
            guard challenge["op"] as? String == "challenge",
                  let nonce = (challenge["nonce"] as? String).flatMap(Base64URL.decode), nonce.count == 32
            else { throw RelayError.unsupported }
            let signature = try identity.signingKey.signature(for: Data("openmae-relay/1 register:".utf8) + nonce)
            channel.send(["op": "register", "sig": Base64URL.encode(signature)])
            let registered = try await channel.receive(timeout: .seconds(8))
            guard registered["op"] as? String == "registered" else { throw RelayError.unsupported }
            // A relay in home mode answers with the Mac's inbound name; an older one, or one not in home mode, without.
            if inbound, registered["inbound"] as? String != InboundName.make(
                signingKey: identity.signingKey.publicKey.rawRepresentation)
            {
                throw RelayError.refused("inbound_off")
            }
            return channel
        } catch {
            channel.close()
            throw error
        }
    }

    /// Hears of tubes and keeps the connection alive: a ping every 25 s, and the connection is given up when the
    /// relay stays silent 10 s after one.
    private func listen(_ channel: ControlChannel) async throws {
        defer { channel.close() }
        let tubeSink = tubeSink
        let deliverySink = deliverySink
        let inbound = inbound
        let stored = stored
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            let lastHeard = Clock()
            tasks.addTask {
                while true {
                    let message = try await channel.receive(timeout: nil)
                    lastHeard.touch()
                    switch message["op"] as? String {
                    case "incoming" where !inbound:
                        if let tube = message["tube"] as? String { tubeSink.yield(tube) }
                    case "inbound" where inbound:
                        if let tube = message["tube"] as? String {
                            deliverySink.yield(Delivery(tube: tube, from: message["from"] as? String ?? ""))
                        }
                    case "acme_challenge_stored":
                        if let token = message["token"] as? String { stored.resolve(token) }
                    default:
                        break
                    }
                }
            }
            tasks.addTask {
                while true {
                    try await Task.sleep(for: .seconds(25))
                    channel.send(["op": "ping"])
                    try await Task.sleep(for: .seconds(10))
                    if lastHeard.secondsSince > 34 { throw TransportError.timeout }
                }
            }
            defer { tasks.cancelAll() }
            try await tasks.next()
        }
    }

    /// Leaves the answer to an HTTP-01 challenge with the relay (`passthrough` only), which serves it to Let's Encrypt
    /// for 10 minutes; returns once the relay has it.
    public func depositChallenge(token: String, keyAuthorization: String) async throws {
        guard passthrough, let channel else { throw RelayError.unreachable("not registered") }
        try await stored.wait(token, timeout: .seconds(10)) {
            channel.send(["op": "acme_challenge", "token": token, "key_authorization": keyAuthorization])
        }
    }

    /// The relay's acknowledgements of the challenges left with it, by token.
    private final class ChallengeAcks: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [String: CheckedContinuation<Void, Error>] = [:]

        func wait(_ token: String, timeout: Duration, send: () -> Void) async throws {
            let timer = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { self?.fail(token, TransportError.timeout) }
            }
            defer { timer.cancel() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock { waiting[token] = continuation }
                send()
            }
        }

        func resolve(_ token: String) {
            lock.withLock { waiting.removeValue(forKey: token) }?.resume()
        }

        func fail(_ token: String, _ error: Error) {
            lock.withLock { waiting.removeValue(forKey: token) }?.resume(throwing: error)
        }

        func failAll() {
            let all = lock.withLock {
                defer { waiting = [:] }
                return Array(waiting.values)
            }
            all.forEach { $0.resume(throwing: RelayError.unreachable("registration lost")) }
        }
    }

    /// When the relay was last heard from.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var last = ContinuousClock.now
        func touch() { lock.withLock { last = .now } }
        var secondsSince: Double {
            let elapsed = lock.withLock { ContinuousClock.now - last }
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
    }
}
