import Foundation

/// An engine whose microphone and voice can be elsewhere than on the Mac: on an iPhone, through the link
/// (OpenMaeLink). One route at a time: while the iPhone has the conversation, the Mac's microphone and speakers are
/// released.
public protocol RemoteAudioRouting: Sendable {
    /// From now on the microphone audio (16 kHz mono, in real time) comes from `microphone` and the voice goes to
    /// `output`, and what it takes to interrupt Maé is `bargeIn`, the profile of that device: its echo is not the Mac's
    /// (`BargeInProfile`). The Mac's own microphone and speakers are released.
    func useRemoteAudio(microphone: AsyncStream<[Float]>, output: any AudioOutput, bargeIn: BargeInProfile) async
    /// Whether the device that has the conversation hears the voice right now: false while its connection is down
    /// (Wi-Fi to 4G, a tunnel), until it comes back, maybe by another way, or until `useLocalAudio`. Meanwhile what the
    /// app has to say on its own (`VoicePipeline.announce`) waits, rather than being said to nobody; an answer it did not
    /// hear to its end is said again from the sentence that was cut once it is back, and a sentence of the user's that
    /// the drop cut is not answered (`VoicePipeline.setOutputReachable`). `reachedUntil`, when it goes out of reach: the
    /// voice sent to it before that instant reached it (it plays it), what was sent since may be lost.
    func setRemoteAudioReachable(_ reachable: Bool, reachedUntil: ContinuousClock.Instant?) async
    /// Back to the Mac's microphone and speakers, and to the Mac's barge-in profile.
    func useLocalAudio() async
    /// Where what the app says on its own (`VoicePipeline.announce`) is spoken: `output`, a home station's speaker,
    /// wherever the conversation is; nil, where the conversation is (the device that has it, or the Mac). The
    /// microphone stays where it is. `reachable` false: the station is gone for a moment and may come back, the
    /// announcements wait for it.
    func announceThrough(_ output: (any AudioOutput)?, reachable: Bool) async
}

/// An engine that can say something on the app's own initiative, as it does when a timer rings: information received
/// from another system (Home Assistant, a script…, see ReceivedInformation.swift). Deliberately not an
/// `AssistantCommand`: a paired iPhone must not be able to make Maé announce anything.
public protocol Announcing: Sendable {
    /// Whether Maé can speak now: her models are loaded and the setup is done. Otherwise what comes in becomes a
    /// notification.
    func canAnnounce() async -> Bool
    /// Says `text` after the chime (when `chime`), as soon as nobody speaks (`VoicePipeline.announce`). `note` tells the
    /// model what happened; it stays in the history with what was said. `urgent`: it may cut Maé's sentence, never the
    /// user's. `id` lets `withdrawAnnouncement` take it back while it waits. Returns false when Maé cannot speak (then
    /// nothing was queued).
    func announce(_ text: String, note: String, language: SpeechLanguage, chime: Bool, urgent: Bool, id: UUID) async
        -> Bool
    /// Takes back an announcement that has not started yet. False when it has started, or is over.
    func withdrawAnnouncement(_ id: UUID) async -> Bool
    /// Whether an announcement is still waiting to be said (false once it has started).
    func announcementWaits(_ id: UUID) async -> Bool
    /// A notification on the Mac.
    func notify(title: String, body: String) async
    /// Asks for the permission to show notifications (when the first source that needs them is added).
    func requestNotificationPermission() async
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

    @discardableResult
    public func waitUntilDone() async -> PlaybackEnd {
        await lock.withLock { current }.waitUntilDone()
    }

    public func stopImmediately() async {
        await lock.withLock { current }.stopImmediately()
    }

    public func abandon() async {
        await lock.withLock { current }.abandon()
    }
}

/// What the app says when the connection of the device that has the conversation dropped. Written as `ActionPhrases`
/// are: "tu", a non-breaking space before « ? », at least five words.
public enum OutOfReachPhrases {
    /// A sentence of the user's was cut by the drop: it was not answered, they are asked to say it again.
    public static func sentenceCut(_ language: SpeechLanguage) -> String {
        language == .french ? "Ta phrase a été coupée, tu peux répéter\u{00A0}?"
            : "Your sentence was cut off. Can you say it again?"
    }
}
