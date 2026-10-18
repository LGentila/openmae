import Foundation
import VoiceCore

/// The Mac's side of the iPhone's speaker: the assistant's voice, encoded and sent as it is produced (usually ahead
/// of real time; the iPhone's jitter buffer plays it at its pace). One voice stream per utterance.
///
/// - `play` encodes and sends;
/// - `waitUntilDone` sends the stream's end and returns when the iPhone says it has played everything (or once it
///   should have, if the iPhone went silent), telling which;
/// - `stopImmediately` tells the iPhone to stop at once and drop the rest.
public final class RemoteVoiceOutput: AudioOutput, @unchecked Sendable {
    private let lock = NSLock()
    private let encoder: OpusEncoder?
    private var session: LinkSession?
    /// Numbered from the clock: always above the streams of an earlier conversation, which the iPhone's buffer
    /// still remembers.
    private var nextStream = StreamNumber.now
    private var stream: UInt32?
    /// The stream being sent began on a connection that was replaced since (`bind`): what went through the one that
    /// dropped is lost, so the iPhone cannot have heard it whole, even if it says it played it (it fills in the gaps).
    private var streamCut = false
    private var sequence: UInt32 = 0
    private var streamStart = ContinuousClock.now
    private var waiters: [UInt32: [CheckedContinuation<PlaybackEnd, Never>]] = [:]
    /// How the last streams ended, once known: the iPhone said it played them, they were stopped, or nobody will say.
    private var outcomes: [UInt32: PlaybackEnd] = [:]

    public init(session: LinkSession) {
        self.session = session
        encoder = try? OpusEncoder(sampleRate: LinkAudio.voiceRate, bitRate: LinkAudio.voiceBitRate)
        if encoder == nil { DebugLog.log("link: no Opus encoder, the iPhone will not hear the voice") }
    }

    /// The iPhone came back on another connection (a change of network): the voice follows it. A stream being sent
    /// goes on through the new one, but cannot be heard whole: its `waitUntilDone` says so.
    public func bind(_ session: LinkSession?) {
        lock.withLock {
            if stream != nil, session !== self.session { streamCut = true }
            self.session = session
        }
    }

    public func play(_ samples: [Float], sampleRate: Double) async {
        guard let encoder, !samples.isEmpty else { return }
        if sampleRate != LinkAudio.voiceRate { DebugLog.log("link: voice at \(sampleRate) Hz, expected 24 kHz") }
        lock.withLock {
            if stream == nil {
                stream = nextStream
                nextStream += 1
                sequence = 0
                streamStart = .now
                streamCut = false
                encoder.reset()
            }
            for packet in encoder.encode(samples) { sendFrame(packet) }
        }
    }

    @discardableResult
    public func waitUntilDone() async -> PlaybackEnd {
        let pending: (stream: UInt32, deadline: ContinuousClock.Instant, cut: Bool)? = lock.withLock {
            guard let stream else { return nil }
            encoder?.flush().forEach(sendFrame)
            session?.send(.audio(.end(stream: stream, frames: sequence)))
            self.stream = nil
            // When the iPhone should be done with it: real time from the stream's start, plus room for its buffer
            // and the network.
            let duration = Duration.milliseconds(Int(sequence) * 20)
            return (stream, max(streamStart + duration, .now) + .seconds(2.5), streamCut)
        }
        guard let pending else { return .confirmed }
        let end = await withTaskGroup(of: PlaybackEnd?.self, returning: PlaybackEnd.self) { tasks in
            tasks.addTask { await self.outcome(of: pending.stream) }
            tasks.addTask {
                // The iPhone went silent (or the wait was cancelled): no word will come, do not wait forever.
                try? await Task.sleep(until: pending.deadline)
                self.settle(pending.stream, .unconfirmed)
                return nil
            }
            var end = PlaybackEnd.unconfirmed
            while let result = await tasks.next() {
                guard let result else { continue }
                end = result
                break
            }
            tasks.cancelAll()
            return end
        }
        return pending.cut ? .unconfirmed : end
    }

    public func stopImmediately() async {
        let stopped: UInt32? = lock.withLock {
            guard let stream else { return nil }
            session?.send(.audio(.stopPlayback(stream: stream)))
            encoder?.reset()
            self.stream = nil
            return stream
        }
        if let stopped { settle(stopped, .confirmed) }  // stopped as asked: nothing more to hear of it
    }

    /// The iPhone played everything of `stream`, or stopped it.
    public func markFinished(_ stream: UInt32) {
        settle(stream, .confirmed)
    }

    /// The link is gone for good: nobody waits for the iPhone any longer, and what it was playing it will not say it
    /// played.
    public func detach() {
        let waiting: [CheckedContinuation<PlaybackEnd, Never>] = lock.withLock {
            session = nil
            stream = nil
            defer { waiters = [:] }
            return waiters.values.flatMap { $0 }
        }
        waiting.forEach { $0.resume(returning: .unconfirmed) }
    }

    /// How `stream` ended: whoever waits for it is told. The first word on it stays.
    private func settle(_ stream: UInt32, _ end: PlaybackEnd) {
        let (waiting, outcome): ([CheckedContinuation<PlaybackEnd, Never>], PlaybackEnd) = lock.withLock {
            let outcome = outcomes[stream] ?? end
            outcomes[stream] = outcome
            if outcomes.count > 64, let oldest = outcomes.keys.min() { outcomes.removeValue(forKey: oldest) }
            return (waiters.removeValue(forKey: stream) ?? [], outcome)
        }
        waiting.forEach { $0.resume(returning: outcome) }
    }

    /// Returns once it is known how `stream` ended.
    private func outcome(of stream: UInt32) async -> PlaybackEnd {
        await withCheckedContinuation { continuation in
            let known: PlaybackEnd? = lock.withLock {
                if let outcome = outcomes[stream] { return outcome }
                if session == nil { return .unconfirmed }  // let go: nobody will say
                waiters[stream, default: []].append(continuation)
                return nil
            }
            if let known { continuation.resume(returning: known) }
        }
    }

    /// Called with the lock held.
    private func sendFrame(_ payload: Data) {
        guard let stream else { return }
        session?.send(AudioPacket(stream: stream, sequence: sequence, payload: payload))
        sequence += 1
    }
}

/// The Mac's side of the iPhone's microphone: frames put back in order, decoded, and handed to the engine at 16 kHz.
public final class RemoteMicrophone: @unchecked Sendable {
    public let samples: AsyncStream<[Float]>
    private let sink: AsyncStream<[Float]>.Continuation
    private let lock = NSLock()
    private let decoder: OpusDecoder?
    private var reorder = MicrophoneReorder()
    private var lastFrame = ContinuousClock.now

    public init() {
        (samples, sink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(250))
        decoder = try? OpusDecoder(sampleRate: LinkAudio.microphoneRate)
    }

    public func receive(_ packet: AudioPacket) {
        guard let decoder else { return }
        let chunks: [[Float]] = lock.withLock {
            lastFrame = .now
            return reorder.insert(packet).compactMap { output in
                switch output {
                case .newStream:
                    decoder.reset()
                    return nil
                case .packet(let payload): return decoder.decode(payload)
                case .conceal: return decoder.decode(nil)
                }
            }
        }
        chunks.forEach { sink.yield($0) }
    }

    /// The microphone went quiet (muted, or the connection dropped): a moment of silence, so that a sentence in
    /// progress ends as if the user had stopped talking.
    public func fillSilence(seconds: Double = 0.8) {
        let chunk = [Float](repeating: 0, count: Int(LinkAudio.microphoneRate * 0.02))
        for _ in 0..<Int(seconds / 0.02) { sink.yield(chunk) }
    }

    public var secondsSinceLastFrame: Double {
        let elapsed = lock.withLock { ContinuousClock.now - lastFrame }
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    public func finish() {
        fillSilence()
        sink.finish()
    }
}
