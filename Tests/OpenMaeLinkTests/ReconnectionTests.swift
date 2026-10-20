import Foundation
import Testing
import VoiceCore

@testable import OpenMaeLink

/// The iPhone's network goes and comes back (airplane mode, Wi-Fi joined again) while it has the conversation: the
/// iPhone sees within seconds that its session no longer reaches the Mac, and opens a new one as soon as the network is
/// back, rather than once the Mac gives up on the old one a minute later. The sessions over memory, the round trips'
/// delays shortened about tenfold.
@Suite("The iPhone back after its network was cut", .serialized)
struct ReconnectionTests {
    static let quick = LinkSession.RoundTrips(every: .milliseconds(50), giveUpAfter: .milliseconds(400),
                                              afterNetworkChange: .milliseconds(200))

    // MARK: The session's round trips

    /// Nobody speaks for a while, so the Mac sends nothing of its own: its answers to the pings keep the session open,
    /// also after a change of network that it lived through.
    @Test func aSessionTheMacAnswersStaysOpen() async throws {
        let wire = MemoryWire(path: .direct)
        let (mac, phone) = wire.sessions(phoneKey: PhoneRig.phoneKey, macKey: Rig.macKey)
        phone.checkRoundTrips(Self.quick)
        try await Task.sleep(for: .seconds(1))
        #expect(phone.isOpen)
        phone.networkChanged()
        try await Task.sleep(for: .milliseconds(500))
        #expect(phone.isOpen)
        #expect(mac.isOpen)
        wire.close()
    }

    /// The network goes without a word (the connection is cut): the iPhone closes its session once the Mac has not
    /// answered for `giveUpAfter`. The Mac's end knows nothing of it.
    @Test func aSessionTheMacNoLongerAnswersIsClosed() async throws {
        let wire = MemoryWire(path: .direct)
        let (mac, phone) = wire.sessions(phoneKey: PhoneRig.phoneKey, macKey: Rig.macKey)
        phone.checkRoundTrips(Self.quick)
        try await Task.sleep(for: .milliseconds(300))
        let cut = ContinuousClock.now
        wire.cut()
        await waitFor { !phone.isOpen }
        let closedAfter = ContinuousClock.now - cut
        #expect(!phone.isOpen)
        #expect(closedAfter >= .milliseconds(300) && closedAfter < .milliseconds(900))
        #expect(mac.isOpen)
        mac.close()
    }

    /// The network changes under the session (Wi-Fi back, another address) and the session did not live through it:
    /// the Mac must answer a ping sent then within `afterNetworkChange`, well before `giveUpAfter`.
    @Test func afterAChangeOfNetworkTheMacMustAnswerAtOnce() async throws {
        let wire = MemoryWire(path: .direct)
        let (mac, phone) = wire.sessions(phoneKey: PhoneRig.phoneKey, macKey: Rig.macKey)
        phone.checkRoundTrips(LinkSession.RoundTrips(every: .milliseconds(50), giveUpAfter: .seconds(3),
                                                     afterNetworkChange: .milliseconds(200)))
        try await Task.sleep(for: .milliseconds(300))
        wire.cut()
        let change = ContinuousClock.now
        phone.networkChanged()
        await waitFor { !phone.isOpen }
        let closedAfter = ContinuousClock.now - change
        #expect(!phone.isOpen)
        #expect(closedAfter >= .milliseconds(200) && closedAfter < .milliseconds(700))
        mac.close()
    }

    // MARK: The iPhone and the Mac

    /// Airplane mode during the conversation, then off. Meanwhile the iPhone says it is reconnecting (not that the Mac
    /// does not answer); once the network is back, the Mac hears it again at once, on a new session, for good.
    @Test func theMacHearsTheIPhoneAgainAsSoonAsItsNetworkIsBack() async throws {
        let rig = try await PhoneRig()
        await rig.start()
        rig.network.airplaneMode(true)
        await waitFor { rig.engine.reachability == [false] }
        #expect(rig.engine.reachability == [false])  // the Mac: a second without its microphone
        await waitFor { rig.statuses.last == .reconnecting }
        try await Task.sleep(for: .milliseconds(800))  // well into the cut: attempts without a network
        #expect(rig.statuses.last == .reconnecting)
        #expect(!rig.statuses.contains(.unreachable))
        let back = ContinuousClock.now
        rig.network.airplaneMode(false)
        await waitFor { rig.engine.reachability == [false, true] }
        let heardAgainAfter = ContinuousClock.now - back
        #expect(rig.engine.reachability == [false, true])
        #expect(heardAgainAfter < .seconds(1))
        try await Task.sleep(for: .seconds(1))
        #expect(rig.engine.reachability == [false, true])  // for good
        #expect(rig.network.sessionsOpened == 2)
        await rig.end()
    }

    /// The connection dies under the session without the network saying anything (what the iPhone did after airplane
    /// mode: heard again for a second, then lost on the same session until the Mac closed it a minute later): the
    /// iPhone sees that the Mac no longer answers and opens a new session, on which the Mac hears it again.
    @Test func aSessionThatDiesSilentlyIsReplaced() async throws {
        let rig = try await PhoneRig()
        await rig.start()
        let cut = ContinuousClock.now
        rig.network.cutSilently()
        await waitFor { rig.engine.reachability == [false, true] }
        let heardAgainAfter = ContinuousClock.now - cut
        #expect(rig.engine.reachability == [false, true])
        #expect(heardAgainAfter < .milliseconds(1500))
        #expect(rig.network.sessionsOpened == 2)
        try await Task.sleep(for: .seconds(1))
        #expect(rig.engine.reachability == [false, true])
        await rig.end()
    }

    /// The Mac could not be reached for a while, the attempts further and further apart; then the network changes (Wi-Fi
    /// joined): the next attempt is now, not at the end of the wait.
    @Test func aChangeOfNetworkCutsTheWaitShort() async throws {
        let rig = try await PhoneRig()
        rig.network.macAnswers = false
        await rig.link.connect()
        // Attempts at about 0, 1 and 2 s; after the third failure the wait is 2 s.
        await waitFor { rig.network.attempts >= 3 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.network.attempts == 3)
        #expect(rig.statuses.last == .unreachable)
        rig.network.macAnswers = true
        let change = ContinuousClock.now
        rig.network.joinWiFi()
        await waitFor { rig.statuses.last == .connected(.direct) }
        let connectedAfter = ContinuousClock.now - change
        #expect(rig.statuses.last == .connected(.direct))
        #expect(connectedAfter < .milliseconds(500))
        await rig.end()
    }
}

// MARK: - The rig

/// The Mac (a LinkHost in front of the engine) and a real PhoneLink as the iPhone, whose sessions go over memory through
/// `TestNetwork`. Once it has the conversation, its microphone sends silence every 20 ms, as the app does.
final class PhoneRig: @unchecked Sendable {
    static let phoneKey = Data(repeating: 9, count: 32)

    let engine: PipelineEngine
    let host: LinkHost
    let network: TestNetwork
    let link: PhoneLink
    private let folder: URL
    private let lock = NSLock()
    private var seen: [PhoneLink.Status] = []
    private var tasks: [Task<Void, Never>] = []

    init(roundTrips: LinkSession.RoundTrips = ReconnectionTests.quick) async throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "reconnection-\(UUID().uuidString)")
        engine = try await PipelineEngine(transcriber: Deaf(), model: Mute(), voice: ToneVoice())
        host = LinkHost(engine: engine, audio: engine, identityStore: NoIdentity(),
                        storeURL: folder.appending(path: "link.json"), macName: "Mac de test")
        let network = TestNetwork(host: host, device: PairedDevice(publicKey: Self.phoneKey, name: "iPhone",
                                                                   model: "iPhone17,3"))
        self.network = network
        link = PhoneLink(mac: PairedMac(id: "mac", publicKey: Rig.macKey, name: "Mac de test", relay: nil),
                         identity: DeviceIdentity.generate(), ways: [.direct], roundTrips: roundTrips,
                         networkChanges: network.changes, connector: { try await network.open() })
        let link = link
        tasks.append(Task { [weak self] in
            for await status in link.status { self?.record(status) }
        })
    }

    /// What the iPhone said of its link, in order.
    var statuses: [PhoneLink.Status] { lock.withLock { seen } }

    private func record(_ status: PhoneLink.Status) {
        lock.withLock { seen.append(status) }
    }

    /// Connected, the conversation taken, the microphone running and heard.
    func start() async {
        await link.connect()
        await waitFor { self.statuses.last == .connected(.direct) }
        await link.setAudio(true)
        await waitFor { self.engine.remoteRoutes == 1 }
        let link = link
        tasks.append(Task {
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
        })
        try? await Task.sleep(for: .milliseconds(300))
    }

    func end() async {
        tasks.forEach { $0.cancel() }
        await link.disconnect()
        await host.takeBack()
        await engine.pipeline.stop()
        network.closeAll()
        try? FileManager.default.removeItem(at: folder)
    }
}

/// The iPhone's network, as `PhoneLink` sees it: what NWPathMonitor reports (`changes`), and its sessions to the Mac,
/// each over a new connection in memory, while there is a network and the Mac answers.
final class TestNetwork: @unchecked Sendable {
    static let wiFi = NetworkPath(available: true, interfaces: ["en0 (wifi)"])

    let changes: AsyncStream<NetworkPath>
    private let sink: AsyncStream<NetworkPath>.Continuation
    private let host: LinkHost
    private let device: PairedDevice
    private let lock = NSLock()
    private var online = true
    private var answers = true
    private var wires: [MemoryWire] = []
    private var tries = 0

    init(host: LinkHost, device: PairedDevice) {
        self.host = host
        self.device = device
        (changes, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        sink.yield(Self.wiFi)  // NWPathMonitor's first report
    }

    /// Whether the Mac answers (otherwise its sessions cannot be opened, as when it is asleep).
    var macAnswers: Bool {
        get { lock.withLock { answers } }
        set { lock.withLock { answers = newValue } }
    }

    var attempts: Int { lock.withLock { tries } }
    var sessionsOpened: Int { lock.withLock { wires.count } }

    /// A session with the Mac, as after a handshake, the Mac's end opened by its LinkHost.
    func open() async throws -> LinkSession {
        let (online, answers) = lock.withLock {
            tries += 1
            return (self.online, self.answers)
        }
        guard online else { throw TransportError.failed("no network") }
        guard answers else { throw TransportError.timeout }
        let wire = MemoryWire(path: .direct)
        let (mac, phone) = wire.sessions(phoneKey: device.publicKey, macKey: Rig.macKey)
        lock.withLock { wires.append(wire) }
        await host.open(mac, device: device)
        return phone
    }

    /// On: no network, the connections cut without a word, and NWPathMonitor reports it. Off: Wi-Fi again.
    func airplaneMode(_ on: Bool) {
        let wires: [MemoryWire] = lock.withLock {
            online = !on
            return self.wires
        }
        if on { wires.forEach { $0.cut() } }
        sink.yield(on ? NetworkPath(available: false) : Self.wiFi)
    }

    /// Another Wi-Fi joined.
    func joinWiFi() {
        sink.yield(NetworkPath(available: true, interfaces: ["en0 (wifi)", "via 192.168.1.1"]))
    }

    /// The current connection dies, and the network says nothing of it.
    func cutSilently() {
        lock.withLock { wires.last }?.cut()
    }

    func closeAll() {
        lock.withLock { wires }.forEach { $0.close() }
        sink.finish()
    }
}
