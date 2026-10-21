import AVFoundation
import Foundation
import VoiceCore

/// Stands in for the speakers: "plays" audio in real time (without sound) and records it, so the
/// pipeline behaves exactly as in the app — the assistant is "speaking" for as long as its audio
/// lasts, and can be interrupted.
actor SimulatedSpeaker: AudioOutput {
    private let clock = ContinuousClock()
    private var playhead: ContinuousClock.Instant?
    private(set) var recorded: [Float] = []
    private(set) var sampleRate = 24_000.0
    private(set) var lastStop: ContinuousClock.Instant?
    /// Whether it keeps what it plays, and when (`takePlays()`).
    private let logsPlays: Bool
    private var plays: [Played] = []

    /// Audio given to the speaker, and when it starts to be heard.
    struct Played {
        var samples: [Float]
        var start: ContinuousClock.Instant
    }

    init(logsPlays: Bool = false) { self.logsPlays = logsPlays }

    func play(_ samples: [Float], sampleRate: Double) {
        self.sampleRate = sampleRate
        recorded += samples
        let now = clock.now
        let start = max(now, playhead ?? now)
        playhead = start + .seconds(Double(samples.count) / sampleRate)
        if logsPlays { plays.append(Played(samples: samples, start: start)) }
    }

    @discardableResult
    func waitUntilDone() async -> PlaybackEnd {
        while let end = playhead, end > clock.now {
            try? await clock.sleep(until: min(end, clock.now + .milliseconds(20)))
        }
        return .confirmed
    }

    func stopImmediately() {
        playhead = nil
        lastStop = clock.now
    }

    var isPlaying: Bool { (playhead ?? clock.now) > clock.now }

    func takeRecording() -> [Float] {
        defer { recorded = [] }
        return recorded
    }

    /// What it played since the last call, in order (with `logsPlays`).
    func takePlays() -> [Played] {
        defer { plays = [] }
        return plays
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// Stands in for the microphone: sends audio to the pipeline at the pace of real speech.
struct SimulatedMicrophone {
    let pipeline: VoicePipeline
    private let clock = ContinuousClock()
    private let chunk = 512  // 32 ms

    /// Sends `samples` in real time (32 ms chunks), then returns.
    func say(_ samples: [Float]) async {
        var next = clock.now
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            await pipeline.push(Array(samples[offset..<end]))
            offset = end
            next += .milliseconds(32)
            try? await clock.sleep(until: next)
        }
    }

    /// Sends silence (a quiet room) for `seconds`.
    func silence(_ seconds: Double) async {
        await say([Float](repeating: 0, count: Int(seconds * EngineAudio.inputSampleRate)))
    }

    /// Sends silence until `condition` is true or `timeout` elapses.
    func silence(until condition: @Sendable () async -> Bool, timeout: Double) async {
        let deadline = clock.now + .seconds(timeout)
        while clock.now < deadline, !(await condition()) { await silence(0.096) }
    }
}

enum WAV {
    /// Reads a WAV/AIFF file as 16 kHz mono Float32 (converting if needed).
    static func read16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(standardFormatWithSampleRate: EngineAudio.inputSampleRate, channels: 1)!
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        if file.processingFormat.sampleRate == target.sampleRate, file.processingFormat.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: input.floatChannelData![0], count: Int(input.frameLength)))
        }
        let converter = AVAudioConverter(from: file.processingFormat, to: target)!
        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let output = AVAudioPCMBuffer(pcmFormat: target,
                                      frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024)!
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    static func write(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }
}
