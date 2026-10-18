import Foundation

/// The voice of an answer, started again when its opening stays near-silent too long.
///
/// Pocket TTS opens every sentence with a near-silent breath of random length (measured with `voice-cli voice-onset` on
/// the reference Mac, 100 first sentences: none in 31, up to 1 s of audio in 61, 1.2 to 4.4 s in 7), and sometimes says
/// a whole sentence as near-silence (one of the 100). The pipeline skips that near-silence, but
/// waits while the voice produces it: the answer's first sound came up to 6 s after its first piece of text, and a
/// first sentence said as near-silence was never heard. Another utterance of the same text draws its breath again:
/// once the opening has lasted `patience` samples without an audible one, the voice stops and starts again with all
/// the text it was given, at most `restarts` times. Nothing is lost, since nothing was heard.
///
/// Before the first audible sound, the near-silence is dropped (the pipeline skips it anyway); then the audio goes
/// through as it comes.
public final class VoiceRestart: SynthesisStream, @unchecked Sendable {
    public let audio: AsyncThrowingStream<VoiceAudio, Error>
    private let output: AsyncThrowingStream<VoiceAudio, Error>.Continuation
    private let lock = NSLock()
    // Guarded by `lock`.
    private var current: any SynthesisStream
    private var texts: [String] = []
    private var finished = false
    private var stopped = false
    private var reader: Task<Void, Never>?

    /// `audible`: whether a chunk of audio can be heard (the pipeline's `leadingSilenceThresholdDB`); `restarting`:
    /// called as the voice starts again; `start`: a new utterance, for each new start.
    public init(_ first: any SynthesisStream, patience: Int, restarts: Int,
                audible: @escaping @Sendable ([Float]) -> Bool, restarting: @escaping @Sendable () -> Void = {},
                start: @escaping @Sendable () async throws -> any SynthesisStream)
    {
        current = first
        (audio, output) = AsyncThrowingStream.makeStream(of: VoiceAudio.self)
        let reader = Task {
            var voice = first
            var restarted = 0
            var heard = false
            do {
                restart: while true {
                    var quiet = 0
                    for try await chunk in voice.audio {
                        if heard || audible(chunk.samples) {
                            heard = true
                            // A voice started again was given the same texts in the same order: they keep their numbers.
                            self.output.yield(chunk)
                            continue
                        }
                        quiet += chunk.samples.count
                        guard quiet >= patience, restarted < restarts else { continue }
                        restarted += 1
                        DebugLog.log("voice: still near-silent after \(quiet) samples, starting again (\(restarted))")
                        restarting()
                        guard let next = try await self.startAgain(stopping: voice, with: start) else { break restart }
                        voice = next
                        continue restart
                    }
                    break
                }
                self.output.finish()
            } catch {
                self.output.finish(throwing: error)
            }
        }
        lock.withLock { self.reader = reader }
        output.onTermination = { [weak self] _ in self?.lock.withLock { self?.reader }?.cancel() }
    }

    public func enqueue(_ text: String) {
        lock.withLock {
            texts.append(text)
            current.enqueue(text)
        }
    }

    public func finish() {
        lock.withLock {
            finished = true
            current.finish()
        }
    }

    public func cancel() async {
        let voice = lock.withLock {
            stopped = true
            return current
        }
        await voice.cancel()
        output.finish()
    }

    /// Stops `voice`, then gives the new one everything said so far; nil once cancelled.
    private func startAgain(stopping voice: any SynthesisStream,
                            with start: @Sendable () async throws -> any SynthesisStream) async throws
        -> (any SynthesisStream)?
    {
        await voice.cancel()  // first, so that two voices never share the GPU
        guard !lock.withLock({ stopped }) else { return nil }
        let next = try await start()
        let kept = lock.withLock {
            guard !stopped else { return false }
            current = next
            texts.forEach(next.enqueue)
            if finished { next.finish() }
            return true
        }
        if !kept { await next.cancel() }
        return kept ? next : nil
    }
}
