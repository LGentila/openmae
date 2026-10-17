import Foundation

/// An engine whose microphone and voice can be elsewhere than on the Mac: on an iPhone, through the link
/// (OpenMaeLink). One route at a time: while the iPhone has the conversation, the Mac's microphone and speakers are
/// released.
public protocol RemoteAudioRouting: Sendable {
    /// From now on the microphone audio (16 kHz mono, in real time) comes from `microphone` and the voice goes to
    /// `output`. The Mac's own microphone and speakers are released.
    func useRemoteAudio(microphone: AsyncStream<[Float]>, output: any AudioOutput) async
    /// Whether the device that has the conversation hears the voice right now: false while its connection is down
    /// (Wi-Fi to 4G, a tunnel), until it comes back, maybe by another way, or until `useLocalAudio`. Meanwhile what the
    /// app has to say on its own (`VoicePipeline.announce`) waits, rather than being said to nobody.
    func setRemoteAudioReachable(_ reachable: Bool) async
    /// Back to the Mac's microphone and speakers.
    func useLocalAudio() async
}

/// The voice's output, switchable while the pipeline runs (the pipeline keeps one output for its whole life). What
/// was queued on the previous output is dropped when switching.
public final class AudioRouter: AudioOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var current: any AudioOutput

    public init(_ output: any AudioOutput) {
        current = output
    }

    public func use(_ output: any AudioOutput) async {
        let previous = lock.withLock {
            defer { current = output }
            return current
        }
        await previous.stopImmediately()
    }

    public func play(_ samples: [Float], sampleRate: Double) async {
        await lock.withLock { current }.play(samples, sampleRate: sampleRate)
    }

    public func waitUntilDone() async {
        await lock.withLock { current }.waitUntilDone()
    }

    public func stopImmediately() async {
        await lock.withLock { current }.stopImmediately()
    }
}
