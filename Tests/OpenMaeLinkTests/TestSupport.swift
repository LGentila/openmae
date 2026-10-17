import CryptoKit
import Foundation
import VoiceCore

@testable import OpenMaeLink

// What the link's tests share: a connection between the Mac and the iPhone in memory, and engine stages without models.

/// Checks `condition` every 10 ms, for 4 s at most.
func waitFor(_ condition: () async -> Bool) async {
    for _ in 0..<400 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
}

// MARK: - A connection in memory

/// A connection between the Mac and the iPhone, in memory: what one end sends, the other end receives. `cut()`: the
/// network is gone and nobody is told, as when the iPhone's Wi-Fi goes off. `close()`: both ends are told.
final class MemoryWire: Sendable {
    let mac: MemoryEnd
    let phone: MemoryEnd
    private let line: Line

    init(path: LinkPath) {
        let line = Line()
        self.line = line
        mac = MemoryEnd(.mac, path: path, line: line)
        phone = MemoryEnd(.phone, path: path, line: line)
    }

    func cut() { line.cut() }
    func close() { line.close(from: nil) }

    /// The datagrams (the voice) the Mac sent into this connection, carried or not.
    var datagramsFromMac: Int { line.datagrams(from: .mac) }

    /// A session over this connection, both of its ends, with keys as a handshake would have agreed them.
    func sessions(phoneKey: Data, macKey: Data) -> (mac: LinkSession, phone: LinkSession) {
        let toPhone = SymmetricKey(size: .bits256)
        let toMac = SymmetricKey(size: .bits256)
        let macSide = LinkSession(transport: mac, inbox: FrameInbox(mac),
                                  keys: SessionKeys((send: NoiseCipher(key: toPhone), receive: NoiseCipher(key: toMac))),
                                  peerKey: phoneKey, peerMac: nil)
        let phoneSide = LinkSession(transport: phone, inbox: FrameInbox(phone),
                                    keys: SessionKeys((send: NoiseCipher(key: toMac), receive: NoiseCipher(key: toPhone))),
                                    peerKey: macKey, peerMac: HandshakePayload.Mac(name: "Mac de test"))
        return (macSide, phoneSide)
    }

    enum Side: Hashable {
        case mac, phone
        var other: Side { self == .mac ? .phone : .mac }
    }

    final class Line: @unchecked Sendable {
        private let lock = NSLock()
        private var sinks: [Side: AsyncStream<TransportInput>.Continuation] = [:]
        private var isCut = false
        private var isClosed = false
        private var sent: [Side: Int] = [:]

        func attach(_ side: Side, _ sink: AsyncStream<TransportInput>.Continuation) {
            lock.withLock { sinks[side] = sink }
        }

        func carry(_ input: TransportInput, from side: Side) {
            let target: AsyncStream<TransportInput>.Continuation? = lock.withLock {
                if case .datagram = input { sent[side, default: 0] += 1 }
                return isCut || isClosed ? nil : sinks[side.other]
            }
            target?.yield(input)
        }

        func datagrams(from side: Side) -> Int { lock.withLock { sent[side] ?? 0 } }

        func cut() { lock.withLock { isCut = true } }

        /// The end that closes knows it; the other one is told unless the line is cut. nil: both are told.
        func close(from side: Side?) {
            let told: [AsyncStream<TransportInput>.Continuation] = lock.withLock {
                guard !isClosed else { return side.flatMap { sinks.removeValue(forKey: $0) }.map { [$0] } ?? [] }
                isClosed = true
                let ends: [Side] = side.map { isCut ? [$0] : [$0, $0.other] } ?? [.mac, .phone]
                return ends.compactMap { sinks.removeValue(forKey: $0) }
            }
            for sink in told {
                sink.yield(.closed(nil))
                sink.finish()
            }
        }
    }
}

final class MemoryEnd: LinkTransport, @unchecked Sendable {
    let path: LinkPath
    let incoming: AsyncStream<TransportInput>
    private let side: MemoryWire.Side
    private let line: MemoryWire.Line

    init(_ side: MemoryWire.Side, path: LinkPath, line: MemoryWire.Line) {
        self.side = side
        self.path = path
        self.line = line
        let (incoming, sink) = AsyncStream<TransportInput>.makeStream(bufferingPolicy: .unbounded)
        self.incoming = incoming
        line.attach(side, sink)
    }

    func send(_ bytes: Data) { line.carry(.bytes(bytes), from: side) }
    func sendDatagram(_ datagram: Data) { line.carry(.datagram(datagram), from: side) }
    func close() { line.close(from: side) }
}

// MARK: - Engine stages without models

/// Nobody speaks, unless told (`hearsSpeech`): then every chunk is speech.
final class Silence: SpeechDetector, @unchecked Sendable {
    let chunkSize = 512
    private let lock = NSLock()
    private var speech = false

    var hearsSpeech: Bool {
        get { lock.withLock { speech } }
        set { lock.withLock { speech = newValue } }
    }

    func speechProbability(_ chunk: [Float]) async throws -> Float { hearsSpeech ? 1 : 0 }
    func reset() async {}
}

struct Deaf: Transcriber {
    func transcribe(_ samples: [Float]) async throws -> String { "" }
}

/// Never asked anything: an announcement is said without the model.
struct Mute: LanguageModel {
    func reply(to conversation: [ChatMessage]) -> AsyncThrowingStream<ModelOutput, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func prefill(_ conversation: [ChatMessage]) async throws {}
    func tokenCount(_ conversation: [ChatMessage]) async throws -> Int { conversation.count * 10 }
}

/// Each piece of text: 0.2 s of a tone, at the voice's rate.
struct ToneVoice: SpeechSynthesizer {
    let outputSampleRate = LinkAudio.voiceRate
    func startUtterance(language: SpeechLanguage) async throws -> any SynthesisStream { ToneStream() }
}

final class ToneStream: SynthesisStream, @unchecked Sendable {
    static let pieceSamples = 4_800
    let audio: AsyncThrowingStream<[Float], Error>
    private let continuation: AsyncThrowingStream<[Float], Error>.Continuation

    init() {
        (audio, continuation) = AsyncThrowingStream.makeStream()
    }

    func enqueue(_ text: String) {
        continuation.yield((0..<Self.pieceSamples).map { Float(0.2 * sin(2 * .pi * 440 * Double($0) / 24_000)) })
    }

    func finish() { continuation.finish() }
    func cancel() async { continuation.finish() }
}
