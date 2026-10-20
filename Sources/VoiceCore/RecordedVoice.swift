import Foundation

/// An announcement's voice as it was produced before, played again as it was: nothing to compute, so no near-silent
/// opening to wait for and no voice to start again (`VoiceRestart`).
///
/// An announcement said on a device that never said it played it (a home station unplugged during the chime, an iPhone
/// whose connection dropped) is said again at once where the user is. Its voice had been produced to its end meanwhile:
/// said again by the voice, it opened with a new near-silent breath and, once, started again after the chime was over
/// (the words came 0.3 to 0.6 s after the chime with the voice at its usual pace, measured with `voice-cli
/// announce-drop`, and 2 s in the app). Its recording comes out as soon as all its texts are given (`finish`), which
/// are the same texts in the same order: each chunk keeps its text's number.
public final class RecordedVoice: SynthesisStream, @unchecked Sendable {
    public let audio: AsyncThrowingStream<VoiceAudio, Error>
    private let output: AsyncThrowingStream<VoiceAudio, Error>.Continuation
    private let recording: [VoiceAudio]

    public init(_ recording: [VoiceAudio]) {
        self.recording = recording
        (audio, output) = AsyncThrowingStream.makeStream(of: VoiceAudio.self)
    }

    public func enqueue(_ text: String) {}

    public func finish() {
        recording.forEach { output.yield($0) }
        output.finish()
    }

    public func cancel() async { output.finish() }
}
