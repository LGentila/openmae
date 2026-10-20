import Foundation

/// The voice of an answer, started again when the opening of a sentence stays near-silent too long.
///
/// Pocket TTS opens every sentence with a near-silent breath of random length (measured with `voice-cli voice-onset` on
/// the reference Mac, 100 first sentences: none in 31, up to 1 s of audio in 61, 1.2 to 4.4 s in 7), and sometimes says
/// a whole sentence as near-silence (one of the 100). The pipeline skips that near-silence, but
/// waits while the voice produces it: the answer's first sound came up to 6 s after its first piece of text, and a
/// first sentence said as near-silence was never heard. Another utterance of the same text draws its breath again:
/// once the opening has lasted `patience` samples without an audible one, the voice stops and starts again with all
/// the text it was given, at most `restarts` times. Nothing is lost, since nothing was heard.
///
/// Before the first audible sound, the near-silence is dropped (the pipeline skips it anyway).
///
/// The later sentences open the same way (in the debug logs of the reference Mac, 443 of them: none in 41 %, under
/// 0.7 s of audio in 75 %, 1.2 s or more in 10 %, up to 5 s), and one was said as 11 s of near-silence: never heard.
/// After the first sound, a sentence that ends without an audible sound (said as near-silence) starts again in a new
/// utterance, from that sentence on: its text and the texts after it, at most `laterRestarts` times per sentence. The
/// sentences before it were said whole: nothing is said twice. With `laterPatience`, a sentence whose opening has lasted
/// that many samples without an audible one starts again the same way; but that does not shorten the silences between
/// sentences (`PipelineConfig.sentenceRestartAfterSeconds`). After the first sound, the audio goes through as it comes,
/// near-silence included.
///
/// A voice started again was given the same texts in the same order, or the texts from one of them on: what it says
/// keeps its numbers (`VoiceAudio.text`). A voice that cannot tell which text it says is never started again after the
/// first sound.
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

    /// The sentence being said after the first sound: its text's number, whether it was heard yet, and the near-silence
    /// it opened with so far.
    private struct Sentence {
        var text: Int?
        var heard = false
        var quiet = 0
    }

    /// `audible`: whether a chunk of audio can be heard (the pipeline's `leadingSilenceThresholdDB`); `restarting`:
    /// called as the voice starts again; `resumed`: called when a sentence started again after the first sound is
    /// heard; `start`: a new utterance, for each new start.
    public init(_ first: any SynthesisStream, patience: Int, restarts: Int, laterPatience: Int? = nil,
                laterRestarts: Int = 0, audible: @escaping @Sendable ([Float]) -> Bool,
                restarting: @escaping @Sendable () -> Void = {}, resumed: @escaping @Sendable () -> Void = {},
                start: @escaping @Sendable () async throws -> any SynthesisStream)
    {
        current = first
        (audio, output) = AsyncThrowingStream.makeStream(of: VoiceAudio.self)
        let reader = Task {
            var voice = first
            var restarted = 0
            var heard = false
            /// The number of the current voice's first text: it numbers its texts from 0.
            var offset = 0
            var sentence = Sentence()
            /// After the first sound: how many times each sentence started again, by its text's number.
            var laterRestarted: [Int: Int] = [:]
            /// A sentence started again after the first sound, not heard yet.
            var resuming = false
            /// Whether the sentence `text` may start again after the first sound.
            func mayStartAgain(_ text: Int) -> Bool { laterRestarted[text, default: 0] < laterRestarts }
            do {
                restart: while true {
                    var quiet = 0
                    var restartFrom: Int?
                    for try await received in voice.audio {
                        var chunk = received
                        chunk.text = received.text.map { $0 + offset }
                        if !heard {
                            if audible(chunk.samples) {
                                heard = true
                                sentence = Sentence(text: chunk.text, heard: true)
                                // A voice started again was given the same texts in the same order: they keep their
                                // numbers.
                                self.output.yield(chunk)
                                continue
                            }
                            quiet += chunk.samples.count
                            guard quiet >= patience, restarted < restarts else { continue }
                            restarted += 1
                            DebugLog.log("voice: still near-silent after \(quiet) samples, starting again (\(restarted))")
                            restarting()
                            guard let next = try await self.startAgain(stopping: voice, from: 0, with: start) else {
                                break restart
                            }
                            voice = next
                            continue restart
                        }
                        // After the first sound: each sentence's opening.
                        if laterRestarts > 0, let text = chunk.text {
                            if text != sentence.text {
                                if let said = sentence.text, !sentence.heard, mayStartAgain(said) {
                                    DebugLog.log("voice: sentence \(said + 1) said as near-silence"
                                                 + " (\(sentence.quiet) samples), starting again from it")
                                    restartFrom = said
                                    break
                                }
                                sentence = Sentence(text: text)
                            }
                            if !sentence.heard {
                                if audible(chunk.samples) {
                                    sentence.heard = true
                                    if resuming {
                                        resuming = false
                                        resumed()
                                    }
                                } else {
                                    sentence.quiet += chunk.samples.count
                                    if let laterPatience, sentence.quiet >= laterPatience, mayStartAgain(text) {
                                        DebugLog.log("voice: sentence \(text + 1) still near-silent after"
                                                     + " \(sentence.quiet) samples, starting again from it")
                                        restartFrom = text
                                        break
                                    }
                                }
                            }
                        }
                        self.output.yield(chunk)
                    }
                    // Everything said: the last sentence too?
                    if restartFrom == nil, heard, let said = sentence.text, !sentence.heard, mayStartAgain(said),
                       !Task.isCancelled, !self.lock.withLock({ self.stopped })
                    {
                        DebugLog.log("voice: sentence \(said + 1) said as near-silence (\(sentence.quiet) samples),"
                                     + " starting again from it")
                        restartFrom = said
                    }
                    guard let from = restartFrom else { break }
                    laterRestarted[from, default: 0] += 1
                    restarting()
                    resuming = true
                    guard let next = try await self.startAgain(stopping: voice, from: from, with: start) else {
                        break restart
                    }
                    voice = next
                    offset = from
                    sentence = Sentence()
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

    /// Stops `voice`, then gives the new one everything said from the text numbered `from` on; nil once cancelled.
    private func startAgain(stopping voice: any SynthesisStream, from: Int,
                            with start: @Sendable () async throws -> any SynthesisStream) async throws
        -> (any SynthesisStream)?
    {
        await voice.cancel()  // first, so that two voices never share the GPU
        guard !lock.withLock({ stopped }) else { return nil }
        let next = try await start()
        let kept = lock.withLock {
            guard !stopped else { return false }
            current = next
            texts[from...].forEach(next.enqueue)
            if finished { next.finish() }
            return true
        }
        if !kept { await next.cancel() }
        return kept ? next : nil
    }
}
