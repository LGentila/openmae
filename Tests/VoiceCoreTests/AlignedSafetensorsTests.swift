import CryptoKit
import Foundation
import Testing

@testable import VoiceCore

/// A language model's files rewritten in place so that its weights can be used from them (`AlignedSafetensors`): on
/// small synthetic models, in folders of their own under the temporary directory. What mlx-swift-lm's loader would read
/// (`loaderView`) must stay the model's weights at every moment, a rewrite killed half-way included.
@Suite("Aligned safetensors")
struct AlignedSafetensorsTests {
    struct Tensor {
        var name: String
        var dtype: String
        var shape: [Int]
        var data: Data

        init(_ name: String, _ dtype: String, _ shape: [Int], seed: Int) {
            self.name = name
            self.dtype = dtype
            self.shape = shape
            let count = shape.reduce(AlignedSafetensors.elementSize(dtype)!, *)
            var state = UInt64(truncatingIfNeeded: seed) &* 6364136223846793005 &+ 1442695040888963407
            data = Data((0 ..< count).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return UInt8(truncatingIfNeeded: state >> 33)
            })
        }
    }

    /// A safetensors file as MLX writes one: its header, then every tensor's data, back to back.
    static func safetensors(_ tensors: [Tensor], metadata: [String: String] = ["format": "mlx"]) -> Data {
        var entries: [String] = []
        if !metadata.isEmpty {
            entries.append("\"__metadata__\":{" + metadata.sorted { $0.key < $1.key }
                .map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",") + "}")
        }
        var offset = 0
        for tensor in tensors {
            entries.append("\"\(tensor.name)\":{\"dtype\":\"\(tensor.dtype)\",\"shape\":["
                + tensor.shape.map(String.init).joined(separator: ",")
                + "],\"data_offsets\":[\(offset),\(offset + tensor.data.count)]}")
            offset += tensor.data.count
        }
        let json = Data(("{" + entries.joined(separator: ",") + "}").utf8)
        var file = withUnsafeBytes(of: UInt64(json.count).littleEndian) { Data($0) }
        file.append(json)
        for tensor in tensors { file.append(tensor.data) }
        return file
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A model's folder in a models folder of its own, its pack (the files' sizes and SHA-256), and its tensors.
    struct Model {
        let base: URL
        let store: ModelStore
        let pack: ModelPack
        let tensors: [String: Data]
        /// The tensors the model keeps (not its vision encoder's).
        let kept: Set<String>
        var folder: URL { store.folder(pack) }

        init(files: [String: [Tensor]], index: Bool) throws {
            base = FileManager.default.temporaryDirectory.appending(path: "OpenMaeAligned-" + UUID().uuidString)
            store = ModelStore(root: base.appending(path: "Models", directoryHint: .isDirectory))
            let id = "synthetic-model"
            let folder = store.root.appending(path: id, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var contents: [String: Data] = ["config.json": Data("{\"model_type\":\"gemma4\"}".utf8)]
            var tensors: [String: Data] = [:]
            var weightMap: [String: String] = [:]
            for (name, list) in files {
                contents[name] = Self.safetensorsFile(list)
                for tensor in list {
                    tensors[tensor.name] = tensor.data
                    weightMap[tensor.name] = name
                }
            }
            if index {
                let object: [String: Any] = ["metadata": ["total_size": tensors.values.reduce(0) { $0 + $1.count }],
                                             "weight_map": weightMap]
                contents[AlignedSafetensors.indexName] = try JSONSerialization.data(
                    withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            }
            for (name, data) in contents { try data.write(to: folder.appending(path: name)) }
            pack = ModelPack(id: id, role: .languageModel, displayName: "Synthetic", repository: "tests/synthetic",
                             revision: "0123abcd", license: "none",
                             files: contents.keys.sorted().map { ModelFile($0, Int64(contents[$0]!.count),
                                                                           AlignedSafetensorsTests.sha256(contents[$0]!)) })
            self.tensors = tensors
            kept = Set(tensors.keys.filter { !$0.hasPrefix("vision_tower.") })
        }

        static func safetensorsFile(_ tensors: [Tensor]) -> Data { AlignedSafetensorsTests.safetensors(tensors) }

        func remove() { try? FileManager.default.removeItem(at: base) }

        func align(availableBytes: Int64? = 100_000_000_000, interruption: ((AlignedSafetensors.Step) -> Bool)? = nil)
            -> AlignedSafetensors.Outcome
        {
            AlignedSafetensors.align(folder: folder, catalog: pack.files, revision: pack.revision, keeping: kept,
                                     availableBytes: { availableBytes }, shouldStop: { false }, progress: { _ in },
                                     interruption: interruption)
        }

        /// A rewrite stopped half-way, gone on with as the app does: without the tensors the model keeps (the manifest
        /// has them).
        func resume() -> AlignedSafetensors.Outcome {
            AlignedSafetensors.align(folder: folder, catalog: pack.files, revision: pack.revision, keeping: nil,
                                     availableBytes: { 100_000_000_000 })
        }

        /// Hidden files left in the folder (a temporary file, a manifest not yet named).
        func leftovers() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".") }
        }

        /// What mlx-swift-lm's loader reads: the files the index names (else `model*.safetensors`), every tensor where
        /// its header says, a later file's over an earlier one's.
        func loaderView() throws -> [String: Data] {
            var view: [String: Data] = [:]
            for url in try AlignedSafetensors.weightFiles(in: folder) {
                let data = try Data(contentsOf: url)
                for tensor in try AlignedSafetensors.header(of: url).tensors {
                    view[tensor.name] = Data(data[tensor.offset ..< tensor.offset + tensor.byteCount])
                }
            }
            return view
        }

        /// The index as mlx-swift-lm decodes it (only its weight map), when there is one.
        func indexWeightMap() throws -> [String: String]? {
            struct Index: Decodable {
                let weightMap: [String: String]
                enum CodingKeys: String, CodingKey { case weightMap = "weight_map" }
            }
            let url = folder.appending(path: AlignedSafetensors.indexName)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try JSONDecoder().decode(Index.self, from: Data(contentsOf: url)).weightMap
        }

        /// Loadable as the model by mlx-swift-lm's loader, and complete for the models folder, as it is now.
        func expectLoadable(_ moment: String) throws {
            let view = try loaderView()
            for name in kept {
                #expect(view[name] == tensors[name], "\(moment): tensor \(name)")
            }
            #expect(store.missingFiles(pack).isEmpty, "\(moment): every file at its catalogued size")
            #expect(try store.corruptedFiles(pack).isEmpty, "\(moment): no file taken as damaged")
            _ = try indexWeightMap()  // decodes
        }

        /// Rewritten: every file at its size, every tensor kept at a boundary with its bytes, none left out kept.
        func expectAligned() throws {
            guard case .aligned(let manifest) = AlignedSafetensors.state(of: folder) else {
                Issue.record("not aligned: \(AlignedSafetensors.state(of: folder))")
                return
            }
            try expectLoadable("aligned")
            let view = try loaderView()
            #expect(Set(view.keys) == kept, "only the tensors the model keeps")
            for url in try AlignedSafetensors.weightFiles(in: folder) {
                let header = try AlignedSafetensors.header(of: url)
                let size = Int(ModelStore.size(of: url)!)
                #expect(AlignedSafetensors.misalignment(header, fileSize: size, file: url.lastPathComponent) == nil)
                #expect(header.dataStart % AlignedSafetensors.alignment == 0)
                for tensor in header.tensors where tensor.byteCount > 0 {
                    #expect(tensor.offset % AlignedSafetensors.alignment == 0, "\(tensor.name) on a boundary")
                }
            }
            for file in manifest.files {
                let data = try Data(contentsOf: folder.appending(path: file.path))
                #expect(data.count == file.size)
                #expect(Self.digest(data) == file.sha256, "\(file.path): the manifest's SHA-256")
                #expect(pack.files.first { $0.path == file.path }?.sha256 == file.originalSHA256)
            }
            #expect(Set(manifest.dropped) == Set(tensors.keys).subtracting(kept))
            let hidden = try leftovers()
            #expect(hidden.isEmpty, "no temporary file left: \(hidden)")
            if let map = try indexWeightMap() {
                #expect(Set(map.keys) == kept)
                for (name, file) in map {
                    let header = try AlignedSafetensors.header(of: folder.appending(path: file))
                    #expect(header.tensors.contains { $0.name == name }, "the index says where \(name) is")
                }
                let index = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: folder.appending(path: AlignedSafetensors.indexName))) as? [String: Any]
                let total = (index?["metadata"] as? [String: Any])?["total_size"] as? Int
                #expect(total == kept.reduce(0) { $0 + tensors[$1]!.count })
            }
        }

        static func digest(_ data: Data) -> String { AlignedSafetensorsTests.sha256(data) }
    }

    /// One file, with a vision encoder to leave out, a scalar, odd sizes, a tensor of whole pages, and one without data.
    static func singleFile() -> [String: [Tensor]] {
        ["model.safetensors": [
            Tensor("language_model.embed.weight", "U32", [300, 50], seed: 1),
            Tensor("language_model.layers.0.norm.weight", "BF16", [1000], seed: 2),
            Tensor("language_model.layers.0.scalar", "BF16", [1], seed: 3),
            Tensor("vision_tower.patch.weight", "F32", [200, 300], seed: 4),
            Tensor("language_model.layers.0.proj.weight", "U8", [4, 16384], seed: 5),
            Tensor("language_model.layers.0.empty", "BF16", [0, 8], seed: 6),
            Tensor("vision_tower.norm.weight", "BF16", [700], seed: 7),
            Tensor("language_model.layers.1.proj.scales", "BF16", [333, 7], seed: 8),
        ]]
    }

    /// Two files: the first has nothing to leave out and no room for its padding, the second a vision encoder.
    static func twoFiles() -> [String: [Tensor]] {
        ["model-00001-of-00002.safetensors": [
            Tensor("language_model.layers.0.big.weight", "U8", [1_000_000], seed: 11),
            Tensor("language_model.layers.0.scalar", "BF16", [1], seed: 12),
            Tensor("language_model.layers.0.norm.weight", "BF16", [150], seed: 13),
            Tensor("language_model.layers.0.small.weight", "U32", [1250], seed: 14),
        ],
         "model-00002-of-00002.safetensors": [
            Tensor("language_model.layers.1.weight", "U8", [500_000], seed: 21),
            Tensor("vision_tower.encoder.weight", "F32", [900_000], seed: 22),
            Tensor("language_model.layers.1.norm.weight", "BF16", [150], seed: 23),
         ]]
    }

    @Test func alignsAFileInPlaceKeepingItsSize() throws {
        let model = try Model(files: Self.singleFile(), index: true)
        defer { model.remove() }
        let original = try AlignedSafetensors.header(of: model.folder.appending(path: "model.safetensors"))
        #expect(AlignedSafetensors.misalignment(original, fileSize: Int(model.pack.files.first { $0.path == "model.safetensors" }!.size),
                                                file: "model.safetensors") != nil)
        try model.expectLoadable("before")
        #expect(AlignedSafetensors.state(of: model.folder) == .original)

        #expect(model.align() == .aligned)
        try model.expectAligned()
        let header = try AlignedSafetensors.header(of: model.folder.appending(path: "model.safetensors"))
        let empty = try #require(header.tensors.first { $0.name == "language_model.layers.0.empty" })
        #expect(empty.byteCount == 0 && empty.shape == [0, 8], "a tensor without data keeps its place in the header")
        #expect(model.align() == .alreadyAligned)
    }

    @Test func aFileWithoutRoomHandsATensorToOneWithRoom() throws {
        let model = try Model(files: Self.twoFiles(), index: true)
        defer { model.remove() }
        let first = "model-00001-of-00002.safetensors"
        let second = "model-00002-of-00002.safetensors"
        let plan = try AlignedSafetensors.plan(folder: model.folder, catalog: model.pack.files, revision: nil,
                                               keeping: model.kept)
        #expect(plan.files.map(\.path) == [second, first, AlignedSafetensors.indexName], "the receiving file first")
        let moved = plan.files[0].tensors!.filter { $0.source == first }.map(\.name)
        #expect(moved == ["language_model.layers.0.big.weight"], "the smallest tensor that frees enough")

        #expect(model.align() == .aligned)
        try model.expectAligned()
        #expect(try model.indexWeightMap()?["language_model.layers.0.big.weight"] == second)
    }

    @Test func withoutAModelIndex() throws {
        let model = try Model(files: Self.twoFiles(), index: false)
        defer { model.remove() }
        #expect(model.align() == .aligned)
        try model.expectAligned()
    }

    @Test(arguments: [
        AlignedSafetensors.Step.planned,
        .written("model-00002-of-00002.safetensors"), .recorded("model-00002-of-00002.safetensors"),
        .renamed("model-00002-of-00002.safetensors"),
        .written("model-00001-of-00002.safetensors"), .recorded("model-00001-of-00002.safetensors"),
        .renamed("model-00001-of-00002.safetensors"),
        .written(AlignedSafetensors.indexName), .recorded(AlignedSafetensors.indexName),
        .renamed(AlignedSafetensors.indexName),
    ])
    func aRewriteKilledHalfWayIsFinishedNextTime(at step: AlignedSafetensors.Step) throws {
        let model = try Model(files: Self.twoFiles(), index: true)
        defer { model.remove() }
        #expect(model.align { $0 == step } == .leftAsIs("interrupted"))
        guard case .aligning = AlignedSafetensors.state(of: model.folder) else {
            Issue.record("after \(step): \(AlignedSafetensors.state(of: model.folder))")
            return
        }
        try model.expectLoadable("killed after \(step)")
        #expect(model.resume() == .aligned)
        try model.expectAligned()
    }

    @Test func stopsWhenAskedAndGoesOnNextTime() throws {
        let model = try Model(files: Self.twoFiles(), index: true)
        defer { model.remove() }
        var asked = 0
        let outcome = AlignedSafetensors.align(
            folder: model.folder, catalog: model.pack.files, revision: nil, keeping: model.kept,
            availableBytes: { 100_000_000_000 }, shouldStop: {
                asked += 1
                return asked > 1  // the app quits while the first file is written
            })
        #expect(outcome == .leftAsIs("stopped"))
        #expect(try model.leftovers().isEmpty, "its temporary file removed")
        try model.expectLoadable("stopped")
        #expect(model.resume() == .aligned)
        try model.expectAligned()
    }

    @Test func leavesAModelThatCannotKeepItsSizes() throws {
        let files = ["model.safetensors": [Tensor("language_model.a", "BF16", [300], seed: 1),
                                           Tensor("language_model.b", "U32", [5000], seed: 2)]]
        let model = try Model(files: files, index: false)
        defer { model.remove() }
        let before = try Data(contentsOf: model.folder.appending(path: "model.safetensors"))
        guard case .leftAsIs = model.align() else { Issue.record("rewritten"); return }
        #expect(try Data(contentsOf: model.folder.appending(path: "model.safetensors")) == before)
        #expect(AlignedSafetensors.state(of: model.folder) == .original, "no manifest written")
    }

    @Test func leavesTheModelWithoutRoomOnTheDisk() throws {
        let model = try Model(files: Self.singleFile(), index: true)
        defer { model.remove() }
        guard case .leftAsIs(let why) = model.align(availableBytes: 500_000_000) else { Issue.record("rewritten"); return }
        #expect(why.hasPrefix("not enough free space"))
        #expect(AlignedSafetensors.state(of: model.folder) == .original)
        try model.expectLoadable("no room")
        #expect(model.align() == .aligned, "with room, the next time")
        try model.expectAligned()
    }

    @Test func stopsWhereItIsWhenRoomRunsOutHalfWay() throws {
        let model = try Model(files: Self.twoFiles(), index: true)
        defer { model.remove() }
        var asked = 0
        let outcome = AlignedSafetensors.align(
            folder: model.folder, catalog: model.pack.files, revision: nil, keeping: model.kept,
            availableBytes: {
                asked += 1
                return asked <= 2 ? 100_000_000_000 : 0  // the plan's check and the first file's, not the second's
            }, shouldStop: { false }, progress: { _ in }, interruption: nil)
        guard case .leftAsIs(let why) = outcome, why.hasPrefix("not enough free space") else {
            Issue.record("\(outcome)")
            return
        }
        try model.expectLoadable("the second file without room")
        #expect(model.align() == .aligned)
        try model.expectAligned()
    }

    @Test func givesUpOnAFileThatIsNeitherTheCataloguedOneNorTheRewrittenOne() throws {
        let model = try Model(files: Self.twoFiles(), index: true)
        defer { model.remove() }
        #expect(model.align { $0 == .renamed("model-00002-of-00002.safetensors") } == .leftAsIs("interrupted"))
        // Another file of the same size where the first one was.
        let url = model.folder.appending(path: "model-00001-of-00002.safetensors")
        var data = try Data(contentsOf: url)
        data[20] ^= 0x20
        try data.write(to: url)
        guard case .leftAsIs(let why) = model.align(), why.contains("neither") else { Issue.record("went on"); return }
        guard case .leftAsIs = AlignedSafetensors.state(of: model.folder) else { Issue.record("not given up"); return }
        guard case .leftAsIs = model.align() else { Issue.record("tried again"); return }
    }

    @Test func refusesAFileWhoseContentIsNotTheCataloguedOne() throws {
        let model = try Model(files: Self.singleFile(), index: false)
        defer { model.remove() }
        let url = model.folder.appending(path: "model.safetensors")
        var data = try Data(contentsOf: url)
        data[data.count - 10] ^= 0xFF  // a tensor's byte: the header is the catalogued one
        try data.write(to: url)
        guard case .leftAsIs(let why) = model.align(), why.contains("SHA-256") else { Issue.record("rewritten"); return }
        #expect(try Data(contentsOf: url) == data, "left as it was")
        #expect(try model.leftovers().isEmpty)
    }

    @Test func aRewrittenFileChangedSinceIsSeenAtOnce() throws {
        let model = try Model(files: Self.singleFile(), index: true)
        defer { model.remove() }
        #expect(model.align() == .aligned)
        let url = model.folder.appending(path: "model.safetensors")
        var data = try Data(contentsOf: url)
        let tensor = try #require(try AlignedSafetensors.header(of: url).tensors.first { $0.byteCount > 0 })
        data[tensor.offset] ^= 0x01
        try data.write(to: url)
        #expect(try model.store.corruptedFiles(model.pack).map(\.path) == ["model.safetensors"])
        // Its header changed: not the rewritten file any more, the weights are not used from it.
        data[30] ^= 0x01
        try data.write(to: url)
        guard case .leftAsIs = AlignedSafetensors.state(of: model.folder) else { Issue.record("still aligned"); return }
    }

    @Test func theIndexKeepsItsSizeAndDecodes() throws {
        let model = try Model(files: Self.twoFiles(), index: true)
        defer { model.remove() }
        #expect(model.align() == .aligned)
        let data = try Data(contentsOf: model.folder.appending(path: AlignedSafetensors.indexName))
        #expect(data.count == Int(model.pack.files.first { $0.path == AlignedSafetensors.indexName }!.size))
        #expect(data.last == 0x0A)
        #expect(try model.indexWeightMap()?.count == model.kept.count)
    }

    @Test func plannedHeadersAreTheSameToTheByte() throws {
        let model = try Model(files: Self.twoFiles(), index: true)
        defer { model.remove() }
        let first = try AlignedSafetensors.plan(folder: model.folder, catalog: model.pack.files, revision: nil,
                                                keeping: model.kept)
        let second = try AlignedSafetensors.plan(folder: model.folder, catalog: model.pack.files, revision: nil,
                                                 keeping: model.kept)
        #expect(first == second)
        for file in first.files where file.holdsWeights {
            let header = try #require(AlignedSafetensors.plannedHeader(file))
            #expect(header.count == file.dataStart && header.count % AlignedSafetensors.alignment == 0)
            #expect(AlignedSafetensors.digest(header) == file.headerSHA256)
        }
    }
}
