#if os(macOS)
import CryptoKit
import Foundation
import Network
import Security
import VoiceCore

// Received information from the internet: the public relay passes each delivery's TLS connection, unopened, through a
// tube; the Mac pipes it into its own HTTPS server, bound to 127.0.0.1 only, which holds the certificate of the Mac's
// inbound name. No port opens on the network, and the relay never sees the secret or the text.

// MARK: - Keys

/// Where the keys of the internet path are kept: the ACME account's and the certificate's, as raw P-256 private keys.
public protocol InboundKeyStore: Sendable {
    func key(_ name: String) -> Data?
    /// Replaces it; nil removes it. False when it could not be saved.
    @discardableResult func setKey(_ key: Data?, _ name: String) -> Bool
}

/// The keychain, one item per key, never leaving this Mac.
public struct KeychainInboundKeys: InboundKeyStore {
    public let service: String

    public init(service: String = "\(AppIdentity.name) received information keys") {
        self.service = service
    }

    private func base(_ name: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name]
    }

    public func key(_ name: String) -> Data? {
        var query = base(name)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    public func setKey(_ key: Data?, _ name: String) -> Bool {
        SecItemDelete(base(name) as CFDictionary)
        guard let key else { return true }
        var item = base(name)
        item[kSecValueData] = key
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel] = "\(AppIdentity.name) — received information, \(name)"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

/// In memory: for the tests and the command-line tool.
public final class MemoryInboundKeys: InboundKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]

    public init() {}

    public func key(_ name: String) -> Data? { lock.withLock { keys[name] } }

    @discardableResult
    public func setKey(_ key: Data?, _ name: String) -> Bool {
        lock.withLock { keys[name] = key }
        return true
    }
}

// MARK: - The certificate

/// The certificate of the Mac's inbound name, as kept next to the sources (it is public), with the server it came from.
struct InboundCertificate: Codable, Sendable, Equatable {
    var domain: String
    /// The chain in PEM, leaf first.
    var chain: String
    var directory: URL

    var certificates: [SecCertificate] {
        PEM.certificates(in: chain).compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    }

    /// When it starts and stops being valid.
    var validity: (from: Date, until: Date)? {
        guard let leaf = certificates.first,
              let from = SecCertificateCopyNotValidBeforeDate(leaf) as Date?,
              let until = SecCertificateCopyNotValidAfterDate(leaf) as Date?
        else { return nil }
        return (from, until)
    }

    /// Renewed at two thirds of its lifetime: 60 days into Let's Encrypt's 90.
    var renewal: Date? {
        validity.map { $0.from + ($0.until.timeIntervalSince($0.from) * 2 / 3) }
    }

    /// The TLS identity: the leaf with its key, and the chain the server sends.
    func identity(key: P256.Signing.PrivateKey) -> (SecIdentity, [SecCertificate])? {
        let chain = certificates
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                                           kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        guard let leaf = chain.first,
              let secKey = SecKeyCreateWithData(key.x963Representation as CFData, attributes as CFDictionary, nil),
              let identity = SecIdentityCreate(nil, leaf, secKey)
        else { return nil }
        return (identity, chain)
    }
}

// MARK: - The HTTPS server

/// HTTPS on 127.0.0.1 only, on a port the system chooses. The public relay's tubes are piped into it (`pipe`), and
/// each connection that comes through one is handed over, TLS ended, with its caller's address. Any other connection
/// (another program of this Mac) is closed.
final class InboundTLSServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: NWEndpoint.Port?
    /// The callers of the connections being piped, by the local port each pipe connects from.
    private var callers: [UInt16: String] = [:]
    private let queue = DispatchQueue(label: "OpenMaeLink.inbound-tls")
    private let handle: @Sendable (any LinkTransport, String) -> Void

    /// `handle`: each connection that came through a tube, and its caller.
    init(handle: @escaping @Sendable (any LinkTransport, String) -> Void) {
        self.handle = handle
    }

    var isRunning: Bool { lock.withLock { port != nil } }

    /// The port it listens on, while it runs.
    var currentPort: UInt16? { lock.withLock { port?.rawValue } }

    /// (Re)starts with this identity; connections in progress keep the previous one.
    func start(identity: SecIdentity, chain: [SecCertificate]) async throws {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        guard let secIdentity = sec_identity_create_with_certificates(identity, chain as CFArray) else {
            throw TransportError.certificate
        }
        sec_protocol_options_set_local_identity(security, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(security, "http/1.1")
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accepted(connection) }
        let ready = AsyncStream<Result<NWEndpoint.Port, Error>>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port { ready.continuation.yield(.success(port)) }
            case .failed(let error):
                ready.continuation.yield(.failure(error))
            case .cancelled:
                ready.continuation.yield(.failure(TransportError.closed))
            default:
                break
            }
        }
        listener.start(queue: queue)
        var result: Result<NWEndpoint.Port, Error> = .failure(TransportError.timeout)
        for await outcome in ready.stream {
            result = outcome
            break
        }
        let port = try result.get()
        let previous: NWListener? = lock.withLock {
            defer {
                self.listener = listener
                self.port = port
            }
            return self.listener
        }
        previous?.cancel()
        DebugLog.log("received information: HTTPS for the internet path on 127.0.0.1:\(port.rawValue)")
    }

    func stop() {
        let listener: NWListener? = lock.withLock {
            defer {
                self.listener = nil
                port = nil
            }
            return self.listener
        }
        listener?.cancel()
    }

    /// A connection to the server, TLS ended: handed over once its handshake is done, if it came through a tube.
    private func accepted(_ connection: NWConnection) {
        guard case .hostPort(let host, let port) = connection.endpoint, "\(host)" == "127.0.0.1" else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let self, let caller = self.lock.withLock({ self.callers[port.rawValue] }) else {
                    connection.cancel()
                    return
                }
                self.handle(StreamTransport(connection, queue: self.queue), caller)
            case .failed, .cancelled:
                connection.stateUpdateHandler = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Pipes a tube from the public relay into the server until either side ends. The tube is closed at once when the
    /// server is not running (no certificate yet).
    func pipe(_ tube: any LinkTransport, from caller: String) async {
        guard let port = lock.withLock({ self.port }) else {
            DebugLog.log("received information: a delivery from the internet before the certificate; closed")
            tube.close()
            return
        }
        let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        let ready = AsyncStream<Bool>.makeStream()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.continuation.yield(true)
            case .failed, .cancelled: ready.continuation.yield(false)
            default: break
            }
        }
        connection.start(queue: queue)
        var isReady = false
        for await outcome in ready.stream {
            isReady = outcome
            break
        }
        guard isReady, case .hostPort(_, let localPort)? = connection.currentPath?.localEndpoint else {
            connection.cancel()
            tube.close()
            return
        }
        // Known before the first byte: the server looks it up once the TLS handshake, which needs those bytes, is done.
        lock.withLock { callers[localPort.rawValue] = caller }
        defer { lock.withLock { callers[localPort.rawValue] = nil } }
        let local = StreamTransport(connection, queue: queue, started: true)
        await withTaskGroup(of: Void.self) { tasks in
            tasks.addTask {
                for await input in tube.incoming {
                    switch input {
                    case .bytes(let data): local.send(data)
                    case .datagram: continue
                    case .closed: break
                    }
                    if case .closed = input { break }
                }
            }
            tasks.addTask {
                for await input in local.incoming {
                    switch input {
                    case .bytes(let data): tube.send(data)
                    case .datagram: continue
                    case .closed: break
                    }
                    if case .closed = input { break }
                }
            }
            await tasks.next()
            // One side ended: give the other a moment to pass on what it already has, then close both.
            try? await Task.sleep(for: .milliseconds(300))
            tube.close()
            local.close()
            tasks.cancelAll()
        }
    }
}

/// A TCP (or TLS) connection as a transport: its bytes in `incoming`, then `.closed`.
final class StreamTransport: LinkTransport, @unchecked Sendable {
    let path = LinkPath.relay
    let incoming: AsyncStream<TransportInput>
    private let sink: AsyncStream<TransportInput>.Continuation
    private let connection: NWConnection
    private let lock = NSLock()
    private var isClosed = false

    /// `started`: the connection is already started and ready (the pipe's own side); otherwise it is ready too, and
    /// this only starts reading it.
    init(_ connection: NWConnection, queue: DispatchQueue, started: Bool = false) {
        self.connection = connection
        (incoming, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error): self?.finish("\(error)")
            case .cancelled: self?.finish(nil)
            default: break
            }
        }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.sink.yield(.bytes(data)) }
            if let error {
                self.finish("\(error)")
            } else if isComplete {
                self.finish(nil)
            } else {
                self.receive()
            }
        }
    }

    func send(_ bytes: Data) {
        guard lock.withLock({ !isClosed }) else { return }
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish("\(error)") }
        })
    }

    func sendDatagram(_ datagram: Data) {}

    func close() {
        finish(nil)
    }

    private func finish(_ reason: String?) {
        let first: Bool = lock.withLock {
            defer { isClosed = true }
            return !isClosed
        }
        guard first else { return }
        connection.cancel()
        sink.yield(.closed(reason))
        sink.finish()
    }
}
#endif
