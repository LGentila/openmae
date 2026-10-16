// voice-cli link-client — a fake iPhone, to measure the link without a telephone, reproducibly.
//
//   voice-cli link-client --pair "<link of the Mac's QR code>"      pairs once (Settings › iPhone on the Mac)
//   voice-cli link-client [--relay-only | --direct-only] [--out folder] phrase.wav…
//
// It takes the conversation as the iPhone app does, says each recording into the link in real time (Opus, 20 ms),
// then silence, and records the assistant's voice as it arrives, "playing" it in real time. Reported per turn: end
// of the recording → first frame of the voice on the "iPhone" (what an iPhone user hears, plus its jitter buffer),
// and the frames lost. The answers go to <out>/link-<n>.wav.

import Foundation
import OpenMaeLink
import VoiceCore

func runLinkClient() async throws {
    var link: String?
    var ways: Set<LinkPath> = [.direct, .relay]
    var out = URL(fileURLWithPath: "measurements")
    var files: [URL] = []
    var arguments = CommandLine.arguments.dropFirst(2).makeIterator()
    while let argument = arguments.next() {
        switch argument {
        case "--pair": link = arguments.next()
        case "--relay-only": ways = [.relay]
        case "--direct-only": ways = [.direct]
        case "--out": out = URL(fileURLWithPath: arguments.next() ?? "measurements")
        default: files.append(URL(fileURLWithPath: argument))
        }
    }
    let folder = AppIdentity.modelsDirectory.deletingLastPathComponent().appending(path: "Link")
    let identityStore = FileIdentityStore(url: folder.appending(path: "cli-iphone.key"))
    let macFile = folder.appending(path: "cli-iphone-mac.json")

    if let link {
        guard let pairingLink = PairingLink(string: link) else { throw CLIError("not a pairing link: \(link)") }
        let mac = try await PhonePairing.pair(link: pairingLink, identity: try identityStore.loadOrCreate(),
                                              phone: HandshakePayload.Phone(name: "voice-cli", model: "cli"),
                                              ways: ways)
        try JSONEncoder().encode(mac).write(to: macFile)
        print("paired with \(mac.name)")
        return
    }
    guard let data = try? Data(contentsOf: macFile), let mac = try? JSONDecoder().decode(PairedMac.self, from: data),
          let identity = try identityStore.load()
    else { throw CLIError("pair first: voice-cli link-client --pair \"<link>\"") }
    guard !files.isEmpty else { throw CLIError("no recording to say") }
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    let phone = PhoneLink(mac: mac, identity: identity, ways: ways)
    // As the app does: the Mac's new relay is kept for the next runs.
    Task { for await mac in phone.macChanges { try? JSONEncoder().encode(mac).write(to: macFile) } }
    let clock = ContinuousClock()
    let connectStart = clock.now
    await phone.connect()
    var path: LinkPath?
    for await status in phone.status {
        if case .connected(let connected) = status {
            path = connected
            break
        }
        if status == .unreachable || status == .forgotten { throw CLIError("the Mac cannot be reached (\(status))") }
    }
    print("connected to \(mac.name) (\(path?.rawValue ?? "?")) in \(fmt(ms(clock.now - connectStart)))")

    let states = StateWatch()
    Task { for await event in phone.events { if case .state(let state) = event { await states.set(state) } } }
    let speaker = FakeSpeaker(phone: phone)
    Task { for await input in phone.voice { await speaker.received(input) } }
    let microphone = FakeMicrophone(phone: phone)
    Task { await microphone.run() }
    // Hands-free, whatever the Mac's own setting: the Mac hears the end of each recording.
    var settings = AssistantSettings()
    settings.pushToTalk = false
    phone.send(.updateSettings(settings))
    await phone.setAudio(true)
    try await Task.sleep(for: .seconds(1))

    var latencies: [Double] = []
    for (n, file) in files.enumerated() {
        let samples = try WAV.read16kMono(file)
        await speaker.reset()
        let said = await microphone.say(samples)
        // The answer: from the first frame to the end of its "playing", or 30 s.
        let deadline = clock.now + .seconds(30)
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            if await speaker.isDone(), await states.state == .listening { break }
        }
        let report = await speaker.report(after: said)
        if let latency = report.latencyMs { latencies.append(latency) }
        let name = "link-\(n + 1).wav"
        try WAV.write(report.samples, sampleRate: LinkAudio.voiceRate, to: out.appending(path: name))
        print("\(file.lastPathComponent): first voice frame \(fmt(report.latencyMs)) after the end of speech · "
              + "\(report.frames) frames, \(report.concealed) concealed · \(name)")
    }
    print("median: \(fmt(median(latencies))) (\(path?.rawValue ?? "?"), \(latencies.count) answers)")
    await phone.setAudio(false)
    await phone.disconnect()
}

private func ms(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

private actor StateWatch {
    private(set) var state = PipelineState.listening
    func set(_ state: PipelineState) { self.state = state }
}

/// The iPhone's microphone: a recording when there is one to say, silence otherwise, 20 ms at a time in real time.
private actor FakeMicrophone {
    private let phone: PhoneLink
    private let encoder = try? OpusEncoder(sampleRate: LinkAudio.microphoneRate, bitRate: LinkAudio.microphoneBitRate)
    private var queue: [Float] = []
    private var finished: [CheckedContinuation<ContinuousClock.Instant, Never>] = []
    private let stream = StreamNumber.now
    private var sequence: UInt32 = 0

    init(phone: PhoneLink) {
        self.phone = phone
    }

    /// Says `samples`; returns when the last of them was sent.
    func say(_ samples: [Float]) async -> ContinuousClock.Instant {
        queue += samples
        return await withCheckedContinuation { finished.append($0) }
    }

    func run() async {
        let clock = ContinuousClock()
        var next = clock.now
        let frame = Int(LinkAudio.microphoneRate * 0.02)
        while !Task.isCancelled {
            let chunk: [Float]
            if queue.isEmpty {
                chunk = [Float](repeating: 0, count: frame)
            } else {
                chunk = Array(queue.prefix(frame))
                queue.removeFirst(chunk.count)
                if queue.isEmpty {
                    let now = clock.now
                    finished.forEach { $0.resume(returning: now) }
                    finished = []
                }
            }
            for payload in encoder?.encode(chunk) ?? [] {
                phone.sendMicrophone(AudioPacket(stream: stream, sequence: sequence, payload: payload))
                sequence &+= 1
            }
            next += .milliseconds(20)
            try? await clock.sleep(until: next)
        }
    }
}

/// The iPhone's speaker: the jitter buffer and the decoder of the app, "played" in real time without sound.
private actor FakeSpeaker {
    private let phone: PhoneLink
    private let decoder = try? OpusDecoder(sampleRate: LinkAudio.voiceRate)
    private let clock = ContinuousClock()
    private var buffer = VoiceJitterBuffer()
    private var samples: [Float] = []
    private var firstFrame: ContinuousClock.Instant?
    private var playhead: ContinuousClock.Instant?
    private var frames = 0
    private var concealed = 0
    private var stream: UInt32?
    private var reported: UInt32?

    init(phone: PhoneLink) {
        self.phone = phone
    }

    func reset() {
        samples = []
        firstFrame = nil
        frames = 0
        concealed = 0
    }

    /// Called regularly, as the app's player calls back: conceals what never came once the "player" runs dry.
    func isDone() -> Bool {
        if scheduled <= 1 {
            play(buffer.playerNeedsMore(scheduled: scheduled, now: Date().timeIntervalSinceReferenceDate))
            scheduleFinish()
        }
        return buffer.isComplete && (playhead.map { $0 <= clock.now } ?? true) && firstFrame != nil
    }

    private var scheduled: Int {
        guard let playhead else { return 0 }
        return max(0, Int(ms(playhead - clock.now) / 20))
    }

    func received(_ input: VoiceInput) {
        let seconds = Date().timeIntervalSinceReferenceDate
        switch input {
        case .packet(let packet):
            if packet.stream != stream {
                stream = packet.stream
                decoder?.reset()
            }
            play(buffer.insert(packet, scheduled: scheduled, now: seconds))
        case .end(let stream, let frames):
            play(buffer.end(stream: stream, frames: frames, scheduled: scheduled, now: seconds))
            scheduleFinish()
        case .stop(let stream):
            buffer.stop(stream: stream)
            playhead = nil
            phone.finished(stream: stream)
        case .released:
            break
        }
    }

    private func play(_ outputs: [VoiceJitterBuffer.Output]) {
        for output in outputs {
            if firstFrame == nil { firstFrame = clock.now }
            let decoded: [Float]
            switch output {
            case .packet(let payload): decoded = decoder?.decode(payload) ?? []
            case .conceal:
                decoded = decoder?.decode(nil) ?? []
                concealed += 1
            }
            frames += 1
            samples += decoded
            playhead = max(playhead ?? clock.now, clock.now) + .milliseconds(20)
        }
    }

    /// Tells the Mac the stream was heard once its last frame would have played.
    private func scheduleFinish() {
        guard let stream, buffer.isComplete, reported != stream else { return }
        reported = stream
        let end = playhead ?? clock.now
        let phone = phone
        Task {
            try? await ContinuousClock().sleep(until: end)
            phone.finished(stream: stream)
        }
    }

    func report(after spoken: ContinuousClock.Instant) -> (latencyMs: Double?, frames: Int, concealed: Int, samples: [Float]) {
        (firstFrame.map { ms($0 - spoken) }, frames, concealed, samples)
    }
}
