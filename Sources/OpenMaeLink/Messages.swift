import Foundation
import VoiceCore

/// The end-to-end messages between the iPhone (or iPad) and the Mac, once a session is open (relay/PROTOCOL.md): one
/// JSON object per Noise transport message, told apart by `"type"`.
public enum LinkMessage: Sendable {
    /// iPhone → Mac: an assistant command (only a few are accepted, see `RemoteCommandPolicy`).
    case command(AssistantCommand)
    /// Mac → iPhone: an assistant event.
    case event(AssistantEvent)
    case audio(AudioControl)
    case ping
    case pong
    /// Mac → iPhone, at the end of a pairing.
    case paired
    /// Mac → iPhone: this iPhone was removed from the Mac's settings; the session closes.
    case removed
    /// Mac → iPhone: the Mac's name or relay changed; the iPhone follows its relay.
    case mac(HandshakePayload.Mac)
    /// iPad → Mac: whether it is a home station right now (station mode on, plugged in, app in the foreground). Sent
    /// when the session opens and on every change, only to a Mac that lists it in its features
    /// (`HandshakePayload.Mac.features`): a Mac from before closes the session on a message it does not know.
    case device(station: Bool)

    /// The optional messages, as a Mac lists those it understands (`HandshakePayload.Mac.features`).
    public static let deviceFeature = "device"
    /// The optional events, as an iPhone or an iPad lists those it understands (`HandshakePayload.Session.features`):
    /// the user's words while they speak (`AssistantEvent.partialTranscript`). Only a device that lists one is sent it:
    /// the first versions of the app closed the session on an event they did not know.
    public static let partialTranscriptFeature = "partialTranscript"

    private enum Kind: String, Codable { case command, event, audio, ping, pong, paired, removed, mac, device }
    private enum Keys: String, CodingKey { case type, command, event, op, stream, frames, name, relay, station }
}

/// Who has the conversation's sound, and the voice streams' ends.
public enum AudioControl: Sendable, Equatable {
    /// iPhone → Mac: the iPhone takes the conversation (its microphone, its speaker).
    case start
    /// iPhone → Mac: the iPhone lets go; the Mac takes its own microphone and speakers back.
    case stop
    /// Mac → iPhone: the Mac took the conversation back.
    case released
    /// Mac → iPhone: voice stream `stream` has `frames` frames in all.
    case end(stream: UInt32, frames: UInt32)
    /// Mac → iPhone: stop playing voice stream `stream` now (the user interrupted).
    case stopPlayback(stream: UInt32)
    /// iPhone → Mac: everything of voice stream `stream` was played, or stopped.
    case finished(stream: UInt32)
}

extension LinkMessage: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .command: self = .command(try c.decode(AssistantCommand.self, forKey: .command))
        case .event: self = .event(try c.decode(AssistantEvent.self, forKey: .event))
        case .ping: self = .ping
        case .pong: self = .pong
        case .paired: self = .paired
        case .removed: self = .removed
        case .mac:
            self = .mac(HandshakePayload.Mac(name: try c.decode(String.self, forKey: .name),
                                             relay: try c.decodeIfPresent(URL.self, forKey: .relay)))
        case .device:
            self = .device(station: try c.decode(Bool.self, forKey: .station))
        case .audio:
            let stream = try c.decodeIfPresent(UInt32.self, forKey: .stream)
            switch try c.decode(String.self, forKey: .op) {
            case "start": self = .audio(.start)
            case "stop": self = .audio(stream.map { .stopPlayback(stream: $0) } ?? .stop)
            case "released": self = .audio(.released)
            case "end":
                guard let stream else { throw DecodingError.keyNotFound(Keys.stream, .init(codingPath: [], debugDescription: "end")) }
                self = .audio(.end(stream: stream, frames: try c.decode(UInt32.self, forKey: .frames)))
            case "finished":
                guard let stream else { throw DecodingError.keyNotFound(Keys.stream, .init(codingPath: [], debugDescription: "finished")) }
                self = .audio(.finished(stream: stream))
            case let op:
                throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unknown audio op \(op)")
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .command(let command):
            try c.encode(Kind.command, forKey: .type)
            try c.encode(command, forKey: .command)
        case .event(let event):
            try c.encode(Kind.event, forKey: .type)
            try c.encode(event, forKey: .event)
        case .ping: try c.encode(Kind.ping, forKey: .type)
        case .pong: try c.encode(Kind.pong, forKey: .type)
        case .paired: try c.encode(Kind.paired, forKey: .type)
        case .removed: try c.encode(Kind.removed, forKey: .type)
        case .mac(let mac):
            try c.encode(Kind.mac, forKey: .type)
            try c.encode(mac.name, forKey: .name)
            try c.encodeIfPresent(mac.relay, forKey: .relay)
        case .device(let station):
            try c.encode(Kind.device, forKey: .type)
            try c.encode(station, forKey: .station)
        case .audio(let control):
            try c.encode(Kind.audio, forKey: .type)
            switch control {
            case .start: try c.encode("start", forKey: .op)
            case .stop: try c.encode("stop", forKey: .op)
            case .released: try c.encode("released", forKey: .op)
            case .end(let stream, let frames):
                try c.encode("end", forKey: .op)
                try c.encode(stream, forKey: .stream)
                try c.encode(frames, forKey: .frames)
            case .stopPlayback(let stream):
                try c.encode("stop", forKey: .op)
                try c.encode(stream, forKey: .stream)
            case .finished(let stream):
                try c.encode("finished", forKey: .op)
                try c.encode(stream, forKey: .stream)
            }
        }
    }

    public var encoded: Data {
        // Cannot fail: every case encodes to plain JSON.
        (try? JSONEncoder().encode(self)) ?? Data("{}".utf8)
    }

    public init(decoding data: Data) throws {
        self = try JSONDecoder().decode(LinkMessage.self, from: data)
    }
}

/// The handshake payloads (relay/PROTOCOL.md).
public enum HandshakePayload {
    /// The Mac, in the second message of a pairing or a session (and in a `mac` message when it changes).
    public struct Mac: Codable, Sendable, Equatable {
        public var name: String
        /// The relay the Mac is registered with, none when it has none (reachable at home only).
        public var relay: URL?
        /// The optional messages this Mac understands (`LinkMessage.deviceFeature`); nil from a Mac from before them,
        /// which must not be sent any.
        public var features: [String]?
        public init(name: String, relay: URL? = nil, features: [String]? = nil) {
            self.name = name
            self.relay = relay
            self.features = features
        }

        public func understands(_ feature: String) -> Bool { features?.contains(feature) == true }
    }

    /// The iPhone or iPad, in the third message of a pairing.
    public struct Phone: Codable, Sendable, Equatable {
        public var name: String
        /// The model identifier, e.g. "iPhone17,3" or "iPad14,1".
        public var model: String
        public init(name: String, model: String) {
            self.name = name
            self.model = model
        }
    }

    /// The iPhone, in the first message of a session.
    public struct Session: Codable, Sendable, Equatable {
        public var v: Int
        /// The optional events this iPhone (or iPad) understands (`LinkMessage.partialTranscriptFeature`); nil from one
        /// from before them, which must not be sent any.
        public var features: [String]?
        public init(v: Int = 1, features: [String]? = nil) {
            self.v = v
            self.features = features
        }

        public func understands(_ feature: String) -> Bool { features?.contains(feature) == true }

        /// What this version's iPhone and iPad app says.
        public static let current = Session(features: [LinkMessage.partialTranscriptFeature])
    }

    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

/// What the iPhone may ask the Mac. It has the same powers as the voice on the Mac (sensitive actions still ask
/// for a spoken "yes"), but never those that belong to the Mac: loading, downloading or deleting models, quitting.
public enum RemoteCommandPolicy {
    /// An allow-list: a command added to the contract later stays the Mac's until it is added here.
    public static func isAllowed(_ command: AssistantCommand) -> Bool {
        switch command {
        case .stopSpeaking, .newConversation, .talkKey, .updateSettings: true
        default: false  // start, downloads, deletions, quitting, typed turns: the Mac's own
        }
    }

    /// Which events go to the iPhone. Not the sound levels (the iPhone measures its own), the measurements, the
    /// download or the models' storage: they belong to the Mac's screens. An allow-list too.
    public static func isRelayed(_ event: AssistantEvent) -> Bool {
        switch event {
        case .state, .partialTranscript, .userTranscript, .assistantPiece, .turnFinished, .ready, .loading, .warning,
             .problem, .setupNeeded:
            true
        default: false
        }
    }

    /// The feature a device must list (`HandshakePayload.Session.features`) to be sent the event; nil: any device gets
    /// it.
    public static func neededFeature(_ event: AssistantEvent) -> String? {
        if case .partialTranscript = event { return LinkMessage.partialTranscriptFeature }
        return nil
    }

    /// The event as the iPhone gets it: a finished turn without its detailed measurements.
    public static func relayed(_ event: AssistantEvent) -> AssistantEvent? {
        guard isRelayed(event) else { return nil }
        if case .turnFinished(let metrics) = event {
            var summary = TurnMetrics()
            summary.userText = metrics.userText
            summary.assistantText = metrics.assistantText
            summary.language = metrics.language
            summary.interrupted = metrics.interrupted
            return .turnFinished(summary)
        }
        return event
    }
}
