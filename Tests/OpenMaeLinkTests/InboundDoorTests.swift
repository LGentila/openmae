import Darwin
import Foundation
import Network
import Testing
import VoiceCore

@testable import OpenMaeLink

// OpenMaé's internal door: the door off by default, local callers only, the warning by kind of Mac, the "home network"
// safeguard, compartmentalisation and the addresses of the home sources, with this Mac's network as the tests say.

/// This Mac and its network, as a test says: a laptop or not, its Wi-Fi and Ethernet networks, and their changes.
private final class FakeNetwork: InboundNetwork, @unchecked Sendable {
    let isLaptop: Bool
    private let lock = NSLock()
    private var current: [HomeLink]
    private var sinks: [AsyncStream<Void>.Continuation] = []

    init(isLaptop: Bool, links: [HomeLink]) {
        self.isLaptop = isLaptop
        current = links
    }

    func links() async -> [HomeLink] { lock.withLock { current } }

    func changes() -> AsyncStream<Void> {
        let (stream, sink) = AsyncStream.makeStream(of: Void.self)
        lock.withLock { sinks.append(sink) }
        return stream
    }

    /// This Mac joins other networks, as the system tells it.
    func move(to links: [HomeLink]) {
        let sinks = lock.withLock {
            current = links
            return self.sinks
        }
        sinks.forEach { $0.yield(()) }
    }
}

/// The engine, as far as announcements go: it says everything at once.
private actor Speaker: Announcing {
    private(set) var said: [String] = []

    func canAnnounce() -> Bool { true }

    func announce(_ text: String, note: String, language: SpeechLanguage, chime: Bool, urgent: Bool, id: UUID) -> Bool {
        said.append(text)
        return true
    }

    func withdrawAnnouncement(_ id: UUID) -> Bool { false }
    func announcementWaits(_ id: UUID) -> Bool { false }
    func notify(title: String, body: String) {}
    func requestNotificationPermission() {}
}

private let homeRouter = "02:1a:2b:3c:4d:05"
private let home = HomeLink(interface: "en0", address: "192.168.1.20", router: "192.168.1.1", routerHardware: homeRouter)
/// Another network with the same router address, as is common: only the router's hardware address differs.
private let cafe = HomeLink(interface: "en0", address: "192.168.1.57", router: "192.168.1.1",
                            routerHardware: "a4:2b:b0:11:22:33")

@Suite("OpenMaé's internal door", .serialized)
struct InboundDoorTests {
    private struct Rig {
        let host: InboundHost
        let network: FakeNetwork
        let speaker: Speaker
        let secrets: MemoryInboundSecrets
        let port: UInt16

        func secret(_ source: UUID) -> String { secrets.secret(for: source)! }

        /// A delivery to the door, on this Mac's loopback; the whole answer.
        func deliver(_ body: String, to source: UUID) async -> String {
            let request = "POST /in/\(secret(source)) HTTP/1.1\r\nHost: mac\r\nContent-Type: text/plain\r\n"
                + "Content-Length: \(Data(body.utf8).count)\r\n\r\n\(body)"
            return await exchange(port: port, request: request)
        }
    }

    private func makeRig(isLaptop: Bool = true, links: [HomeLink] = [home], store: URL? = nil) async -> Rig {
        let network = FakeNetwork(isLaptop: isLaptop, links: links)
        let speaker = Speaker()
        let secrets = MemoryInboundSecrets()
        let identity = FileIdentityStore(url: FileManager.default.temporaryDirectory
            .appending(path: "inbound-door-tests-\(UUID().uuidString)/keys"))
        let host = InboundHost(announcer: speaker, identityStore: identity, secrets: secrets, storeURL: store,
                               network: network)
        let port = freePort()
        await host.setDoorPort(port)
        return Rig(host: host, network: network, speaker: speaker, secrets: secrets, port: port)
    }

    /// Within 10 seconds: a busy Mac (the other suites run meanwhile) may take a few seconds to let a port go.
    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<1000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    // MARK: - Off by default

    @Test func offByDefault() async throws {
        let network = FakeNetwork(isLaptop: false, links: [home])
        let host = InboundHost(announcer: nil, identityStore: FileIdentityStore(url: FileManager.default.temporaryDirectory
            .appending(path: "inbound-door-tests-\(UUID().uuidString)/keys")), secrets: MemoryInboundSecrets(),
                               storeURL: nil, network: network)
        let source = await host.addSource(name: "Home Assistant")
        try await Task.sleep(for: .milliseconds(100))
        let status = await host.current
        #expect(status.homePath == .none)
        #expect(status.door == .off && status.doorAddress == nil)
        #expect(status.doorPort == 47321)
        #expect(!status.doorSafeguard)  // a desktop's safeguard is off until chosen
        #expect(status.addresses[source] == nil)
        #expect(host.door.port == nil)  // nothing listens
    }

    // MARK: - Callers

    @Test func localAddresses() {
        // The home relay's list (relay/internal/relay/inbound_test.go).
        let cases: [String: Bool] = [
            "10.1.2.3": true, "172.16.0.1": true, "172.31.255.255": true, "192.168.1.20": true, "169.254.10.1": true,
            "127.0.0.1": true, "127.8.9.10": true, "fc00::1": true, "fd12:3456::1": true, "fe80::1": true,
            "fe80::1%en0": true, "::1": true, "::ffff:192.168.1.20": true,
            "172.32.0.1": false, "192.169.0.1": false, "100.64.0.1": false, "8.8.8.8": false, "203.0.113.9": false,
            "0.0.0.0": false, "::": false, "::ffff:8.8.8.8": false, "2001:db8::1": false, "fec0::1": false,
            "relay.example": false, "": false,
        ]
        for (address, local) in cases {
            #expect(InboundCaller.isLocal(address) == local, "\(address)")
        }
    }

    @Test func nonLocalCallerRefused() async throws {
        let handled = Handled()
        let door = InboundDoor(isLocal: { _ in false }) { transport, caller in
            Task { await handled.add(caller) }
            transport.close()
        }
        let port = freePort()
        try await door.open(port: port, address: "192.168.1.20")
        defer { door.close() }
        let answer = await exchange(port: port, request: "POST /in/secret HTTP/1.1\r\nHost: mac\r\nContent-Length: 5\r\n\r\nhello")
        #expect(answer.hasPrefix("HTTP/1.1 403"), "\(answer)")
        #expect(answer.contains("home network"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await handled.all.isEmpty)
        // A local caller is let in, with its address.
        let open = InboundDoor { transport, caller in
            Task {
                await handled.add(caller)
                transport.send(HTTPResponse.json(202, ["status": "queued"]))
                try? await Task.sleep(for: .milliseconds(200))  // as the host does: time for the answer to leave
                transport.close()
            }
        }
        let other = freePort()
        try await open.open(port: other, address: "192.168.1.20")
        defer { open.close() }
        #expect(await exchange(port: other, request: "GET /in/x?text=hi HTTP/1.1\r\nHost: mac\r\n\r\n").hasPrefix("HTTP/1.1 202"))
        #expect(await handled.all == ["127.0.0.1"])
    }

    @Test func answersOnlyAtItsAddress() {
        #expect(InboundDoor.answers(at: "192.168.1.20", address: "192.168.1.20"))
        #expect(InboundDoor.answers(at: "127.0.0.1", address: "192.168.1.20"))
        #expect(InboundDoor.answers(at: "::1", address: "192.168.1.20"))
        // Another network this Mac is on at the same time (another interface).
        #expect(!InboundDoor.answers(at: "10.0.0.12", address: "192.168.1.20"))
        #expect(!InboundDoor.answers(at: "192.168.1.20", address: nil))
    }

    @Test func atMostTwentyConnections() async throws {
        let held = Held()
        let door = InboundDoor { transport, _ in Task { await held.add(transport) } }
        let port = freePort()
        try await door.open(port: port, address: "192.168.1.20")
        defer { door.close() }
        var clients: [NWConnection] = []
        for _ in 0..<InboundDoor.maxConnections {
            clients.append(try await connect(port: port))
        }
        #expect(await eventually { await held.count == InboundDoor.maxConnections })
        // The 21st is closed at once, never handed over.
        let extra = await exchange(port: port, request: "GET /in/x?text=hi HTTP/1.1\r\nHost: mac\r\n\r\n")
        #expect(extra == "")
        #expect(await held.count == InboundDoor.maxConnections)
        // Once they end, there is room again.
        await held.closeAll()
        clients.forEach { $0.cancel() }
        #expect(await eventually { door.openConnections == 0 })
        _ = try await connect(port: port)
        #expect(await eventually { await held.count == InboundDoor.maxConnections + 1 })
        await held.closeAll()
    }

    // MARK: - The warning, by kind of Mac

    @Test func warningByKindOfMac() async throws {
        let laptop = await makeRig(isLaptop: true)
        let laptopStatus = await laptop.host.current
        #expect(laptopStatus.isLaptop && laptopStatus.doorWarning == .laptop)
        #expect(laptopStatus.doorSafeguard)  // always on for a laptop
        #expect(await laptop.host.setDoorSafeguard(false))
        #expect(await laptop.host.current.doorSafeguard)

        let desktop = await makeRig(isLaptop: false)
        let desktopStatus = await desktop.host.current
        #expect(!desktopStatus.isLaptop && desktopStatus.doorWarning == .desktop)
        #expect(!desktopStatus.doorSafeguard)
        #expect(await desktop.host.setDoorSafeguard(true))
        #expect(await desktop.host.current.doorSafeguard)
        #expect(InboundDoorWarning(isLaptop: true) == .laptop && InboundDoorWarning(isLaptop: false) == .desktop)
    }

    // MARK: - The "home network" safeguard

    @Test func closedWhenTheRouterDiffers() async throws {
        let rig = await makeRig(isLaptop: true)
        let source = await rig.host.addSource(name: "Home Assistant")
        #expect(await rig.host.openDoor() == .opened)
        #expect(await eventually { await rig.host.current.door == .open })
        #expect(await rig.host.current.addresses[source]?.absoluteString
            == "http://192.168.1.20:\(rig.port)/in/\(rig.secret(source))")
        #expect(await rig.deliver("Le linge est sec", to: source).hasPrefix("HTTP/1.1 202"))

        // At the café: another router behind the same address.
        rig.network.move(to: [cafe])
        #expect(await eventually { await rig.host.current.door == .notHome })
        #expect(rig.host.door.port == nil)  // nothing listens any more
        #expect(await rig.host.current.addresses[source] == nil)
        #expect(await rig.deliver("Bonjour", to: source) == "")

        // No network at all.
        rig.network.move(to: [])
        #expect(await eventually { await rig.host.current.door == .noNetwork })

        // Back home: open again.
        rig.network.move(to: [home])
        #expect(await eventually { await rig.host.current.door == .open })
        #expect(await rig.deliver("Le courrier est arrivé", to: source).hasPrefix("HTTP/1.1 202"))
        #expect(await eventually { await rig.speaker.said == ["Le linge est sec", "Le courrier est arrivé"] })
        await rig.host.setHomePath(.none)
        #expect(await eventually { await rig.host.current.door == .off })
    }

    @Test func homeNetworkIsTheOneOfAnyWiFiOrEthernet() async throws {
        // Ethernet on another network first, the home Wi-Fi second: the door answers at the home Wi-Fi's address.
        let office = HomeLink(interface: "en7", address: "10.0.0.12", router: "10.0.0.1",
                              routerHardware: "00:11:22:33:44:55")
        let rig = await makeRig(isLaptop: true, links: [home])
        #expect(await rig.host.openDoor() == .opened)
        #expect(await eventually { await rig.host.current.door == .open })
        rig.network.move(to: [office, HomeLink(interface: "en0", address: "192.168.1.200", router: "192.168.1.1",
                                                routerHardware: homeRouter)])
        #expect(await eventually { await rig.host.current.doorAddress?.host() == "192.168.1.200" })
        await rig.host.setHomePath(.none)
    }

    @Test func aLaptopNeedsItsHomeNetworkToTurnTheDoorOn() async throws {
        let rig = await makeRig(isLaptop: true, links: [HomeLink(interface: "en0", address: "192.168.1.20")])
        #expect(await rig.host.openDoor() == .noHomeNetwork)  // the router's hardware address is not known
        #expect(await rig.host.current.homePath == .none)
        let offline = await makeRig(isLaptop: true, links: [])
        #expect(await offline.host.openDoor() == .noHomeNetwork)
    }

    @Test func aDesktopWithoutTheSafeguardOpensOnAnyNetwork() async throws {
        let rig = await makeRig(isLaptop: false)
        #expect(await rig.host.openDoor() == .opened)
        #expect(await eventually { await rig.host.current.door == .open })
        rig.network.move(to: [cafe])
        #expect(await eventually { await rig.host.current.doorAddress?.host() == "192.168.1.57" })
        #expect(await rig.host.current.door == .open)
        // With the safeguard, turned on here: only here.
        #expect(await rig.host.setDoorSafeguard(true))
        rig.network.move(to: [home])
        #expect(await eventually { await rig.host.current.door == .notHome })
        rig.network.move(to: [cafe])
        #expect(await eventually { await rig.host.current.door == .open })
        await rig.host.setHomePath(.none)
    }

    @Test func choosingTheDoorAgainRecordsANewRouter() async throws {
        let rig = await makeRig(isLaptop: true)
        #expect(await rig.host.openDoor() == .opened)
        #expect(await eventually { await rig.host.current.door == .open })
        // A new router at home: closed until the door is chosen again.
        let newRouter = HomeLink(interface: "en0", address: "192.168.1.20", router: "192.168.1.1",
                                 routerHardware: "de:ad:be:ef:00:01")
        rig.network.move(to: [newRouter])
        #expect(await eventually { await rig.host.current.door == .notHome })
        #expect(await rig.host.openDoor() == .opened)
        #expect(await eventually { await rig.host.current.door == .open })
        await rig.host.setHomePath(.none)
    }

    // MARK: - Compartmentalisation and addresses

    @Test func internetSourceRefusedThroughTheDoor() async throws {
        let rig = await makeRig(isLaptop: false)
        let internet = await rig.host.addSource(name: "Alerte du serveur", origin: .internet)
        let homeSource = await rig.host.addSource(name: "Home Assistant", origin: .home)
        #expect(await rig.host.openDoor() == .opened)
        #expect(await eventually { await rig.host.current.door == .open })
        let refused = await rig.deliver("Bonjour", to: internet)
        #expect(refused.hasPrefix("HTTP/1.1 404"), "\(refused)")
        let log = await rig.host.current.logs[internet] ?? []
        #expect(log.first?.result == .wrongPath && log.first?.path == .internalDoor)
        let accepted = await rig.deliver("Bonjour", to: homeSource)
        #expect(accepted.hasPrefix("HTTP/1.1 202"), "\(accepted)")
        #expect(await rig.host.current.logs[homeSource]?.first?.path == .internalDoor)
        #expect(await rig.host.current.logs[homeSource]?.first?.caller == "127.0.0.1")
        await rig.host.setHomePath(.none)
    }

    @Test func addressesChangeWithTheHomePath() async throws {
        let rig = await makeRig(isLaptop: true)
        let source = await rig.host.addSource(name: "Home Assistant")
        let secret = rig.secret(source)
        await rig.host.setHomeRelay(URL(string: "http://127.0.0.1:9")!)  // nothing listens there: the address is known
        let name = try #require(await rig.host.current.inboundName)
        #expect(await rig.host.current.homePath == .relay)
        #expect(await rig.host.current.addresses[source]?.absoluteString == "http://127.0.0.1:9/\(name)/in/\(secret)")

        #expect(await rig.host.openDoor() == .opened)
        #expect(await eventually { await rig.host.current.door == .open })
        var status = await rig.host.current
        #expect(status.homePath == .door && status.homeRelay == .none)  // one home path at a time
        #expect(status.addresses[source]?.absoluteString == "http://192.168.1.20:\(rig.port)/in/\(secret)")

        await rig.host.setHomePath(.none)
        #expect(await eventually { await rig.host.current.door == .off })
        status = await rig.host.current
        #expect(status.addresses[source] == nil)
        #expect(rig.host.door.port == nil)

        // The relay's address is kept: back to it.
        await rig.host.setHomePath(.relay)
        #expect(await rig.host.current.addresses[source]?.absoluteString == "http://127.0.0.1:9/\(name)/in/\(secret)")

        // Another port: other addresses.
        #expect(await rig.host.openDoor() == .opened)
        #expect(await eventually { await rig.host.current.door == .open })
        let other = freePort()
        await rig.host.setDoorPort(other)
        #expect(await eventually { await rig.host.current.addresses[source]?.port == Int(other) })
        #expect(await eventually { rig.host.door.port == other })
        await rig.host.setHomePath(.none)
        await rig.host.setHomeRelay(nil)
    }

    @Test func portTakenBySomethingElse() async throws {
        let blocker = InboundDoor { transport, _ in transport.close() }
        let port = freePort()
        try await blocker.open(port: port, address: "127.0.0.1")
        defer { blocker.close() }
        let rig = await makeRig(isLaptop: false)
        await rig.host.setDoorPort(port)
        #expect(await rig.host.openDoor() == .opened)
        #expect(await eventually { await rig.host.current.door == .portTaken })
        #expect(await rig.host.current.doorAddress == nil)
        await rig.host.setHomePath(.none)
    }

    @Test func reopensOnTheSamePortRightAfterClosing() async throws {
        // As when the home path goes to none and back, or the network changes back and forth.
        let door = InboundDoor { transport, _ in transport.close() }
        let port = freePort()
        for _ in 0..<5 {
            try await door.open(port: port, address: "127.0.0.1")
            #expect(door.port == port)
            door.close()
            #expect(door.port == nil)
        }
    }

    @Test func settingsSurviveARestart() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "inbound-door-tests-\(UUID().uuidString)")
        let store = folder.appending(path: "received-information.json")
        let rig = await makeRig(isLaptop: true, store: store)
        #expect(await rig.host.openDoor() == .opened)
        #expect(await eventually { await rig.host.current.door == .open })
        await rig.host.setHomePath(.none)  // closes the door, which must not stay open with the second host
        #expect(await eventually { await rig.host.current.door == .off })
        #expect(await rig.host.openDoor() == .opened)
        #expect(await eventually { await rig.host.current.door == .open })
        let raw = try String(contentsOf: store, encoding: .utf8)
        #expect(raw.contains(#""homePath":"door""#) && raw.contains(homeRouter))
        await rig.host.setHomePath(.none)
        #expect(await eventually { rig.host.door.port == nil })

        // Written by hand as the step before the door wrote it: a home relay, no home path.
        let legacy = folder.appending(path: "legacy.json")
        try Data(#"{"homeRelay":"http:\/\/192.168.1.10:8080","sources":[],"logs":[]}"#.utf8).write(to: legacy)
        let old = InboundHost(announcer: nil, identityStore: FileIdentityStore(url: folder.appending(path: "keys")),
                              secrets: MemoryInboundSecrets(), storeURL: legacy,
                              network: FakeNetwork(isLaptop: true, links: [home]))
        #expect(await eventually { await old.current.homePath == .relay })
        #expect(await old.current.homeRelayAddress?.absoluteString == "http://192.168.1.10:8080")
        await old.setHomeRelay(nil)

        // A door kept from before opens again by itself, on its port, at home.
        let again = folder.appending(path: "again.json")
        try Data(#"{"homePath":"door","door":{"port":\#(rig.port),"safeguard":false,"router":"\#(homeRouter)"},"sources":[],"logs":[]}"#.utf8)
            .write(to: again)
        let reopened = InboundHost(announcer: nil, identityStore: FileIdentityStore(url: folder.appending(path: "keys")),
                                   secrets: MemoryInboundSecrets(), storeURL: again,
                                   network: FakeNetwork(isLaptop: true, links: [home]))
        #expect(await eventually { await reopened.current.door == .open })
        #expect(await reopened.current.doorPort == rig.port)
        await reopened.setHomePath(.none)
        #expect(await eventually { reopened.door.port == nil })
    }

    // MARK: - Reading the network

    @Test func hardwareAddresses() {
        #expect(SystemInboundNetwork.parseARP("? (192.168.1.1) at 2:1a:2b:3c:4d:5 on en0 ifscope [ethernet]\n")
            == "02:1a:2b:3c:4d:05")
        #expect(SystemInboundNetwork.parseARP("? (192.168.1.1) at (incomplete) on en0 ifscope [ethernet]") == nil)
        #expect(SystemInboundNetwork.parseARP("192.168.1.1 (192.168.1.1) -- no entry") == nil)
        #expect(SystemInboundNetwork.normalizedHardware("02:1A:2B:3C:4D:05") == "02:1a:2b:3c:4d:05")
        #expect(SystemInboundNetwork.normalizedHardware("0:0:0:0:0:0") == nil)
        #expect(SystemInboundNetwork.normalizedHardware("02:1a:2b:3c:4d") == nil)
        #expect(HomeLink(interface: "en0", address: "192.168.1.20", routerHardware: "2:1A:2B:3C:4D:5").routerHardware
            == "02:1a:2b:3c:4d:05")
    }

    /// This Mac's own network, as the system tells it (nothing to check when it is on none).
    @Test func thisMacsNetwork() async {
        let links = await SystemInboundNetwork().links()
        for link in links {
            #expect(link.interface.hasPrefix("en"))
            #expect(IPv4Address(link.address) != nil)
            if let hardware = link.routerHardware { #expect(SystemInboundNetwork.normalizedHardware(hardware) == hardware) }
        }
    }
}

// MARK: - Helpers

private actor Handled {
    var all: [String] = []
    func add(_ caller: String) { all.append(caller) }
}

/// Connections the door handed over, kept open until the test ends them.
private actor Held {
    private var transports: [any LinkTransport] = []
    var count: Int { transports.count }
    func add(_ transport: any LinkTransport) { transports.append(transport) }
    func closeAll() { transports.forEach { $0.close() } }
}

/// A port nothing listens on now: the system's choice, given back at once.
private func freePort() -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
    }
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    return UInt16(bigEndian: address.sin_port)
}

/// An open TCP connection to the loopback.
private func connect(port: UInt16) async throws -> NWConnection {
    let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    let ready = AsyncStream<Bool>.makeStream()
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready: ready.continuation.yield(true)
        case .failed, .cancelled, .waiting: ready.continuation.yield(false)
        default: break
        }
    }
    connection.start(queue: DispatchQueue(label: "door-test-client"))
    for await isReady in ready.stream {
        guard isReady else { throw TransportError.closed }
        return connection
    }
    throw TransportError.closed
}

/// Sends `request` to the door on the loopback, and returns all it answers until it closes ("" when it says nothing).
private func exchange(port: UInt16, request: String) async -> String {
    guard let connection = try? await connect(port: port) else { return "" }
    defer { connection.cancel() }
    let reader = Reader(connection)
    connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
    reader.read()
    let timeout = Task {
        try? await Task.sleep(for: .seconds(10))
        reader.answer.continuation.yield("timed out")
    }
    defer { timeout.cancel() }
    for await text in reader.answer.stream { return text }
    return ""
}

/// Reads a connection until it ends.
private final class Reader: @unchecked Sendable {
    let answer = AsyncStream<String>.makeStream()
    private let connection: NWConnection
    private let lock = NSLock()
    private var received = Data()

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            let text: String? = self.lock.withLock {
                if let data { self.received.append(data) }
                return complete || error != nil ? String(decoding: self.received, as: UTF8.self) : nil
            }
            if let text { self.answer.continuation.yield(text) } else { self.read() }
        }
    }
}
