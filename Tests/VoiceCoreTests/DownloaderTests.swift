import CryptoKit
import Foundation
import Testing

@testable import VoiceCore

/// A fake Hugging Face, in memory: serves the files of one repository, honours "Range", and can drop the
/// connection, damage a file or refuse it. Each test has its own (found by the repository name in the URL).
final class FakeHub: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hubs: [String: FakeHub] = [:]

    let repository = "tests/" + UUID().uuidString
    var files: [String: Data] = [:]
    /// Drops the connection after this many bytes of the response (once).
    var dropAfterBytes: Int?
    /// Damages the content of these files this many times.
    var damage: [String: Int] = [:]
    var ignoreRange = false
    var status: [String: Int] = [:]
    /// Wait between two 4 KB chunks (to pause in the middle of a file).
    var chunkDelay: TimeInterval = 0
    private(set) var requests: [(path: String, range: String?)] = []

    init() {
        Self.lock.withLock { Self.hubs[repository] = self }
    }

    static func hub(for url: URL) -> (FakeHub, String)? {
        // /<owner>/<name>/resolve/<revision>/<path…>
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count > 4, parts[2] == "resolve" else { return nil }
        let hub = lock.withLock { hubs[parts[0] + "/" + parts[1]] }
        return hub.map { ($0, parts[4...].joined(separator: "/")) }
    }

    func record(_ path: String, _ range: String?) -> Int? {
        Self.lock.withLock {
            requests.append((path, range))
            return status[path]
        }
    }

    func serverIsBack() {
        Self.lock.withLock { status = [:] }
    }

    func takeDrop() -> Int? {
        Self.lock.withLock { defer { dropAfterBytes = nil }; return dropAfterBytes }
    }

    func takeDamage(_ path: String) -> Bool {
        Self.lock.withLock {
            guard let left = damage[path], left > 0 else { return false }
            damage[path] = left - 1
            return true
        }
    }

    func pack(_ paths: [String]) -> ModelPack {
        ModelPack(id: "test-model", role: .languageModel, displayName: "Test", repository: repository,
                  revision: "0123abcd", license: "MIT",
                  files: paths.map { ModelFile($0, Int64(files[$0]!.count), Self.sha256(files[$0]!)) })
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeHubProtocol.self]
        return configuration
    }
}

final class FakeHubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "huggingface.co" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let (hub, path) = FakeHub.hub(for: url) else {
            return fail(URLError(.badURL))
        }
        let range = request.value(forHTTPHeaderField: "Range")
        if let status = hub.record(path, range) {
            return respond(status: status, headers: [:], body: Data())
        }
        guard var content = hub.files[path] else { return respond(status: 404, headers: [:], body: Data()) }
        if hub.takeDamage(path) { content[content.count / 2] ^= 0xFF }
        if let range, !hub.ignoreRange,
           let start = Int(range.dropFirst("bytes=".count).dropLast())
        {
            let body = content.subdata(in: start..<content.count)
            respond(status: 206, headers: ["Content-Range": "bytes \(start)-\(content.count - 1)/\(content.count)"],
                    body: body, hub: hub)
        } else {
            respond(status: 200, headers: [:], body: content, hub: hub)
        }
    }

    private func respond(status: Int, headers: [String: String], body: Data, hub: FakeHub? = nil) {
        var headers = headers
        headers["Content-Length"] = "\(body.count)"
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let drop = hub?.takeDrop()
        var sent = 0
        while sent < body.count {
            if let drop, sent >= drop {
                // Like a real connection, what arrived before the cut is delivered before the error.
                Thread.sleep(forTimeInterval: 0.05)
                return fail(URLError(.networkConnectionLost))
            }
            let chunk = body.subdata(in: sent..<min(sent + 4096, body.count))
            client?.urlProtocol(self, didLoad: chunk)
            sent += chunk.count
            if let delay = hub?.chunkDelay, delay > 0 { Thread.sleep(forTimeInterval: delay) }
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(_ error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }
}

/// Collects the progress reports.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [DownloadProgress] = []
    func add(_ p: DownloadProgress) { lock.withLock { reports.append(p) } }
    var all: [DownloadProgress] { lock.withLock { reports } }
}

@Suite("Model download")
struct DownloaderTests {
    let store = ModelStore(root: FileManager.default.temporaryDirectory
        .appending(path: "OpenMaeTests-" + UUID().uuidString).appending(path: "Models"))

    func downloader(available: Int64? = nil) -> ModelDownloader {
        let space: @Sendable () -> Int64? = { available ?? 1_000_000_000_000 }
        return ModelDownloader(store: store, configuration: FakeHub.configuration,
                               retryDelays: [.milliseconds(10)], availableBytes: space)
    }

    func randomData(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    @Test func filesAreDownloadedCheckedAndPutInPlace() async throws {
        let hub = FakeHub()
        hub.files = ["config.json": Data("{}".utf8), "weights/model.bin": randomData(300_000)]
        let pack = hub.pack(["config.json", "weights/model.bin"])
        let log = ProgressLog()
        try await downloader().download([pack]) { log.add($0) }

        #expect(store.isComplete([pack]))
        #expect(try Data(contentsOf: store.location(pack.files[1], in: pack)) == hub.files["weights/model.bin"])
        #expect(!FileManager.default.fileExists(atPath: store.incompleteDirectory.path))
        #expect(log.all.last?.doneBytes == pack.totalBytes)
        #expect(log.all.last?.totalBytes == pack.totalBytes)
        // Already there: nothing more is asked of the server.
        let before = hub.requests.count
        try await downloader().download([pack]) { _ in }
        #expect(hub.requests.count == before)
    }

    @Test func droppedConnectionResumesWhereItStopped() async throws {
        let hub = FakeHub()
        hub.files = ["model.bin": randomData(300_000)]
        hub.dropAfterBytes = 163_840  // 40 chunks of 4 KB
        let pack = hub.pack(["model.bin"])
        let log = ProgressLog()
        try await downloader().download([pack]) { log.add($0) }

        #expect(store.isComplete([pack]))
        #expect(hub.requests.map(\.range) == [nil, "bytes=163840-"])
        #expect(log.all.contains { $0.waitingForNetwork })
    }

    @Test func partialFileFromAnEarlierRunIsResumed() async throws {
        let hub = FakeHub()
        let content = randomData(200_000)
        hub.files = ["model.bin": content]
        let pack = hub.pack(["model.bin"])
        try FileManager.default.createDirectory(at: store.incompleteDirectory, withIntermediateDirectories: true)
        try content.prefix(120_000).write(to: store.partialLocation(pack.files[0]))
        #expect(store.bytesToDownload([pack]) == 80_000)

        let log = ProgressLog()
        try await downloader().download([pack]) { log.add($0) }
        #expect(store.isComplete([pack]))
        #expect(hub.requests.map(\.range) == ["bytes=120000-"])
        #expect(log.all.first?.doneBytes == 120_000)
    }

    @Test func serverIgnoringTheRangeMeansStartingAgain() async throws {
        let hub = FakeHub()
        let content = randomData(100_000)
        hub.files = ["model.bin": content]
        hub.ignoreRange = true
        let pack = hub.pack(["model.bin"])
        try FileManager.default.createDirectory(at: store.incompleteDirectory, withIntermediateDirectories: true)
        try content.prefix(40_000).write(to: store.partialLocation(pack.files[0]))

        try await downloader().download([pack]) { _ in }
        #expect(try Data(contentsOf: store.location(pack.files[0], in: pack)) == content)
    }

    @Test func damagedFileIsDownloadedAgainOnce() async throws {
        let hub = FakeHub()
        hub.files = ["model.bin": randomData(50_000)]
        hub.damage = ["model.bin": 1]
        let pack = hub.pack(["model.bin"])
        try await downloader().download([pack]) { _ in }
        #expect(store.isComplete([pack]))
        #expect(hub.requests.count == 2)
    }

    @Test func fileDamagedTwiceStopsTheDownload() async throws {
        let hub = FakeHub()
        hub.files = ["model.bin": randomData(50_000)]
        hub.damage = ["model.bin": 2]
        let pack = hub.pack(["model.bin"])
        await #expect(throws: DownloadFailure.corrupted(file: "test-model/model.bin")) {
            try await downloader().download([pack]) { _ in }
        }
        #expect(!store.isComplete([pack]))
    }

    @Test func refusedFileStopsTheDownload() async throws {
        let hub = FakeHub()
        hub.files = ["model.bin": randomData(1_000)]
        hub.status = ["model.bin": 404]
        let pack = hub.pack(["model.bin"])
        await #expect(throws: DownloadFailure.unavailable(file: "test-model/model.bin", status: 404)) {
            try await downloader().download([pack]) { _ in }
        }
    }

    @Test func busyServerIsRetried() async throws {
        let hub = FakeHub()
        hub.files = ["model.bin": randomData(1_000)]
        hub.status = ["model.bin": 503]
        let pack = hub.pack(["model.bin"])
        let task = Task { try await downloader().download([pack]) { _ in } }
        try await Task.sleep(for: .milliseconds(100))
        hub.serverIsBack()
        try await task.value
        #expect(store.isComplete([pack]))
        #expect(hub.requests.count > 2)
    }

    @Test func notEnoughSpaceIsSaidBeforeStarting() async throws {
        let hub = FakeHub()
        hub.files = ["model.bin": randomData(10_000)]
        let pack = hub.pack(["model.bin"])
        await #expect(throws: DownloadFailure.notEnoughSpace(
            needed: 10_000 + ModelDownloader.safetyMarginBytes, available: 5_000))
        {
            try await downloader(available: 5_000).download([pack]) { _ in }
        }
        #expect(hub.requests.isEmpty)
    }

    @Test func pauseKeepsWhatWasDownloaded() async throws {
        let hub = FakeHub()
        hub.files = ["model.bin": randomData(400_000)]
        hub.chunkDelay = 0.005  // 100 chunks of 4 KB: about half a second
        let pack = hub.pack(["model.bin"])
        let task = Task { try await downloader().download([pack]) { _ in } }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let kept = store.partialSize(pack.files[0])
        #expect(kept > 0 && kept < 400_000)
        #expect(store.bytesToDownload([pack]) == 400_000 - kept)
    }
}

@Suite("Model catalog")
struct CatalogTests {
    @Test func everyModelHasItsFilesWithSizesAndFingerprints() {
        for pack in ModelCatalog.all {
            #expect(!pack.files.isEmpty, "\(pack.id)")
            #expect(pack.revision.count == 40, "\(pack.id)")
            for file in pack.files {
                #expect(file.size > 0 && file.sha256.count == 64, "\(pack.id)/\(file.path)")
            }
        }
    }

    @Test func eachTierGetsSpeechVoiceAndItsLanguageModel() {
        #expect(ModelCatalog.packs(for: .unsupported).isEmpty)
        for tier in HardwareTier.selectable {
            #expect(ModelCatalog.packs(for: tier).map(\.role) == [.speechRecognition, .voice, .languageModel])
        }
        // The reference Mac's tier: about 17.5 GB, 15.4 GB of it for the language model.
        let total = ModelCatalog.packs(for: .comfort).reduce(0) { $0 + $1.totalBytes }
        #expect(total > 17_000_000_000 && total < 18_000_000_000)
    }

    @Test func downloadAddressPointsToThePinnedRevision() {
        let pack = ModelCatalog.speechRecognition
        #expect(pack.downloadURL(pack.files[0]).absoluteString
            == "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/"
            + "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe/" + pack.files[0].path)
    }

    @Test func modelsOfAnotherTierAreSeenAsUnused() throws {
        let store = ModelStore(root: FileManager.default.temporaryDirectory
            .appending(path: "OpenMaeTests-" + UUID().uuidString).appending(path: "Models"))
        let small = ModelCatalog.languageModel(for: .minimum)!
        try FileManager.default.createDirectory(at: store.folder(small), withIntermediateDirectories: true)
        try Data(count: 1_000).write(to: store.folder(small).appending(path: "x"))
        #expect(store.unusedPacks(keeping: ModelCatalog.packs(for: .comfort)).map(\.id) == [small.id])
        #expect(store.unusedPacks(keeping: ModelCatalog.packs(for: .minimum)).isEmpty)
        try store.deleteAll()
        #expect(store.usedBytes() == 0)
    }
}
