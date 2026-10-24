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

    /// The same with an iPhone that pings every second, as the app does: it is waited for as before. Its session is not
    /// closed after a few seconds of silence, as a home station's is (the grace period would then start, and the Mac
    /// take the sound back once it is over, here after 0.8 s).
    @Test func aSilentIPhoneThatPingsKeepsTheConversation() async throws {
        let rig = try await Rig(gracePeriod: .milliseconds(800), phone: FakePhone(roundTrips: .standard))
        let first = await rig.connect()
        await rig.takeTheConversation()
        try await Task.sleep(for: .milliseconds(1500))  // its pings heard
        first.wire.cut()
        await waitFor { rig.engine.reachability == [false] }
        #expect(rig.engine.reachability == [false])
        try await Task.sleep(for: .seconds(5))
        #expect(first.mac.isOpen)
        #expect(rig.engine.localRoutes == 0)  // the iPhone keeps the conversation
        #expect(rig.engine.reachability == [false])
        let second = await rig.connect(path: .relay)
        await waitFor { rig.engine.reachability == [false, true] }
        #expect(rig.engine.reachability == [false, true])
        #expect(!first.mac.isOpen)  // replaced
        #expect(second.mac.isOpen)
        await rig.end()
    }

    // MARK: Cut off on the way

    /// Its Wi-Fi goes off while the announcement is being sent: the chime reached it, and it comes back through the
    /// relay while the sentence is on its way. What it then says it played lacks the beginning (it fills in what it did
    /// not get): the announcement is said there again, whole, and recorded once.
    @Test func cutWhileItIsSentThenSaidWholeOnTheNewSession() async throws {
        let (voice, model) = (GatedVoice(), Notebook())
        let rig = try await Rig(model: model, voice: voice)
        let first = await rig.connect()
        await rig.takeTheConversation()
        try await Task.sleep(for: .milliseconds(200))
        await rig.ringTheTimer()
        await waitFor { first.phone.framesHeard >= Rig.chimeFrames }  // the chime is there, the sentence not yet
        first.wire.cut()
        let second = await rig.connect(path: .relay)
        voice.open()
        await waitFor { second.phone.played.count == 2 }
        #expect(second.phone.played.map(\.frames) == [Rig.announcementFrames - Rig.chimeFrames, Rig.announcementFrames])
        await waitFor { rig.engine.said == [Self.sentence] }
        #expect(rig.engine.said == [Self.sentence])
        #expect(rig.engine.cutOff == [Self.sentence])
        await waitFor { await model.recorded == [Self.sentence] }
        #expect(await model.recorded == [Self.sentence])  // said once, in the history
        #expect(rig.engine.remotePlayed == 2 * Rig.announcementSamples)
        #expect(rig.engine.localPlayed == 0)
        #expect(first.phone.played.isEmpty)
        await rig.end()
    }

    /// The same, but the iPhone comes back only later: the rest of the announcement and its end went into the dead
    /// connection. The Mac waits for the iPhone to say it played it until it should have, then takes it as not heard
    /// and says it again once the iPhone is back.
    @Test func cutWhileItIsSentThenSaidAgainOnceTheIPhoneIsBack() async throws {
        let (voice, model) = (GatedVoice(), Notebook())
        let rig = try await Rig(model: model, voice: voice)
        let first = await rig.connect()
        await rig.takeTheConversation()
        try await Task.sleep(for: .milliseconds(200))
        await rig.ringTheTimer()
        await waitFor { first.phone.framesHeard >= Rig.chimeFrames }
        first.wire.cut()
        voice.open()
        await waitFor(seconds: 8) { rig.engine.cutOff == [Self.sentence] }
        #expect(rig.engine.cutOff == [Self.sentence])
        #expect(rig.engine.said.isEmpty)
        #expect(rig.engine.reachability == [false])
        let second = await rig.connect(path: .relay)
        await waitFor { second.phone.played.count == 1 }
        #expect(second.phone.played.map(\.frames) == [Rig.announcementFrames])
        await waitFor { rig.engine.said == [Self.sentence] }
        #expect(rig.engine.said == [Self.sentence])
        await waitFor { await model.recorded == [Self.sentence] }
        #expect(await model.recorded == [Self.sentence])
        #expect(rig.engine.reachability == [false, true])
        #expect(first.phone.played.isEmpty)
        await rig.end()
    }

    /// The iPhone lets go of the conversation while it plays the announcement: it will not say it played it. The Mac's
    /// speakers have the voice again: said there.
    @Test func theIPhoneLetsGoWhileItSaysIt() async throws {
        let model = Notebook()
        let rig = try await Rig(model: model)
        let first = await rig.connect(playsInRealTime: true)
        await rig.takeTheConversation()
        try await Task.sleep(for: .milliseconds(200))
        await rig.ringTheTimer()
        await waitFor { first.phone.framesHeard == Rig.announcementFrames }  // all there: it plays it
        rig.phone.letGo()
        await waitFor { rig.engine.said == [Self.sentence] }
        #expect(rig.engine.said == [Self.sentence])
        #expect(rig.engine.cutOff == [Self.sentence])
        #expect(rig.engine.localRoutes == 1)
        #expect(rig.engine.remotePlayed == Rig.announcementSamples)
        #expect(rig.engine.localPlayed == Rig.announcementSamples)
        await waitFor { await model.recorded == [Self.sentence] }
        #expect(await model.recorded == [Self.sentence])
        await rig.end()
    }

    // MARK: The Mac's talk key

    /// The Mac's talk key while the announcement waits for the iPhone: the Mac takes the sound back, which lets the
    /// announcement start there, and the key then stops it. It is the user's turn: the announcement is said after it.
    @Test func theMacsTalkKeyGoesFirst() async throws {
        let model = Notebook(answer: "Il est midi.")
        let rig = try await Rig(transcriber: Hears("Quelle heure est-il ?"), model: model)
        let first = await rig.connect()
        await rig.takeTheConversation()
        first.wire.close()
        await waitFor { rig.engine.reachability == [false] }
        await rig.ringTheTimer()
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.engine.said.isEmpty)
        rig.host.send(.talkKey(pressed: true))
        await waitFor { rig.engine.localRoutes == 1 }
        try await Task.sleep(for: .milliseconds(100))
        await rig.engine.speakIntoTheMac(seconds: 0.5)
        rig.host.send(.talkKey(pressed: false))
        await waitFor { rig.engine.said.count == 2 }
        #expect(rig.engine.said == ["Il est midi.", Self.sentence])
        await waitFor { await model.recorded.count == 2 }
        #expect(await model.recorded == ["Il est midi.", Self.sentence])
        #expect(rig.engine.remotePlayed == 0)
        #expect(first.phone.framesHeard == 0)
        await rig.end()
    }
}

// MARK: - The Mac and the iPhone

// Shared with the home station's tests (StationTests).

/// The Mac (a LinkHost in front of the engine), and an iPhone that connects to it over memory.
final class Rig: @unchecked Sendable {
    /// The chime, then the sentence (one piece of `ToneVoice`), as played.
    static let announcementSamples = Chime.samples(sampleRate: LinkAudio.voiceRate).count + ToneStream.pieceSamples
    /// The same in the voice's frames of 20 ms, the last one completed with silence.
    static let announcementFrames = (announcementSamples + 479) / 480
    /// The frames sent with the chime alone, before the sentence.
    static let chimeFrames = Chime.samples(sampleRate: LinkAudio.voiceRate).count / 480
    static let macKey = Data(repeating: 7, count: 32)

    let engine: PipelineEngine
    let host: LinkHost
    let phone: FakePhone
    private let folder: URL
    private let lock = NSLock()
    private var connections: [Connection] = []

    /// `transcriber`, `model`, `voice`: the engine's stages, none of which hears, answers or speaks by default (beyond
    /// the announcement, said by the voice alone). `phone`: the iPhone of `connect()` and `takeTheConversation()`.
    init(gracePeriod: Duration = .seconds(15), transcriber: any Transcriber = Deaf(), model: any LanguageModel = Mute(),
         voice: any SpeechSynthesizer = ToneVoice(), config: PipelineConfig = .init(), phone: FakePhone = FakePhone())
        async throws
    {
        self.phone = phone
        folder = FileManager.default.temporaryDirectory.appending(path: "held-announcement-\(UUID().uuidString)")
        engine = try await PipelineEngine(transcriber: transcriber, model: model, voice: voice, config: config)
        host = LinkHost(engine: engine, audio: engine, identityStore: NoIdentity(),
                        storeURL: folder.appending(path: "link.json"), macName: "Mac de test", gracePeriod: gracePeriod)
    }

    /// A new session with the iPhone (or `device`), as after a handshake; its microphone and its player move to it.
    /// `playsInRealTime`: its player says it played a stream once it would have, rather than as soon as it has it all.
    func connect(_ device: FakePhone? = nil, path: LinkPath = .direct, playsInRealTime: Bool = false) async
        -> Connection
    {
        let phone = device ?? self.phone
        let wire = MemoryWire(path: path)
        let (mac, phoneEnd) = wire.sessions(phoneKey: phone.key, macKey: Self.macKey)
        let connection = Connection(wire: wire, phone: PhoneSession(phoneEnd, playsInRealTime: playsInRealTime),
                                    mac: mac)
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

    func end(_ others: FakePhone...) async {
        await host.takeBack()
        phone.end()
        others.forEach { $0.end() }
        lock.withLock { connections }.forEach { $0.phone.close() }
        await engine.pipeline.stop()
        try? FileManager.default.removeItem(at: folder)
    }
}

struct Connection {
    let wire: MemoryWire
    let phone: PhoneSession
    /// The Mac's end of the session.
    let mac: LinkSession
}

/// No keys: the Mac's link stays off the network (no listener, no relay); the tests open the sessions themselves.
struct NoIdentity: IdentityStore {
    func load() throws -> DeviceIdentity? { nil }
    func save(_ identity: DeviceIdentity) throws {}
    func delete() throws {}
}

/// The iPhone app as the Mac sees it, across its sessions. Once it has the conversation, its microphone sends silence
/// every 20 ms on its current session, as the app does all the time (muted or not); its player is `PhoneSession`.
final class FakePhone: @unchecked Sendable {
    let key: Data
    let model: String
    /// How its sessions check that the Mac answers (`LinkSession.checkRoundTrips`): a ping every second, as the app
    /// does since then. nil: an app from before, which pings only after 25 s without sending anything.
    let roundTrips: LinkSession.RoundTrips?
    var device: PairedDevice { PairedDevice(publicKey: key, name: model.hasPrefix("iPad") ? "iPad" : "iPhone",
                                            model: model) }
    private let lock = NSLock()
    private var session: PhoneSession?
    private var wantsTheConversation = false
    /// What it said with `device` (nil: nothing, as an iPhone).
    private var station: Bool?
    private var microphone: Task<Void, Never>?

    init(key: Data = Data(repeating: 9, count: 32), model: String = "iPhone17,3",
         roundTrips: LinkSession.RoundTrips? = nil)
    {
        self.key = key
        self.model = model
        self.roundTrips = roundTrips
    }

    /// The user's iPad mini, left at home.
    static func iPad(roundTrips: LinkSession.RoundTrips? = nil) -> FakePhone {
        FakePhone(key: Data(repeating: 11, count: 32), model: "iPad14,1", roundTrips: roundTrips)
    }

    /// A new session: as `PhoneLink` does, it checks its round trips on it (if it does), says again whether it is a
    /// station, and asks for the conversation again on it, if it had it.
    func use(_ session: PhoneSession) {
        let (asks, station) = lock.withLock {
            self.session = session
            return (wantsTheConversation, self.station)
        }
        if let roundTrips { session.session.checkRoundTrips(roundTrips) }
        if let station { session.session.send(.device(station: station)) }
        if asks { session.session.send(.audio(.start)) }
    }

    /// `device`: whether it is a home station now.
    func say(station: Bool) {
        let session: PhoneSession? = lock.withLock {
            self.station = station
            return self.session
        }
        session?.session.send(.device(station: station))
    }

    /// It lets go of the conversation (`audio stop`), its link staying open: what a station does a minute after an
    /// exchange in "Tap to talk".
    func giveTheConversationBack() {
        let session: PhoneSession? = lock.withLock {
            wantsTheConversation = false
            microphone?.cancel()
            microphone = nil
            return self.session
        }
        session?.session.send(.audio(.stop))
    }

    /// What its microphone sends from now on: a 220 Hz tone that loud (peak amplitude), or silence (0). With
    /// `PipelineEngine.iPhoneUserSpeaks`, a voice into the iPhone at that level.
    func microphoneTone(amplitude: Float) {
        lock.withLock { tone = amplitude }
    }

    private var tone: Float = 0

    func takeTheConversation() {
        let encoder = try? OpusEncoder(sampleRate: LinkAudio.microphoneRate, bitRate: LinkAudio.microphoneBitRate)
        let stream = StreamNumber.now
        let microphone = Task { [weak self] in
            let samples = Int(LinkAudio.microphoneRate * 0.02)
            var sequence: UInt32 = 0
            var phase = 0
            while !Task.isCancelled {
                let amplitude = self.map { phone in phone.lock.withLock { phone.tone } } ?? 0
                let frame = (0..<samples).map {
                    amplitude * Float(sin(2 * .pi * 220 * Double(phase + $0) / LinkAudio.microphoneRate))
                }
                phase += samples
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

    /// It lets go of the conversation (its sound turned off): the Mac takes it back.
    func letGo() {
        let session: PhoneSession? = lock.withLock {
            wantsTheConversation = false
            microphone?.cancel()
            return self.session
        }
        session?.session.send(.audio(.stop))
    }

    func end() {
        lock.withLock { microphone }?.cancel()
    }
}

/// The iPhone's end of one session, and its player: it counts the voice's frames of each stream, and tells the Mac
/// once a stream was played (`finished`), as the app does: as soon as it has all of it, or once it would have played it
/// (`playsInRealTime`). A stream whose end came but some of whose frames never did is played all the same, the gaps
/// filled in as the app's jitter buffer does, and said played a moment later.
final class PhoneSession: @unchecked Sendable {
    struct Stream: Equatable {
        var number: UInt32
        var frames = 0
        var announced: UInt32?
        var finished = false
        /// Its player has it (whole, or with the gaps filled in): `finished` follows once it is played.
        var playing = false
        /// When its first frame came.
        var start = ContinuousClock.now
    }

    let session: LinkSession
    private let playsInRealTime: Bool
    private let lock = NSLock()
    private var streams: [UInt32: Stream] = [:]
    private var tasks: [Task<Void, Never>] = []
    /// While set, a stream played is not reported (`finished`) yet: the voice is still heard.
    private var holding = false
    private var held: [UInt32] = []
    private var stopsHeard: [UInt32] = []

    init(_ session: LinkSession, playsInRealTime: Bool = false) {
        self.session = session
        self.playsInRealTime = playsInRealTime
        tasks = [
            Task { [weak self] in
                for await packet in session.audio { self?.heard(packet) }
            },
            Task { [weak self] in
                for await message in session.messages {
                    switch message {
                    case .audio(.end(let stream, let frames)): self?.ends(stream, frames: frames)
                    case .audio(.stopPlayback(let stream)): self?.stopped(stream)
                    default: break
                    }
                }
            },
        ]
    }

    /// The streams played (`frames`: how many of them came), in order.
    var played: [Stream] {
        lock.withLock { streams.values.filter(\.finished).sorted { $0.number < $1.number } }
    }

    var framesHeard: Int { lock.withLock { streams.values.reduce(0) { $0 + $1.frames } } }

    /// The streams heard whole, reported or not.
    var heardWhole: [Stream] {
        lock.withLock { streams.values.filter(\.finished).sorted { $0.number < $1.number } }
    }

    /// The streams the Mac told it to stop.
    var stops: [UInt32] { lock.withLock { stopsHeard } }

    /// The voice lasts until `release()`: what is played is reported then.
    func hold() { lock.withLock { holding = true } }

    func release() {
        let streams: [UInt32] = lock.withLock {
            holding = false
            defer { held = [] }
            return held
        }
        for stream in streams { session.send(.audio(.finished(stream: stream))) }
    }

    private func stopped(_ stream: UInt32) {
        lock.withLock {
            stopsHeard.append(stream)
            held.removeAll { $0 == stream }
        }
        session.send(.audio(.finished(stream: stream)))
    }

    func close() {
        tasks.forEach { $0.cancel() }
        session.close()
    }

    private func heard(_ packet: AudioPacket) {
        let whole = lock.withLock {
            streams[packet.stream, default: Stream(number: packet.stream)].frames += 1
            return takeIfWhole(packet.stream)
        }
        if whole { play(packet.stream) }
    }

    private func ends(_ stream: UInt32, frames: UInt32) {
        let whole = lock.withLock {
            streams[stream, default: Stream(number: stream)].announced = frames
            return takeIfWhole(stream)
        }
        if whole {
            play(stream)
            return
        }
        // Some of it is missing: played with the gaps filled in, once what is still on its way had time to come.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.lock.withLock({ self.take(stream) }) else { return }
            self.play(stream)
        }
    }

    /// With the lock held. The frames and the stream's end come on two channels, in either order.
    private func takeIfWhole(_ number: UInt32) -> Bool {
        guard let stream = streams[number], let announced = stream.announced, stream.frames >= Int(announced)
        else { return false }
        return take(number)
    }

    /// With the lock held: the player takes the stream, once.
    private func take(_ number: UInt32) -> Bool {
        guard var stream = streams[number], !stream.playing else { return false }
        stream.playing = true
        streams[number] = stream
        return true
    }

    /// Plays the stream, at once or in its own time, then says so to the Mac.
    private func play(_ number: UInt32) {
        let wait: Duration = lock.withLock {
            guard playsInRealTime, let stream = streams[number], let announced = stream.announced else { return .zero }
            return stream.start + .milliseconds(Int(announced) * 20) - .now
        }
        guard wait > .zero else { return said(number) }
        Task { [weak self] in
            try? await Task.sleep(for: wait)
            self?.said(number)
        }
    }

    private func said(_ number: UInt32) {
        let report: Bool = lock.withLock {
            streams[number]?.finished = true
            guard holding else { return true }
            held.append(number)
            return false
        }
        if report { session.send(.audio(.finished(stream: number))) }
    }
}

// MARK: - The engine

/// The engine as the link sees it, with the real conversation logic inside: a `VoicePipeline` whose voice goes to the
/// Mac's speakers, or to the iPhone while it has the conversation, switched as `AssistantHost` switches them.
final class PipelineEngine: AssistantConnection, RemoteAudioRouting, @unchecked Sendable {
    let events: AsyncStream<AssistantEvent>
    let pipeline: VoicePipeline
    private let emit: AsyncStream<AssistantEvent>.Continuation
    let speakers = CountingSpeaker()
    private let detector = Silence()
    private let router: AudioRouter
    private let lock = NSLock()
    private var counts = (remoteRoutes: 0, localRoutes: 0, remotePlayed: 0, stationPlayed: 0)
    private var reachabilityTold: [Bool] = []
    private var announcementsTold: [Bool?] = []
    private var bargeInsTold: [BargeInProfile] = []
    private var finished: [String] = []
    private var interrupted: [String] = []
    private var bargeIns = 0
    private var received: [AssistantCommand] = []
    private var statesSeen: [PipelineState] = []
    private var piecesShown: [String] = []
    private var feed: Task<Void, Never>?

    init(transcriber: any Transcriber, model: any LanguageModel, voice: any SpeechSynthesizer,
         config: PipelineConfig = .init()) async throws
    {
        router = AudioRouter(speakers)
        pipeline = VoicePipeline(detector: detector, transcriber: transcriber, model: model, synthesizer: voice,
                                 output: router, config: config)
        (events, emit) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        try await pipeline.start()
        Task { [weak self, pipeline, emit] in
            for await event in pipeline.events {
                switch event {
                case .state(let state):
                    self?.lock.withLock { self?.statesSeen.append(state) }
                    emit.yield(.state(state))
                case .assistantPiece(let piece):
                    self?.lock.withLock { self?.piecesShown.append(piece) }
                    emit.yield(.assistantPiece(piece))
                case .turnFinished(let metrics):
                    self?.lock.withLock {
                        if metrics.interrupted {
                            self?.interrupted.append(metrics.assistantText)
                        } else {
                            self?.finished.append(metrics.assistantText)
                        }
                    }
                    emit.yield(.turnFinished(metrics))
                case .bargeIn: self?.lock.withLock { self?.bargeIns += 1 }
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
    /// What was cut off, in order: stopped on the way, or not heard.
    var cutOff: [String] { lock.withLock { interrupted } }
    /// Samples sent to a home station's voice, for announcements (`announceThrough`).
    var stationPlayed: Int { lock.withLock { counts.stationPlayed } }
    /// What the link said about announcements, in order: nil where the conversation is, true on a station that hears
    /// them, false waiting for one.
    var announcements: [Bool?] { lock.withLock { announcementsTold } }
    /// Times the user's voice interrupted Maé.
    var interruptions: Int { lock.withLock { bargeIns } }
    /// The barge-in profiles the link gave with the devices that took the conversation, in order.
    var bargeInProfiles: [BargeInProfile] { lock.withLock { bargeInsTold } }
    /// The commands it got, in order.
    var commands: [AssistantCommand] { lock.withLock { received } }
    /// The conversation's states, in order.
    var states: [PipelineState] { lock.withLock { statesSeen } }
    /// What the interfaces were shown of what Maé said, piece by piece.
    var pieces: [String] { lock.withLock { piecesShown } }

    /// The user speaks into the iPhone (on) or stops (off): its microphone's frames are taken for speech meanwhile.
    func iPhoneUserSpeaks(_ on: Bool) {
        detector.hearsSpeech = on
    }

    /// The user speaks into the Mac's microphone, for `seconds`.
    func speakIntoTheMac(seconds: Double) async {
        let chunk = [Float](repeating: 0.1, count: 512)
        for _ in 0..<Int(seconds * 16_000 / 512) { await pipeline.push(chunk) }
    }

    /// The Mac's own microphone hears someone talk for `seconds` (loud enough not to be taken for an echo).
    func macMicrophoneHearsSpeech(seconds: Double) async {
        detector.hearsSpeech = true
        let chunk = (0..<512).map { Float(0.3 * sin(2 * .pi * 220 * Double($0) / 16_000)) }
        for _ in 0..<Int(seconds * 16_000 / 512) { await pipeline.push(chunk) }
        detector.hearsSpeech = false
        for _ in 0..<20 { await pipeline.push([Float](repeating: 0, count: 512)) }
    }

    func send(_ command: AssistantCommand) {
        lock.withLock { received.append(command) }
        switch command {
        case .talkKey(let pressed): Task { [pipeline] in await pipeline.setTalkKey(pressed: pressed) }
        case .stopSpeaking: Task { [pipeline] in await pipeline.interrupt() }
        default: break
        }
    }

    func useRemoteAudio(microphone: AsyncStream<[Float]>, output: any AudioOutput, bargeIn: BargeInProfile) async {
        let feed = Task { [pipeline] in
            for await chunk in microphone { await pipeline.push(chunk) }
        }
        lock.withLock {
            counts.remoteRoutes += 1
            self.feed?.cancel()
            self.feed = feed
            bargeInsTold.append(bargeIn)
        }
        await router.use(CountingOutput(output: output) { [weak self] samples in
            self?.lock.withLock { self?.counts.remotePlayed += samples }
        })
        await pipeline.setBargeIn(bargeIn)
        await pipeline.resetAudioInput()
        await pipeline.voiceOutputChanged()
        await pipeline.setOutputReachable(true)
    }

    func setRemoteAudioReachable(_ reachable: Bool, reachedUntil: ContinuousClock.Instant?) async {
        lock.withLock { reachabilityTold.append(reachable) }
        await pipeline.setOutputReachable(reachable, reachedUntil: reachedUntil)
    }

    func announceThrough(_ output: (any AudioOutput)?, reachable: Bool) async {
        lock.withLock { announcementsTold.append(output.map { _ in reachable }) }
        let counted = output.map { output in
            CountingOutput(output: output) { [weak self] samples in
                self?.lock.withLock { self?.counts.stationPlayed += samples }
            }
        }
        await pipeline.announceThrough(counted, reachable: reachable)
    }

    /// As `AssistantHost` does: the Mac's speakers again, what was playing stopped while its audio restarts, then what
    /// waited for the voice is said (not what waited for the iPhone only).
    func useLocalAudio() async {
        lock.withLock {
            counts.localRoutes += 1
            feed?.cancel()
            feed = nil
        }
        await router.use(speakers)
        await pipeline.setBargeIn(.mac)
        await pipeline.interrupt()
        await pipeline.resetAudioInput()
        await pipeline.voiceOutputChanged()
        await pipeline.setOutputReachable(true)
    }
}

// MARK: - Stages for the tests that cut an announcement off

/// Hears the same sentence in whatever it is given.
private struct Hears: Transcriber {
    let sentence: String
    init(_ sentence: String) { self.sentence = sentence }
    func transcribe(_ samples: [Float]) async throws -> String { sentence }
}

/// Answers every request with the same sentence, and keeps the history as it was last recorded (`catchUp`).
private actor Notebook: LanguageModel {
    nonisolated let answer: String
    private var history: [ChatMessage] = []

    init(answer: String = "D'accord.") { self.answer = answer }

    /// What the history holds of what was said, in order.
    var recorded: [String] { history.filter { $0.role == .assistant }.map(\.content) }

    nonisolated func reply(to conversation: [ChatMessage]) -> AsyncThrowingStream<ModelOutput, Error> {
        AsyncThrowingStream { [answer] in
            $0.yield(.text(answer))
            $0.finish()
        }
    }

    func catchUp(with conversation: [ChatMessage]) async { history = conversation }
    func prefill(_ conversation: [ChatMessage]) async throws {}
    func tokenCount(_ conversation: [ChatMessage]) async throws -> Int { conversation.count * 10 }
}

/// `ToneVoice`, whose first utterance holds its sound until `open()`: an announcement whose sentence is on its way.
private final class GatedVoice: SpeechSynthesizer, @unchecked Sendable {
    let outputSampleRate = LinkAudio.voiceRate
    private let door = Door()
    private let lock = NSLock()
    private var utterances = 0

    func startUtterance(language: SpeechLanguage) async throws -> any SynthesisStream {
        let first = lock.withLock {
            utterances += 1
            return utterances == 1
        }
        return first ? GatedStream(door) : ToneStream()
    }

    func open() { door.open() }
}

/// A `ToneStream` whose text waits behind a door. It gives the tone its texts and its end under its lock, in the order
/// it took them: given outside it, a text let through while the pipeline ends the stream could reach the tone after
/// that end, which drops it.
private final class GatedStream: SynthesisStream, @unchecked Sendable {
    private let tone = ToneStream()
    private let lock = NSLock()
    /// What came while the door was shut; nil once it is open.
    private var held: [String]? = []
    private var finishing = false

    var audio: AsyncThrowingStream<VoiceAudio, Error> { tone.audio }

    init(_ door: Door) {
        Task { [weak self] in
            await door.wait()
            self?.release()
        }
    }

    func enqueue(_ text: String) {
        lock.withLock {
            if held == nil { tone.enqueue(text) }
            held?.append(text)
        }
    }

    func finish() {
        lock.withLock {
            finishing = true
            if held == nil { tone.finish() }
        }
    }

    func cancel() async { await tone.cancel() }

    private func release() {
        lock.withLock {
            held?.forEach(tone.enqueue)
            held = nil
            if finishing { tone.finish() }
        }
    }
}

/// A door that opens once: `wait()` returns once `open()` was called.
private final class Door: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func open() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { self.waiting = [] }
            return self.waiting
        }
        waiting.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let open = lock.withLock {
                if !isOpen { waiting.append(continuation) }
                return isOpen
            }
            if open { continuation.resume() }
        }
    }
}

/// An output that counts what goes through it.
struct CountingOutput: AudioOutput {
    let output: any AudioOutput
    let counted: @Sendable (Int) -> Void

    func play(_ samples: [Float], sampleRate: Double) async {
        counted(samples.count)
        await output.play(samples, sampleRate: sampleRate)
    }

    func waitUntilDone() async -> PlaybackEnd { await output.waitUntilDone() }
    func stopImmediately() async { await output.stopImmediately() }
    func abandon() async { await output.abandon() }
}

/// The Mac's speakers: they count what they are given, and play it in real time; held (`hold()`), what they play
/// lasts until `release()`, or until stopped.
final class CountingSpeaker: AudioOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var samples = 0
    private var busyUntil = ContinuousClock.now
    private var holding = false
    private var stopsCount = 0

    var played: Int { lock.withLock { samples } }
    var stops: Int { lock.withLock { stopsCount } }

    func hold() { lock.withLock { holding = true } }
    func release() { lock.withLock { holding = false } }

    func play(_ samples: [Float], sampleRate: Double) async {
        lock.withLock {
            self.samples += samples.count
            busyUntil = max(busyUntil, .now) + .seconds(Double(samples.count) / sampleRate)
        }
    }

    func waitUntilDone() async -> PlaybackEnd {
        while !Task.isCancelled, lock.withLock({ holding || busyUntil > .now }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return .confirmed
    }

    func stopImmediately() async {
        lock.withLock {
            stopsCount += 1
            holding = false
            busyUntil = .now
        }
    }
}
