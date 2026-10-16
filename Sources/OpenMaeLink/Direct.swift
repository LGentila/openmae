import Foundation
import Network
import VoiceCore

/// Bonjour service type of the Mac on the local network; its TXT record says which Mac it is (`id=<device id>`).
public enum DirectService {
    public static let type = "_openmae._udp"
}

/// The Mac's side of the local network: a QUIC listener, announced with Bonjour. Each connection that arrives is
/// handed over once its first stream is open; Noise then decides who it is.
public final class DirectListener: @unchecked Sendable {
    public let connections: AsyncStream<any LinkTransport>
    private let sink: AsyncStream<any LinkTransport>.Continuation
    private let macID: String
    private let lock = NSLock()
    private var listener: NWListener?
    private var restart: Task<Void, Never>?
    /// Called on the listener's queue with whether the Mac can be reached on the local network.
    public var onReadyChange: (@Sendable (Bool) -> Void)?

    public init(macID: String) {
        self.macID = macID
        (connections, sink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    public func start() {
        lock.withLock { restart?.cancel() }
        do {
            let parameters = NWParameters(quic: QUIC.options(alpn: QUIC.directALPN, server: try QUIC.throwawayIdentity()))
            parameters.includePeerToPeer = false
            let listener = try NWListener(using: parameters)
            // A name of its own rather than the computer's: two announcements with the same name collide, and the
            // second is silently dropped (two OpenMaé on one Mac, or two Macs named alike). The iPhone goes by the
            // TXT record's id anyway.
            listener.service = NWListener.Service(name: "OpenMaé \(macID.prefix(8))", type: DirectService.type,
                                                  txtRecord: NWTXTRecord(["id": macID]).data)
            listener.serviceRegistrationUpdateHandler = { change in
                if case .add(let endpoint) = change { DebugLog.log("link: announced as \(endpoint)") }
            }
            listener.newConnectionGroupHandler = { [weak self] group in
                Task {
                    do {
                        let transport = try await QUICTransport.accept(group)
                        self?.sink.yield(transport)
                    } catch {
                        DebugLog.log("link: direct connection dropped before its stream (\(error))")
                        group.cancel()
                    }
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    DebugLog.log("link: listening on the local network, port \(listener.port?.rawValue ?? 0)")
                    self?.onReadyChange?(true)
                case .failed(let error):
                    DebugLog.log("link: local listener failed (\(error)), restarting")
                    self?.onReadyChange?(false)
                    self?.scheduleRestart()
                default:
                    break
                }
            }
            lock.withLock {
                self.listener?.cancel()
                self.listener = listener
            }
            listener.start(queue: QUIC.queue)
        } catch {
            DebugLog.log("link: local listener cannot start (\(error))")
            scheduleRestart()
        }
    }

    public func stop() {
        let listener: NWListener? = lock.withLock {
            restart?.cancel()
            restart = nil
            defer { self.listener = nil }
            return self.listener
        }
        listener?.cancel()
        onReadyChange?(false)
    }

    private func scheduleRestart() {
        lock.withLock {
            restart?.cancel()
            restart = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.start()
            }
        }
    }
}

/// The iPhone's side: looks for its Mac on the local network.
public final class DirectBrowser: @unchecked Sendable {
    private let macID: String
    private let lock = NSLock()
    private var browser: NWBrowser?
    private var found: NWEndpoint?
    private var restart: Task<Void, Never>?
    /// Called on the browser's queue whenever the Mac appears or disappears.
    public var onChange: (@Sendable (NWEndpoint?) -> Void)?

    public init(macID: String) {
        self.macID = macID
    }

    /// The Mac's endpoint on the local network, if it is announced right now.
    public var endpoint: NWEndpoint? { lock.withLock { found } }

    public func start() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: DirectService.type, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let match = results.first { result in
                if case .bonjour(let txt) = result.metadata { return txt["id"] == self.macID }
                return false
            }
            let endpoint = match?.endpoint
            let changed: Bool = self.lock.withLock {
                defer { self.found = endpoint }
                return self.found != endpoint
            }
            if changed {
                DebugLog.log("link: the Mac is \(endpoint == nil ? "no longer" : "now") on the local network "
                             + "(\(results.count) announced)")
                self.onChange?(endpoint)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            DebugLog.log("link: local network browser \(state)")
            if case .failed = state {
                self?.lock.withLock { self?.found = nil }
                self?.onChange?(nil)
                // After the app was suspended, iOS reports the browser defunct: a new one takes over.
                self?.scheduleRestart()
            }
        }
        lock.withLock {
            restart?.cancel()
            restart = nil
            self.browser?.cancel()
            self.browser = browser
        }
        browser.start(queue: QUIC.queue)
    }

    public func stop() {
        let browser: NWBrowser? = lock.withLock {
            defer {
                self.browser = nil
                found = nil
                restart?.cancel()
                restart = nil
            }
            return self.browser
        }
        browser?.cancel()
    }

    private func scheduleRestart() {
        lock.withLock {
            guard browser != nil else { return }  // stopped meanwhile
            restart?.cancel()
            restart = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.lock.withLock({ self.browser != nil }) else { return }
                self.start()
            }
        }
    }

    /// Opens a direct connection to the Mac found on the local network.
    public static func connect(to endpoint: NWEndpoint) async throws -> any LinkTransport {
        try await QUICTransport.connect(to: endpoint, alpn: QUIC.directALPN, verification: .none, path: .direct,
                                        timeout: .seconds(4))
    }
}
