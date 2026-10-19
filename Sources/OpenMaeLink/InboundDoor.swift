#if os(macOS)
import Foundation
import IOKit.ps
import Network
import SystemConfiguration
import VoiceCore

// OpenMaé's internal door: for home sources when there is no home relay, the Mac itself listens on the home network
// (plain HTTP, port 47321 by default). It is off by default and discouraged on laptops. A laptop's door only opens on
// the network where it was turned on (the "home network" safeguard: the router's hardware address must be the one
// recorded then); a desktop may ask for the same. Only callers with a local address are answered, and only at the
// address the settings give (or on this Mac's loopback, for its own tools).

// MARK: - Callers

/// Who may knock on the door: the same list as the home relay's.
public enum InboundCaller {
    /// Whether an address is on the local network: private (10/8, 172.16/12, 192.168/16, fc00::/7), link-local
    /// (169.254/16, fe80::/10) or the loopback (127/8, ::1). An IPv4 address mapped into IPv6 counts as itself.
    public static func isLocal(_ address: String) -> Bool {
        let bare = String(address.split(separator: "%", maxSplits: 1).first ?? "")
        if let ipv4 = IPv4Address(bare) { return isLocal(ipv4: [UInt8](ipv4.rawValue)) }
        if let ipv6 = IPv6Address(bare) { return isLocal(ipv6: [UInt8](ipv6.rawValue)) }
        return false
    }

    static func isLocal(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address): isLocal(ipv4: [UInt8](address.rawValue))
        case .ipv6(let address): isLocal(ipv6: [UInt8](address.rawValue))
        default: false
        }
    }

    private static func isLocal(ipv4 b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        return b[0] == 10 || (b[0] == 172 && b[1] & 0xF0 == 16) || (b[0] == 192 && b[1] == 168)
            || (b[0] == 169 && b[1] == 254) || b[0] == 127
    }

    private static func isLocal(ipv6 b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if let mapped = mappedIPv4(b) { return isLocal(ipv4: mapped) }
        return b[0] & 0xFE == 0xFC  // fc00::/7, unique local
            || (b[0] == 0xFE && b[1] & 0xC0 == 0x80)  // fe80::/10, link-local
            || (b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1)  // ::1
    }

    /// The IPv4 address inside `::ffff:a.b.c.d`.
    static func mappedIPv4(_ b: [UInt8]) -> [UInt8]? {
        guard b.count == 16, b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF else { return nil }
        return Array(b[12..<16])
    }

    /// An address as the log keeps it: an IPv4 address mapped into IPv6 as itself, without an interface's scope.
    static func text(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            return [UInt8](address.rawValue).map(String.init).joined(separator: ".")
        case .ipv6(let address):
            if let mapped = mappedIPv4([UInt8](address.rawValue)) { return mapped.map(String.init).joined(separator: ".") }
            return String("\(address)".split(separator: "%", maxSplits: 1).first ?? "")
        default:
            return "\(host)"
        }
    }
}

// MARK: - This Mac and its network

/// One of this Mac's Wi-Fi or Ethernet networks: its interface, this Mac's IPv4 address on it, and its router.
public struct HomeLink: Sendable, Equatable {
    public var interface: String
    public var address: String
    public var router: String?
    /// The router's hardware (MAC) address, as "02:1a:2b:3c:4d:05"; nil when it is not known.
    public var routerHardware: String?

    public init(interface: String, address: String, router: String? = nil, routerHardware: String? = nil) {
        self.interface = interface
        self.address = address
        self.router = router
        self.routerHardware = routerHardware.flatMap(SystemInboundNetwork.normalizedHardware)
    }
}

/// What the internal door needs to know of this Mac and its network. The tests give their own.
public protocol InboundNetwork: Sendable {
    /// Whether this Mac runs on an internal battery: a laptop, which takes its door along to other networks.
    var isLaptop: Bool { get }
    /// This Mac's Wi-Fi and Ethernet networks that have an IPv4 address, the one of the default route first.
    func links() async -> [HomeLink]
    /// A value each time the network may have changed, and now and then to look again.
    func changes() -> AsyncStream<Void>
}

/// The real Mac. Its networks come from the system's network state (SystemConfiguration), where macOS keeps, for each
/// service, the router and the hardware address it resolved for it by ARP: the routing and ARP tables themselves
/// (`sysctl`) hide the neighbours' hardware addresses from apps. When that address is missing (a configuration it did
/// not resolve), the system's `arp` tool reads the table. No permission is needed, and not the Wi-Fi's name (which
/// would need the Location permission).
public struct SystemInboundNetwork: InboundNetwork {
    public init() {}

    public var isLaptop: Bool { Self.hasInternalBattery }

    static var hasInternalBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return list.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    public func links() async -> [HomeLink] {
        guard let store = SCDynamicStoreCreate(nil, "OpenMaé internal door" as CFString, nil, nil) else { return [] }
        let primary = (SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any])?[
            "PrimaryService"] as? String
        let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] ?? []
        var found: [(isPrimary: Bool, link: HomeLink)] = []
        for key in keys {
            // Wi-Fi and Ethernet (USB and Thunderbolt adapters too) are the "en" interfaces; not VPNs or bridges.
            guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let interface = value["InterfaceName"] as? String, interface.hasPrefix("en"),
                  let address = (value["Addresses"] as? [String])?.first(where: { !$0.hasPrefix("169.254.") })
            else { continue }
            let router = value["Router"] as? String
            var hardware: String?
            if let router, value["ARPResolvedIPAddress"] as? String == router {
                hardware = value["ARPResolvedHardwareAddress"] as? String
            }
            if hardware == nil, let router {
                hardware = await Self.arpTable(router)
            }
            let service = key.split(separator: "/").dropFirst(3).first.map(String.init)
            found.append((service != nil && service == primary,
                          HomeLink(interface: interface, address: address, router: router, routerHardware: hardware)))
        }
        return found.sorted { a, b in
            a.isPrimary != b.isPrimary ? a.isPrimary : a.link.interface.localizedStandardCompare(b.link.interface)
                == .orderedAscending
        }.map(\.link)
    }

    /// The router's hardware address from the ARP table, through the system's `arp` tool; nil without an entry.
    static func arpTable(_ router: String) async -> String? {
        guard IPv4Address(router) != nil else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
                process.arguments = ["-n", router]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { process.terminate() }
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: parseARP(String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// "? (192.168.1.1) at 2:1a:2b:3c:4d:5 on en0 ifscope [ethernet]" → "02:1a:2b:3c:4d:05".
    static func parseARP(_ output: String) -> String? {
        guard let at = output.range(of: " at ") else { return nil }
        let word = output[at.upperBound...].prefix { !$0.isWhitespace }
        return normalizedHardware(String(word))
    }

    /// A hardware address as six two-digit hexadecimal bytes in lowercase; nil when it is not one (or all zeros).
    static func normalizedHardware(_ text: String) -> String? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard (1...2).contains(part.count), let byte = UInt8(part, radix: 16) else { return nil }
            bytes.append(byte)
        }
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Each change of the network path; then again 2, 6 and 15 seconds later, as the system finishes learning the
    /// new network (its router's hardware address comes a moment after the path); then every minute.
    public func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            let followUps = FollowUps()
            monitor.pathUpdateHandler = { _ in
                continuation.yield(())
                followUps.restart {
                    for delay in [2.0, 4, 9] {
                        try await Task.sleep(for: .seconds(delay))
                        continuation.yield(())
                    }
                    while true {
                        try await Task.sleep(for: .seconds(60))
                        continuation.yield(())
                    }
                }
            }
            monitor.start(queue: DispatchQueue(label: "OpenMaeLink.inbound-door-network"))
            continuation.onTermination = { _ in
                monitor.cancel()
                followUps.restart(nil)
            }
        }
    }

    /// The looks after a change; a new change starts them again.
    private final class FollowUps: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?

        func restart(_ work: (@Sendable () async throws -> Void)?) {
            lock.withLock {
                task?.cancel()
                task = work.map { work in Task { try? await work() } }
            }
        }
    }
}

/// The warning shown before the door opens, by the kind of Mac.
public enum InboundDoorWarning: Sendable, Equatable {
    /// It would go along to other networks: a home relay is better; turned on anyway, it only opens on this network.
    case laptop
    /// The devices of the network can knock, with the secret address, and what they send is not encrypted.
    case desktop

    public init(isLaptop: Bool) {
        self = isLaptop ? .laptop : .desktop
    }
}

// MARK: - The door

/// The door itself: plain HTTP on every interface, at most 20 connections at once. A connection is handed over with its
/// caller's address when the caller is local and it came to the door's address (or to this Mac's loopback); any other
/// is told 403.
final class InboundDoor: @unchecked Sendable {
    static let maxConnections = 20

    private let lock = NSLock()
    private var listener: NWListener?
    private var listeningPort: UInt16?
    /// The port the door's own listener let go of last, and when.
    private var lastClosed: (port: UInt16, at: ContinuousClock.Instant)?
    /// The address the settings give: the door answers there (and on the loopback).
    private var address: String?
    private var open: Set<ObjectIdentifier> = []
    private let queue = DispatchQueue(label: "OpenMaeLink.inbound-door")
    private let isLocal: @Sendable (NWEndpoint.Host) -> Bool
    private let handle: @Sendable (any LinkTransport, String) -> Void

    /// `isLocal`: which callers are on the local network (the tests pretend otherwise). `handle`: each connection
    /// let in, with its caller's address.
    init(isLocal: @escaping @Sendable (NWEndpoint.Host) -> Bool = InboundCaller.isLocal,
         handle: @escaping @Sendable (any LinkTransport, String) -> Void)
    {
        self.isLocal = isLocal
        self.handle = handle
    }

    /// The port it listens on, once listening.
    var port: UInt16? { lock.withLock { listener == nil ? nil : listeningPort } }

    var openConnections: Int { lock.withLock { open.count } }

    /// Listens on `port` and answers at `address`. Already listening on that port: only the address changes.
    func open(port: UInt16, address: String) async throws {
        let listening = lock.withLock {
            self.address = address
            return listener != nil && listeningPort == port
        }
        guard !listening else { return }
        close()
        guard let endpointPort = NWEndpoint.Port(rawValue: port), port != 0 else { throw TransportError.failed("port \(port)") }
        // The system lets go of a closed listener's port a moment after: tried again for 2 seconds, or for 6 when the
        // door's own listener left that port just before (a busy Mac can take that long).
        let reopening = lock.withLock {
            lastClosed.map { $0.port == port && ContinuousClock.now - $0.at < .seconds(10) } ?? false
        }
        let deadline = ContinuousClock.now + (reopening ? .seconds(6) : .seconds(2))
        var started: NWListener?
        while started == nil {
            do {
                started = try await listen(on: endpointPort)
            } catch NWError.posix(.EADDRINUSE) where ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard let listener = started else { return }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard case .failed(let error) = state, let listener else { return }
            // Forgotten, so that the next look at the network (within a minute) opens a new one.
            DebugLog.log("received information: the internal door failed (\(error))")
            self?.forget(listener)
        }
        let previous: NWListener? = lock.withLock {
            defer {
                self.listener = listener
                listeningPort = port
            }
            return self.listener
        }
        previous?.cancel()
        DebugLog.log("received information: the internal door is open on port \(port)")
    }

    /// A listener on `port`, every interface, once it is ready.
    private func listen(on port: NWEndpoint.Port) async throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let ready = AsyncStream<Error?>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.continuation.yield(nil)
            case .failed(let error): ready.continuation.yield(error)
            case .cancelled: ready.continuation.yield(TransportError.closed)
            default: break
            }
        }
        listener.start(queue: queue)
        // A listener left waiting (no network after all) must not hold the door's checks.
        let limit = Task {
            try await Task.sleep(for: .seconds(5))
            ready.continuation.yield(TransportError.timeout)
        }
        var failure: Error? = TransportError.timeout
        for await outcome in ready.stream {
            failure = outcome
            break
        }
        limit.cancel()
        if let failure {
            listener.cancel()
            throw failure
        }
        return listener
    }

    private func forget(_ failed: NWListener) {
        let isCurrent = lock.withLock {
            guard listener === failed else { return false }
            if let listeningPort { lastClosed = (listeningPort, .now) }
            listener = nil
            listeningPort = nil
            return true
        }
        if isCurrent { failed.cancel() }
    }

    /// Stops listening. Deliveries already in progress finish (within their own time limit).
    func close() {
        let listener: NWListener? = lock.withLock {
            defer {
                if self.listener != nil, let listeningPort { lastClosed = (listeningPort, .now) }
                self.listener = nil
                listeningPort = nil
            }
            return self.listener
        }
        guard let listener else { return }
        listener.cancel()
        DebugLog.log("received information: the internal door is closed")
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let admitted: Bool = lock.withLock {
            guard open.count < Self.maxConnections else { return false }
            open.insert(id)
            return true
        }
        guard admitted else {
            DebugLog.log("received information: the internal door already has \(Self.maxConnections) connections; one refused")
            connection.cancel()
            return
        }
        guard case .hostPort(let caller, _) = connection.endpoint, isLocal(caller) else {
            refuse(connection, id: id, why: "a caller not on the local network")
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                connection.stateUpdateHandler = nil
                guard self.answersHere(connection) else {
                    self.refuse(connection, id: id, why: "a connection to another address of this Mac")
                    return
                }
                let transport = StreamTransport(connection, queue: self.queue, started: true) { [weak self] in
                    self?.release(id)
                }
                self.handle(transport, InboundCaller.text(caller))
            case .failed:
                connection.cancel()
            case .cancelled:
                connection.stateUpdateHandler = nil
                self.release(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Whether the connection came to the door's address, or to the loopback.
    private func answersHere(_ connection: NWConnection) -> Bool {
        guard case .hostPort(let local, _)? = connection.currentPath?.localEndpoint else { return false }
        return Self.answers(at: InboundCaller.text(local), address: lock.withLock { address })
    }

    static func answers(at local: String, address: String?) -> Bool {
        local == address || local == "::1" || local.hasPrefix("127.")
    }

    /// 403, then the connection closes; the caller learns no more.
    private func refuse(_ connection: NWConnection, id: ObjectIdentifier, why: String) {
        DebugLog.log("received information: the internal door refused \(why)")
        let answer = HTTPResponse.json(403, ["error": "This door only answers on the home network."])
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                connection.send(content: answer, completion: .contentProcessed { _ in })
                // Time for the answer to arrive before the connection closes.
                self?.queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
            case .failed:
                connection.cancel()
            case .cancelled:
                connection.stateUpdateHandler = nil
                self?.release(id)
            default:
                break
            }
        }
        if connection.state == .setup {
            connection.start(queue: queue)
        } else {
            connection.send(content: answer, completion: .contentProcessed { _ in })
            queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
        }
    }

    private func release(_ id: ObjectIdentifier) {
        lock.withLock { _ = open.remove(id) }
    }
}
#endif
