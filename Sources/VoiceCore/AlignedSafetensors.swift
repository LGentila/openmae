import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto  // swift-crypto: the same API on Linux and Windows
#endif

/// A language model's safetensors files, rewritten once in place so that the GPU can use its weights straight from the
/// files, without a copy (`FileBackedWeights` in VoiceEngineApple): every tensor on a page boundary of its file.
///
/// Metal wraps memory it did not allocate only from a page boundary and for whole pages, and MLX copies it otherwise,
/// without a word; and a tensor that starts 1 to 3 bytes off a 4-byte boundary inside a buffer is read wrong by the GPU,
/// without an error either (measured on the reference Mac). The files as converted for MLX align nothing: 1,429 of Gemma
/// 4 26B's 1,697 tensors do not even start on a 4-byte boundary. So each tensor moves to a boundary of `alignment` bytes,
/// its region padded with zeros up to the next one.
///
/// Every file keeps its name and its exact size, so that a version of the app without this code still takes the model as
/// complete (`ModelStore.missingFiles` compares sizes) and loads it with mlx-swift-lm's loader, which reads each tensor
/// where its file's header says (the same tokens, measured). The room for the padding comes from the tensors the model's
/// own clean-up drops at every load, left out (Gemma 4's vision and audio encoders: 1.14 GB in Gemma 4 26B, 0.95 GB in E2B
/// and E4B); a file that holds none of them hands a tensor or two to one that does (`plan`), and the index says where each
/// tensor now is. What is left at a file's end is zeros, which take no room on disk (a hole). Headers are padded with
/// spaces, as the format allows, and so is the index.
///
/// The reference `safetensors` library (Rust, Python) refuses such files, since their data has gaps no tensor indexes;
/// MLX's reader, and so mlx-swift-lm's loader, takes them.
///
/// The folder stays loadable by mlx-swift-lm's loader at every moment (`align`): the manifest (`manifestName`), written
/// before anything else, says what goes where; each file is written under a temporary name, checked against its
/// catalogued SHA-256 as it is read, synced, then takes its name; a file that receives tensors is rewritten before those
/// that give them, so that a tensor is always in at least one file (for a moment in two, with the same bytes: the loader
/// takes the later file's). A rewrite stopped half-way (the app quits, the Mac crashes, the disk is full) is finished at
/// the next launch. The manifest keeps every new file's SHA-256 (`ModelStore.corruptedFiles`).
public enum AlignedSafetensors {
    /// The boundary every tensor starts on: a page of Apple Silicon's memory (16 KiB).
    public static let alignment = 16384

    /// The manifest of the rewrite, in the model's folder (`Manifest`).
    public static let manifestName = "aligned-manifest.json"

    /// The index of a model in several files: which file holds which tensor (mlx-swift-lm reads only its file names).
    static let indexName = "model.safetensors.index.json"

    /// The longest header MLX reads, as the reference library.
    static let longestHeader = 100_000_000

    /// The manifest's format.
    static let format = 1

    /// A tensor as a safetensors header describes it.
    public struct Tensor: Sendable, Equatable {
        public var name: String
        /// The format's name for its type: "BF16", "U32"…
        public var dtype: String
        public var shape: [Int]
        /// Where its data starts in the file (from the file's first byte), and its length.
        public var offset: Int
        public var byteCount: Int

        /// The bytes its region takes in a rewritten file: its data, padded to the next boundary.
        public var regionCount: Int { AlignedSafetensors.rounded(byteCount) }
    }

    /// A safetensors file's header: its tensors in the order of their data in the file, its metadata, and where its data
    /// starts (after the 8 bytes of the header's length and the header).
    public struct Header: Sendable {
        public var tensors: [Tensor]
        public var metadata: [String: String]
        public var dataStart: Int

        /// Where the last tensor's region ends (its data padded to the next boundary): what a rewritten file holds before
        /// the zeros of its end.
        public var dataEnd: Int { tensors.map { $0.offset + $0.regionCount }.max() ?? dataStart }
    }

    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    static func rounded(_ count: Int, to boundary: Int = alignment) -> Int {
        (count + boundary - 1) / boundary * boundary
    }

    /// The bytes of one element of a type MLX reads, by the format's name; nil for a type it lacks (FP8…).
    public static func elementSize(_ dtype: String) -> Int? {
        switch dtype {
        case "BOOL", "U8", "I8": 1
        case "U16", "I16", "F16", "BF16": 2
        case "U32", "I32", "F32": 4
        case "U64", "I64", "F64", "C64": 8
        default: nil
        }
    }

    // MARK: - Reading

    /// Reads the header of the safetensors file at `url`.
    public static func header(of url: URL) throws -> Header {
        try readHeader(url).header
    }

    /// The header of the safetensors file at `url`, and its bytes (the 8 bytes of its length included).
    static func readHeader(_ url: URL) throws -> (header: Header, bytes: Data) {
        let bytes = try headerBytes(of: url)
        return (try header(json: bytes.dropFirst(8), dataStart: bytes.count, file: url.lastPathComponent), bytes)
    }

    /// The bytes of the safetensors file's header at `url`, the 8 bytes of its length included, as they are.
    static func headerBytes(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let prefix = try handle.read(upToCount: 8), prefix.count == 8 else {
            throw Failure("\(url.lastPathComponent): not a safetensors file")
        }
        let length = UInt64(littleEndian: prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
        guard length > 0, length < UInt64(longestHeader), let json = try handle.read(upToCount: Int(length)),
              json.count == Int(length)
        else { throw Failure("\(url.lastPathComponent): not a safetensors file") }
        return prefix + json
    }

    /// Reads a header from the start of a file's bytes (a mapped file).
    public static func header(bytes: UnsafeRawBufferPointer, file: String) throws -> Header {
        guard bytes.count >= 8 else { throw Failure("\(file): not a safetensors file") }
        let length = UInt64(littleEndian: bytes.loadUnaligned(as: UInt64.self))
        guard length > 0, length < UInt64(longestHeader), length <= UInt64(bytes.count - 8) else {
            throw Failure("\(file): not a safetensors file")
        }
        return try header(json: Data(bytes[8 ..< 8 + Int(length)]), dataStart: 8 + Int(length), file: file)
    }

    private static func header(json: Data, dataStart: Int, file: String) throws -> Header {
        guard let entries = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw Failure("\(file): its header is not a JSON object")
        }
        var tensors: [Tensor] = []
        var metadata: [String: String] = [:]
        for (name, value) in entries {
            if name == "__metadata__" {
                for (key, text) in value as? [String: Any] ?? [:] { metadata[key] = text as? String }
                continue
            }
            guard let entry = value as? [String: Any], let dtype = entry["dtype"] as? String,
                  let shape = (entry["shape"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.intValue }),
                  let offsets = (entry["data_offsets"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.intValue }),
                  offsets.count == 2, offsets[0] >= 0, offsets[1] >= offsets[0]
            else { throw Failure("\(file): tensor \(name) is described wrongly") }
            let count = offsets[1] - offsets[0]
            if let size = elementSize(dtype), shape.reduce(size, *) != count {
                throw Failure("\(file): tensor \(name) holds \(count) bytes, not those of \(dtype) \(shape)")
            }
            tensors.append(Tensor(name: name, dtype: dtype, shape: shape, offset: dataStart + offsets[0], byteCount: count))
        }
        tensors.sort { ($0.offset, $0.name) < ($1.offset, $1.name) }
        return Header(tensors: tensors, metadata: metadata, dataStart: dataStart)
    }

    /// The safetensors files that hold a model's weights, as mlx-swift-lm chooses them (`safetensorWeightURLs`): those
    /// `model.safetensors.index.json` names when they all exist, else `model*.safetensors`, else `weight*.safetensors`,
    /// else every safetensors file of the folder (not its subfolders).
    public static func weightFiles(in folder: URL) throws -> [URL] {
        let index = folder.appending(path: indexName, directoryHint: .notDirectory)
        if let data = try? Data(contentsOf: index),
           let map = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["weight_map"] as? [String: String]
        {
            let named = Set(map.values).sorted().map { folder.appending(path: $0, directoryHint: .notDirectory) }
            if !named.isEmpty, named.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) { return named }
        }
        let present = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for prefix in ["model", "weight"] {
            let matches = present.filter { $0.lastPathComponent.hasPrefix(prefix) }
            if !matches.isEmpty { return matches }
        }
        return present
    }

    /// Why a file's weights cannot be used without a copy, nil when they can: a tensor that does not start on a boundary
    /// of `alignment` bytes, or whose region (its data padded to the next boundary) runs into the next tensor or past the
    /// file's end. A tensor without data takes no region.
    public static func misalignment(_ header: Header, fileSize: Int, file: String) -> String? {
        var end = header.dataStart
        for tensor in header.tensors {
            guard tensor.byteCount > 0 else {
                guard tensor.offset <= fileSize else { return "\(file): tensor \(tensor.name) lies past the file's end" }
                continue
            }
            guard tensor.offset % alignment == 0 else {
                return "\(file): tensor \(tensor.name) starts at byte \(tensor.offset), not on a boundary of \(alignment)"
            }
            guard tensor.offset >= end else { return "\(file): tensor \(tensor.name) overlaps the one before it" }
            end = tensor.offset + tensor.regionCount
            guard end <= fileSize else { return "\(file): tensor \(tensor.name) runs past the file's end" }
        }
        return nil
    }

    // MARK: - The manifest

    /// What a rewrite does, and has done, to a model's folder: saved there (`manifestName`) before the first file is
    /// written, and again after each, so that a rewrite stopped half-way is finished at the next launch (`align`).
    public struct Manifest: Codable, Sendable, Equatable {
        public enum State: String, Codable, Sendable {
            /// Files are being rewritten: some may be, some not yet.
            case aligning
            /// Every file is rewritten: the weights can be used from them.
            case aligned
        }

        /// A tensor of a rewritten file: where its bytes come from, and where they go.
        public struct Placement: Codable, Sendable, Equatable {
            public var name: String
            public var dtype: String
            public var shape: [Int]
            /// The file it comes from (another one when it moved), and where its data starts there.
            public var source: String
            public var sourceOffset: Int
            /// Where its data starts in the rewritten file, and its length.
            public var offset: Int
            public var bytes: Int
        }

        /// A file the rewrite replaces: a safetensors file (`tensors`), or the index.
        public struct File: Codable, Sendable, Equatable {
            public var path: String
            /// Its size, the same before and after (the catalog's).
            public var size: Int
            /// Its catalogued SHA-256, checked as it is read.
            public var originalSHA256: String
            /// The SHA-256 of what replaces it, recorded before it takes its name; nil until then.
            public var sha256: String?
            /// A safetensors file's header before and after (its bytes, the 8 of its length included), to tell which one
            /// the folder holds; where its data starts once rewritten, its metadata, and its tensors in their new order.
            public var originalHeaderSHA256: String?
            public var headerSHA256: String?
            public var dataStart: Int?
            public var metadata: [String: String]?
            public var tensors: [Placement]?

            public var holdsWeights: Bool { tensors != nil }
        }

        public var format: Int
        public var alignment: Int
        public var state: State
        /// The catalog's revision of the model, when known.
        public var revision: String?
        /// In the order they are rewritten: those that receive tensors from other files first, the index last.
        public var files: [File]
        /// The tensors left out (those the model's clean-up drops), and their bytes.
        public var dropped: [String]
        public var droppedBytes: Int
        /// Why the rewrite stopped for good (a file is neither the catalogued one nor the rewritten one): the folder is
        /// left as it is, and loaded as before.
        public var gaveUp: String?
    }

    /// The manifest in `folder`, nil when there is none or it cannot be read.
    public static func manifest(in folder: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: manifestLocation(folder)) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// The SHA-256 of each file the rewrite replaced, or is replacing, with the catalogued SHA-256 of the file it
    /// replaces (`ModelStore.corruptedFiles`).
    static func rewrittenDigests(in folder: URL) -> [String: (sha256: String, originalSHA256: String)] {
        guard let manifest = manifest(in: folder) else { return [:] }
        var digests: [String: (sha256: String, originalSHA256: String)] = [:]
        for file in manifest.files {
            if let sha256 = file.sha256 { digests[file.path] = (sha256, file.originalSHA256) }
        }
        return digests
    }

    // MARK: - What the folder holds

    public enum FolderState: Sendable, Equatable {
        /// Never rewritten: no manifest.
        case original
        /// A rewrite stopped half-way: `align` finishes it.
        case aligning(Manifest)
        /// Rewritten, and its files are those of the manifest: the weights can be used from them.
        case aligned(Manifest)
        /// Neither: a manifest that cannot be read or does not match its files, or a rewrite given up. The folder is left
        /// as it is, and loaded as before.
        case leftAsIs(String)
    }

    /// What `folder` holds, checked cheaply: the manifest, each file's size, each safetensors file's header (its
    /// SHA-256 and its tensors' alignment), and that the files mlx-swift-lm would read are those rewritten. A few
    /// milliseconds: what is checked before every load.
    public static func state(of folder: URL) -> FolderState {
        guard FileManager.default.fileExists(atPath: manifestLocation(folder).path) else { return .original }
        guard let manifest = manifest(in: folder) else { return .leftAsIs("its manifest cannot be read") }
        guard manifest.format == format, manifest.alignment == alignment else {
            return .leftAsIs("its manifest is of another format")
        }
        if let gaveUp = manifest.gaveUp { return .leftAsIs(gaveUp) }
        switch manifest.state {
        case .aligning:
            return .aligning(manifest)
        case .aligned:
            if let problem = mismatch(manifest, in: folder) { return .leftAsIs(problem) }
            return .aligned(manifest)
        }
    }

    /// What does not match between a rewritten folder and its manifest, nil when everything does.
    static func mismatch(_ manifest: Manifest, in folder: URL) -> String? {
        let weights = manifest.files.filter(\.holdsWeights).map(\.path)
        guard let chosen = try? weightFiles(in: folder).map(\.lastPathComponent), Set(chosen) == Set(weights) else {
            return "the files that hold the weights are not those its manifest lists"
        }
        for file in manifest.files {
            let url = folder.appending(path: file.path, directoryHint: .notDirectory)
            guard ModelStore.size(of: url) == Int64(file.size) else { return "\(file.path) is not of its size" }
            guard file.holdsWeights else { continue }
            guard let (header, bytes) = try? readHeader(url), digest(bytes) == file.headerSHA256 else {
                return "\(file.path) is not the rewritten file"
            }
            if let problem = misalignment(header, fileSize: file.size, file: file.path) { return problem }
        }
        return nil
    }

    // MARK: - Planning

    /// The rewrite of a folder never rewritten: each weight file's tensors that `keep` accepts (those the model's
    /// clean-up keeps), in their order, on boundaries; what each file then needs must fit in its size. A file whose
    /// tensors do not fit (it holds nothing to leave out) hands tensors to files with room, the smallest that frees
    /// enough, else the largest ones until it fits, and those files are rewritten first. Reads only headers and the
    /// index. Throws when the folder cannot be rewritten so: files that are not the catalogued ones (by size), a type MLX
    /// lacks, a tensor in two files, a file that would hold no tensor, tensors no file has room for.
    static func plan(folder: URL, catalog: [ModelFile], revision: String?, keeping keep: Set<String>) throws -> Manifest {
        let catalogued = Dictionary(catalog.map { ($0.path, $0) }) { first, _ in first }
        let urls = try weightFiles(in: folder)
        guard !urls.isEmpty else { throw Failure("no safetensors file") }
        struct Source {
            var file: ModelFile
            var header: Header
            var headerSHA256: String
        }
        var sources: [Source] = []
        var seen = Set<String>()
        for url in urls {
            let name = url.lastPathComponent
            guard let file = catalogued[name], ModelStore.size(of: url) == file.size else {
                throw Failure("\(name) is not a catalogued file of its size")
            }
            let (header, bytes) = try readHeader(url)
            var end = header.dataStart
            for tensor in header.tensors {
                guard elementSize(tensor.dtype) != nil else {
                    throw Failure("\(name): tensor \(tensor.name) is of a type MLX lacks (\(tensor.dtype))")
                }
                guard tensor.offset >= end else { throw Failure("\(name): tensor \(tensor.name) overlaps another") }
                end = tensor.offset + tensor.byteCount
                guard end <= Int(file.size) else {
                    throw Failure("\(name): tensor \(tensor.name) runs past the file's end")
                }
                guard seen.insert(tensor.name).inserted else { throw Failure("tensor \(tensor.name) is in two files") }
            }
            sources.append(Source(file: file, header: header, headerSHA256: digest(bytes)))
        }
        var dropped: [String] = []
        var droppedBytes = 0
        // What each file holds once rewritten: its own tensors kept, then those it receives.
        var contents: [String: [(tensor: Tensor, source: String)]] = [:]
        for source in sources {
            let name = source.file.path
            contents[name] = source.header.tensors.filter { keep.contains($0.name) }.map { ($0, name) }
            for tensor in source.header.tensors where !keep.contains(tensor.name) {
                dropped.append(tensor.name)
                droppedBytes += tensor.byteCount
            }
        }
        let names = sources.map(\.file.path)
        let sizes = Dictionary(sources.map { ($0.file.path, Int($0.file.size)) }) { first, _ in first }
        let metadata = Dictionary(sources.map { ($0.file.path, $0.header.metadata) }) { first, _ in first }
        func end(_ name: String, adding extra: Tensor? = nil) -> Int {
            layout((contents[name] ?? []).map(\.tensor) + (extra.map { [$0] } ?? []), metadata: metadata[name] ?? [:]).end
        }
        let donors = Set(names.filter { end($0) > sizes[$0]! })
        var receivers: [String] = []
        for donor in names where donors.contains(donor) {
            while end(donor) > sizes[donor]! {
                let deficit = end(donor) - sizes[donor]!
                let movable = (contents[donor] ?? []).filter { $0.tensor.byteCount > 0 }.map(\.tensor)
                // The smallest tensor whose region covers what is missing, else the largest.
                let pick = movable.filter { $0.regionCount >= deficit }
                    .min { ($0.regionCount, $0.name) < ($1.regionCount, $1.name) }
                    ?? movable.max { ($0.regionCount, $1.name) < ($1.regionCount, $0.name) }
                guard let pick, contents[donor]!.count > 1 else {
                    throw Failure("\(donor) holds nothing to leave out, and too little to give: it cannot keep its size")
                }
                guard let receiver = names.first(where: { !donors.contains($0) && end($0, adding: pick) <= sizes[$0]! })
                else { throw Failure("no file has room for tensor \(pick.name) of \(donor)") }
                contents[donor]!.removeAll { $0.tensor.name == pick.name }
                contents[receiver]!.append((pick, donor))
                if !receivers.contains(receiver) { receivers.append(receiver) }
            }
        }
        var files: [Manifest.File] = []
        var weightMap: [String: String] = [:]
        var keptBytes = 0
        for name in receivers + names.filter({ !receivers.contains($0) }) {
            let held = contents[name] ?? []
            guard !held.isEmpty else { throw Failure("\(name) would hold no tensor") }
            let planned = layout(held.map(\.tensor), metadata: metadata[name] ?? [:])
            let placements = zip(held, planned.offsets).map { entry, offset in
                Manifest.Placement(name: entry.tensor.name, dtype: entry.tensor.dtype, shape: entry.tensor.shape,
                                   source: entry.source, sourceOffset: entry.tensor.offset, offset: offset,
                                   bytes: entry.tensor.byteCount)
            }
            let source = sources.first { $0.file.path == name }!
            files.append(Manifest.File(
                path: name, size: sizes[name]!, originalSHA256: source.file.sha256, sha256: nil,
                originalHeaderSHA256: source.headerSHA256, headerSHA256: digest(planned.header),
                dataStart: planned.header.count, metadata: metadata[name], tensors: placements))
            for placement in placements {
                weightMap[placement.name] = name
                keptBytes += placement.bytes
            }
        }
        let index = folder.appending(path: indexName, directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: index.path) {
            guard let file = catalogued[indexName], ModelStore.size(of: index) == file.size else {
                throw Failure("\(indexName) is not the catalogued file of its size")
            }
            let original = try Data(contentsOf: index)
            guard digest(original) == file.sha256 else { throw Failure("\(indexName) is not the catalogued file") }
            let rewritten = try rewrittenIndex(original, weightMap: weightMap, keptBytes: keptBytes, size: Int(file.size))
            files.append(Manifest.File(path: indexName, size: Int(file.size), originalSHA256: file.sha256,
                                       sha256: digest(rewritten)))
        }
        return Manifest(format: format, alignment: alignment, state: .aligning, revision: revision, files: files,
                        dropped: dropped.sorted(), droppedBytes: droppedBytes, gaveUp: nil)
    }

    /// A rewritten file's layout: its header (the 8 bytes of its length, the JSON, spaces up to a boundary), where each
    /// tensor's data starts (from the file's first byte), and where the last one's region ends.
    static func layout(_ tensors: [Tensor], metadata: [String: String]) -> (header: [UInt8], offsets: [Int], end: Int) {
        var relative: [Int] = []
        var position = 0
        for tensor in tensors {
            relative.append(position)
            position += tensor.regionCount
        }
        let json = headerJSON(metadata: metadata, entries: zip(tensors, relative).map { tensor, start in
            (tensor.name, tensor.dtype, tensor.shape, start, start + tensor.byteCount)
        })
        let dataStart = rounded(8 + json.count)
        var header = withUnsafeBytes(of: UInt64(dataStart - 8).littleEndian) { Array($0) }
        header += json
        header += [UInt8](repeating: 0x20, count: dataStart - header.count)  // spaces, as the format allows
        return (header, relative.map { dataStart + $0 }, dataStart + position)
    }

    /// A header's JSON: the metadata (by key), then the tensors in the order given, with their offsets from the start of
    /// the data. The same JSON for the same entries, to the byte: a rewrite stopped half-way is checked against it.
    private static func headerJSON(metadata: [String: String],
                                   entries: [(name: String, dtype: String, shape: [Int], start: Int, end: Int)]) -> [UInt8]
    {
        var parts: [String] = []
        if !metadata.isEmpty {
            parts.append("\"__metadata__\":{"
                + metadata.sorted { $0.key < $1.key }.map { "\(quoted($0.key)):\(quoted($0.value))" }.joined(separator: ",")
                + "}")
        }
        for entry in entries {
            parts.append("\(quoted(entry.name)):{\"dtype\":\(quoted(entry.dtype)),\"shape\":["
                + entry.shape.map(String.init).joined(separator: ",")
                + "],\"data_offsets\":[\(entry.start),\(entry.end)]}")
        }
        return Array(("{" + parts.joined(separator: ",") + "}").utf8)
    }

    /// The header a planned file gets.
    static func plannedHeader(_ file: Manifest.File) -> [UInt8]? {
        guard let tensors = file.tensors, let dataStart = file.dataStart else { return nil }
        let json = headerJSON(metadata: file.metadata ?? [:], entries: tensors.map {
            ($0.name, $0.dtype, $0.shape, $0.offset - dataStart, $0.offset - dataStart + $0.bytes)
        })
        guard rounded(8 + json.count) == dataStart else { return nil }
        var header = withUnsafeBytes(of: UInt64(dataStart - 8).littleEndian) { Array($0) }
        header += json
        header += [UInt8](repeating: 0x20, count: dataStart - header.count)
        return header
    }

    /// The index for the tensors kept, where they now are, of exactly `size` bytes: its weight map, its total size (when
    /// it has one), its other keys as they were; compact, then spaces and a line break, which JSON allows.
    static func rewrittenIndex(_ original: Data, weightMap: [String: String], keptBytes: Int, size: Int) throws -> Data {
        guard var index = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            throw Failure("\(indexName) is not a JSON object")
        }
        index["weight_map"] = weightMap
        if var metadata = index["metadata"] as? [String: Any], metadata["total_size"] != nil {
            metadata["total_size"] = keptBytes
            index["metadata"] = metadata
        }
        var data = try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count < size else { throw Failure("\(indexName) would not keep its size") }
        data.append(contentsOf: [UInt8](repeating: 0x20, count: size - data.count - 1))
        data.append(0x0A)
        return data
    }

    // MARK: - Rewriting

    /// What `align` did.
    public enum Outcome: Sendable, Equatable {
        /// The folder was rewritten already: nothing to do.
        case alreadyAligned
        /// Rewritten now (the whole rewrite, or the rest of one stopped half-way).
        case aligned
        /// Left as it is, for the reason given: the model is loaded as before. A rewrite stopped half-way, for want of
        /// room or because the app quits, goes on at the next call.
        case leftAsIs(String)
    }

    /// The moments of a rewrite where a test stops it dead, as if the process were killed (`align`'s `interruption`).
    enum Step: Equatable, Sendable {
        /// The manifest is written, no file yet.
        case planned
        /// A file's new content is written under its temporary name, and synced.
        case written(String)
        /// Its SHA-256 is in the manifest.
        case recorded(String)
        /// It has taken its name.
        case renamed(String)
    }

    /// Room left free on the disk on top of a file being written (as for a download: `ModelDownloader`).
    static let margin = 1_000_000_000

    /// Rewrites the model in `folder` so that its weights can be used from its files, or finishes a rewrite stopped
    /// half-way, in place (see the type). `catalog`: the model's files, by size and SHA-256 (`ModelPack.files`);
    /// `keep`: the tensors the model's clean-up keeps (`FileBackedWeights.keptTensors`), needed only for a folder never
    /// rewritten; `availableBytes`: the disk's free space, asked before each file is written (`ModelStore`); `shouldStop`,
    /// asked every few megabytes, ends it where it is (the app quits). Blocks its thread for the whole rewrite: about a
    /// second per gigabyte of weights. One process at a time rewrites a folder (a lock on it).
    ///
    /// Each file in turn, as the manifest orders them: written under a temporary name (`.<name>.aligning`) from the file
    /// it replaces, read in full past macOS's file cache (its SHA-256 checked against the catalog's), and from the files
    /// that give it tensors; synced; its SHA-256 written in the manifest; then it takes its name. A file already rewritten
    /// is recognized by its header and skipped. A file that is neither the catalogued one nor the rewritten one stops the
    /// rewrite for good (`Manifest.gaveUp`); so does the catalogued SHA-256 not matching. Without room for the next file,
    /// it stops and tries again at the next call.
    public static func align(folder: URL, catalog: [ModelFile], revision: String?, keeping keep: Set<String>?,
                             availableBytes: () -> Int64?, shouldStop: () -> Bool = { false },
                             progress: (String) -> Void = { _ in }) -> Outcome
    {
        align(folder: folder, catalog: catalog, revision: revision, keeping: keep, availableBytes: availableBytes,
              shouldStop: shouldStop, progress: progress, interruption: nil)
    }

    /// `align`; `interruption` (tests): returns true at the step where the rewrite stops dead, leaving everything as a
    /// killed process would.
    static func align(folder: URL, catalog: [ModelFile], revision: String?, keeping keep: Set<String>?,
                      availableBytes: () -> Int64?, shouldStop: () -> Bool, progress: (String) -> Void,
                      interruption: ((Step) -> Bool)?) -> Outcome
    {
        let lock = open(folder.path, O_RDONLY)
        guard lock >= 0 else { return .leftAsIs("\(folder.path) cannot be opened") }
        defer { close(lock) }  // and the lock goes with it
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return .leftAsIs("another process is rewriting it") }

        var manifest: Manifest
        switch state(of: folder) {
        case .aligned:
            return .alreadyAligned
        case .leftAsIs(let why):
            return .leftAsIs(why)
        case .aligning(let stopped):
            manifest = stopped
        case .original:
            guard let keep else { return .leftAsIs("which tensors the model keeps is not known") }
            do {
                manifest = try plan(folder: folder, catalog: catalog, revision: revision, keeping: keep)
            } catch {
                return .leftAsIs("\(error)")
            }
            removeTemporaries(of: manifest, in: folder)
            let largest = manifest.files.map(allocation).max() ?? 0
            if let available = availableBytes(), available < Int64(largest + margin) {
                return .leftAsIs(noRoom(needed: largest + margin, available: available))
            }
            do { try save(manifest, in: folder) } catch { return .leftAsIs("its manifest cannot be written: \(error)") }
            if interruption?(.planned) == true { return .leftAsIs("interrupted") }
        }
        removeTemporaries(of: manifest, in: folder)
        for index in manifest.files.indices {
            let file = manifest.files[index]
            let url = folder.appending(path: file.path, directoryHint: .notDirectory)
            switch currentState(of: file, at: url) {
            case .rewritten:
                continue
            case .neither(let why):
                manifest.gaveUp = why
                try? save(manifest, in: folder)
                return .leftAsIs(why)
            case .original:
                break
            }
            if shouldStop() { return .leftAsIs("stopped") }
            if let available = availableBytes(), available < Int64(allocation(file) + margin) {
                return .leftAsIs(noRoom(needed: allocation(file) + margin, available: available))
            }
            progress(file.path)
            let temporary = temporaryLocation(of: file.path, in: folder)
            let sha256: String
            do {
                sha256 = file.holdsWeights
                    ? try writeWeights(file, folder: folder, to: temporary, shouldStop: shouldStop)
                    : try writeIndex(file, of: manifest, folder: folder, to: temporary)
            } catch let reason as GivingUp {
                try? FileManager.default.removeItem(at: temporary)
                manifest.gaveUp = reason.description
                try? save(manifest, in: folder)
                return .leftAsIs(reason.description)
            } catch {
                // Stopped, a full disk, a read or write that failed: the next call tries again.
                try? FileManager.default.removeItem(at: temporary)
                return .leftAsIs("\(error)")
            }
            if interruption?(.written(file.path)) == true { return .leftAsIs("interrupted") }
            manifest.files[index].sha256 = sha256
            do {
                try save(manifest, in: folder)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                return .leftAsIs("its manifest cannot be written: \(error)")
            }
            if interruption?(.recorded(file.path)) == true { return .leftAsIs("interrupted") }
            guard rename(temporary.path, url.path) == 0 else {
                let problem = String(cString: strerror(errno))
                try? FileManager.default.removeItem(at: temporary)
                return .leftAsIs("\(file.path) cannot take its name: \(problem)")
            }
            syncFolder(folder)
            if interruption?(.renamed(file.path)) == true { return .leftAsIs("interrupted") }
        }
        manifest.state = .aligned
        do { try save(manifest, in: folder) } catch { return .leftAsIs("its manifest cannot be written: \(error)") }
        if let problem = mismatch(manifest, in: folder) { return .leftAsIs(problem) }
        return .aligned
    }

    /// Which of its two versions the folder holds of a file the manifest lists.
    private enum FileState: Equatable {
        case original, rewritten
        case neither(String)
    }

    private static func currentState(of file: Manifest.File, at url: URL) -> FileState {
        guard ModelStore.size(of: url) == Int64(file.size) else { return .neither("\(file.path) is not of its size") }
        let found: String
        if file.holdsWeights {
            guard let bytes = try? headerBytes(of: url) else { return .neither("\(file.path) cannot be read") }
            found = digest(bytes)
            if found == file.headerSHA256 { return .rewritten }
            if found == file.originalHeaderSHA256 { return .original }
        } else {
            guard let data = try? Data(contentsOf: url) else { return .neither("\(file.path) cannot be read") }
            found = digest(data)
            if found == file.sha256 { return .rewritten }
            if found == file.originalSHA256 { return .original }
        }
        return .neither("\(file.path) is neither the catalogued file nor the rewritten one")
    }

    /// Why a rewrite stops for good: what it reads is not what the manifest says.
    private struct GivingUp: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func noRoom(needed: Int, available: Int64) -> String {
        String(format: "not enough free space: %.2f GB needed, %.2f GB available", Double(needed) / 1e9,
               Double(available) / 1e9)
    }

    /// The disk a file's new version takes: its data (the zeros of its end are a hole).
    static func allocation(_ file: Manifest.File) -> Int {
        guard let tensors = file.tensors, let dataStart = file.dataStart else { return rounded(file.size, to: 4096) }
        let end = tensors.map { $0.offset + rounded($0.bytes) }.max() ?? dataStart
        return rounded(end, to: 4096)
    }

    static func manifestLocation(_ folder: URL) -> URL {
        folder.appending(path: manifestName, directoryHint: .notDirectory)
    }

    static func temporaryLocation(of path: String, in folder: URL) -> URL {
        folder.appending(path: ".\(path).aligning", directoryHint: .notDirectory)
    }

    /// What a rewrite killed half-way left: a file's new version not yet named, a manifest not yet named.
    private static func removeTemporaries(of manifest: Manifest, in folder: URL) {
        for file in manifest.files {
            try? FileManager.default.removeItem(at: temporaryLocation(of: file.path, in: folder))
        }
        try? FileManager.default.removeItem(at: temporaryLocation(of: manifestName, in: folder))
    }

    /// Writes the manifest under a temporary name, syncs it, then gives it its name.
    static func save(_ manifest: Manifest, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        let temporary = temporaryLocation(of: manifestName, in: folder)
        try writeSynced(data, to: temporary)
        guard rename(temporary.path, manifestLocation(folder).path) == 0 else {
            let problem = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw Failure("\(manifestName) cannot take its name: \(problem)")
        }
        syncFolder(folder)
    }

    /// The index's new version, from the index it replaces (checked against its catalogued SHA-256).
    private static func writeIndex(_ file: Manifest.File, of manifest: Manifest, folder: URL, to temporary: URL) throws
        -> String
    {
        let original = try Data(contentsOf: folder.appending(path: file.path, directoryHint: .notDirectory))
        guard digest(original) == file.originalSHA256 else { throw GivingUp("\(file.path) is not the catalogued file") }
        var weightMap: [String: String] = [:]
        var keptBytes = 0
        for weights in manifest.files {
            for placement in weights.tensors ?? [] {
                weightMap[placement.name] = weights.path
                keptBytes += placement.bytes
            }
        }
        let content = try rewrittenIndex(original, weightMap: weightMap, keptBytes: keptBytes, size: file.size)
        let sha256 = digest(content)
        guard sha256 == file.sha256 else { throw GivingUp("\(file.path) would not be the planned one") }
        try writeSynced(content, to: temporary)
        return sha256
    }

    /// A safetensors file's new version, at `temporary`: its header; its own tensors, read with the whole file it
    /// replaces (whose SHA-256 must be the catalog's) in the file's order; the tensors it receives from other files; the
    /// zeros of its end as a hole. Returns its SHA-256. The files are read and written past macOS's file cache: 15 GB
    /// going through it would push other apps' memory out.
    private static func writeWeights(_ file: Manifest.File, folder: URL, to temporary: URL,
                                     shouldStop: () -> Bool) throws -> String
    {
        guard let placements = file.tensors, let header = plannedHeader(file), digest(header) == file.headerSHA256 else {
            throw GivingUp("\(file.path)'s header would not be the planned one")
        }
        // Tensors without data are in the header only.
        let own = placements.filter { $0.source == file.path && $0.bytes > 0 }
        let received = placements.filter { $0.source != file.path && $0.bytes > 0 }
        let written = own + received
        guard zip(own, own.dropFirst()).allSatisfy({ $0.sourceOffset + $0.bytes <= $1.sourceOffset }),
              zip(written, written.dropFirst()).allSatisfy({ $0.offset + $0.bytes <= $1.offset }),
              written.first.map({ $0.offset >= header.count }) ?? true
        else { throw GivingUp("\(file.path)'s plan is not in the files' order") }

        let output = Output(try openFile(temporary, writing: true))
        defer { close(output.descriptor) }
        try output.write(header, at: 0)

        // Its own tensors, as the file is read: the reads of the next chunk, the SHA-256 of the file read so far and the
        // writes of what it holds of the tensors, at the same time.
        let source = try openFile(folder.appending(path: file.path, directoryHint: .notDirectory), writing: false)
        defer { close(source) }
        let chunk = 16 << 20
        let buffers = [UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: alignment),
                       UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: alignment)]
        defer { buffers.forEach { $0.deallocate() } }
        let read = ChunkRead()
        read.count = try readFully(source, into: buffers[0], at: 0, count: min(chunk, file.size), file: file.path)
        var start = 0
        var turn = 0
        var next = own.startIndex
        var sourceHasher = SHA256()
        while start < file.size {
            // The chunk read (hashed and copied) and the other buffer (the next chunk read into it): never the same.
            let step = ChunkBuffers(current: UnsafeRawBufferPointer(rebasing: buffers[turn % 2][..<read.count]),
                                    reading: buffers[(turn + 1) % 2], start: start)
            let following = start + read.count
            let hashing = SourceHash(sourceHasher)
            let copy = CopyState(next: next)
            DispatchQueue.concurrentPerform(iterations: 3) { stage in
                switch stage {
                case 0:
                    guard following < file.size else { return }
                    do {
                        read.next = try readFully(source, into: step.reading, at: following,
                                                  count: min(chunk, file.size - following), file: file.path)
                    } catch { read.failure = error }
                case 1:
                    hashing.hasher.update(bufferPointer: step.current)
                default:
                    do {
                        copy.next = try copyOwn(own, from: step.current, at: step.start, startingAt: copy.next,
                                                into: output)
                    } catch { copy.failure = error }
                }
            }
            if let failure = read.failure ?? copy.failure { throw failure }
            sourceHasher = hashing.hasher
            next = copy.next
            if shouldStop() { throw Failure("stopped") }
            start = following
            read.count = read.next
            turn += 1
        }
        guard next == own.endIndex else { throw GivingUp("\(file.path) ended before its tensors") }
        guard hex(sourceHasher.finalize()) == file.originalSHA256 else {
            throw GivingUp("\(file.path) is not the catalogued file: its SHA-256 differs")
        }

        // The tensors it receives, from the files that give them (rewritten after it: still as catalogued).
        for placement in received {
            let giver = try openFile(folder.appending(path: placement.source, directoryHint: .notDirectory), writing: false)
            defer { close(giver) }
            var done = 0
            while done < placement.bytes {
                let count = min(chunk, placement.bytes - done)
                let got = try readFully(giver, into: buffers[0], at: placement.sourceOffset + done, count: count,
                                        file: placement.source)
                try output.put(UnsafeRawBufferPointer(rebasing: buffers[0][..<got]), at: placement.offset + done)
                done += got
            }
            if shouldStop() { throw Failure("stopped") }
        }

        // The zeros of its end, a hole on the disk.
        try output.zeros(upTo: file.size, writing: false)
        guard ftruncate(output.descriptor, off_t(file.size)) == 0 else {
            throw Failure("\(temporary.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        try syncFile(output.descriptor, temporary.lastPathComponent)
        return hex(output.hasher.finalize())
    }

    /// Writes the parts of `own` tensors in `bytes` (the file's bytes from `start` on), from the `next`th tensor on;
    /// returns the first tensor not finished.
    private static func copyOwn(_ own: [Manifest.Placement], from bytes: UnsafeRawBufferPointer, at start: Int,
                                startingAt next: Int, into output: Output) throws -> Int
    {
        var next = next
        let end = start + bytes.count
        while next < own.count {
            let placement = own[next]
            let tensorEnd = placement.sourceOffset + placement.bytes
            if placement.sourceOffset >= end { break }  // starts in a later chunk
            guard tensorEnd > start else { throw GivingUp("tensor \(placement.name) was missed") }
            let from = max(placement.sourceOffset, start)
            let to = min(tensorEnd, end)
            try output.put(UnsafeRawBufferPointer(rebasing: bytes[(from - start) ..< (to - start)]),
                           at: placement.offset + (from - placement.sourceOffset))
            if tensorEnd > end { break }  // goes on in the next chunk
            next += 1
        }
        return next
    }

    /// A file being written in order, with its SHA-256: the zeros between two tensors are written, those of the end left
    /// as a hole (and hashed all the same).
    private final class Output: @unchecked Sendable {
        let descriptor: Int32
        var hasher = SHA256()
        /// How far it is written (and hashed).
        var position = 0
        private let zeros = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: alignment)

        init(_ descriptor: Int32) {
            self.descriptor = descriptor
            zeros.initializeMemory(as: UInt8.self, repeating: 0)
        }

        deinit { zeros.deallocate() }

        func write(_ bytes: [UInt8], at offset: Int) throws {
            try bytes.withUnsafeBytes { try put($0, at: offset) }
        }

        /// Writes `bytes` at `offset`, after zeros from where it stands.
        func put(_ bytes: UnsafeRawBufferPointer, at offset: Int) throws {
            try zeros(upTo: offset, writing: true)
            var done = 0
            while done < bytes.count {
                let n = pwrite(descriptor, bytes.baseAddress! + done, bytes.count - done, off_t(position + done))
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw Failure("write failed (\(String(cString: strerror(errno))))") }
                done += n
            }
            hasher.update(bufferPointer: bytes)
            position += bytes.count
        }

        /// Zeros from where it stands up to `offset`: written, or left as a hole.
        func zeros(upTo offset: Int, writing: Bool) throws {
            guard offset >= position else { throw Failure("a tensor overlaps the one before it") }
            while position < offset {
                let count = min(offset - position, self.zeros.count)
                let zeros = UnsafeRawBufferPointer(rebasing: self.zeros[..<count])
                if writing {
                    var done = 0
                    while done < count {
                        let n = pwrite(descriptor, zeros.baseAddress! + done, count - done, off_t(position + done))
                        if n < 0, errno == EINTR { continue }
                        guard n > 0 else { throw Failure("write failed (\(String(cString: strerror(errno))))") }
                        done += n
                    }
                }
                hasher.update(bufferPointer: zeros)
                position += count
            }
        }
    }

    /// A chunk's buffers, for its three stages (`writeWeights`): the chunk, from the file's byte `start` on, which two of
    /// them read, and the other buffer, into which the third reads the next chunk.
    private struct ChunkBuffers: @unchecked Sendable {
        let current: UnsafeRawBufferPointer
        let reading: UnsafeMutableRawBufferPointer
        let start: Int
    }

    /// What the three stages of a chunk share: the next chunk read, and what failed.
    private final class ChunkRead: @unchecked Sendable {
        var count = 0
        var next = 0
        var failure: Error?
    }

    private final class SourceHash: @unchecked Sendable {
        var hasher: SHA256
        init(_ hasher: SHA256) { self.hasher = hasher }
    }

    private final class CopyState: @unchecked Sendable {
        var next: Int
        var failure: Error?
        init(next: Int) { self.next = next }
    }

    /// Reads `count` bytes at `offset`, all of them.
    private static func readFully(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: Int,
                                  count: Int, file: String) throws -> Int
    {
        var done = 0
        while done < count {
            let n = pread(descriptor, buffer.baseAddress! + done, count - done, off_t(offset + done))
            if n < 0, errno == EINTR { continue }
            guard n > 0 else {
                throw Failure("\(file): read failed (\(n < 0 ? String(cString: strerror(errno)) : "end of file"))")
            }
            done += n
        }
        return done
    }

    /// Opens a file to read, or creates one to write (emptied first), past macOS's file cache.
    private static func openFile(_ url: URL, writing: Bool) throws -> Int32 {
        let descriptor = writing ? open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644) : open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw Failure("\(url.lastPathComponent) cannot be \(writing ? "written" : "read") "
                + "(\(String(cString: strerror(errno))))")
        }
        #if canImport(Darwin)
        _ = fcntl(descriptor, F_NOCACHE, 1)
        #endif
        return descriptor
    }

    /// Writes `data` to a new file, synced.
    private static func writeSynced(_ data: Data, to url: URL) throws {
        let descriptor = try openFile(url, writing: true)
        defer { close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var done = 0
            while done < bytes.count {
                let n = pwrite(descriptor, bytes.baseAddress! + done, bytes.count - done, off_t(done))
                if n < 0, errno == EINTR { continue }
                guard n > 0 else {
                    throw Failure("\(url.lastPathComponent): write failed (\(String(cString: strerror(errno))))")
                }
                done += n
            }
        }
        try syncFile(descriptor, url.lastPathComponent)
    }

    /// Has the file's bytes reach the disk itself, not only its cache (`F_FULLFSYNC`), before it takes its name.
    private static func syncFile(_ descriptor: Int32, _ name: String) throws {
        #if canImport(Darwin)
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        #endif
        guard fsync(descriptor) == 0 else { throw Failure("\(name): sync failed (\(String(cString: strerror(errno))))") }
    }

    /// Has a renaming reach the disk.
    private static func syncFolder(_ folder: URL) {
        let descriptor = open(folder.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }

    static func digest(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    static func digest(_ bytes: [UInt8]) -> String { hex(SHA256.hash(data: bytes)) }

    /// The SHA-256 of bytes, in lowercase hexadecimal: a header read from a mapped file, against its manifest's.
    public static func digest(_ bytes: UnsafeRawBufferPointer) -> String {
        var hasher = SHA256()
        hasher.update(bufferPointer: bytes)
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func quoted(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: (try? encoder.encode(text)) ?? Data("\"\"".utf8), as: UTF8.self)
    }
}
