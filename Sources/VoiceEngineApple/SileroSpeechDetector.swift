@preconcurrency import CoreML
import Foundation
import VoiceCore

/// Voice activity detection with Silero VAD v6.2.1 (MIT), CoreML export by aufklarer (MIT).
///
/// Why this export and not FluidAudio's own VAD: FluidAudio's model works on 256 ms windows, which
/// adds up to a quarter of a second to end-of-speech detection. This one takes the original 32 ms
/// frames and exposes the LSTM state, measured at ~0.1 ms per frame on the CPU.
public actor SileroSpeechDetector: SpeechDetector {
    public nonisolated let chunkSize = 512  // 32 ms at 16 kHz

    private static let contextSize = 64
    private let model: MLModel
    private var hidden: MLMultiArray
    private var cell: MLMultiArray
    private var context: [Float]

    /// `modelURL` points to `silero_vad.mlmodelc`.
    public init(modelURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly  // tiny model: the CPU beats any dispatch to ANE/GPU
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        hidden = try MLMultiArray(shape: [1, 1, 128], dataType: .float16)
        cell = try MLMultiArray(shape: [1, 1, 128], dataType: .float16)
        context = [Float](repeating: 0, count: Self.contextSize)
        Self.zero(hidden)
        Self.zero(cell)
    }

    public func reset() {
        Self.zero(hidden)
        Self.zero(cell)
        context = [Float](repeating: 0, count: Self.contextSize)
    }

    public func speechProbability(_ chunk: [Float]) throws -> Float {
        precondition(chunk.count == chunkSize, "Silero expects \(chunkSize) samples")
        let input = context + chunk
        let audio = try MLMultiArray(shape: [1, 1, NSNumber(value: input.count)], dataType: .float16)
        audio.withUnsafeMutableBufferPointer(ofType: Float16.self) { buffer, _ in
            for i in 0..<input.count { buffer[i] = Float16(input[i]) }
        }
        let features = try MLDictionaryFeatureProvider(dictionary: ["audio": audio, "h": hidden, "c": cell])
        let out = try model.prediction(from: features)
        hidden = out.featureValue(for: "h_out")!.multiArrayValue!
        cell = out.featureValue(for: "c_out")!.multiArrayValue!
        context = Array(chunk.suffix(Self.contextSize))
        return out.featureValue(for: "probability")!.multiArrayValue![0].floatValue
    }

    private static func zero(_ array: MLMultiArray) {
        for i in 0..<array.count { array[i] = 0 }
    }
}
