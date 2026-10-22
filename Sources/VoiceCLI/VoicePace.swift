// voice-cli voice-pace — the voice alone, without the pipeline: five-sentence answers, each said in one utterance as
// in a turn, one after the other (2 s apart), and the voice's time per 80 ms frame by second since the answer's first
// frame. With the language model loaded, its memory is taken as in the app; `--model-writes n` has it also write an
// answer of n pieces at the start of each one, as in a turn (it shares the GPU meanwhile).
//
//   voice-cli voice-pace [--repeats 5] [--with-llm [--model-writes n]] [--tts cpu] [--fingerprint] [options]
//
// --fingerprint: two sentences said twice with a fixed seed, and a fingerprint of all their samples: the same in two
// builds, they produced the same sound.
//
// On the reference Mac (M1 Pro, 32 GB), 2026-10-22: the French voice alone, 39 ms per frame throughout; with Gemma 4
// 26B loaded, idle, 40 or 55 to 58 ms depending on the second (the Mac's free memory down to 0.1 to 1.3 GB); with E4B
// or E2B loaded instead, 39 ms throughout; while a model writes, 67 to 80 ms.

import FluidAudio
import Foundation
import VoiceCore
import VoiceEngineApple

func runVoicePace(_ o: Options) async throws {
    let store = ModelStore()
    if o.fingerprint {
        try await printVoiceFingerprints(store)
        return
    }
    let voice = PocketSpeechSynthesizer(computeUnits: o.ttsOnCPU ? .uniform(.cpuOnly) : .avoidNeuralEngine, store: store)
    try await voice.preload([.french])
    var llm: MLXChatModel?
    if o.withLLM {
        guard let languageModel = ModelCatalog.languageModel(for: try tierOption(o)) else {
            throw CLIError("no language model for this tier")
        }
        let url = o.llm.map { URL(fileURLWithPath: $0) } ?? store.folder(languageModel)
        llm = try await MLXChatModel.load(directory: url)
        print("loaded: \(url.lastPathComponent)" + String(format: ", memory %.2f GB", ProcessMemory.footprintGB))
    }
    // An answer as Gemma 4 26B writes them in voice-gaps.
    let sentences = [
        "La mer est salée à cause des minéraux que les rivières y apportent.",
        "En coulant sur les roches, l'eau de pluie dissout des sels comme le sodium et le chlorure.",
        "Les rivières transportent ensuite ces sels jusqu'à l'océan.",
        "Quand l'eau de mer s'évapore sous le soleil, le sel reste dans l'océan.",
        "Au fil des millions d'années, le sel s'est donc accumulé dans les mers.",
    ]
    let questions = ["Raconte-moi une longue histoire de pirates.", "Explique-moi en détail comment marche un volcan.",
                     "Raconte-moi l'histoire de la tour Eiffel en détail."]
    let clock = ContinuousClock()
    // One-second intervals of time since the answer's first frame, the last one without an end.
    let seconds = 13
    let name = { (s: Int) in s + 1 < seconds ? "\(s)" : "\(s)+" }
    let cell = { (values: [Double]) in median(values).map { String(format: "%.0f", $0) } ?? "—" }
    var pooled = [[Double]](repeating: [], count: seconds)
    for round in 1...(o.repeats ?? 5) {
        try? await clock.sleep(for: .seconds(2))
        let start = clock.now
        let writing = llm.map { model in
            Task {
                guard let pieces = o.modelWrites, pieces > 0 else { return (pieces: 0, seconds: 0.0) }
                var written = 0
                do {
                    for try await output in model.reply(to: [ChatMessage(.user, questions[round % questions.count])]) {
                        if case .text = output { written += 1 }
                        if written >= pieces { break }
                    }
                } catch {}
                return (pieces: written, seconds: (clock.now - start).seconds)
            }
        }
        let stream = try await voice.startUtterance(language: .french)
        for sentence in sentences { stream.enqueue(sentence) }
        stream.finish()
        var frames: [(at: ContinuousClock.Instant, text: Int?)] = []
        for try await chunk in stream.audio { frames.append((clock.now, chunk.text)) }
        let written = await writing?.value
        guard let first = frames.first?.at, let last = frames.last?.at else { continue }
        // The time between two frames of the same sentence (the first frame of each one waits for its text's reading).
        var cells = [[Double]](repeating: [], count: seconds)
        for i in frames.indices.dropFirst() where frames[i].text == frames[i - 1].text {
            cells[min(Int((frames[i].at - first).seconds), seconds - 1)].append((frames[i].at - frames[i - 1].at)
                .seconds * 1000)
        }
        for s in 0..<seconds { pooled[s] += cells[s] }
        let total = (last - first).seconds
        print(String(format: "answer %d: %d frames in %.2f s (%.0f ms per frame), the first %.2f s after the start",
                     round, frames.count, total, total * 1000 / Double(max(1, frames.count - 1)),
                     (first - start).seconds)
              + (written.map { String(format: "; the model wrote %d pieces, done %.1f s after the start", $0.pieces,
                                      $0.seconds) } ?? ""))
        print("  ms per frame by second since the first frame: "
              + (0..<seconds).map { "\(name($0)): \(cell(cells[$0]))" }.joined(separator: "  "))
    }
    print("\n=== Summary: median ms per frame by second since the answer's first frame ===")
    print((0..<seconds).map { "\(name($0)): \(cell(pooled[$0])) (n=\(pooled[$0].count))" }.joined(separator: "  "))
}

/// `--fingerprint`: two sentences said twice with a fixed seed, and a fingerprint (FNV-1a) of all their samples.
private func printVoiceFingerprints(_ store: ModelStore) async throws {
    let manager = PocketTtsManager(defaultVoice: PocketSpeechSynthesizer.voices[.french]!, language: .french24L,
                                   directory: store.voiceBaseFolder, computeUnits: .avoidNeuralEngine)
    try await manager.initialize()
    for round in 1...2 {
        let session = try await manager.makeSession(voice: PocketSpeechSynthesizer.voices[.french], seed: 42)
        session.enqueue("La mer est salée à cause des minéraux que les rivières y apportent.")
        session.enqueue("Les rivières transportent ensuite ces sels jusqu'à l'océan.")
        session.finish()
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var count = 0
        for try await frame in session.frames {
            for sample in frame.samples { hash = (hash ^ UInt64(sample.bitPattern)) &* 0x100_0000_01b3 }
            count += frame.samples.count
        }
        print(String(format: "fingerprint %d: %d samples, %016llx", round, count, hash))
    }
}
