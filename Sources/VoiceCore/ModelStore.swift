import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto  // swift-crypto: the same API on Linux and Windows
#endif

/// The models folder on disk (`~/Library/Application Support/OpenMaé/Models`): what is there, what is
/// missing, what can be deleted.
///
/// A downloaded file only gets its final name once its SHA-256 has been checked, so "present with the right
/// size" means "verified": checking a whole tier takes a few milliseconds instead of re-reading 17 GB.
///
/// The folder must be named "Models": FluidAudio (the voice) is given its parent and adds "Models" itself.
public struct ModelStore: Sendable {
    public let root: URL

    public init(root: URL = AppIdentity.modelsDirectory) {
        self.root = root
    }

    public func folder(_ pack: ModelPack) -> URL {
        root.appending(path: pack.id, directoryHint: .isDirectory)
    }

    public func location(_ file: ModelFile, in pack: ModelPack) -> URL {
        folder(pack).appending(path: file.path, directoryHint: .notDirectory)
    }

    /// Partial downloads, named after their SHA-256 (so they cannot be mistaken for a finished file).
    var incompleteDirectory: URL {
        root.appending(path: ".incomplete", directoryHint: .isDirectory)
    }

    func partialLocation(_ file: ModelFile) -> URL {
        incompleteDirectory.appending(path: file.sha256, directoryHint: .notDirectory)
    }

    func partialSize(_ file: ModelFile) -> Int64 {
        Self.size(of: partialLocation(file)) ?? 0
    }

    // MARK: - What is there

    /// Files of `pack` that are not downloaded yet.
    public func missingFiles(_ pack: ModelPack) -> [ModelFile] {
        pack.files.filter { Self.size(of: location($0, in: pack)) != $0.size }
    }

    public func isComplete(_ packs: [ModelPack]) -> Bool {
        packs.allSatisfy { missingFiles($0).isEmpty }
    }

    /// What is left to download for these packs, in bytes (partial downloads count for what they hold).
    public func bytesToDownload(_ packs: [ModelPack]) -> Int64 {
        packs.flatMap(missingFiles).reduce(0) { $0 + $1.size - min(partialSize($1), $1.size) }
    }

    /// Space taken on disk by everything in the models folder, partial downloads included.
    public func usedBytes() -> Int64 {
        Self.allocatedSize(of: root)
    }

    /// The models of `catalog` on disk, even partly: their folder, or a partial download of one of their files.
    public func presentPacks(of catalog: [ModelPack] = ModelCatalog.all) -> [ModelPack] {
        catalog.filter { pack in
            FileManager.default.fileExists(atPath: folder(pack).path)
                || pack.files.contains { FileManager.default.fileExists(atPath: partialLocation($0).path) }
        }
    }

    /// Space taken by one model: its folder and its partial downloads.
    public func usedBytes(_ pack: ModelPack) -> Int64 {
        Self.allocatedSize(of: folder(pack)) + pack.files.reduce(0) { $0 + Self.allocatedSize(ofFile: partialLocation($1)) }
    }

    /// What Settings › Advanced shows: the total, and each model of `catalog` on disk. `inUse`: the ids of the models
    /// that cannot be deleted on their own (the tier's, those the engine has loaded).
    public func storage(inUse: Set<String>, catalog: [ModelPack] = ModelCatalog.all) -> ModelStorage {
        ModelStorage(
            usedBytes: usedBytes(),
            models: presentPacks(of: catalog).map { pack in
                ModelStorage.Model(id: pack.id, role: pack.role, displayName: pack.displayName, bytes: usedBytes(pack),
                                   missingBytes: bytesToDownload([pack]), inUse: inUse.contains(pack.id))
            },
            folder: root.path)
    }

    /// Free space for the models, in bytes. "Important usage" counts the space macOS can free on demand
    /// (purgeable caches), like the Finder does.
    public func availableBytes() -> Int64? {
        var url = root
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        #if os(macOS) || os(iOS)
        if let important = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        {
            return important
        }
        #endif
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity)
            .map(Int64.init)
    }

    // MARK: - Deleting

    /// A path that would leave the models folder: nothing is deleted.
    public struct OutsideModelsFolder: Error, Equatable {
        public let name: String
    }

    /// Deletes one model: its folder and its partial downloads, and nothing else. A pack whose id, or one of whose
    /// files' fingerprints, is not a plain name of the models folder ("", "..", a path) is refused before anything is
    /// deleted.
    public func delete(_ pack: ModelPack) throws {
        for name in [pack.id] + pack.files.map(\.sha256) where !Self.isPlainName(name) {
            throw OutsideModelsFolder(name: name)
        }
        try Self.removeIfPresent(folder(pack))
        for file in pack.files {
            try Self.removeIfPresent(partialLocation(file))
        }
    }

    /// One entry of a folder, by itself: not empty, not "." or "..", no separator, not hidden.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && !name.contains(":")
            && name.rangeOfCharacter(from: .controlCharacters) == nil
    }

    /// Deletes every model and every partial download.
    public func deleteAll() throws {
        try Self.removeIfPresent(root)
    }

    // MARK: - Checking

    /// Re-reads every downloaded file of `pack` and returns those whose content is not the expected one.
    /// Slow (about 1 s per GB): for diagnosis only, the downloader already checks each file it writes.
    public func corruptedFiles(_ pack: ModelPack, progress: (ModelFile) -> Void = { _ in }) throws -> [ModelFile] {
        try pack.files.filter { file in
            let url = location(file, in: pack)
            guard Self.size(of: url) == file.size else { return false }  // missing, not corrupted
            progress(file)
            var hasher = SHA256()
            try Self.hash(url, length: file.size, into: &hasher)
            return Self.hex(hasher.finalize()) != file.sha256
        }
    }

    // MARK: - Helpers

    static func size(of url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    static func allocatedSize(of folder: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys))
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func allocatedSize(ofFile url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? 0)
    }

    static func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Feeds the first `length` bytes of a file to `hasher`, 8 MB at a time.
    static func hash(_ url: URL, length: Int64, into hasher: inout SHA256) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var remaining = length
        while remaining > 0 {
            guard let data = try handle.read(upToCount: Int(min(remaining, 8 << 20))), !data.isEmpty else { break }
            hasher.update(data: data)
            remaining -= Int64(data.count)
        }
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
