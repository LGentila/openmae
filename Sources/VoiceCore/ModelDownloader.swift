import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession on Linux and Windows
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Progress of a model download, for the first-launch screen.
public struct DownloadProgress: Sendable, Codable, Equatable {
    /// Bytes on disk so far (including what earlier, interrupted downloads left) and bytes in all.
    public var doneBytes: Int64
    public var totalBytes: Int64
    /// Speed over the last few seconds; nil at the very start.
    public var bytesPerSecond: Double?
    /// Display name of the model being downloaded.
    public var currentModel: String?
    /// The connection dropped: the download waits, then resumes by itself.
    public var waitingForNetwork = false
    /// Bytes still missing for each model being downloaded, for a progress per model.
    public var missingBytes: [ModelRole: Int64] = [:]

    public init(doneBytes: Int64, totalBytes: Int64) {
        self.doneBytes = doneBytes
        self.totalBytes = totalBytes
    }

    public var fraction: Double {
        totalBytes > 0 ? min(1, max(0, Double(doneBytes) / Double(totalBytes))) : 1
    }

    public var secondsRemaining: Double? {
        guard let speed = bytesPerSecond, speed > 0, !waitingForNetwork else { return nil }
        return Double(max(0, totalBytes - doneBytes)) / speed
    }
}

/// Why a download stopped and cannot go on by itself. (A dropped connection is not a failure: the download
/// waits and resumes.)
public enum DownloadFailure: Error, Sendable, Codable, Equatable {
    /// Not enough free space: bytes needed (models plus a safety margin) and bytes available.
    case notEnoughSpace(needed: Int64, available: Int64)
    /// The server refused a file (HTTP status 404, 403…): the file moved, the app needs an update.
    case unavailable(file: String, status: Int)
    /// A file arrived damaged twice in a row.
    case corrupted(file: String)
    /// A file could not be written on the disk.
    case disk(String)
}

/// Downloads models into the models folder: resumes after an interruption (even after quitting the app),
/// checks the SHA-256 of every file, checks the free space first, and waits for the network to come back.
///
/// Each file goes into `Models/.incomplete/<sha256>` and is moved to its place only once complete and
/// verified. Four files are downloaded at a time. It does not make big files faster (measured on the
/// reference Mac, one connection already uses the whole line, ~45 MB/s), but each file costs a few round
/// trips to the server (Hugging Face redirects every request to its CDN), and the models have dozens of
/// small files: one at a time, a 2.2 GB download spent a third of its time waiting.
public actor ModelDownloader {
    public typealias ProgressHandler = @Sendable (DownloadProgress) -> Void

    /// Space left free on top of the models: macOS and the compiled-model caches need some.
    public static let safetyMarginBytes: Int64 = 1_000_000_000
    static let filesAtOnce = 4

    private let store: ModelStore
    private let configuration: URLSessionConfiguration
    /// Waits between attempts after a network error; the last one repeats until the network is back.
    private let retryDelays: [Duration]
    private let availableBytes: @Sendable () -> Int64?

    /// `availableBytes` replaces the free-space measurement in tests.
    public init(
        store: ModelStore,
        configuration: URLSessionConfiguration = ModelDownloader.defaultConfiguration,
        retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)],
        availableBytes: (@Sendable () -> Int64?)? = nil
    ) {
        self.store = store
        self.configuration = configuration
        self.retryDelays = retryDelays
        self.availableBytes = availableBytes ?? { store.availableBytes() }
    }

    /// No cache, no cookies; Hugging Face's public repositories need no account.
    public static var defaultConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60  // longest silence tolerated in the middle of a file
        configuration.httpAdditionalHeaders = ["User-Agent": "\(AppIdentity.directoryName.folding(options: .diacriticInsensitive, locale: nil))/model-downloader"]
        return configuration
    }

    /// Downloads every missing file of `packs`. Returns once all are on disk and verified.
    ///
    /// Throws a `DownloadFailure` for problems a retry cannot fix, and `CancellationError` when the calling
    /// task is cancelled (pause): what was downloaded stays on disk for next time.
    public func download(_ packs: [ModelPack], progress: @escaping ProgressHandler) async throws {
        let todo = packs.flatMap { pack in store.missingFiles(pack).map { (pack, $0) } }
        let total = todo.reduce(Int64(0)) { $0 + $1.1.size }
        let alreadyThere = todo.reduce(Int64(0)) { $0 + min(store.partialSize($1.1), $1.1.size) }
        var start = DownloadProgress(doneBytes: alreadyThere, totalBytes: total)
        for (pack, file) in todo {
            start.missingBytes[pack.role, default: 0] += file.size - min(store.partialSize(file), file.size)
        }
        let reporter = ProgressReporter(start, progress)

        let needed = total - alreadyThere + Self.safetyMarginBytes
        if !todo.isEmpty, let available = availableBytes(), available < needed {
            throw DownloadFailure.notEnoughSpace(needed: needed, available: available)
        }
        do {
            try FileManager.default.createDirectory(at: store.incompleteDirectory, withIntermediateDirectories: true)
        } catch {
            throw DownloadFailure.disk(error.localizedDescription)
        }

        // One session for every file: its connections are reused, which saves a connection set-up (about
        // 0.5 s) per file; there are dozens of small ones.
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        reporter.send()
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = todo.makeIterator()
            func startNext() {
                guard let (pack, file) = next.next() else { return }
                group.addTask {
                    reporter.update { $0.currentModel = pack.displayName }
                    try await self.fetch(file, of: pack, session: session, reporter: reporter)
                }
            }
            for _ in 0..<Self.filesAtOnce { startNext() }
            // A failure ends the group, which cancels the other files (their partial files stay).
            while try await group.next() != nil { startNext() }
        }
        // Partial files left by another tier's download are of no use any more.
        try? FileManager.default.removeItem(at: store.incompleteDirectory)
        reporter.update { $0.currentModel = nil }
    }

    // MARK: - One file

    /// What went wrong with one attempt at one file.
    private enum AttemptError: Error {
        /// Network trouble: try again later. `progressed`: some bytes arrived during this attempt.
        case network(progressed: Bool)
        /// The bytes on disk are wrong: start the file again from zero.
        case damaged
        /// The server refuses the file (HTTP status).
        case refused(status: Int)
        case fatal(DownloadFailure)
    }

    private func fetch(_ file: ModelFile, of pack: ModelPack, session: URLSession, reporter: ProgressReporter)
        async throws
    {
        let name = pack.id + "/" + file.path
        var damagedAttempts = 0
        var networkFailures = 0
        while true {
            try Task.checkCancellation()
            do {
                try await attempt(file, of: pack, session: session, reporter: reporter)
                return
            } catch AttemptError.damaged {
                damagedAttempts += 1
                DebugLog.log("download: \(name) arrived damaged (attempt \(damagedAttempts))")
                let removed = min(store.partialSize(file), file.size)
                try? FileManager.default.removeItem(at: store.partialLocation(file))
                reporter.update {
                    $0.doneBytes -= removed
                    $0.missingBytes[pack.role, default: 0] += removed
                }
                if damagedAttempts >= 2 { throw DownloadFailure.corrupted(file: name) }
            } catch AttemptError.network(let progressed) {
                if progressed { networkFailures = 0 }
                let delay = retryDelays[min(networkFailures, retryDelays.count - 1)]
                networkFailures += 1
                DebugLog.log("download: network problem on \(name), retrying in \(delay)")
                reporter.update { $0.waitingForNetwork = true }
                try await Task.sleep(for: delay)  // throws when the download is paused meanwhile
                reporter.update { $0.waitingForNetwork = false }
            } catch AttemptError.refused(let status) {
                throw DownloadFailure.unavailable(file: name, status: status)
            } catch AttemptError.fatal(let failure) {
                if case .disk = failure, let available = availableBytes(),
                   available < file.size - store.partialSize(file)
                {
                    let left = reporter.current.totalBytes - reporter.current.doneBytes
                    throw DownloadFailure.notEnoughSpace(needed: left + Self.safetyMarginBytes, available: available)
                }
                throw failure
            }
        }
    }

    /// One attempt: resumes the partial file where it stopped, appends what the server sends while hashing
    /// it, then checks size and SHA-256 and moves the file to its place.
    private func attempt(_ file: ModelFile, of pack: ModelPack, session: URLSession, reporter: ProgressReporter)
        async throws
    {
        let partial = store.partialLocation(file)
        var offset = store.partialSize(file)
        if offset > file.size {
            throw AttemptError.damaged
        }
        // The SHA-256 covers the whole file: re-read what is already there (a few seconds per GB at most).
        var hasher = SHA256()
        if offset > 0 {
            do { try ModelStore.hash(partial, length: offset, into: &hasher) } catch { throw AttemptError.damaged }
        } else if !FileManager.default.createFile(atPath: partial.path, contents: nil) {
            throw AttemptError.fatal(.disk("cannot create \(partial.path)"))
        }

        if offset < file.size {
            var request = URLRequest(url: pack.downloadURL(file))
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
            let writer = ResponseWriter(partial: partial, offset: offset, hasher: hasher) { delta in
                reporter.update {
                    $0.doneBytes += delta
                    $0.missingBytes[pack.role, default: 0] -= delta
                }
            }
            try await writer.run(request, session: session)
            hasher = writer.hasher
            offset = writer.offset
        }

        guard offset == file.size else { throw AttemptError.network(progressed: true) }
        guard ModelStore.hex(hasher.finalize()) == file.sha256 else { throw AttemptError.damaged }
        let destination = store.location(file, in: pack)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ModelStore.removeIfPresent(destination)
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            throw AttemptError.fatal(.disk(error.localizedDescription))
        }
    }

    /// Receives one HTTP response and appends its body to the partial file, hashing as it goes. It is the
    /// delegate of one task only (`URLSessionTask.delegate`), so the session can be shared.
    ///
    /// URLSession calls the delegate methods one at a time on its own serial queue: the mutable state is
    /// only touched there, then read by `run` once the transfer is over.
    private final class ResponseWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let partial: URL
        /// Bytes in the partial file.
        private(set) var offset: Int64
        private(set) var hasher: SHA256
        private let onBytes: @Sendable (Int64) -> Void
        private var handle: FileHandle?
        private var problem: AttemptError?
        private var received: Int64 = 0
        private var continuation: CheckedContinuation<Void, Error>?
        private let lock = NSLock()

        init(partial: URL, offset: Int64, hasher: SHA256, onBytes: @escaping @Sendable (Int64) -> Void) {
            self.partial = partial
            self.offset = offset
            self.hasher = hasher
            self.onBytes = onBytes
        }

        func run(_ request: URLRequest, session: URLSession) async throws {
            let task = session.dataTask(with: request)
            task.delegate = self
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.withLock { self.continuation = continuation }
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void)
        {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                // The whole file (the server ignored the range, or none was asked): start from zero.
                onBytes(-offset)
                offset = 0
                hasher = SHA256()
            case 206 where Self.rangeStart(response) == offset:
                break  // the rest of the file, as asked
            case 206, 416:
                problem = .damaged  // another range than asked, or our partial file is longer than the file
            case 400..<500 where status != 408 && status != 429:
                problem = .refused(status: status)
            default:
                problem = .network(progressed: false)  // 5xx, 408, 429: the server is busy
            }
            if problem == nil {
                do {
                    let handle = try FileHandle(forWritingTo: partial)
                    try handle.truncate(atOffset: UInt64(offset))
                    try handle.seekToEnd()
                    self.handle = handle
                } catch {
                    problem = .fatal(.disk(error.localizedDescription))
                }
            }
            completionHandler(problem == nil ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard problem == nil, let handle else { return }
            do {
                try handle.write(contentsOf: data)
            } catch {
                problem = .fatal(.disk(error.localizedDescription))
                dataTask.cancel()
                return
            }
            hasher.update(data: data)
            offset += Int64(data.count)
            received += Int64(data.count)
            onBytes(Int64(data.count))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            try? handle?.close()
            handle = nil
            let outcome: Result<Void, Error>
            if let problem {
                outcome = .failure(problem)
            } else if let error = error as? URLError, error.code == .cancelled {
                outcome = .failure(CancellationError())
            } else if error != nil {
                outcome = .failure(AttemptError.network(progressed: received > 0))
            } else {
                outcome = .success(())
            }
            lock.withLock {
                continuation?.resume(with: outcome)
                continuation = nil
            }
        }

        /// "bytes 1000-1999/5000" → 1000.
        static func rangeStart(_ response: URLResponse) -> Int64? {
            guard let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
                  let range = header.split(separator: " ").last?.split(separator: "-").first
            else { return nil }
            return Int64(range)
        }
    }
}

/// Collects the progress from the network queue and the downloader, and passes it on at most 5 times per
/// second (plus every change of model or of network state).
private final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: DownloadProgress
    private let handler: ModelDownloader.ProgressHandler
    private var lastSent = ContinuousClock.now - .seconds(1)
    /// (time, bytes done) over the last seconds, for the speed.
    private var samples: [(ContinuousClock.Instant, Int64)] = []

    init(_ progress: DownloadProgress, _ handler: @escaping ModelDownloader.ProgressHandler) {
        self.progress = progress
        self.handler = handler
    }

    var current: DownloadProgress { lock.withLock { progress } }

    func update(_ change: (inout DownloadProgress) -> Void) {
        let now = ContinuousClock.now
        let toSend: DownloadProgress? = lock.withLock {
            let before = progress
            change(&progress)
            if samples.last.map({ now - $0.0 >= .milliseconds(100) }) ?? true {
                samples.append((now, progress.doneBytes))
                samples.removeAll { now - $0.0 > .seconds(5) }
            }
            if let first = samples.first, now - first.0 > .milliseconds(500) {
                let seconds = Double((now - first.0).components.attoseconds) / 1e18
                    + Double((now - first.0).components.seconds)
                progress.bytesPerSecond = max(0, Double(progress.doneBytes - first.1) / seconds)
            }
            let changedState = before.currentModel != progress.currentModel
                || before.waitingForNetwork != progress.waitingForNetwork
            guard changedState || now - lastSent >= .milliseconds(200) else { return nil }
            lastSent = now
            return progress
        }
        if let toSend { handler(toSend) }
    }

    func send() {
        handler(current)
    }
}
