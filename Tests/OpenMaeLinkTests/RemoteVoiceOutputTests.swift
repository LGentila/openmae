import Foundation
import Testing
import VoiceCore

@testable import OpenMaeLink

/// The iPhone's voice is stopped when the user interrupts, also near the end of an answer. The voice is faster than real
/// time and `play` only encodes and sends: once the voice has produced the whole answer, the Mac sends the stream's end
/// and waits for the iPhone, which may still have seconds of it in its buffer. A barge-in (or the stop button) then must
/// stop it there, as earlier in the answer.
@Suite("Stopping the iPhone's voice", .serialized)
struct RemoteVoiceOutputTests {
    /// An answer of 5 s, produced at once: the iPhone plays it for 5 s, the Mac waits for it for 7.5 s at most.
    static let answer = tone(seconds: 5)

    /// The Mac sent the whole answer and its end, and waits for the iPhone to play it; the user interrupts.
    @Test func aStreamWhoseEndWasSentIsStopped() async throws {
        let link = MemoryLink()
        let output = RemoteVoiceOutput(session: link.mac)
        await output.play(Self.answer, sampleRate: LinkAudio.voiceRate)
        let wait = Wait(output)
        await waitFor { link.phone.ended != nil }
        let stream = try #require(link.phone.ended)
        let stopped = ContinuousClock.now
        await output.stopImmediately()
        await waitFor { !link.phone.stops.isEmpty }
        #expect(link.phone.stops == [stream])  // the iPhone drops what it still had to play
        await waitFor { wait.returned != nil }
        let returned = try #require(wait.returned)  // the turn ends at once, not after the stream's length
        #expect(returned - stopped < .milliseconds(500))
        await wait.end()
        link.close()
    }

    /// The turn is cancelled first (a new conversation, another tier chosen), then the voice stopped: the wait ends at
    /// once, and the stop still reaches the iPhone.
    @Test func itIsStoppedAfterTheWaitWasCancelled() async throws {
        let link = MemoryLink()
        let output = RemoteVoiceOutput(session: link.mac)
        await output.play(Self.answer, sampleRate: LinkAudio.voiceRate)
        let wait = Wait(output)
        await waitFor { link.phone.ended != nil }
        let stream = try #require(link.phone.ended)
        let cancelled = ContinuousClock.now
        wait.task.cancel()
        await waitFor { wait.returned != nil }
        let returned = try #require(wait.returned)
        #expect(returned - cancelled < .milliseconds(500))
        await output.stopImmediately()
        await waitFor { !link.phone.stops.isEmpty }
        #expect(link.phone.stops == [stream])
        link.close()
    }

    /// Once the iPhone said it played the stream, there is nothing left to stop there; the next answer is the one that
    /// gets stopped.
    @Test func aStreamThePhonePlayedIsNotStoppedAgain() async throws {
        let link = MemoryLink()
        let output = RemoteVoiceOutput(session: link.mac)
        await output.play(tone(seconds: 0.2), sampleRate: LinkAudio.voiceRate)
        let wait = Wait(output)
        await waitFor { link.phone.ended != nil }
        let first = try #require(link.phone.ended)
        output.markFinished(first)  // what LinkHost does when the iPhone says so
        await waitFor { wait.returned != nil }
        #expect(wait.returned != nil)
        await output.stopImmediately()
        try await Task.sleep(for: .milliseconds(200))
        #expect(link.phone.stops.isEmpty)

        await output.play(Self.answer, sampleRate: LinkAudio.voiceRate)
        await output.stopImmediately()
        await waitFor { !link.phone.stops.isEmpty }
        #expect(link.phone.stops.count == 1)
        #expect(link.phone.stops.allSatisfy { $0 > first })
        await wait.end()
        link.close()
    }

    /// Through the conversation's logic, which waits for the iPhone once the voice has said everything: an
    /// announcement, said to its end on the Mac's side and still playing on the iPhone; the user presses stop.
    @Test func theStopButtonAtTheEndOfAnAnswerStopsTheIPhone() async throws {
        let link = MemoryLink()
        let output = RemoteVoiceOutput(session: link.mac)
        let pipeline = VoicePipeline(detector: Silence(), transcriber: Deaf(), model: Mute(), synthesizer: ToneVoice(),
                                     output: output)
        try await pipeline.start()
        await pipeline.announce("Ton minuteur de 20 secondes est terminé.",
                                note: "(Le minuteur t1 de 20 secondes vient de sonner.)", language: .french)
        await waitFor { link.phone.ended != nil }
        let stream = try #require(link.phone.ended)
        await pipeline.interrupt()
        await waitFor { !link.phone.stops.isEmpty }
        #expect(link.phone.stops == [stream])
        await pipeline.stop()
        link.close()
    }
}

/// `seconds` of a tone at the voice's rate.
private func tone(seconds: Double) -> [Float] {
    (0..<Int(seconds * LinkAudio.voiceRate)).map { Float(0.2 * sin(2 * .pi * 440 * Double($0) / LinkAudio.voiceRate)) }
}

/// `waitUntilDone`, as the turn calls it, and when it returned.
private final class Wait: Sendable {
    let task: Task<Void, Never>
    private let moment: Moment

    init(_ output: RemoteVoiceOutput) {
        let moment = Moment()
        self.moment = moment
        task = Task {
            await output.waitUntilDone()
            moment.set(.now)
        }
    }

    var returned: ContinuousClock.Instant? { moment.value }

    /// Lets it return if it has not yet (a test that failed), so that nothing outlives the test.
    func end() async {
        task.cancel()
        await task.value
    }

    private final class Moment: @unchecked Sendable {
        private let lock = NSLock()
        private var instant: ContinuousClock.Instant?
        var value: ContinuousClock.Instant? { lock.withLock { instant } }
        func set(_ value: ContinuousClock.Instant) { lock.withLock { instant = value } }
    }
}

/// A session between the Mac and an iPhone, in memory. The iPhone is still playing its buffer: it records what the Mac
/// tells it about the voice, and never says it finished.
private final class MemoryLink: @unchecked Sendable {
    let mac: LinkSession
    let phone: Player
    private let wire = MemoryWire(path: .direct)

    init() {
        let sessions = wire.sessions(phoneKey: Data(repeating: 9, count: 32), macKey: Data(repeating: 7, count: 32))
        mac = sessions.mac
        phone = Player(sessions.phone)
    }

    func close() {
        phone.close()
        mac.close()
    }

    final class Player: @unchecked Sendable {
        private let session: LinkSession
        private let lock = NSLock()
        private var end: UInt32?
        private var stopped: [UInt32] = []
        private var tasks: [Task<Void, Never>] = []

        init(_ session: LinkSession) {
            self.session = session
            tasks = [
                Task { [weak self] in
                    for await message in session.messages {
                        guard case .audio(let control) = message else { continue }
                        self?.received(control)
                    }
                },
            ]
        }

        /// The last stream whose end the Mac sent.
        var ended: UInt32? { lock.withLock { end } }
        /// The streams the Mac told it to stop, in order.
        var stops: [UInt32] { lock.withLock { stopped } }

        func close() {
            tasks.forEach { $0.cancel() }
            session.close()
        }

        private func received(_ control: AudioControl) {
            lock.withLock {
                switch control {
                case .end(let stream, _): end = stream
                case .stopPlayback(let stream): stopped.append(stream)
                default: break
                }
            }
        }
    }
}
