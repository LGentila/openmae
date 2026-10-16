import CryptoKit
import Foundation
import Network
import Security

/// One connection that carries the end-to-end layer: an ordered, reliable byte stream and unreliable datagrams.
/// Direct (QUIC on the local network) or through a relay (QUIC, or WebSocket when UDP is blocked).
public protocol LinkTransport: AnyObject, Sendable {
    var path: LinkPath { get }
    /// What arrives, in order, then `.closed`. Single consumer.
    var incoming: AsyncStream<TransportInput> { get }
    /// Bytes of the reliable stream (already framed by the caller).
    func send(_ bytes: Data)
    /// One datagram; dropped silently if it cannot be sent.
    func sendDatagram(_ datagram: Data)
    func close()
}

public enum TransportInput: Sendable {
    case bytes(Data)
    case datagram(Data)
    /// The connection ended; a reason when it failed.
    case closed(String?)
}

/// How the iPhone and the Mac are linked.
public enum LinkPath: String, Sendable, Codable, Equatable {
    /// On the same local network.
    case direct
    /// Through a relay.
    case relay
}

/// The QUIC side of things: TLS options, a throwaway certificate for the Mac's listener, the relay's pinned key.
enum QUIC {
    static let directALPN = "openmae/1"
    static let relayALPN = "openmae-relay/1"
    static let queue = DispatchQueue(label: "OpenMaeLink.quic", qos: .userInteractive)

    enum Verification: Sendable {
        /// A direct connection: TLS is only QUIC's mandatory envelope. The Mac's certificate is not checked, on
        /// purpose — the Mac is authenticated by Noise, inside (its key is known since pairing).
        case none
        /// A relay: its key must be one of these SHA-256 pins of its SubjectPublicKeyInfo (from its /v1/info).
        case pinned([Data])
    }

    static func options(alpn: String, server identity: SecIdentity? = nil,
                        verification: Verification = .none) -> NWProtocolQUIC.Options
    {
        let options = NWProtocolQUIC.Options(alpn: [alpn])
        options.maxDatagramFrameSize = 1350
        options.idleTimeout = 60_000
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        if let identity, let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(security, secIdentity)
        } else {
            sec_protocol_options_set_verify_block(security, { _, trust, complete in
                switch verification {
                case .none: complete(true)
                case .pinned(let pins): complete(spkiPin(of: sec_trust_copy_ref(trust).takeRetainedValue())
                    .map(pins.contains) ?? false)
                }
            }, queue)
        }
        return options
    }

    /// SHA-256 of the leaf certificate's SubjectPublicKeyInfo (P-256 keys, as the relay uses).
    static func spkiPin(of trust: SecTrust) -> Data? {
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              let key = SecCertificateCopyKey(leaf),
              let point = SecKeyCopyExternalRepresentation(key, nil) as Data?, point.count == 65
        else { return nil }
        // DER header of an id-ecPublicKey / prime256v1 SubjectPublicKeyInfo, followed by the uncompressed point.
        let header = Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08,
                           0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00])
        return Data(SHA256.hash(data: header + point))
    }

    /// A self-signed certificate made in memory for the Mac's listener, never stored: TLS needs one, nobody checks
    /// it (see `Verification.none`).
    static func throwawayIdentity() throws -> SecIdentity {
        let key = P256.Signing.PrivateKey()
        func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
            let n = content.count
            let length: [UInt8] = n < 0x80 ? [UInt8(n)] : n < 0x100 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 0xFF)]
            return [tag] + length + content
        }
        func sequence(_ parts: [UInt8]...) -> [UInt8] { der(0x30, parts.flatMap { $0 }) }
        func oid(_ bytes: [UInt8]) -> [UInt8] { der(0x06, bytes) }
        func time(_ date: Date) -> [UInt8] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return der(0x17, Array(formatter.string(from: date).utf8))
        }
        let ecdsaWithSHA256 = sequence(oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))
        let name = sequence(der(0x31, sequence(oid([0x55, 0x04, 0x03]), der(0x0C, Array("OpenMae".utf8)))))
        let publicKeyInfo = sequence(
            sequence(oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]), oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])),
            der(0x03, [0] + Array(key.publicKey.x963Representation)))
        var serial = (0..<8).map { _ in UInt8.random(in: 0...255) }
        serial[0] = serial[0] & 0x7F | 0x01
        let now = Date()
        // A version 1 certificate: serial, signature algorithm, issuer, validity, subject, key. Nothing else is needed.
        let tbs = sequence(der(0x02, serial), ecdsaWithSHA256, name,
                           sequence(time(now - 86_400), time(now + 86_400 * 365)), name, publicKeyInfo)
        let signature = try key.signature(for: Data(tbs)).derRepresentation
        let signed = sequence(tbs, ecdsaWithSHA256, der(0x03, [0] + Array(signature)))
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                                           kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        guard let cert = SecCertificateCreateWithData(nil, Data(signed) as CFData),
              let secKey = SecKeyCreateWithData(key.x963Representation as CFData, attributes as CFDictionary, nil),
              let identity = SecIdentityCreate(nil, cert, secKey)
        else { throw TransportError.certificate }
        return identity
    }
}

public enum TransportError: Error, Equatable, Sendable {
    case certificate
    case timeout
    case failed(String)
    case closed
}

/// A QUIC connection: its first bidirectional stream is the reliable channel, its datagram flow the datagrams.
///
/// Network.framework gives each side its own datagram flow; each side makes it as soon as the connection is up, and
/// nobody sends a datagram before the handshake on the stream is over, so none is lost to a flow not made yet.
final class QUICTransport: LinkTransport, @unchecked Sendable {
    let path: LinkPath
    let incoming: AsyncStream<TransportInput>
    private let sink: AsyncStream<TransportInput>.Continuation
    private let group: NWConnectionGroup
    private let lock = NSLock()
    private var stream: NWConnection?
    private var datagrams: NWConnection?
    /// The flows the peer opened (server side), kept until the end.
    private var inboundFlows: [NWConnection] = []
    private var isClosed = false

    /// `stream`: the reliable stream, already open (client side). The server side waits for the client's.
    private init(group: NWConnectionGroup, path: LinkPath) {
        self.group = group
        self.path = path
        (incoming, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: Opening

    /// Connects to `endpoint` and opens the reliable stream and the datagram flow. `receiving: false` leaves the
    /// stream to `readExactly` until `startReceiving()` (the relay's control exchange comes first).
    static func connect(to endpoint: NWEndpoint, alpn: String, verification: QUIC.Verification, path: LinkPath,
                        receiving: Bool = true, timeout: Duration = .seconds(8)) async throws -> QUICTransport
    {
        let parameters = NWParameters(quic: QUIC.options(alpn: alpn, verification: verification))
        let group = NWConnectionGroup(with: NWMultiplexGroup(to: endpoint), using: parameters)
        let transport = QUICTransport(group: group, path: path)
        // A client must say what to do with the peer's streams before starting, or the group never starts.
        group.newConnectionHandler = { $0.cancel() }
        try await transport.start(timeout: timeout) { group in
            guard let stream = NWConnection(from: group) else { return false }
            transport.useStream(stream, receiving: receiving)
            return true
        }
        return transport
    }

    /// The server side of a connection accepted by `DirectListener`: ready once the client's stream arrived.
    static func accept(_ group: NWConnectionGroup, timeout: Duration = .seconds(8)) async throws -> QUICTransport {
        let transport = QUICTransport(group: group, path: .direct)
        let streamArrived = AsyncStream<Void>.makeStream()
        group.newConnectionHandler = { [weak transport] connection in
            guard let transport else {
                connection.cancel()
                return
            }
            // Network.framework also announces the client's datagram flow as a new flow, which never becomes ready
            // (this side's own datagram flow is the one that receives): the reliable channel is the first flow to
            // become ready.
            transport.lock.withLock { transport.inboundFlows.append(connection) }
            connection.stateUpdateHandler = { [weak transport, weak connection] state in
                guard let transport, let connection else { return }
                switch state {
                case .ready:
                    let chosen: Bool = transport.lock.withLock {
                        guard transport.stream == nil else { return false }
                        transport.stream = connection
                        return true
                    }
                    guard chosen else { return }
                    transport.watch(connection)
                    transport.receiveBytes(on: connection)
                    streamArrived.continuation.yield()
                    streamArrived.continuation.finish()
                case .failed, .cancelled:
                    if transport.lock.withLock({ transport.stream === connection }) { transport.finish(nil) }
                default:
                    break
                }
            }
            connection.start(queue: QUIC.queue)
        }
        try await transport.start(timeout: timeout) { _ in true }
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { for await _ in streamArrived.stream { return } }
            tasks.addTask {
                try await Task.sleep(for: timeout)
                throw TransportError.timeout
            }
            try await tasks.next()
            tasks.cancelAll()
        }
        return transport
    }

    /// Starts the group; once it is ready, `ready` opens what this side opens, then the datagram flow is made.
    private func start(timeout: Duration, ready: @escaping @Sendable (NWConnectionGroup) -> Bool) async throws {
        let outcome = AsyncStream<Result<Void, Error>>.makeStream()
        group.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if ready(self.group) {
                    self.makeDatagramFlow()
                    outcome.continuation.yield(.success(()))
                } else {
                    outcome.continuation.yield(.failure(TransportError.failed("no stream")))
                }
            case .failed(let error):
                outcome.continuation.yield(.failure(TransportError.failed("\(error)")))
                self.finish("\(error)")
            case .waiting(let error):
                // Unreachable for now (no route, nobody listening): give up at once rather than wait for a network.
                if case .posix(let code) = error, code == .ENETDOWN { return }  // reported briefly while starting
                outcome.continuation.yield(.failure(TransportError.failed("\(error)")))
            case .cancelled:
                outcome.continuation.yield(.failure(TransportError.closed))
                self.finish(nil)
            default:
                break
            }
        }
        group.start(queue: QUIC.queue)
        do {
            let result = try await withThrowingTaskGroup(of: Result<Void, Error>.self) { tasks in
                tasks.addTask {
                    for await result in outcome.stream { return result }
                    return .failure(TransportError.closed)
                }
                tasks.addTask {
                    try await Task.sleep(for: timeout)
                    return .failure(TransportError.timeout)
                }
                defer { tasks.cancelAll() }
                return try await tasks.next()!
            }
            try result.get()
        } catch {
            close()  // timed out, failed or cancelled: nothing stays open
            throw error
        }
    }

    private func useStream(_ stream: NWConnection, receiving: Bool) {
        lock.withLock { self.stream = stream }
        watch(stream)
        stream.start(queue: QUIC.queue)
        if receiving { receiveBytes(on: stream) }
    }

    /// The reliable stream ending ends the transport.
    private func watch(_ stream: NWConnection) {
        stream.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error): self?.finish("\(error)")
            case .cancelled: self?.finish(nil)
            default: break
            }
        }
    }

    private func makeDatagramFlow() {
        let options = NWProtocolQUIC.Options()
        options.isDatagram = true
        guard let flow = NWConnection(from: group, using: options) else { return }
        lock.withLock { datagrams = flow }
        flow.start(queue: QUIC.queue)
        receiveDatagrams(on: flow)
    }

    // MARK: Receiving

    private func receiveBytes(on stream: NWConnection) {
        stream.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.sink.yield(.bytes(data)) }
            if let error {
                self.finish("\(error)")
            } else if isComplete {
                self.finish(nil)
            } else {
                self.receiveBytes(on: stream)
            }
        }
    }

    private func receiveDatagrams(on flow: NWConnection) {
        flow.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.sink.yield(.datagram(data)) }
            if error == nil { self.receiveDatagrams(on: flow) }
        }
    }

    // MARK: Sending

    func send(_ bytes: Data) {
        guard let stream = lock.withLock({ isClosed ? nil : stream }) else { return }
        stream.send(content: bytes, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish("\(error)") }
        })
    }

    func sendDatagram(_ datagram: Data) {
        guard let flow = lock.withLock({ isClosed ? nil : datagrams }) else { return }
        flow.send(content: datagram, completion: .idempotent)
    }

    /// Reads exactly `count` bytes of the stream before `incoming` takes over: the relay's answer, whatever
    /// follows it staying in the stream for the tube.
    func readExactly(_ count: Int) async throws -> Data {
        guard let stream = lock.withLock({ stream }) else { throw TransportError.closed }
        return try await withCheckedThrowingContinuation { continuation in
            stream.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error.map { TransportError.failed("\($0)") } ?? TransportError.closed)
                }
            }
        }
    }

    /// For the relay's control exchange: the stream is read by `readExactly` until this is called.
    func startReceiving() {
        guard let stream = lock.withLock({ stream }) else { return }
        receiveBytes(on: stream)
    }

    // MARK: Closing

    func close() {
        finish(nil)
    }

    private func finish(_ reason: String?) {
        let (flows, group): ([NWConnection], NWConnectionGroup?) = lock.withLock {
            guard !isClosed else { return ([], nil) }
            isClosed = true
            defer { inboundFlows = [] }
            return ([stream, datagrams].compactMap { $0 } + inboundFlows, self.group)
        }
        guard let group else { return }
        flows.forEach { $0.cancel() }
        group.cancel()
        sink.yield(.closed(reason))
        sink.finish()
    }
}
