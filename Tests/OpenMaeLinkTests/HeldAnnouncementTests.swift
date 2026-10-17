import CryptoKit
import Foundation
import Testing
import VoiceCore

@testable import OpenMaeLink

/// A timer rings while the iPhone that has the conversation is out of reach: the announcement is not said to nobody, it
/// waits. Then it is said on the iPhone once it is back, or on the Mac once the Mac takes the sound back. A LinkHost in
/// front of the real conversation logic (`VoicePipeline`, on stages without models), the iPhone's sessions over memory.
@Suite("Announcements while the iPhone is out of reach", .serialized)
struct HeldAnnouncementTests {
    static let sentence = "Ton minuteur de 20 secondes est terminé."

    /// Its connection drops and the Mac sees it (the iPhone could say so, or the relay did): it has a few seconds to
    /// come back, by another way.
    @Test func saidOnTheIPhoneOnceItComesBack() async throws {
        let rig = try await Rig()
        let first = await rig.connect()
        await rig.takeTheConversation()
        first.wire.close()
        await waitFor { rig.engine.reachability == [false] }
        #expect(rig.engine.reachability == [false])
        await rig.ringTheTimer()
        try await Task.sleep(for: .milliseconds(400))
        #expect(rig.engine.remotePlayed == 0)  // nothing was played to the closed session…
        #expect(rig.engine.localPlayed == 0)  // …nor on the Mac: the sound is still the iPhone's
        #expect(rig.engine.said.isEmpty)
        // It comes back: the chime and the sentence are played there, whole.
        let second = await rig.connect(path: .relay)
        await waitFor { second.phone.played.count == 1 }
        #expect(second.phone.played.map(\.frames) == [Rig.announcementFrames])
        await waitFor { rig.engine.said == [Self.sentence] }
        #expect(rig.engine.said == [Self.sentence])
        #expect(rig.engine.reachability == [false, true])
        #expect(rig.engine.remotePlayed == Rig.announcementSamples)
        #expect(rig.engine.localPlayed == 0)
        #expect(rig.engine.localRoutes == 0)
        #expect(first.phone.framesHeard == 0)
        await rig.end()
    }

    /// It does not come back: at the end of the grace period the Mac takes the sound back, and says it.
    @Test func saidOnTheMacOnceTheGracePeriodIsOver() async throws {
        let rig = try await Rig(gracePeriod: .milliseconds(800))
        let first = await rig.connect()
        await rig.takeTheConversation()
        first.wire.close()
        await waitFor { rig.engine.reachability == [false] }
        await rig.ringTheTimer()
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.engine.localPlayed == 0)  // still the iPhone's time to come back
        #expect(rig.engine.said.isEmpty)
        await waitFor { rig.engine.said == [Self.sentence] }
        #expect(rig.engine.said == [Self.sentence])
        #expect(rig.engine.localRoutes == 1)
        #expect(rig.engine.localPlayed == Rig.announcementSamples)
        #expect(rig.engine.remotePlayed == 0)  // nothing ever went to the closed session
        #expect(first.phone.framesHeard == 0)
        await rig.end()
    }

    /// Its Wi-Fi goes off: nothing tells the Mac, whose session with it looks open for a minute more. Its microphone
    /// no longer comes: that is enough to wait for it.
    @Test func aSilentIPhoneIsWaitedForToo() async throws {
        let rig = try await Rig()
        let first = await rig.connect()
        await rig.takeTheConversation()
        try await Task.sleep(for: .milliseconds(200))
        first.wire.cut()
        await waitFor { rig.engine.reachability == [false] }
        #expect(rig.engine.reachability == [false])
        let sent = first.wire.datagramsFromMac
        await rig.ringTheTimer()
        try await Task.sleep(for: .milliseconds(400))
        #expect(first.wire.datagramsFromMac == sent)  // nothing was sent into the dead session
        #expect(rig.engine.remotePlayed == 0)
        #expect(rig.engine.said.isEmpty)
        // It comes back through the relay: the announcement is played there.
        let second = await rig.connect(path: .relay)
        await waitFor { second.phone.played.count == 1 }
        #expect(second.phone.played.map(\.frames) == [Rig.announcementFrames])
        await waitFor { rig.engine.said == [Self.sentence] }
        #expect(rig.engine.said == [Self.sentence])
        #expect(rig.engine.reachability == [false, true])
        #expect(first.phone.framesHeard == 0)
        await rig.end()
    }
}

private func waitFor(_ condition: () async -> Bool) async {
    for _ in 0..<400 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
}

// MARK: - The Mac and the iPhone

/// The Mac (a LinkHost in front of the engine), and an iPhone that connects to it over memory.
private final class Rig: @unchecked Sendable {
    /// The chime, then the sentence (one piece of `ToneVoice`), as played.
    static let announcementSamples = Chime.samples(sampleRate: LinkAudio.voiceRate).count + ToneStream.pieceSamples
    /// The same in the voice's frames of 20 ms, the last one completed with silence.
    static let announcementFrames = (announcementSamples + 479) / 480
    static let macKey = Data(repeating: 7, count: 32)

    let engine: PipelineEngine
    let host: LinkHost
    let phone = FakePhone()
    private let folder: URL
    private let lock = NSLock()
    private var connections: [Connection] = []

    init(gracePeriod: Duration = .seconds(15)) async throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "held-announcement-\(UUID().uuidString)")
        engine = try await PipelineEngine()
        host = LinkHost(engine: engine, audio: engine, identityStore: NoIdentity(),
                        storeURL: folder.appending(path: "link.json"), macName: "Mac de test", gracePeriod: gracePeriod)
    }

    /// A new session with the iPhone, as after a handshake; its microphone and its player move to it.
    func connect(path: LinkPath = .direct) async -> Connection {
        let wire = MemoryWire(path: path)
        let (mac, phoneEnd) = wire.sessions(phoneKey: phone.key, macKey: Self.macKey)
        let connection = Connection(wire: wire, phone: PhoneSession(phoneEnd))
        lock.withLock { connections.append(connection) }
        await host.open(mac, device: phone.device)
        phone.use(connection.phone)
        return connection
    }

    /// The iPhone takes the conversation: the engine's microphone and voice go to it.
    func takeTheConversation() async {
        phone.takeTheConversation()
        await waitFor { engine.remoteRoutes == 1 }
    }

    /// What `AssistantHost` does when a timer rings.
    func ringTheTimer() async {
        await engine.pipeline.announce(HeldAnnouncementTests.sentence,
                                       note: "(Le minuteur t1 de 20 secondes vient de sonner.)", language: .french)
    }

    func end() async {
        await host.takeBack()
        phone.end()
        lock.withLock { connections }.forEach { $0.phone.close() }
        await engine.pipeline.stop()
        try? FileManager.default.removeItem(at: folder)
    }
}

private struct Connection {
    let wire: MemoryWire
    let phone: PhoneSession
}

/// No keys: the Mac's link stays off the network (no listener, no relay); the tests open the sessions themselves.
private struct NoIdentity: IdentityStore {
    func load() throws -> DeviceIdentity? { nil }
    func save(_ identity: DeviceIdentity) throws {}
    func delete() throws {}
}

/// The iPhone app as the Mac sees it, across its sessions. Once it has the conversation, its microphone sends silence
/// every 20 ms on its current session, as the app does all the time (muted or not); its player is `PhoneSession`.
private final class FakePhone: @unchecked Sendable {
    let key = Data(repeating: 9, count: 32)
    var device: PairedDevice { PairedDevice(publicKey: key, name: "iPhone", model: "iPhone17,3") }
    private let lock = NSLock()
    private var session: PhoneSession?
    private var wantsTheConversation = false
    private var microphone: Task<Void, Never>?

    /// A new session: as `PhoneLink` does, it asks for the conversation again on it, if it had it.
    func use(_ session: PhoneSession) {
        let asks = lock.withLock {
            self.session = session
            return wantsTheConversation
        }
        if asks { session.session.send(.audio(.start)) }
    }

    func takeTheConversation() {
        let encoder = try? OpusEncoder(sampleRate: LinkAudio.microphoneRate, bitRate: LinkAudio.microphoneBitRate)
        let stream = StreamNumber.now
        let microphone = Task { [weak self] in
            let frame = [Float](repeating: 0, count: Int(LinkAudio.microphoneRate * 0.02))
            var sequence: UInt32 = 0
            while !Task.isCancelled {
                for payload in encoder?.encode(frame) ?? [] {
                    self?.current?.session.send(AudioPacket(stream: stream, sequence: sequence, payload: payload))
                    sequence &+= 1
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let session: PhoneSession? = lock.withLock {
            wantsTheConversation = true
            self.microphone = microphone
            return self.session
        }
        session?.session.send(.audio(.start))
    }

    private var current: PhoneSession? { lock.withLock { session } }

    func end() {
        lock.withLock { microphone }?.cancel()
    }
}

/// The iPhone's end of one session, and its player: it counts the voice's frames of each stream, and tells the Mac
/// once a stream was played whole (`finished`), as the app does.
private final class PhoneSession: @unchecked Sendable {
    struct Stream: Equatable {
        var number: UInt32
        var frames = 0
        var announced: UInt32?
        var finished = false
    }

    let session: LinkSession
    private let lock = NSLock()
    private var streams: [UInt32: Stream] = [:]
    private var tasks: [Task<Void, Never>] = []

    init(_ session: LinkSession) {
        self.session = session
        tasks = [
            Task { [weak self] in
                for await packet in session.audio { self?.heard(packet) }
            },
            Task { [weak self] in
                for await message in session.messages {
                    if case .audio(.end(let stream, let frames)) = message { self?.ends(stream, frames: frames) }
                }
            },
        ]
    }

    /// The streams played whole, in order.
    var played: [Stream] {
        lock.withLock { streams.values.filter(\.finished).sorted { $0.number < $1.number } }
    }

    var framesHeard: Int { lock.withLock { streams.values.reduce(0) { $0 + $1.frames } } }

    func close() {
        tasks.forEach { $0.cancel() }
        session.close()
    }

    private func heard(_ packet: AudioPacket) {
        let whole = lock.withLock {
            streams[packet.stream, default: Stream(number: packet.stream)].frames += 1
            return finishIfWhole(packet.stream)
        }
        if whole { session.send(.audio(.finished(stream: packet.stream))) }
    }

    private func ends(_ stream: UInt32, frames: UInt32) {
        let whole = lock.withLock {
            streams[stream, default: Stream(number: stream)].announced = frames
            return finishIfWhole(stream)
        }
        if whole { session.send(.audio(.finished(stream: stream))) }
    }

    /// With the lock held. The frames and the stream's end come on two channels, in either order.
    private func finishIfWhole(_ number: UInt32) -> Bool {
        guard var stream = streams[number], !stream.finished, let announced = stream.announced,
              stream.frames >= Int(announced)
        else { return false }
        stream.finished = true
        streams[number] = stream
        return true
    }
}

// MARK: - A connection in memory

/// A connection between the Mac and the iPhone, in memory: what one end sends, the other end receives. `cut()`: the
/// network is gone and nobody is told, as when the iPhone's Wi-Fi goes off. `close()`: both ends are told.
private final class MemoryWire: Sendable {
    let mac: MemoryEnd
    let phone: MemoryEnd
    private let line: Line

    init(path: LinkPath) {
        let line = Line()
        self.line = line
        mac = MemoryEnd(.mac, path: path, line: line)
        phone = MemoryEnd(.phone, path: path, line: line)
    }

    func cut() { line.cut() }
    func close() { line.close(from: nil) }

    /// The datagrams (the voice) the Mac sent into this connection, carried or not.
    var datagramsFromMac: Int { line.datagrams(from: .mac) }

    /// A session over this connection, both of its ends, with keys as a handshake would have agreed them.
    func sessions(phoneKey: Data, macKey: Data) -> (mac: LinkSession, phone: LinkSession) {
        let toPhone = SymmetricKey(size: .bits256)
        let toMac = SymmetricKey(size: .bits256)
        let macSide = LinkSession(transport: mac, inbox: FrameInbox(mac),
                                  keys: SessionKeys((send: NoiseCipher(key: toPhone), receive: NoiseCipher(key: toMac))),
                                  peerKey: phoneKey, peerMac: nil)
        let phoneSide = LinkSession(transport: phone, inbox: FrameInbox(phone),
                                    keys: SessionKeys((send: NoiseCipher(key: toMac), receive: NoiseCipher(key: toPhone))),
                                    peerKey: macKey, peerMac: HandshakePayload.Mac(name: "Mac de test"))
        return (macSide, phoneSide)
    }

    enum Side: Hashable {
        case mac, phone
        var other: Side { self == .mac ? .phone : .mac }
    }

    final class Line: @unchecked Sendable {
        private let lock = NSLock()
        private var sinks: [Side: AsyncStream<TransportInput>.Continuation] = [:]
        private var isCut = false
        private var isClosed = false
        private var sent: [Side: Int] = [:]

        func attach(_ side: Side, _ sink: AsyncStream<TransportInput>.Continuation) {
            lock.withLock { sinks[side] = sink }
        }

        func carry(_ input: TransportInput, from side: Side) {
            let target: AsyncStream<TransportInput>.Continuation? = lock.withLock {
                if case .datagram = input { sent[side, default: 0] += 1 }
                return isCut || isClosed ? nil : sinks[side.other]
            }
            target?.yield(input)
        }

        func datagrams(from side: Side) -> Int { lock.withLock { sent[side] ?? 0 } }

        func cut() { lock.withLock { isCut = true } }

        /// The end that closes knows it; the other one is told unless the line is cut. nil: both are told.
        func close(from side: Side?) {
            let told: [AsyncStream<TransportInput>.Continuation] = lock.withLock {
                guard !isClosed else { return side.flatMap { sinks.removeValue(forKey: $0) }.map { [$0] } ?? [] }
                isClosed = true
                let ends: [Side] = side.map { isCut ? [$0] : [$0, $0.other] } ?? [.mac, .phone]
                return ends.compactMap { sinks.removeValue(forKey: $0) }
            }
            for sink in told {
                sink.yield(.closed(nil))
                sink.finish()
            }
        }
    }
}

private final class MemoryEnd: LinkTransport, @unchecked Sendable {
    let path: LinkPath
    let incoming: AsyncStream<TransportInput>
    private let side: MemoryWire.Side
    private let line: MemoryWire.Line

    init(_ side: MemoryWire.Side, path: LinkPath, line: MemoryWire.Line) {
        self.side = side
        self.path = path
        self.line = line
        let (incoming, sink) = AsyncStream<TransportInput>.makeStream(bufferingPolicy: .unbounded)
        self.incoming = incoming
        line.attach(side, sink)
    }

    func send(_ bytes: Data) { line.carry(.bytes(bytes), from: side) }
    func sendDatagram(_ datagram: Data) { line.carry(.datagram(datagram), from: side) }
    func close() { line.close(from: side) }
}

// MARK: - The engine

/// The engine as the link sees it, with the real conversation logic inside: a `VoicePipeline` whose voice goes to the
/// Mac's speakers, or to the iPhone while it has the conversation, switched as `AssistantHost` switches them.
private final class PipelineEngine: AssistantConnection, RemoteAudioRouting, @unchecked Sendable {
    let events: AsyncStream<AssistantEvent>
    let pipeline: VoicePipeline
    private let emit: AsyncStream<AssistantEvent>.Continuation
    private let speakers = CountingSpeaker()
    private let router: AudioRouter
    private let lock = NSLock()
    private var counts = (remoteRoutes: 0, localRoutes: 0, remotePlayed: 0)
    private var reachabilityTold: [Bool] = []
    private var finished: [String] = []
    private var feed: Task<Void, Never>?

    init() async throws {
        router = AudioRouter(speakers)
        pipeline = VoicePipeline(detector: Silence(), transcriber: Deaf(), model: Mute(), synthesizer: ToneVoice(),
                                 output: router)
        (events, emit) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        try await pipeline.start()
        Task { [weak self, pipeline, emit] in
            for await event in pipeline.events {
                switch event {
                case .state(let state): emit.yield(.state(state))
                case .turnFinished(let metrics):
                    self?.lock.withLock { self?.finished.append(metrics.assistantText) }
                    emit.yield(.turnFinished(metrics))
                default: break
                }
            }
        }
    }

    var remoteRoutes: Int { lock.withLock { counts.remoteRoutes } }
    var localRoutes: Int { lock.withLock { counts.localRoutes } }
    /// Samples sent to the iPhone's voice.
    var remotePlayed: Int { lock.withLock { counts.remotePlayed } }
    /// Samples played on the Mac's speakers.
    var localPlayed: Int { speakers.played }
    /// What the link said, in order: whether the iPhone hears the voice.
    var reachability: [Bool] { lock.withLock { reachabilityTold } }
    /// What was said to the end, in order.
    var said: [String] { lock.withLock { finished } }

    func send(_ command: AssistantCommand) {
        guard case .talkKey(let pressed) = command else { return }
        Task { [pipeline] in await pipeline.setTalkKey(pressed: pressed) }
    }

    func useRemoteAudio(microphone: AsyncStream<[Float]>, output: any AudioOutput) async {
        let feed = Task { [pipeline] in
            for await chunk in microphone { await pipeline.push(chunk) }
        }
        lock.withLock {
            counts.remoteRoutes += 1
            self.feed?.cancel()
            self.feed = feed
        }
        await router.use(CountingOutput(output: output) { [weak self] samples in
            self?.lock.withLock { self?.counts.remotePlayed += samples }
        })
        await pipeline.setOutputReachable(true)
    }

    func setRemoteAudioReachable(_ reachable: Bool) async {
        lock.withLock { reachabilityTold.append(reachable) }
        await pipeline.setOutputReachable(reachable)
    }

    func useLocalAudio() async {
        lock.withLock {
            counts.localRoutes += 1
            feed?.cancel()
            feed = nil
        }
        await router.use(speakers)
        await pipeline.setOutputReachable(true)
    }
}

/// An output that counts what goes through it.
private struct CountingOutput: AudioOutput {
    let output: any AudioOutput
    let counted: @Sendable (Int) -> Void

    func play(_ samples: [Float], sampleRate: Double) async {
        counted(samples.count)
        await output.play(samples, sampleRate: sampleRate)
    }

    func waitUntilDone() async { await output.waitUntilDone() }
    func stopImmediately() async { await output.stopImmediately() }
}

/// The Mac's speakers: they count what they are given, and are done with it at once.
private final class CountingSpeaker: AudioOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var samples = 0

    var played: Int { lock.withLock { samples } }

    func play(_ samples: [Float], sampleRate: Double) async { lock.withLock { self.samples += samples.count } }
    func waitUntilDone() async {}
    func stopImmediately() async {}
}

/// Nobody speaks.
private struct Silence: SpeechDetector {
    let chunkSize = 512
    func speechProbability(_ chunk: [Float]) async throws -> Float { 0 }
    func reset() async {}
}

private struct Deaf: Transcriber {
    func transcribe(_ samples: [Float]) async throws -> String { "" }
}

/// Never asked anything: an announcement is said without the model.
private struct Mute: LanguageModel {
    func reply(to conversation: [ChatMessage]) -> AsyncThrowingStream<ModelOutput, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func prefill(_ conversation: [ChatMessage]) async throws {}
    func tokenCount(_ conversation: [ChatMessage]) async throws -> Int { conversation.count * 10 }
}

/// Each piece of text: 0.2 s of a tone, at the voice's rate.
private struct ToneVoice: SpeechSynthesizer {
    let outputSampleRate = LinkAudio.voiceRate
    func startUtterance(language: SpeechLanguage) async throws -> any SynthesisStream { ToneStream() }
}

private final class ToneStream: SynthesisStream, @unchecked Sendable {
    static let pieceSamples = 4_800
    let audio: AsyncThrowingStream<[Float], Error>
    private let continuation: AsyncThrowingStream<[Float], Error>.Continuation

    init() {
        (audio, continuation) = AsyncThrowingStream.makeStream()
    }

    func enqueue(_ text: String) {
        continuation.yield((0..<Self.pieceSamples).map { Float(0.2 * sin(2 * .pi * 440 * Double($0) / 24_000)) })
    }

    func finish() { continuation.finish() }
    func cancel() async { continuation.finish() }
}
