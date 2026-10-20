import Darwin
import Foundation
import Network
import Testing
import VoiceCore

@testable import OpenMaeLink

/// A measurement on this Mac over the real link (QUIC, Noise, the Mac's LinkHost and its listener, a PhoneLink as the
/// iPhone): the iPhone's network is cut during a conversation, then back. Between the two, a UDP relay that drops
/// everything meanwhile, and may come back from another port, as the iPhone comes back from a new address after
/// airplane mode. How long until the Mac hears the iPhone again, with the iPhone as before its round trips and network
/// watch, and as now (NWPathMonitor's reports given by the test, and the attempts failing at once without a network, as
/// they do on the iPhone). Only when asked, as it takes minutes:
///
///     OPENMAE_NETWORK_TESTS=1 OPENMAE_CUT_SECONDS=25      (with xcodebuild test: TEST_RUNNER_ in front of each)
@Suite("A cut of the iPhone's network, measured", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["OPENMAE_NETWORK_TESTS"] == "1"))
struct NetworkCutMeasurementTests {
    struct Case: Sendable, CustomStringConvertible {
        /// The iPhone checks its round trips and follows its network (this change), or not (before it).
        var watching: Bool
        var newAddress: Bool

        var description: String {
            (watching ? "now" : "before") + (newAddress ? ", back from a new address" : ", back from the same address")
        }
    }

    @Test(arguments: [Case(watching: false, newAddress: false), Case(watching: false, newAddress: true),
                      Case(watching: true, newAddress: false), Case(watching: true, newAddress: true)])
    func aCutDuringAConversation(_ scenario: Case) async throws {
        let cutSeconds = ProcessInfo.processInfo.environment["OPENMAE_CUT_SECONDS"].flatMap(Double.init) ?? 25
        let folder = FileManager.default.temporaryDirectory.appending(path: "network-cut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // The Mac, with its keys and its iPhone already paired, without a relay.
        let macStore = FileIdentityStore(url: folder.appending(path: "mac.key"))
        let macIdentity = try macStore.loadOrCreate()
        let phoneIdentity = DeviceIdentity.generate()
        let device = PairedDevice(publicKey: phoneIdentity.publicKey, name: "iPhone", model: "iPhone17,3")
        let devices = String(decoding: try JSONEncoder().encode([device]), as: UTF8.self)
        try Data(#"{"devices":\#(devices),"relay":{"none":{}},"keepAwake":false}"#.utf8)
            .write(to: folder.appending(path: "link.json"))
        let engine = TimedEngine()
        let host = LinkHost(engine: engine, audio: engine, identityStore: macStore,
                            storeURL: folder.appending(path: "link.json"), macName: "Mac de test")
        var macPort: UInt16?
        for _ in 0..<100 where macPort == nil {
            macPort = await host.directPort
            if macPort == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let relay = try CuttableUDP(toMacPort: try #require(macPort, "the Mac's listener did not start"))
        defer { relay.stop() }

        // The iPhone, through the relay. Without a network its attempts fail at once, as on the iPhone (no Bonjour
        // answer, the relay's address unreachable).
        let (paths, path) = AsyncStream<NetworkPath>.makeStream(bufferingPolicy: .unbounded)
        let wiFi = NetworkPath(available: true, interfaces: ["en0 (wifi)"])
        path.yield(wiFi)
        let online = Flag(true)
        let counts = Counts()
        let relayPort = relay.port
        let macKey = macIdentity.publicKey
        let link = PhoneLink(
            mac: PairedMac(id: macIdentity.id, publicKey: macKey, name: "Mac de test", relay: nil),
            identity: phoneIdentity, ways: [.direct], roundTrips: scenario.watching ? .standard : nil,
            networkChanges: paths,
            connector: {
                counts.attempt()
                guard online.value else { throw TransportError.failed("no network") }
                let transport = try await QUICTransport.connect(
                    to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: relayPort)!),
                    alpn: QUIC.directALPN, verification: .none, path: .direct, timeout: .seconds(4))
                let session = try await LinkSession.open(over: transport, macKey: macKey, identity: phoneIdentity)
                counts.opened()
                return session
            })
        await link.connect()
        await waitFor { await link.isConnected }
        await link.setAudio(true)
        await waitFor { engine.remoteRoutes == 1 }
        #expect(engine.remoteRoutes == 1)
        let microphone = Task {
            let encoder = try? OpusEncoder(sampleRate: LinkAudio.microphoneRate, bitRate: LinkAudio.microphoneBitRate)
            let stream = StreamNumber.now
            let silence = [Float](repeating: 0, count: Int(LinkAudio.microphoneRate * 0.02))
            var sequence: UInt32 = 0
            while !Task.isCancelled {
                for payload in encoder?.encode(silence) ?? [] {
                    link.sendMicrophone(AudioPacket(stream: stream, sequence: sequence, payload: payload))
                    sequence &+= 1
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        try await Task.sleep(for: .seconds(2))
        #expect(engine.reachability.isEmpty)  // heard all along

        // The cut, then the network back.
        let cut = ContinuousClock.now
        online.value = false
        relay.cut()
        if scenario.watching { path.yield(NetworkPath(available: false)) }
        try await Task.sleep(for: .seconds(cutSeconds))
        let back = ContinuousClock.now
        relay.restore(newAddress: scenario.newAddress)
        online.value = true
        if scenario.watching { path.yield(wiFi) }

        // Heard again for good: the last word is "hears", given after the network was back, 10 s ago.
        var heardAgain: ContinuousClock.Instant?
        while ContinuousClock.now - back < .seconds(80) {
            if let last = engine.reachability.last, last.reachable, last.at > back {
                heardAgain = last.at
                if ContinuousClock.now - last.at >= .seconds(10) { break }
            } else {
                heardAgain = nil
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let timeline = engine.reachability.map {
            "\(Self.seconds($0.at - cut)): \($0.reachable ? "hears the voice again" : "out of reach")"
        }
        print("MEASURE [\(scenario)] cut \(Int(cutSeconds)) s; heard again for good "
              + (heardAgain.map { "\(Self.seconds($0 - back)) after the network was back" } ?? "not within 70 s of it")
              + "; sessions opened \(counts.sessions) in \(counts.attempts) attempts; timeline from the cut: "
              + timeline.joined(separator: ", "))
        if scenario.watching {
            let after = try #require(heardAgain, "not heard again")
            #expect(after - back < .seconds(5))
        }
        microphone.cancel()
        await link.disconnect()
        await host.takeBack()
        await host.remove(device.id)
    }

    static func seconds(_ duration: Duration) -> String {
        String(format: "%.2f s", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }
}

/// The engine as the link sees it: when it was told that the iPhone hears the voice, or no longer does.
private final class TimedEngine: AssistantConnection, RemoteAudioRouting, @unchecked Sendable {
    let events: AsyncStream<AssistantEvent>
    private let emit: AsyncStream<AssistantEvent>.Continuation
    private let lock = NSLock()
    private var told: [(reachable: Bool, at: ContinuousClock.Instant)] = []
    private var routes = 0

    init() {
        (events, emit) = AsyncStream.makeStream()
    }

    var reachability: [(reachable: Bool, at: ContinuousClock.Instant)] { lock.withLock { told } }
    var remoteRoutes: Int { lock.withLock { routes } }

    func send(_ command: AssistantCommand) {}

    func useRemoteAudio(microphone: AsyncStream<[Float]>, output: any AudioOutput, bargeIn: BargeInProfile) async {
        lock.withLock { routes += 1 }
        Task { for await _ in microphone {} }
    }

    func setRemoteAudioReachable(_ reachable: Bool, reachedUntil: ContinuousClock.Instant?) async {
        lock.withLock { told.append((reachable, .now)) }
    }

    func announceThrough(_ output: (any AudioOutput)?, reachable: Bool) async {}
    func useLocalAudio() async {}
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool

    init(_ on: Bool) { self.on = on }

    var value: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}

private final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var tries = 0
    private var made = 0

    func attempt() { lock.withLock { tries += 1 } }
    func opened() { lock.withLock { made += 1 } }
    var attempts: Int { lock.withLock { tries } }
    var sessions: Int { lock.withLock { made } }
}

/// A UDP relay on this Mac between the iPhone's QUIC and the Mac's listener, as the network between them: it can drop
/// everything for a while (the iPhone's network gone), and come back with the iPhone at another port, as from a new
/// address (what the Mac sends to the old one still reaching the iPhone, as it may on a real network for a while).
final class CuttableUDP: @unchecked Sendable {
    let port: UInt16
    private let macPort: UInt16
    private let front: Int32
    private let lock = NSLock()
    private var dropping = false
    private var stopped = false
    /// For each port of the iPhone's sockets: the sockets towards the Mac, the one it sends from now last.
    private var upstreams: [UInt16: [Int32]] = [:]

    init(toMacPort macPort: UInt16) throws {
        self.macPort = macPort
        front = try Self.boundSocket()
        port = Self.localPort(of: front)
        Thread.detachNewThread { [self] in loop() }
    }

    func cut() {
        lock.withLock { dropping = true }
    }

    func restore(newAddress: Bool) {
        lock.withLock {
            if newAddress {
                for (phone, sockets) in upstreams {
                    if let socket = try? Self.boundSocket() { upstreams[phone] = sockets + [socket] }
                }
            }
            dropping = false
        }
    }

    func stop() {
        lock.withLock { stopped = true }
    }

    private func loop() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let (stopped, dropping, upstreams) = lock.withLock { (self.stopped, self.dropping, self.upstreams) }
            if stopped { break }
            var fds = [pollfd(fd: front, events: Int16(POLLIN), revents: 0)]
            var owners: [UInt16] = [0]
            for (phone, sockets) in upstreams {
                for socket in sockets {
                    fds.append(pollfd(fd: socket, events: Int16(POLLIN), revents: 0))
                    owners.append(phone)
                }
            }
            guard poll(&fds, nfds_t(fds.count), 50) > 0 else { continue }
            for (i, entry) in fds.enumerated() where entry.revents & Int16(POLLIN) != 0 {
                var from = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(entry.fd, &buffer, buffer.count, 0, $0, &length)
                    }
                }
                guard count > 0, !dropping else { continue }
                if i == 0 {
                    let phone = UInt16(bigEndian: from.sin_port)
                    let socket: Int32? = lock.withLock {
                        if let socket = self.upstreams[phone]?.last { return socket }
                        guard let socket = try? Self.boundSocket() else { return nil }
                        self.upstreams[phone] = [socket]
                        return socket
                    }
                    if let socket { Self.forward(buffer, count, from: socket, to: macPort) }
                } else {
                    Self.forward(buffer, count, from: front, to: owners[i])
                }
            }
        }
        Darwin.close(front)
        lock.withLock { upstreams.values.flatMap { $0 } }.forEach { Darwin.close($0) }
    }

    private static func forward(_ buffer: [UInt8], _ count: Int, from socket: Int32, to port: UInt16) {
        var address = loopback(port: port)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(socket, buffer, count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private static func loopback(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    private static func boundSocket() throws -> Int32 {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard socket >= 0 else { throw TransportError.failed("socket") }
        var address = loopback(port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(socket)
            throw TransportError.failed("bind")
        }
        return socket
    }

    private static func localPort(of socket: Int32) -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        return UInt16(bigEndian: address.sin_port)
    }
}
