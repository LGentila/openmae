import Foundation

/// Several utterances of the same answer at once, each with its own random draws: the first one to make an audible
/// sound says the answer, the others stop.
///
/// Pocket TTS opens every sentence with a near-silent breath of random length: none in a quarter of the cases, 0.4 to
/// 1 s of audio in half of them, up to 4.4 s, and sometimes the whole sentence (measured with `voice-cli voice-onset`
/// on the reference Mac). The pipeline skips that near-silence, but has to wait while the voice produces it: the
/// answer's first sound came 0.2 to 6 s after its first piece of text. With two voices racing, it comes when the
/// sooner of the two breaths ends.
///
/// Before one is audible, the near-silence of all of them is dropped (the pipeline skips it anyway); then the winner's
/// audio goes through as it comes, near-silence included. The others are stopped and let go at once.
public final class VoiceRace: SynthesisStream, @unchecked Sendable {
    public let audio: AsyncThrowingStream<VoiceAudio, Error>
    private let count: Int
    private let output: AsyncThrowingStream<VoiceAudio, Error>.Continuation
    private let audible: @Sendable ([Float]) -> Bool
    private let lock = NSLock()
    // Guarded by `lock`.
    /// The voices still in the race, then the winner only.
    private var runners: [(any SynthesisStream)?]
    private var winner: Int?
    private var ended = 0
    private var failures = 0
    private var readers: [Task<Void, Never>] = []

    /// `audible`: whether a chunk of audio can be heard (the pipeline's `leadingSilenceThresholdDB`).
    public init(_ runners: [any SynthesisStream], audible: @escaping @Sendable ([Float]) -> Bool) {
        self.runners = runners
        count = runners.count
        self.audible = audible
        (audio, output) = AsyncThrowingStream.makeStream(of: VoiceAudio.self)
        let readers = runners.enumerated().map { index, runner in
            Task {
                do {
                    for try await chunk in runner.audio {
                        if !self.take(chunk, from: index) { break }
                    }
                    self.end(index, failed: nil)
                } catch {
                    self.end(index, failed: error)
                }
            }
        }
        lock.withLock { self.readers = readers }
        output.onTermination = { [weak self] _ in self?.stopReading() }
    }

    /// The runner whose voice is heard, once one is audible.
    public var heard: Int? { lock.withLock { winner } }

    public func enqueue(_ text: String) { speaking.forEach { $0.enqueue(text) } }
    public func finish() { speaking.forEach { $0.finish() } }

    public func cancel() async {
        for runner in speaking { await runner.cancel() }
        output.finish()
    }

    private var speaking: [any SynthesisStream] { lock.withLock { runners.compactMap { $0 } } }

    /// Whether `chunk`'s runner is still in the race, or speaks. The first audible chunk decides: the others stop.
    private func take(_ chunk: VoiceAudio, from index: Int) -> Bool {
        let (keep, losers): (Bool, [any SynthesisStream]) = lock.withLock {
            if winner == nil {
                guard audible(chunk.samples) else { return (true, []) }
                winner = index
                DebugLog.log("voice: voice \(index + 1) of \(count) audible first")
                output.yield(chunk)
                let losers = runners.indices.filter { $0 != index }.compactMap { runners[$0] }
                runners = runners.indices.map { $0 == index ? runners[$0] : nil }
                return (true, losers)
            }
            guard winner == index else { return (false, []) }
            output.yield(chunk)
            return (true, [])
        }
        if !losers.isEmpty { Task { for loser in losers { await loser.cancel() } } }
        return keep
    }

    private func end(_ index: Int, failed error: Error?) {
        // Decided under the lock, done outside it: finishing calls `onTermination`, which takes the lock.
        let (over, failure): (Bool, Error?) = lock.withLock {
            ended += 1
            if error != nil { failures += 1 }
            if winner == index { return (true, error) }
            // None was audible: near-silence throughout (or every voice failed).
            if winner == nil, ended == count { return (true, failures == count ? error : nil) }
            return (false, nil)
        }
        guard over else { return }
        if let failure { output.finish(throwing: failure) } else { output.finish() }
    }

    private func stopReading() {
        lock.withLock { readers }.forEach { $0.cancel() }
    }
}
