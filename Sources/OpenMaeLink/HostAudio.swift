import Foundation
import VoiceCore

/// The Mac's side of the iPhone's speaker: the assistant's voice, encoded and sent as it is produced (usually ahead
/// of real time; the iPhone's jitter buffer plays it at its pace). One voice stream per utterance.
///
/// - `play` encodes and sends;
/// - `waitUntilDone` sends the stream's end and returns when the iPhone says it has played everything (or once it
///   should have, if the iPhone went silent);
/// - `stopImmediately` tells the iPhone to stop at once and drop the rest.
public final class RemoteVoiceOutput: AudioOutput, @unchecked Sendable {
    private let lock = NSLock()
    private let encoder: OpusEncoder?
    private var session: LinkSession?
    /// Numbered from the clock: always above the streams of an earlier conversation, which the iPhone's buffer
    /// still remembers.
    private var nextStream = StreamNumber.now
    private var stream: UInt32?
    private var sequence: UInt32 = 0
    private var streamStart = ContinuousClock.now
    private var waiters: [UInt32: [CheckedContinuation<Void, Never>]] = [:]
    private var finished: Set<UInt32> = []

    public init(session: LinkSession) {
        self.session = session
        encoder = try? OpusEncoder(sampleRate: LinkAudio.voiceRate, bitRate: LinkAudio.voiceBitRate)
        if encoder == nil { DebugLog.log("link: no Opus encoder, the iPhone will not hear the voice") }
    }

    /// The iPhone came back on another connection (a change of network): the voice follows it.
    public func bind(_ session: LinkSession?) {
        lock.withLock { self.session = session }
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
                encoder.reset()
            }
            for packet in encoder.encode(samples) { sendFrame(packet) }
        }
    }

    public func waitUntilDone() async {
        let pending: (stream: UInt32, deadline: ContinuousClock.Instant)? = lock.withLock {
            guard let stream else { return nil }
            encoder?.flush().forEach(sendFrame)
            session?.send(.audio(.end(stream: stream, frames: sequence)))
            self.stream = nil
            // When the iPhone should be done with it: real time from the stream's start, plus room for its buffer
            // and the network.
            let duration = Duration.milliseconds(Int(sequence) * 20)
            return (stream, max(streamStart + duration, .now) + .seconds(2.5))
        }
        guard let pending else { return }
        await withTaskGroup(of: Void.self) { tasks in
            tasks.addTask { await self.finishedSignal(pending.stream) }
            tasks.addTask {
                try? await Task.sleep(until: pending.deadline)
                self.markFinished(pending.stream)  // the iPhone went silent: do not wait forever
            }
            await tasks.next()
            tasks.cancelAll()
        }
    }

    public func stopImmediately() async {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard let stream else { return [] }
            session?.send(.audio(.stopPlayback(stream: stream)))
            encoder?.reset()
            self.stream = nil
            finished.insert(stream)
            return waiters.removeValue(forKey: stream) ?? []
        }
        waiting.forEach { $0.resume() }
    }

    /// The iPhone played everything of `stream`, or stopped it.
    public func markFinished(_ stream: UInt32) {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            finished.insert(stream)
            if finished.count > 64, let oldest = finished.min() { finished.remove(oldest) }
            return waiters.removeValue(forKey: stream) ?? []
        }
        waiting.forEach { $0.resume() }
    }

    /// The link is gone for good: nobody waits for the iPhone any longer.
    public func detach() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            session = nil
            stream = nil
            defer { waiters = [:] }
            return waiters.values.flatMap { $0 }
        }
        waiting.forEach { $0.resume() }
    }

    private func finishedSignal(_ stream: UInt32) async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock {
                if finished.contains(stream) || session == nil { return true }
                waiters[stream, default: []].append(continuation)
                return false
            }
            if done { continuation.resume() }
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
