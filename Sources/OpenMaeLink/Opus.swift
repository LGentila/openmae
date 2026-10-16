@preconcurrency import AVFoundation
import Foundation
import VoiceCore

/// The voice's codec: Opus, through Apple's own encoder and decoder (AudioToolbox), so no library is added. Packets
/// of 20 ms, mono. Apple's decoder conceals a lost packet when given an empty one (as libopus does); its encoder
/// offers no in-band forward error correction, so a lost packet is only concealed, not recovered.
///
/// Microphone: 16 kHz, about 24 kbit/s. Voice: 24 kHz (the voice's own rate), about 32 kbit/s.
public final class OpusEncoder: @unchecked Sendable {
    public let sampleRate: Double
    public let frameSamples: Int
    private let converter: AVAudioConverter
    private let pcm: AVAudioFormat
    private let opus: AVAudioFormat
    /// Samples waiting for a full frame.
    private var pending: [Float] = []
    private var reportedFailure = false

    public init(sampleRate: Double, bitRate: Int) throws {
        self.sampleRate = sampleRate
        frameSamples = Int(sampleRate * 0.02)
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                                      interleaved: false),
              let opus = OpusFormat.make(sampleRate: sampleRate, frameSamples: frameSamples),
              let converter = AVAudioConverter(from: pcm, to: opus)
        else { throw OpusError.unavailable }
        converter.bitRate = bitRate
        self.pcm = pcm
        self.opus = opus
        self.converter = converter
    }

    /// Encodes whatever full frames `samples` completes; the rest waits for the next call.
    public func encode(_ samples: [Float]) -> [Data] {
        pending += samples
        var packets: [Data] = []
        while pending.count >= frameSamples {
            let frame = Array(pending.prefix(frameSamples))
            pending.removeFirst(frameSamples)
            if let packet = encodeFrame(frame) { packets.append(packet) }
        }
        return packets
    }

    /// The last partial frame, completed with silence (end of an utterance). Empty when nothing is pending.
    public func flush() -> [Data] {
        guard !pending.isEmpty else { return [] }
        let frame = pending + [Float](repeating: 0, count: frameSamples - pending.count)
        pending = []
        return encodeFrame(frame).map { [$0] } ?? []
    }

    /// Forgets what was pending (an utterance stopped in the middle).
    public func reset() {
        pending = []
        converter.reset()
    }

    private func encodeFrame(_ frame: [Float]) -> Data? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(frameSamples)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameSamples)
        frame.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: frameSamples) }
        let output = AVAudioCompressedBuffer(format: opus, packetCapacity: 1,
                                             maximumPacketSize: max(converter.maximumOutputPacketSize, 1500))
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.packetCount > 0, output.byteLength > 0 else {
            if !reportedFailure {
                reportedFailure = true
                DebugLog.log("opus: cannot encode at \(Int(sampleRate)) Hz (status \(status.rawValue), "
                             + "\(output.packetCount) packets, \(error.map { "\($0)" } ?? "no error"))")
            }
            return nil
        }
        return Data(bytes: output.data, count: Int(output.byteLength))
    }
}

public final class OpusDecoder: @unchecked Sendable {
    public let sampleRate: Double
    public let frameSamples: Int
    private let converter: AVAudioConverter
    private let pcm: AVAudioFormat
    private let opus: AVAudioFormat

    public init(sampleRate: Double) throws {
        self.sampleRate = sampleRate
        frameSamples = Int(sampleRate * 0.02)
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                                      interleaved: false),
              let opus = OpusFormat.make(sampleRate: sampleRate, frameSamples: frameSamples),
              let converter = AVAudioConverter(from: opus, to: pcm)
        else { throw OpusError.unavailable }
        self.pcm = pcm
        self.opus = opus
        self.converter = converter
    }

    /// One packet's 20 ms of sound; `nil` for a lost packet, which the decoder conceals from what came before.
    public func decode(_ packet: Data?) -> [Float] {
        let bytes = packet ?? Data()
        let input = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: max(bytes.count, 1))
        bytes.withUnsafeBytes { raw in
            if let base = raw.baseAddress { input.data.copyMemory(from: base, byteCount: bytes.count) }
        }
        input.byteLength = UInt32(bytes.count)
        input.packetCount = 1
        input.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                    mDataByteSize: UInt32(bytes.count))
        guard let output = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(frameSamples * 2)) else {
            return []
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    /// A new stream starts: what the decoder remembers of the previous one is dropped.
    public func reset() {
        converter.reset()
    }
}

public enum OpusError: Error {
    case unavailable
}

enum OpusFormat {
    static func make(sampleRate: Double, frameSamples: Int) -> AVAudioFormat? {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(frameSamples), mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0,
            mReserved: 0)
        return AVAudioFormat(streamDescription: &description)
    }
}

/// The two streams' settings.
public enum LinkAudio {
    /// The microphone, as the engine wants it.
    public static let microphoneRate = 16_000.0
    public static let microphoneBitRate = 24_000
    /// The voice, at Pocket TTS' rate.
    public static let voiceRate = 24_000.0
    public static let voiceBitRate = 32_000
}
