import Foundation
import Testing
import VoiceCore

@testable import OpenMaeLink

/// The whole link on this Mac: a LinkHost in front of a scripted engine, a PhoneLink as the iPhone. They use the
/// network (QUIC and Bonjour on the local network, or a relay), so they only run when asked:
///
///     OPENMAE_NETWORK_TESTS=1                        the direct way
///     OPENMAE_TEST_RELAY=http://127.0.0.1:8080       also through a relay (relay/ running locally)
@Suite("Link, end to end", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["OPENMAE_NETWORK_TESTS"] == "1"))
struct LinkIntegrationTests {
    @Test func direct() async throws {
        try await conversation(relay: nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENMAE_TEST_RELAY"] != nil))
    func throughTheRelay() async throws {
        let relay = try #require(ProcessInfo.processInfo.environment["OPENMAE_TEST_RELAY"].flatMap(URL.init(string:)))
        try await conversation(relay: relay)
    }

    /// Pairing, a session, the microphone and the voice, the commands, the Mac taking over, removal.
    private func conversation(relay: URL?) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "link-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = ScriptedEngine()
        let host = LinkHost(engine: engine, audio: engine,
                            identityStore: FileIdentityStore(url: folder.appending(path: "mac.key")),
                            storeURL: folder.appending(path: "link.json"), macName: "Mac de test")
        await host.setRelay(relay.map { .custom($0) } ?? .none)
        var statuses = host.status.makeAsyncIterator()
        await host.startPairing()
        var link: PairingLink?
        while let status = await statuses.next() {
            if case .waiting(let waiting, _) = status.pairing {
                link = waiting
                if relay == nil || status.relay == .registered { break }
            }
        }
        let pairing = try #require(link)
        let ways: Set<LinkPath> = relay == nil ? [.direct] : [.relay]

        // Pairing, once: the code serves only once.
        let identity = DeviceIdentity.generate()
        let phone = HandshakePayload.Phone(name: "iPhone", model: "iPhone17,3")
        let mac = try await PhonePairing.pair(link: pairing, identity: identity, phone: phone, ways: ways)
        #expect(mac.name == "Mac de test")
        await #expect(throws: HandshakeFailure.refused("expired")) {
            _ = try await PhonePairing.pair(link: pairing, identity: DeviceIdentity.generate(), phone: phone, ways: ways)
        }

        // A session, the expected way.
        let link2 = PhoneLink(mac: mac, identity: identity, ways: ways)
        var phoneStatuses = link2.status.makeAsyncIterator()
        await link2.connect()
        var path: LinkPath?
        while let status = await phoneStatuses.next() {
            if case .connected(let connected) = status {
                path = connected
                break
            }
            if status == .forgotten { break }
        }
        #expect(path == (relay == nil ? .direct : .relay))

        // The iPhone follows the relay its Mac chooses afterwards.
        if relay == nil {
            var changes = link2.macChanges.makeAsyncIterator()
            let elsewhere = try #require(URL(string: "https://relay.example.com"))
            await host.setRelay(.custom(elsewhere))
            let first = await changes.next()
            #expect(first?.relay == elsewhere)
            await host.setRelay(.none)
            let second = await changes.next()
            #expect(second?.relay == nil)
        }

        // The iPhone takes the conversation and sends its microphone.
        await link2.setAudio(true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.remoteRoutes == 1)
        let encoder = try OpusEncoder(sampleRate: LinkAudio.microphoneRate, bitRate: LinkAudio.microphoneBitRate)
        var sequence: UInt32 = 0
        for frame in 0..<50 {
            let samples = (0..<320).map { Float(0.2 * sin(2 * .pi * 440 * Double(frame * 320 + $0) / 16_000)) }
            for packet in encoder.encode(samples) {
                link2.sendMicrophone(AudioPacket(stream: 1, sequence: sequence, payload: packet))
                sequence += 1
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.heardSamples >= 15_000)

        // Commands: the talk key goes through, deleting the models does not; the voice comes back.
        link2.send(.talkKey(pressed: true))
        link2.send(.deleteModels)
        link2.send(.talkKey(pressed: false))
        var frames = 0
        var end: (stream: UInt32, frames: UInt32)?
        var voice = link2.voice.makeAsyncIterator()
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(5), let input = await voice.next() {
            if case .packet = input { frames += 1 }
            if case .end(let stream, let total) = input { end = (stream, total) }
            if let end, frames >= Int(end.frames) { break }
        }
        #expect(frames == 50)
        #expect(end?.frames == 50)
        if let end { link2.finished(stream: end.stream) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.commands.contains { if case .talkKey = $0 { true } else { false } })
        #expect(!engine.commands.contains { if case .deleteModels = $0 { true } else { false } })

        // The Mac takes the conversation back.
        host.send(.talkKey(pressed: true))
        var released = false
        while let input = await voice.next() {
            if case .released = input {
                released = true
                break
            }
        }
        #expect(released)
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.localRoutes == 1)

        // Removed, the iPhone is told so.
        var device: PairedDevice?
        while device == nil, let status = await statuses.next() { device = status.devices.first }
        await host.remove(try #require(device).id)
        var forgotten = false
        while let status = await phoneStatuses.next() {
            if status == .forgotten {
                forgotten = true
                break
            }
        }
        #expect(forgotten)
        await link2.disconnect()
    }
}

/// The engine as the link sees it: commands in, a scripted answer (a second of tone as "voice") out.
private final class ScriptedEngine: AssistantConnection, RemoteAudioRouting, @unchecked Sendable {
    let events: AsyncStream<AssistantEvent>
    private let emit: AsyncStream<AssistantEvent>.Continuation
    private let lock = NSLock()
    private var _commands: [AssistantCommand] = []
    private var _heard = 0
    private var _remoteRoutes = 0
    private var _localRoutes = 0
    private var output: (any AudioOutput)?

    init() {
        (events, emit) = AsyncStream.makeStream()
    }

    var commands: [AssistantCommand] { lock.withLock { _commands } }
    var heardSamples: Int { lock.withLock { _heard } }
    var remoteRoutes: Int { lock.withLock { _remoteRoutes } }
    var localRoutes: Int { lock.withLock { _localRoutes } }

    func send(_ command: AssistantCommand) {
        lock.withLock { _commands.append(command) }
        if case .talkKey(pressed: false) = command { Task { await answer() } }
    }

    func useRemoteAudio(microphone: AsyncStream<[Float]>, output: any AudioOutput, bargeIn: BargeInProfile) async {
        lock.withLock {
            _remoteRoutes += 1
            self.output = output
        }
        Task {
            for await chunk in microphone { lock.withLock { _heard += chunk.count } }
        }
    }

    func setRemoteAudioReachable(_ reachable: Bool, reachedUntil: ContinuousClock.Instant?) async {}

    func announceThrough(_ output: (any AudioOutput)?, reachable: Bool) async {}

    func useLocalAudio() async {
        lock.withLock {
            _localRoutes += 1
            output = nil
        }
    }

    private func answer() async {
        emit.yield(.state(.speaking))
        guard let output = lock.withLock({ output }) else { return }
        for chunk in 0..<10 {
            await output.play((0..<2400).map { Float(0.3 * sin(2 * .pi * 330 * Double(chunk * 2400 + $0) / 24_000)) },
                              sampleRate: 24_000)
        }
        await output.waitUntilDone()
        emit.yield(.state(.listening))
    }
}
