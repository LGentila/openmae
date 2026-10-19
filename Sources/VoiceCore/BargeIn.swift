import Foundation

/// What it takes for a voice heard while Maé speaks to interrupt her (a barge-in), on the device that has the
/// conversation.
///
/// Her own voice comes back into the microphone after the echo cancellation, in bursts that speech detection can take
/// for someone speaking. How loud and how long they get depends on the device: its speaker, its microphones and its
/// echo cancellation (the Mac's, or Apple's voice processing on an iPhone). So each kind of device has its own profile,
/// applied while it has the conversation (`VoicePipeline.setBargeIn`): speech over her that does not last `minSpeechMs`,
/// or stays quieter than `minLevelDB`, is taken for her echo and does not stop her.
///
/// With `VOICE_DEBUG=1` the log shows how each voice heard over her was judged ("speech started (level … dB, over the
/// assistant…)", "ignored while the assistant talks…"), and after each answer what was heard over her voice ("heard
/// over Maé's voice…"): the numbers to check a profile against, and to tune it.
public struct BargeInProfile: Sendable, Equatable {
    /// The device it is for, in the log.
    public var device: String
    /// Speech quieter than this at the microphone (dB, its mean level over the last `minSpeechMs`) is taken for her
    /// echo. nil = no check.
    public var minLevelDB: Float?
    /// Speech must last this long without a break before it interrupts her: more than to start a turn
    /// (`TurnDetectorConfig.minSpeechMs`), since leftovers of her voice come in bursts.
    public var minSpeechMs: Double

    public init(device: String, minLevelDB: Float?, minSpeechMs: Double) {
        self.device = device
        self.minLevelDB = minLevelDB
        self.minSpeechMs = minSpeechMs
    }

    /// The Mac, after its echo cancellation (tuned in the app): leftovers of her voice come in short bursts (170–260 ms)
    /// quieter than -38 dB; the user's voice over hers is at about -22 dB (`voice-cli interruption`).
    public static let mac = BargeInProfile(device: "Mac", minLevelDB: -38, minSpeechMs: 224)

    /// An iPhone that has the conversation, its speaker on, after Apple's voice processing (its echo cancellation). On
    /// 2026-10-18 (hands-free, nobody speaking, a quiet room), bursts of her echo reached -53, -47, -39 and -33 dB over
    /// 224 ms, and the last one was taken for the user. Their own voice over hers was not measured on an iPhone yet (at
    /// the start of their sentences the log gave -31 and -29 dB, means that also counted two quieter chunks from before
    /// the voice). First values, to check on the iPhone and tune from the log.
    public static let iPhone = BargeInProfile(device: "iPhone", minLevelDB: -30, minSpeechMs: 288)

    /// The same, with the values that `environment` sets, to try others on a device without building the app again:
    /// `<prefix>_DB` for the level (dB) and `<prefix>_MS` for the duration (ms), e.g. `VOICE_BARGE_IN_IPHONE_DB=-28`.
    public func adjusted(by environment: [String: String] = ProcessInfo.processInfo.environment,
                         prefix: String) -> BargeInProfile
    {
        var profile = self
        if let level = environment[prefix + "_DB"].flatMap({ Float($0) }), level.isFinite { profile.minLevelDB = level }
        if let ms = environment[prefix + "_MS"].flatMap({ Double($0) }), ms.isFinite, ms > 0 { profile.minSpeechMs = ms }
        if profile != self { profile.device += ", set by \(prefix)_DB/_MS" }
        return profile
    }

    /// For the log: "iPhone, -30 dB for 288 ms".
    public var summary: String {
        "\(device), \(minLevelDB.map { "\(Int($0.rounded())) dB" } ?? "any level") for \(Int(minSpeechMs.rounded())) ms"
    }
}
