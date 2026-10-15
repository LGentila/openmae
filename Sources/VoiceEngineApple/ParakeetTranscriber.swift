import FluidAudio
import Foundation
import VoiceCore

/// Speech-to-text with NVIDIA Parakeet TDT 0.6B v3 (CC-BY-4.0, 25 European languages) on the
/// Neural Engine, through FluidAudio. Measured on the reference Mac: 5.8 % word errors on French
/// FLEURS, a 3–5 s phrase in 0.1–0.15 s. It also transcribes English without any setting.
///
/// The whole utterance is transcribed once the user stops (or pauses): at this speed a streaming
/// recogniser would not reduce latency, and full-utterance decoding is more accurate.
public actor ParakeetTranscriber: Transcriber {
    private let asr: AsrManager

    private init(asr: AsrManager) { self.asr = asr }

    /// Loads the models from `directory` (FluidAudio's default cache when nil, downloading if absent).
    public static func load(directory: URL? = nil) async throws -> ParakeetTranscriber {
        let models = try await AsrModels.downloadAndLoad(to: directory, version: .v3)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        let transcriber = ParakeetTranscriber(asr: asr)
        _ = try await transcriber.transcribe([Float](repeating: 0, count: 16_000))  // warm-up
        return transcriber
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        // Parakeet needs about one second of audio; pad very short utterances with silence.
        let minimum = Int(EngineAudio.inputSampleRate)
        let audio = samples.count < minimum ? samples + [Float](repeating: 0, count: minimum - samples.count) : samples
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        return try await asr.transcribe(audio, decoderState: &state).text
    }
}
