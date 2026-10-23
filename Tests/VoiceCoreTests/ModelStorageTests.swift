import CryptoKit
import Foundation
import Testing

@testable import VoiceCore

/// The models one by one (Settings › Advanced): what is on disk, and deleting one model without touching anything else.
/// Every test works in a folder of its own under the temporary directory, never in the real models folder.
@Suite("Model storage")
struct ModelStorageTests {
    /// A temporary folder holding a "Models" folder, and things next to it that must survive every deletion.
    struct Place {
        let base: URL
        let store: ModelStore
        /// A file next to the models folder, and one inside it that belongs to no model.
        let besideModels: URL
        let strayInModels: URL

        init() throws {
            base = FileManager.default.temporaryDirectory.appending(path: "OpenMaeModelStorage-" + UUID().uuidString)
            store = ModelStore(root: base.appending(path: "Models", directoryHint: .isDirectory))
            try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
            besideModels = base.appending(path: "Memory").appending(path: "memory.md")
            try FileManager.default.createDirectory(at: besideModels.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("- Allergique aux noix\n".utf8).write(to: besideModels)
            strayInModels = store.root.appending(path: "notes.txt")
            try Data("not a model".utf8).write(to: strayInModels)
        }

        func remove() {
            try? FileManager.default.removeItem(at: base)
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

        /// Writes every file of `pack` with its content (a complete, "verified" model).
        func install(_ pack: ModelPack, contents: [String: Data]) throws {
            for file in pack.files {
                let url = store.location(file, in: pack)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try contents[file.path]!.write(to: url)
            }
        }

        /// The first `count` bytes of `file`, as a download interrupted in the middle leaves them.
        func partial(_ file: ModelFile, _ data: Data, count: Int) throws {
            try FileManager.default.createDirectory(at: store.incompleteDirectory, withIntermediateDirectories: true)
            try data.prefix(count).write(to: store.partialLocation(file))
        }

        /// Files of the real catalog's sizes without their bytes (sparse files): the store takes a file of the right size
        /// under its final name as verified.
        func installSparse(_ pack: ModelPack) throws {
            for file in pack.files {
                let url = store.location(file, in: pack)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: UInt64(file.size))
                try handle.close()
            }
        }
    }

    static func data(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A small model of two files, under `id`.
    static func pack(_ id: String, role: ModelRole = .languageModel, seed: UInt8) -> (ModelPack, [String: Data]) {
        let contents = ["config.json": data(2_000, seed: seed), "weights/model.safetensors": data(60_000, seed: seed + 1)]
        let files = contents.keys.sorted().map { ModelFile($0, Int64(contents[$0]!.count), sha256(contents[$0]!)) }
        return (ModelPack(id: id, role: role, displayName: "Model \(id)", repository: "tests/\(id)", revision: "0123abcd",
                          license: "MIT", files: files), contents)
    }

    // MARK: - What is on disk

    @Test func eachModelOnDiskIsListedWithItsSizeWhatIsMissingAndWhetherItIsInUse() throws {
        let place = try Place()
        defer { place.remove() }
        let (speech, speechData) = Self.pack("speech", role: .speechRecognition, seed: 1)
        let (small, smallData) = Self.pack("small", seed: 3)
        let (big, bigData) = Self.pack("big", seed: 5)
        let (absent, _) = Self.pack("absent", seed: 7)
        try place.install(speech, contents: speechData)
        try place.install(small, contents: smallData)
        // "big" only has the beginning of one file, in the partial downloads.
        let weights = big.files.first { $0.path.hasPrefix("weights") }!
        try place.partial(weights, bigData[weights.path]!, count: 10_000)

        let storage = place.store.storage(inUse: ["speech", "big"], catalog: [speech, small, big, absent])
        #expect(storage.models.map(\.id) == ["speech", "small", "big"])  // the catalog's order, nothing absent
        #expect(storage.models.map(\.inUse) == [true, false, true])
        #expect(storage.models.map(\.role) == [.speechRecognition, .languageModel, .languageModel])
        #expect(storage.models[1].displayName == "Model small")
        #expect(storage.models[0].missingBytes == 0 && storage.models[1].missingBytes == 0)
        #expect(storage.models[2].missingBytes == big.totalBytes - 10_000)
        for model in storage.models { #expect(model.bytes > 0, "\(model.id)") }
        #expect(storage.models[1].bytes == place.store.usedBytes(small))
        #expect(storage.usedBytes >= storage.models.reduce(0) { $0 + $1.bytes })
        #expect(storage.folder == place.store.root.path)
    }

    @Test func aTierIsCompleteWhenEachOfItsModelsIs() throws {
        let (speech, _) = Self.pack("speech", role: .speechRecognition, seed: 1)
        let (small, _) = Self.pack("small", seed: 3)
        let (big, _) = Self.pack("big", seed: 5)
        func model(_ pack: ModelPack, missing: Int64) -> ModelStorage.Model {
            ModelStorage.Model(id: pack.id, role: pack.role, displayName: pack.displayName, bytes: 1_000,
                               missingBytes: missing, inUse: false)
        }
        let storage = ModelStorage(usedBytes: 3_000, models: [model(speech, missing: 0), model(small, missing: 0),
                                                              model(big, missing: 500)], folder: "/tmp")
        #expect(storage.hasComplete([speech, small]))
        #expect(!storage.hasComplete([speech, big]))  // partly downloaded
        #expect(!storage.hasComplete([speech, Self.pack("absent", seed: 7).0]))
        #expect(!storage.hasComplete([]))
    }

    @Test func storageSentByAnEarlierEngineStillReads() throws {
        let old = #"{"usedBytes":17520000000,"unusedBytes":0,"folder":"/Users/me/Models"}"#
        let storage = try JSONDecoder().decode(ModelStorage.self, from: Data(old.utf8))
        #expect(storage.usedBytes == 17_520_000_000 && storage.models.isEmpty && storage.folder == "/Users/me/Models")
        let model = ModelStorage.Model(id: "gemma-4-e4b-it-4bit", role: .languageModel, displayName: "Gemma 4 E4B",
                                       bytes: 5_180_000_000, missingBytes: 0, inUse: false)
        let new = ModelStorage(usedBytes: 5_180_000_000, models: [model], folder: "/Users/me/Models")
        let encoded = try JSONEncoder().encode(new)
        #expect(try JSONDecoder().decode(ModelStorage.self, from: encoded) == new)
    }

    // MARK: - Deleting one model

    @Test func deletingAModelRemovesItsFolderAndItsPartialDownloadsOnly() throws {
        let place = try Place()
        defer { place.remove() }
        let (small, smallData) = Self.pack("small", seed: 3)
        let (big, bigData) = Self.pack("big", seed: 5)
        try place.install(small, contents: smallData)
        try place.install(big, contents: bigData)
        // A newer revision of one of "small"'s files was being downloaded, and so was one of "big"'s.
        let smallWeights = small.files.first { $0.path.hasPrefix("weights") }!
        let bigWeights = big.files.first { $0.path.hasPrefix("weights") }!
        var other = smallWeights
        other.sha256 = Self.sha256(Self.data(10, seed: 99))
        try place.partial(bigWeights, bigData[bigWeights.path]!, count: 5_000)
        try place.partial(other, Self.data(10, seed: 99), count: 10)

        try place.store.delete(small)
        #expect(!place.exists(place.store.folder(small)))
        #expect(place.store.storage(inUse: [], catalog: [small, big]).models.map(\.id) == ["big"])
        // Everything else is still there: the other model and its partial download, the stray file, the partial
        // download of a file that is not one of "small"'s, what is next to the models folder.
        #expect(place.store.missingFiles(big).isEmpty)
        #expect(place.exists(place.store.partialLocation(bigWeights)))
        #expect(place.exists(place.store.partialLocation(other)))
        #expect(place.exists(place.strayInModels))
        #expect(place.exists(place.besideModels))

        try place.store.delete(big)
        #expect(!place.exists(place.store.folder(big)))
        #expect(!place.exists(place.store.partialLocation(bigWeights)))
        #expect(place.store.presentPacks(of: [small, big]).isEmpty)
        #expect(place.exists(place.strayInModels) && place.exists(place.besideModels))
        // Deleting a model that is not there does nothing.
        try place.store.delete(big)
    }

    @Test func aModelWhoseNameWouldLeaveTheModelsFolderIsRefused() throws {
        let place = try Place()
        defer { place.remove() }
        let (small, smallData) = Self.pack("small", seed: 3)
        try place.install(small, contents: smallData)
        try place.partial(small.files[0], smallData[small.files[0].path]!, count: 100)
        for id in ["", ".", "..", "../Memory", "Models/../..", ".incomplete", "a/b", "/", "x\\y", "a:b"] {
            var pack = small
            pack.id = id
            #expect(throws: ModelStore.OutsideModelsFolder.self, "\(id)") { try place.store.delete(pack) }
        }
        // A file's fingerprint names its partial download: one that would leave the folder is refused too, and nothing
        // of the model is deleted meanwhile.
        for fingerprint in ["../notes.txt", "../../Memory/memory.md", "", ".."] {
            var pack = small
            pack.files[1].sha256 = fingerprint
            #expect(throws: ModelStore.OutsideModelsFolder.self, "\(fingerprint)") { try place.store.delete(pack) }
        }
        #expect(place.store.missingFiles(small).isEmpty)
        #expect(place.exists(place.store.partialLocation(small.files[0])))
        #expect(place.exists(place.strayInModels) && place.exists(place.besideModels))
        #expect(place.exists(place.base.appending(path: "Memory")))
    }

    /// A tier whose language model was deleted has something to download again: the engine's start-up then shows the
    /// first-launch screen (`setupNeeded`) for it, with the model's size, instead of loading it.
    @Test func aTierWhoseModelWasDeletedHasToDownloadItAgain() throws {
        let place = try Place()
        defer { place.remove() }
        let standard = ModelCatalog.packs(for: .standard)
        let minimum = ModelCatalog.languageModel(for: .minimum)!
        for pack in standard + [minimum] { try place.installSparse(pack) }
        #expect(place.store.isComplete(standard))
        #expect(place.store.storage(inUse: []).hasComplete(standard))

        let e4b = ModelCatalog.languageModel(for: .standard)!
        try place.store.delete(e4b)
        #expect(!place.store.isComplete(standard))
        #expect(place.store.bytesToDownload(standard) == e4b.totalBytes)
        let storage = place.store.storage(inUse: Set(ModelCatalog.packs(for: .minimum).map(\.id)))
        #expect(!storage.hasComplete(standard))
        #expect(storage.hasComplete(ModelCatalog.packs(for: .minimum)))
        #expect(storage.models.map(\.id) == [ModelCatalog.speechRecognition.id, ModelCatalog.voice.id, minimum.id])
        let allInUse = storage.models.allSatisfy { $0.inUse }
        #expect(allInUse)
    }
}
