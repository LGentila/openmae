import Foundation
import VoiceCore

/// What kind of device is paired with the Mac, from the model identifier it gives at pairing.
public enum DeviceKind: String, Sendable, Equatable {
    case iPhone
    case iPad

    public init(model: String) {
        self = model.hasPrefix("iPad") ? .iPad : .iPhone
    }
}

/// How the user talks to Maé on an iPhone or an iPad.
public enum DeviceTalkMode: String, Codable, CaseIterable, Sendable {
    /// Maé hears whenever the user speaks.
    case handsFree
    /// One big button, held while talking.
    case hold
    /// A tap on the orb (or the main button) to talk, another to finish: what ⌥ Space does on the Mac. The default
    /// of an iPad left at home as a station.
    case tap

    /// The Mac's way of listening that goes with it: only the talk key opens a turn, except in hands-free.
    public var listening: ListeningMode { self == .handsFree ? .handsFree : .pushToTalk }
}

/// "Tap to talk": the first tap presses the talk key, the next one releases it, exactly as ⌥ Space on the Mac. The
/// device sends the command (`LinkMessage.command`); the Mac gives it the conversation on the press.
public struct TapToTalk: Sendable, Equatable {
    public private(set) var isPressed = false

    public init() {}

    /// The command a tap sends.
    public mutating func tap() -> AssistantCommand {
        isPressed.toggle()
        return .talkKey(pressed: isPressed)
    }

    /// The turn ended without a second tap (the Mac answered, or took the conversation back).
    public mutating func reset() {
        isPressed = false
    }
}

/// When a device gives the conversation back to the Mac on its own, after an exchange.
public enum ConversationRelease {
    /// How long a home station keeps the conversation after an exchange in "Tap to talk" or "Hold": the shortest
    /// "Automatic end" of the iPhone.
    public static let stationDelay = Duration.seconds(60)

    /// How long after the last exchange the device lets go (`audio stop`), nil: it keeps the conversation. A station
    /// gives it back one minute after an exchange, so that the Mac hears the user again without anything to press,
    /// and keeps its link open for the announcements; in hands-free it never does. Elsewhere (an iPhone, an iPad
    /// unplugged or in the background), after `autoEndMinutes` of silence, 0 being never.
    public static func delay(station: Bool, mode: DeviceTalkMode, autoEndMinutes: Int) -> Duration? {
        if station { return mode == .handsFree ? nil : stationDelay }
        return autoEndMinutes > 0 ? .seconds(autoEndMinutes * 60) : nil
    }
}
