import Cmlx
import Darwin
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Synchronization
import VoiceCore

/// The language model's weights used by the GPU straight from the model's files, mapped into memory, rather than read
/// into buffers of MLX's own: what `MLXChatModel.load` does with a folder whose files were rewritten for it
/// (`AlignedSafetensors`, once, before the first load: `prepare`).
///
/// MLX reads every weight into memory of its own, which macOS can only compress or write to swap when it runs short:
/// on the reference Mac, 42 to 62% of Gemma 4 26B's weights were compressed by the end of a load, at about 1:1 (4-bit
/// weights do not compress). Pages of a mapped file are dropped instead, and read again from the file when needed; and
/// macOS does not count them in the app's memory (`footprint`: 15 GB → 1.7 GB with Gemma 4 26B). MLX wraps such memory
/// without a copy (`MLXArray(rawPointer:)`, a Metal buffer with no copy) when it starts on a page boundary and is a whole
/// number of pages long; it copies it otherwise, without a word. So each tensor is wrapped from its region in the file:
/// its data, padded to the next page; a tensor whose data is not a whole number of pages long is a view of its region.
/// One Metal buffer per tensor: the GPU's driver wires (and reads back when macOS dropped them) a whole buffer at a time,
/// so a buffer per file would have a layer read back the whole file.
///
/// Then the steps of mlx-swift-lm's loader (`LLMModelFactory`, `loadWeights`): the model's clean-up (`sanitize`), the
/// quantization, `update(parameters:)`, with nothing changed in MLX or mlx-swift-lm. Every weight is checked to be the
/// files' memory, at its own tensor's place, once loaded, and again with what the model swaps in to compute in float32
/// (`MLXChatModel.checkFileBackedWeights`): a copy or a misaligned file makes the load fail, and `MLXChatModel.load`
/// reads the weights into MLX's memory instead. On the reference Mac, Gemma 4 26B and E2B give the same tokens either
/// way, and every weight holds the bytes of the same tensor in the original files.
///
/// The files are mapped read-only and shared (`MAP_SHARED`): wiring a page of a private mapping for the GPU makes it an
/// anonymous copy. MLX v0.32.2 may write an operation's result into the buffer of an input it holds the only reference
/// to; every tensor stays held here, so none ever is (read-only, the write would crash rather than change the file).
/// A mapping lasts as long as an array uses it: each array's finalizer holds it.
public final class FileBackedWeights: @unchecked Sendable {
    /// `VOICE_FILE_BACKED_WEIGHTS=0` has `MLXChatModel.load` read the weights into MLX's own memory, as before, even from a
    /// rewritten folder: for comparisons. Read at each load.
    static var allowed: Bool { ProcessInfo.processInfo.environment["VOICE_FILE_BACKED_WEIGHTS"] != "0" }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// A safetensors file, mapped read-only and shared, unmapped once nothing uses it.
    final class Mapping: @unchecked Sendable {
        let url: URL
        let descriptor: Int32
        let base: UnsafeMutableRawPointer
        let size: Int
        /// Where its first tensor starts and its last tensor's region ends: what `bringBack` reads (not the zeros of the
        /// file's end, a hole on the disk that would take memory once read).
        fileprivate(set) var dataStart = 0
        fileprivate(set) var dataEnd = 0

        init(_ url: URL) throws {
            self.url = url
            descriptor = open(url.path, O_RDONLY)
            guard descriptor >= 0 else {
                throw Failure("\(url.lastPathComponent): cannot be opened (\(String(cString: strerror(errno))))")
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_size > 0 else {
                close(descriptor)
                throw Failure("\(url.lastPathComponent): cannot be read")
            }
            size = Int(status.st_size)
            guard let base = mmap(nil, size, PROT_READ, MAP_SHARED, descriptor, 0), base != MAP_FAILED else {
                close(descriptor)
                throw Failure("\(url.lastPathComponent): cannot be mapped (\(String(cString: strerror(errno))))")
            }
            self.base = base
        }

        deinit {
            munmap(base, size)
            close(descriptor)
        }

        var addresses: Range<UInt> {
            UInt(bitPattern: base) ..< UInt(bitPattern: base) + UInt(size)
        }
    }

    let mappings: [Mapping]
    /// The tensors, named as in the files (what the model's clean-up gets).
    let tensors: [String: MLXArray]
    /// The files' metadata (the first file that has some, as mlx-swift-lm passes it to `sanitize`).
    let metadata: [String: String]
    /// The regions the tensors that are not a whole number of pages long are views of.
    private let regions: [MLXArray]
    /// The tensors by the address their data starts at, for the checks.
    private let starts: [UInt: String]
    /// For each of the model's weights, by its name in the model, the tensor of the files the model's clean-up gave it
    /// (`load(into:)`): where `verify` expects it.
    private var expected: [String: String] = [:]

    /// Maps the weight files of a rewritten model folder (those its manifest lists) and wraps every tensor. Throws if a
    /// file is not the one the manifest describes or not aligned, or if MLX copied a tensor rather than wrapping it.
    init(directory: URL, manifest: AlignedSafetensors.Manifest) throws {
        let files = manifest.files.filter(\.holdsWeights).sorted { $0.path < $1.path }  // mlx-swift-lm's order
        guard !files.isEmpty else { throw Failure("\(directory.path): no safetensors file") }
        var mappings: [Mapping] = []
        var tensors: [String: MLXArray] = [:]
        var regions: [MLXArray] = []
        var starts: [UInt: String] = [:]
        var metadata: [String: String] = [:]
        for file in files {
            let url = directory.appending(path: file.path, directoryHint: .notDirectory)
            let mapping = try Mapping(url)
            mappings.append(mapping)
            let bytes = UnsafeRawBufferPointer(start: mapping.base, count: mapping.size)
            let header = try AlignedSafetensors.header(bytes: bytes, file: file.path)
            // The header the manifest describes, read from the memory the GPU will use: not a file replaced since.
            guard mapping.size == file.size,
                  AlignedSafetensors.digest(UnsafeRawBufferPointer(rebasing: bytes[..<header.dataStart]))
                  == file.headerSHA256
            else { throw Failure("\(file.path) is not the file its manifest describes") }
            if let problem = AlignedSafetensors.misalignment(header, fileSize: mapping.size, file: file.path) {
                throw Failure("not aligned: \(problem)")
            }
            mapping.dataStart = header.tensors.first?.offset ?? header.dataStart
            mapping.dataEnd = header.dataEnd
            if metadata.isEmpty { metadata = header.metadata }
            for tensor in header.tensors {
                guard let dtype = Self.dtype(tensor.dtype) else {
                    throw Failure("\(file.path): tensor \(tensor.name) has a type MLX lacks (\(tensor.dtype))")
                }
                let array: MLXArray
                if tensor.byteCount == 0 {
                    array = MLXArray.zeros(tensor.shape, dtype: dtype)  // no data to use from the file
                } else {
                    let address = mapping.base + tensor.offset
                    // Each array's finalizer holds the mapping: MLX calls it once it lets the buffer go.
                    if tensor.byteCount == tensor.regionCount {
                        array = MLXArray(rawPointer: address, tensor.shape, dtype: dtype) { [mapping] in _ = mapping }
                        guard Self.address(of: array) == UInt(bitPattern: address) else {
                            throw Failure("MLX copied tensor \(tensor.name) instead of using the file's memory")
                        }
                    } else {
                        let region = MLXArray(rawPointer: address, [tensor.regionCount], dtype: .uint8) { [mapping] in
                            _ = mapping
                        }
                        guard Self.address(of: region) == UInt(bitPattern: address) else {
                            throw Failure("MLX copied the region of tensor \(tensor.name) instead of using the file's memory")
                        }
                        regions.append(region)
                        array = region[0 ..< tensor.byteCount].view(dtype: dtype).reshaped(tensor.shape)
                    }
                    starts[UInt(bitPattern: address)] = tensor.name
                }
                guard tensors.updateValue(array, forKey: tensor.name) == nil else {
                    throw Failure("tensor \(tensor.name) is in two files")
                }
            }
        }
        self.mappings = mappings
        self.tensors = tensors
        self.regions = regions
        self.starts = starts
        self.metadata = metadata
    }

    /// MLX's type for a safetensors type name, as MLX reads it.
    static func dtype(_ name: String) -> DType? {
        switch name {
        case "BOOL": .bool
        case "U8": .uint8
        case "I8": .int8
        case "U16": .uint16
        case "I16": .int16
        case "U32": .uint32
        case "I32": .int32
        case "U64": .uint64
        case "I64": .int64
        case "F16": .float16
        case "BF16": .bfloat16
        case "F32": .float32
        case "F64": .float64
        case "C64": .complex64
        default: nil
        }
    }

    /// Where an evaluated array's data starts. (`asData(access: .noCopy)` hands over a copy for arrays of 14 bytes or
    /// less, which `Data` keeps inline: the bfloat16 scalars.)
    static func address(of array: MLXArray) -> UInt {
        array.eval()
        return UInt(bitPattern: mlx_array_data_uint8(array.ctx))
    }

    // MARK: - Checks

    /// What `verify` found.
    struct Check: CustomStringConvertible {
        var fromFiles = 0
        var fromFilesBytes = 0
        /// Copies `verify` was told to accept (the small weights computing in float32 swaps for copies of their own).
        var acceptedCopies = 0
        var acceptedCopiesBytes = 0

        var description: String {
            String(format: "%d arrays (%.2f GB) in the files' memory, each at its own tensor's place", fromFiles,
                   Double(fromFilesBytes) / 1e9)
                + (acceptedCopies > 0
                    ? String(format: "; %d small copies (%.1f MB)", acceptedCopies, Double(acceptedCopiesBytes) / 1e6) : "")
        }
    }

    /// Checks that every weight is the files' memory, where the tensor the model's clean-up gave it starts (on a page
    /// boundary, as the files are aligned), and throws otherwise: a copy MLX made without a word, or a weight in another
    /// tensor's place. `copyAccepted` tells, by their names, the weights that may be copies.
    @discardableResult
    func verify(_ arrays: [(String, MLXArray)], copyAccepted: (String) -> Bool = { _ in false }) throws -> Check {
        var check = Check()
        var problems: [String] = []
        let page = UInt(AlignedSafetensors.alignment)
        for (name, array) in arrays where array.nbytes > 0 {
            let address = Self.address(of: array)
            if let found = starts[address], address % page == 0, found == expected[name] {
                check.fromFiles += 1
                check.fromFilesBytes += array.nbytes
            } else if copyAccepted(name) {
                check.acceptedCopies += 1
                check.acceptedCopiesBytes += array.nbytes
            } else if let found = starts[address] {
                problems.append("\(name): at tensor \(found)'s place, not at \(expected[name] ?? "a tensor of its own")'s")
            } else if mappings.contains(where: { $0.addresses.contains(address) }) {
                problems.append("\(name): in the files, but not where a tensor starts")
            } else {
                problems.append("\(name): not in the files' memory (a copy)")
            }
        }
        guard problems.isEmpty else {
            throw Failure("weights not used from the files: \(problems.count) of \(arrays.count), "
                          + problems.prefix(8).joined(separator: "; "))
        }
        return check
    }

    // MARK: - In memory

    /// Has macOS read back into memory, from the files, the weights' pages it dropped, and keeps them there: what
    /// `MLXChatModel` does after loading, as the user starts to speak (`wakeUp`) and in its keep-warm passes, instead of
    /// reading one byte of every page from the CPU (`MemoryResidency.touch`), which reads a dropped page with one fault at
    /// a time.
    ///
    /// `F_RDADVISE` over each file's tensors, 512 MiB at a time, returns once they are read: 6.9 GB/s for Gemma 4 26B
    /// dropped whole on the reference Mac (2.1 s), against 1.5 to 2.4 GB/s for page faults from 4 to 8 threads. But the
    /// pages it reads are speculative: macOS counts them as free and takes them back first, and with little free memory it
    /// took back the first chunks while it read the next (56% of Gemma 4 E2B's file kept, with the RAM full of file cache).
    /// Reading one byte of every page of a chunk maps its pages, which keeps them (100%); so each chunk's pages are mapped
    /// from 4 threads while the next chunk is read: Gemma 4 26B dropped whole came back in 2.2 to 2.6 s in a conversation,
    /// in time for the request (1 thread after each read: 3.2 to 3.9 s; 8 threads after each: 3.0 to 3.2 s).
    ///
    /// A file system that refuses `F_RDADVISE` leaves the reads to the faults (logged once). `stop`, asked between two
    /// chunks and every 64 MB of a chunk's pages, ends it where it is.
    func bringBack(stop: (@Sendable () -> Bool)? = nil) {
        let chunk = 512 << 20
        let mapped = DispatchGroup()
        let mapping = DispatchQueue(label: "file-backed weights' pages", qos: .userInitiated, attributes: .concurrent)
        var refused: (count: Int, reason: String)?
        reading: for file in mappings {
            var offset = file.dataStart
            while offset < file.dataEnd {
                if stop?() == true { break reading }
                let count = min(chunk, file.dataEnd - offset)
                var advice = radvisory(ra_offset: off_t(offset), ra_count: Int32(count))
                if fcntl(file.descriptor, F_RDADVISE, &advice) != 0 {
                    refused = ((refused?.count ?? 0) + 1, refused?.reason ?? String(cString: strerror(errno)))
                }
                let start = UInt(bitPattern: file.base) + UInt(offset)
                mapping.async(group: mapped) { MemoryResidency.touch([start ..< start + UInt(count)], threads: 4, stop: stop) }
                offset += count
            }
        }
        mapped.wait()
        if let refused, !Self.refusalLogged.exchange(true, ordering: .relaxed) {
            DebugLog.log("LLM: F_RDADVISE refused for \(refused.count) chunk(s) of the weights (\(refused.reason)): their "
                + "pages are read one fault at a time")
        }
    }

    /// `bringBack` says once per process that `F_RDADVISE` is refused.
    private static let refusalLogged = Atomic<Bool>(false)

    // MARK: - Loading the model

    /// Loads the model in a rewritten folder as mlx-swift-lm's `LLMModelFactory` does: its configuration, the model of
    /// its type, its tokenizer, then its weights (`load(into:)`), wrapped from the mapped files.
    ///
    /// The model's configuration gets what the factory reads from the folder that the app uses (the end-of-answer tokens,
    /// from `config.json` and `generation_config.json`); its tool-call format and reasoning are the model's own
    /// (`MLXChatModel` reads calls and thoughts itself).
    static func loadModel(directory: URL, manifest: AlignedSafetensors.Manifest) async throws
        -> (context: ModelContext, weights: FileBackedWeights)
    {
        let configurationData = try Data(contentsOf: directory.appending(component: "config.json"))
        let base = try JSONDecoder.json5().decode(BaseConfiguration.self, from: configurationData)
        let model = try await LLMModelFactory.shared.typeRegistry.createModel(
            configuration: configurationData, modelType: base.modelType)
        var endTokens = base.effectiveEOSTokenIds
        var stopStrings = Set<String>()
        if let data = try? Data(contentsOf: directory.appending(component: "generation_config.json")),
           let generation = try? JSONDecoder.json5().decode(GenerationConfigFile.self, from: data)
        {
            if let ids = generation.eosTokenIds?.values { endTokens = Set(ids) }
            stopStrings = generation.stopStrings
        }
        async let tokenizerLoad = TokenizerLoaderBridge().load(from: directory)
        // Off Swift's concurrency threads, which must never block, as mlx-swift-lm's loader.
        let boxed = SendableModel(model)
        let quantization = base.perLayerQuantization
        let weights = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    let weights = try FileBackedWeights(directory: directory, manifest: manifest)
                    try weights.load(into: boxed.model, quantization: quantization)
                    return weights
                })
            }
        }
        let tokenizer = try await tokenizerLoad
        let configuration = ModelConfiguration(directory: directory, stopStrings: stopStrings, eosTokenIds: endTokens,
                                               toolCallFormat: model.toolCallFormat,
                                               reasoningConfig: model.reasoningConfig)
        let messages = (model as? any LLMModel)?.messageGenerator(tokenizer: tokenizer) ?? DefaultMessageGenerator()
        let processor = TemplateInputProcessor(tokenizer: tokenizer, messageGenerator: messages)
        return (ModelContext(configuration: configuration, model: model, processor: processor, tokenizer: tokenizer),
                weights)
    }

    /// mlx-swift-lm's `loadWeights` after it has read the files: the model's clean-up, its quantization (from the
    /// configuration), `update(parameters:)` checking every key and shape, the model's preparation for inference, and
    /// its evaluation. Then every weight is checked to be the files' own memory, at the place of the tensor the clean-up
    /// gave it.
    func load(into model: any MLXLMCommon.LanguageModel, quantization: BaseConfiguration.PerLayerQuantization?) throws {
        guard !(model is any AdditionalWeightFilesProviding) else {
            throw Failure("\(type(of: model)) reads weights from other files too: not handled")
        }
        let weights = model.sanitize(weights: tensors, metadata: metadata)
        let names = Dictionary(tensors.map { (ObjectIdentifier($0.value), $0.key) }) { first, _ in first }
        for (key, array) in weights {
            guard let name = names[ObjectIdentifier(array)] else {
                throw Failure("the model's clean-up makes \(key) out of other tensors: it cannot be used from the files")
            }
            expected[key] = name
        }
        if let quantization {
            quantize(model: model) { path, _ in
                guard weights["\(path).scales"] != nil else { return nil }
                return quantization.quantization(layer: path)?.asTuple
            }
        }
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        do {
            try model.prepare()
        } catch {
            // As mlx-swift-lm: a failed optional optimization leaves the model usable through its unfused path.
            DebugLog.log("LLM: preparing \(type(of: model)) for inference failed: \(error)")
        }
        eval(model)
        let check = try verify(model.parameters().flattened())
        DebugLog.log("LLM: weights from the files: \(check)")
    }

    /// The tensors of a model folder's files that reach the model: those its clean-up (`sanitize`, the same arrays the
    /// loader would give it) keeps as they are, renamed at most; it drops the others. Nothing is read but the files'
    /// headers. Throws when the clean-up makes a weight out of other tensors (splits, converts…): such a weight could not
    /// be used from the files.
    static func keptTensors(in directory: URL) async throws -> Set<String> {
        let configurationData = try Data(contentsOf: directory.appending(component: "config.json"))
        let base = try JSONDecoder.json5().decode(BaseConfiguration.self, from: configurationData)
        let model = try await LLMModelFactory.shared.typeRegistry.createModel(
            configuration: configurationData, modelType: base.modelType)
        guard !(model is any AdditionalWeightFilesProviding) else {
            throw Failure("\(type(of: model)) reads weights from other files too: not handled")
        }
        var tensors: [String: MLXArray] = [:]
        var metadata: [String: String] = [:]
        for url in try AlignedSafetensors.weightFiles(in: directory) {
            let (arrays, fileMetadata) = try loadArraysAndMetadata(url: url)  // lazy: nothing read but the header
            tensors.merge(arrays) { _, new in new }
            if metadata.isEmpty { metadata = fileMetadata }
        }
        let names = Dictionary(tensors.map { (ObjectIdentifier($0.value), $0.key) }) { first, _ in first }
        var kept = Set<String>()
        for (key, array) in model.sanitize(weights: tensors, metadata: metadata) {
            guard let name = names[ObjectIdentifier(array)] else {
                throw Failure("the model's clean-up makes \(key) out of other tensors: it cannot be used from the files")
            }
            kept.insert(name)
        }
        return kept
    }

    // MARK: - The files

    /// The manifest of a folder whose weights can be used from its files (`AlignedSafetensors.state`), nil when they
    /// cannot (never rewritten, a rewrite stopped half-way or given up, a file that is not the rewritten one), or with
    /// `VOICE_FILE_BACKED_WEIGHTS=0`. Logs why a folder that was rewritten cannot be used.
    static func usableManifest(_ directory: URL) -> AlignedSafetensors.Manifest? {
        switch AlignedSafetensors.state(of: directory) {
        case .aligned(let manifest):
            guard allowed else {
                DebugLog.log("LLM: weights read into MLX's memory (VOICE_FILE_BACKED_WEIGHTS=0)")
                return nil
            }
            return manifest
        case .aligning:
            DebugLog.log("LLM: weights read into MLX's memory: the rewrite of their files is not finished")
            return nil
        case .leftAsIs(let why):
            DebugLog.log("LLM: weights read into MLX's memory: their files were left as they are (\(why))")
            return nil
        case .original:
            return nil
        }
    }

    /// Before the language model `pack` is loaded (`AssistantHost.start`): rewrites its files once so that its weights can
    /// be used from them, or finishes a rewrite stopped half-way (`AlignedSafetensors.align`, in place: 17 s for
    /// Gemma 4 26B on the reference Mac). Only for the models checked (`ModelCatalog.alignedWeights`), and when the disk has
    /// room for the largest file's new version; the files are left as they are otherwise, and the model is loaded as
    /// before. The task's cancellation (the app quits) stops it where it is; the next launch goes on.
    @discardableResult
    public static func prepare(_ pack: ModelPack, in store: ModelStore) async -> AlignedSafetensors.Outcome {
        guard ModelCatalog.alignedWeights.contains(pack.id) else {
            return .leftAsIs("\(pack.id) is not one of the models whose weights are used from their files")
        }
        let folder = store.folder(pack)
        let keep: Set<String>?
        switch AlignedSafetensors.state(of: folder) {
        case .aligned:
            return .alreadyAligned
        case .leftAsIs(let why):
            DebugLog.log("models: \(pack.id) left as it is (\(why))")
            return .leftAsIs(why)
        case .aligning:
            keep = nil  // the manifest says the rest
        case .original:
            do {
                keep = try await keptTensors(in: folder)
            } catch {
                DebugLog.log("models: \(pack.id) left as it is (\(error))")
                return .leftAsIs("\(error)")
            }
        }
        let stopped = StopFlag()
        let clock = ContinuousClock()
        let start = clock.now
        DebugLog.log("models: rewriting \(pack.id) so that its weights can be used from its files")
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AlignedSafetensors.Outcome, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: AlignedSafetensors.align(
                        folder: folder, catalog: pack.files, revision: pack.revision, keeping: keep,
                        availableBytes: { store.availableBytes() }, shouldStop: { stopped.isSet },
                        progress: { DebugLog.log("models: rewriting \(pack.id)/\($0)") }))
                }
            }
        } onCancel: {
            stopped.set()
        }
        DebugLog.log("models: \(pack.id): \(outcome) in \(clock.now - start)")
        return outcome
    }
}

/// Set once, read from any thread: `FileBackedWeights.prepare`'s rewrite stops at its next check.
private final class StopFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    var isSet: Bool { flag.load(ordering: .relaxed) }
    func set() { flag.store(true, ordering: .relaxed) }
}

/// A model handed to the loading queue (`FileBackedWeights.loadModel`), as mlx-swift-lm's `SendableBox`: nothing else
/// uses it meanwhile.
private struct SendableModel: @unchecked Sendable {
    let model: any MLXLMCommon.LanguageModel
    init(_ model: any MLXLMCommon.LanguageModel) { self.model = model }
}

/// What mlx-swift-lm's LLM factory gives a model to turn a user's input into tokens (its own is private): the chat
/// template applied to the messages. The app never calls it: `MLXChatModel` renders its conversations itself.
private struct TemplateInputProcessor: UserInputProcessor {
    let tokenizer: any MLXLMCommon.Tokenizer
    let messageGenerator: any MessageGenerator

    func prepare(input: UserInput) async throws -> LMInput {
        let tokens = try tokenizer.applyChatTemplate(messages: messageGenerator.generate(from: input), tools: input.tools,
                                                     additionalContext: input.additionalContext)
        return LMInput(tokens: MLXArray(tokens))
    }
}
