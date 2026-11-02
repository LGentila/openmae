// The language model's files rewritten so that its weights can be used from them (`AlignedSafetensors`,
// `FileBackedWeights`):
//
//   voice-cli align-model [--tier minimum|standard|comfort|max] [--models <folder>] [--status]
//       does to the tier's language model what the app does before loading it (`FileBackedWeights.prepare`): rewrites its
//       files once, in place, every tensor on a page boundary, each file keeping its size; or finishes a rewrite stopped
//       half-way. --models: that models folder instead of the app's. --status: only says what the folder holds. Every
//       command then uses the weights from the files (VOICE_FILE_BACKED_WEIGHTS=0: as before).

import Foundation
import VoiceCore
import VoiceEngineApple

func runAlignModel(_ o: Options, arguments: [String]) async throws {
    let tier = try tierOption(o)
    let store = modelStore(o)
    guard let pack = ModelCatalog.languageModel(for: tier) else { throw CLIError("no language model for this tier") }
    guard store.isComplete([pack]) else {
        throw CLIError("\(pack.displayName) is not complete in \(store.root.path): "
                       + "“voice-cli download --tier \(tier.rawValue)” first")
    }
    let folder = store.folder(pack)
    print("\(pack.displayName): \(folder.path)")
    print("now: \(describe(AlignedSafetensors.state(of: folder))) · free space \(gb(store.availableBytes()))")
    guard !arguments.contains("--status") else { return }
    let clock = ContinuousClock()
    let start = clock.now
    let outcome = await FileBackedWeights.prepare(pack, in: store)
    print("\(describe(outcome)) in \(clock.now - start) · free space \(gb(store.availableBytes()))")
    if let manifest = AlignedSafetensors.manifest(in: folder) {
        for file in manifest.files {
            let tensors = file.tensors.map { tensors in
                let received = tensors.filter { $0.source != file.path }
                return " · \(tensors.count) tensors" + (received.isEmpty ? "" : ", \(received.count) from "
                    + Set(received.map(\.source)).sorted().joined(separator: ", "))
            } ?? ""
            print("  \(file.path): \(file.size) bytes\(tensors) · sha256 \(file.sha256 ?? "not written yet")")
        }
        print("left out: \(manifest.dropped.count) tensors, \(gb(Int64(manifest.droppedBytes)))")
    }
    print("complete for the models folder: \(store.isComplete([pack]) ? "yes" : "NO")")
}

private func describe(_ state: AlignedSafetensors.FolderState) -> String {
    switch state {
    case .original: "never rewritten"
    case .aligning: "a rewrite stopped half-way"
    case .aligned: "rewritten: the weights are used from the files"
    case .leftAsIs(let why): "left as it is (\(why))"
    }
}

private func describe(_ outcome: AlignedSafetensors.Outcome) -> String {
    switch outcome {
    case .alreadyAligned: "rewritten already"
    case .aligned: "rewritten"
    case .leftAsIs(let why): "left as it is: \(why)"
    }
}
