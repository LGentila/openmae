// voice-cli announce-drop — an announcement that a home station was saying when it dropped (the iPad unplugged 0.6 s
// into its chime), said again at once on the Mac, as the app does; then the pace of every utterance of the voice, and
// the gaps in the Mac's sound after its chime.
//
//   voice-cli announce-drop [--repeats 5] [--mute-first | --mute-station] [options]
//
// --mute-first: the Mac's first utterance of the announcement is taken for near-silence (its audio is replaced with
// silence on its way to the pipeline), so that the voice starts it again after 1.2 s of its audio (`VoiceRestart`),
// as it did in the app when the gap was seen. The voice computes exactly what it would otherwise.
// --mute-station: the same for the station's first utterance of it, which then starts again just after the drop.
//
// Each utterance is reported with its frames: how long its first frame took after its first text, then the time per
// frame (all the frames after the first, and the near-silent ones before its first audible frame), and the other
// utterances that ran at the same time.

import Foundation
import VoiceCore
import VoiceEngineApple

/// A home station's speaker that drops: it plays in real time until `drop()`, as `RemoteVoiceOutput` does; then
/// nothing it was given will ever be said played (`RemoteVoiceOutput.detach`), and what still comes reaches nobody.
actor DroppingStation: AudioOutput {
    private let clock = ContinuousClock()
    private var playhead: ContinuousClock.Instant?
    private var dropped = false
    /// When its first sound came (the chime).
    private(set) var firstSound: ContinuousClock.Instant?

    func play(_ samples: [Float], sampleRate: Double) {
        if firstSound == nil { firstSound = clock.now }
        guard !dropped else { return }
        let start = max(clock.now, playhead ?? clock.now)
        playhead = start + .seconds(Double(samples.count) / sampleRate)
    }

    @discardableResult
    func waitUntilDone() async -> PlaybackEnd {
        while !dropped, let end = playhead, end > clock.now {
            try? await clock.sleep(until: min(end, clock.now + .milliseconds(20)))
        }
        return dropped ? .unconfirmed : .confirmed
    }

    func stopImmediately() { playhead = nil }

    func drop() {
        dropped = true
        playhead = nil
    }

    func reset() {
        dropped = false
        playhead = nil
        firstSound = nil
    }
}

/// One utterance of the voice, as the pipeline received it: when it started, when its first text came, each frame,
/// and how it ended.
final class MeasuredUtterance: @unchecked Sendable {
    struct Frame {
        var at: ContinuousClock.Instant
        var audible: Bool
    }

    let started: ContinuousClock.Instant
    let muted: Bool
    /// Started while the one before was being stopped: the same turn's voice, started again (`VoiceRestart`).
    let restart: Bool
    private let lock = NSLock()
    // Guarded by `lock`.
    private var _firstText: ContinuousClock.Instant?
    private var _frames: [Frame] = []
    private var _cancelled: ContinuousClock.Instant?
    private var _ended: ContinuousClock.Instant?

    init(started: ContinuousClock.Instant, muted: Bool, restart: Bool) {
        self.started = started
        self.muted = muted
        self.restart = restart
    }

    var firstText: ContinuousClock.Instant? { lock.withLock { _firstText } }
    var frames: [Frame] { lock.withLock { _frames } }
    var cancelled: Bool { lock.withLock { _cancelled != nil } }
    /// When it stopped producing frames: stopped, or over.
    var ended: ContinuousClock.Instant? { lock.withLock { _cancelled ?? _ended } }

    func texted() { lock.withLock { if _firstText == nil { _firstText = .now } } }
    func frame(audible: Bool) { lock.withLock { _frames.append(Frame(at: .now, audible: audible)) } }
    func cancel() { lock.withLock { if _cancelled == nil { _cancelled = .now } } }
    func end() { lock.withLock { if _ended == nil { _ended = .now } } }

    /// Milliseconds per frame after the first one: over all of them, and over the near-silent ones before the first
    /// audible frame (nil with fewer than two).
    var pace: (all: Double?, opening: Double?) {
        let frames = self.frames
        func perFrame(_ count: Int) -> Double? {
            guard count >= 2 else { return nil }
            return (frames[count - 1].at - frames[0].at).seconds * 1000 / Double(count - 1)
        }
        let opening = frames.firstIndex(where: \.audible).map { $0 + 1 } ?? frames.count
        return (perFrame(frames.count), perFrame(opening))
    }

    /// The slowest interval between two frames, in milliseconds.
    var slowest: Double? {
        let frames = self.frames
        guard frames.count >= 2 else { return nil }
        return frames.indices.dropFirst().map { (frames[$0].at - frames[$0 - 1].at).seconds * 1000 }.max()
    }

    /// Whether it ran at the same time as `other`.
    func overlaps(_ other: MeasuredUtterance) -> Bool {
        guard self !== other else { return false }
        let end = ended ?? .now
        let otherEnd = other.ended ?? .now
        return started < otherEnd && other.started < end
    }
}

/// The voice, with the time each frame of each utterance came out. `muteNextTurn`: the first utterance of the next
/// turn's voice goes to the pipeline as silence (the voice still computes it as usual), so that the pipeline starts it
/// again; a turn's voice starts again (`VoiceRestart`) right after its utterance was stopped, a new turn's voice after
/// the one before ended.
final class MeasuringSynthesizer: SpeechSynthesizer, KeepsWarm, @unchecked Sendable {
    let voice: PocketSpeechSynthesizer
    private let lock = NSLock()
    // Guarded by `lock`.
    private var utterances: [MeasuredUtterance] = []
    private var last: MeasuredUtterance?
    private var muteNext = false

    init(_ voice: PocketSpeechSynthesizer) { self.voice = voice }

    var outputSampleRate: Double { voice.outputSampleRate }

    func startUtterance(language: SpeechLanguage) async throws -> any SynthesisStream {
        let started = ContinuousClock.now
        let stream = try await voice.startUtterance(language: language)
        let utterance: MeasuredUtterance = lock.withLock {
            let restart = last?.cancelled ?? false
            let mute = muteNext && !restart
            if mute { muteNext = false }
            let utterance = MeasuredUtterance(started: started, muted: mute, restart: restart)
            utterances.append(utterance)
            last = utterance
            return utterance
        }
        return MeasuredStream(stream, utterance: utterance)
    }

    func keepWarm() async { await voice.keepWarm() }

    func muteNextTurn(_ mute: Bool = true) { lock.withLock { muteNext = mute } }

    /// The utterances started since the last call, in order.
    func take() -> [MeasuredUtterance] {
        lock.withLock {
            defer { utterances = [] }
            return utterances
        }
    }
}

struct MeasuredStream: SynthesisStream {
    let audio: AsyncThrowingStream<VoiceAudio, Error>
    private let voice: any SynthesisStream
    private let utterance: MeasuredUtterance

    init(_ voice: any SynthesisStream, utterance: MeasuredUtterance) {
        self.voice = voice
        self.utterance = utterance
        let threshold = PipelineConfig().leadingSilenceThresholdDB ?? -45
        audio = AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in voice.audio {
                        let meanSquare = chunk.samples.reduce(0) { $0 + $1 * $1 } / Float(max(chunk.samples.count, 1))
                        utterance.frame(audible: 10 * log10(max(meanSquare, 1e-12)) >= threshold)
                        continuation.yield(utterance.muted
                            ? VoiceAudio([Float](repeating: 0, count: chunk.samples.count), text: chunk.text) : chunk)
                    }
                    utterance.end()
                    continuation.finish()
                } catch {
                    utterance.end()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func enqueue(_ text: String) {
        utterance.texted()
        voice.enqueue(text)
    }

    func finish() { voice.finish() }

    func cancel() async {
        utterance.cancel()
        await voice.cancel()
    }
}

func runAnnounceDrop(_ o: Options, _ e: Engine, voice: MeasuringSynthesizer) async throws {
    let mic = SimulatedMicrophone(pipeline: e.pipeline)
    let station = DroppingStation()
    let text = ActionPhrases.timerFinished(seconds: 15, label: nil, .french)
    let note = "(Le minuteur 1 de 15 secondes vient de sonner.)"
    var fresh: [Double] = []
    var restarted: [Double] = []
    var restartedOpenings: [Double] = []
    var afterChime: [Double] = []
    var laterGaps: [Double] = []
    let tries = o.repeats ?? 5
    for attempt in 1...tries {
        print("■ try \(attempt)")
        await mic.silence(3)  // what the model computes once an announcement is recorded is over
        await station.reset()
        _ = voice.take()
        _ = await e.speaker.takeGaps()
        await e.pipeline.announceThrough(station)
        let before = await e.log.completedTurns
        voice.muteNextTurn(o.muteStation)
        await e.pipeline.announce(text, note: note, language: .french)
        await mic.silence(until: { await station.firstSound != nil }, timeout: 10)
        guard let chime = await station.firstSound else {
            print("  the station never played the chime")
            continue
        }
        // 0.6 s into the chime, the iPad is unplugged: `LinkHost` lets its speaker go (`detach`) and announcements go
        // where the conversation is (`announceThrough(nil)`).
        await mic.silence(until: { ContinuousClock.now - chime >= .milliseconds(600) }, timeout: 2)
        if o.muteFirst { voice.muteNextTurn() }
        await station.drop()
        await e.pipeline.announceThrough(nil)
        await waitForAnswer(e, mic: mic, after: before, timeout: 30)
        await mic.silence(0.3)

        let utterances = voice.take()
        let gaps = await e.speaker.takeGaps()
        var turn = 0
        var restarts = 0
        for (index, u) in utterances.enumerated() {
            if index > 0 {
                if u.restart { restarts += 1 } else { (turn, restarts) = (turn + 1, 0) }
            }
            let role = (turn == 0 ? "station" : "Mac") + (restarts > 0 ? ", started again (\(restarts))" : "")
            let others = utterances.filter { $0.overlaps(u) }.count
            let firstFrame = u.firstText.flatMap { text in u.frames.first.map { ($0.at - text).seconds * 1000 } }
            let audibleAt = u.frames.firstIndex(where: \.audible).map { "audible at frame \($0 + 1)" }
                ?? "near-silent throughout"
            print("  \(role): \(u.frames.count) frames, \(audibleAt)\(u.muted ? " (muted)" : "")"
                  + "\(u.cancelled ? ", stopped" : ""); first frame \(fmt(firstFrame)) after its text,"
                  + " then \(fmt(u.pace.all)) per frame (opening \(fmt(u.pace.opening)), slowest \(fmt(u.slowest)))"
                  + (others > 0 ? "; \(others) other utterance(s) meanwhile" : ""))
            guard let pace = u.pace.all else { continue }
            if u.restart {
                restarted.append(pace)
                if let opening = u.pace.opening { restartedOpenings.append(opening) }
            } else {
                fresh.append(pace)
            }
        }
        if turn == 0 { print("  Mac: no voice computed (said again from the station's recording)") }
        if let first = gaps.first { afterChime.append(first * 1000) } else { afterChime.append(0) }
        laterGaps += gaps.dropFirst().map { $0 * 1000 }
        print("  Mac's sound: gap after the chime \(fmt(gaps.first.map { $0 * 1000 } ?? 0))"
              + (gaps.count > 1 ? ", then \(gaps.dropFirst().map { fmt($0 * 1000) }.joined(separator: ", "))" : ""))
    }
    print("\n=== Summary: \(tries) tries ===")
    print("frames of fresh utterances: median \(fmt(median(fresh))) per frame (\(fresh.count) utterances)")
    print("frames of utterances started again: median \(fmt(median(restarted))) per frame, max"
          + " \(fmt(restarted.max())) (\(restarted.count) utterances; opening: median \(fmt(median(restartedOpenings))))")
    if let r = median(restarted), let f = median(fresh) {
        print(String(format: "started again / fresh: %.2f", r / f))
    }
    print("gap after the chime: median \(fmt(median(afterChime))), max \(fmt(afterChime.max()))"
          + "; later gaps: \(laterGaps.count), max \(fmt(laterGaps.max()))")
}
