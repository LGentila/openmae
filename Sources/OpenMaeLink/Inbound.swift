#if os(macOS)
import Foundation
import Security
import VoiceCore

// Received information, the Mac's side: the sources and their secret addresses, the home relay registration, the
// deliveries' HTTP exchange, and what becomes of them (said, notified, ignored), with a log per source.

/// A delivery in its source's log: when, by which path, in which form, what became of it, from which address, and
/// its text, cleaned. Never the body as it came.
public struct InboundLogEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Result: String, Codable, Sendable {
        /// Waiting to be said.
        case queued
        case said
        /// Not said in time: a notification instead.
        case expired
        case notified
        case kept
        case duplicate
        /// Refused: the source is paused (answered 404).
        case paused
        /// Refused: it came by a path its origin does not allow (answered 404).
        case wrongPath
        /// Refused: no text, or broken JSON (400).
        case unreadable
        /// Refused: JSON without a recognised text field (422).
        case noText
        case tooLarge
        case rateLimited
        case methodRefused
        case timedOut
    }

    public var id: UUID
    public var date: Date
    /// Nil for "Send a test", from the settings.
    public var path: InboundPath?
    public var form: InboundMessage.Form?
    public var result: Result
    public var caller: String?
    public var text: String?
    /// Why it was refused, as the caller was told.
    public var detail: String?

    public init(id: UUID = UUID(), date: Date, path: InboundPath?, form: InboundMessage.Form? = nil, result: Result,
                caller: String? = nil, text: String? = nil, detail: String? = nil)
    {
        self.id = id
        self.date = date
        self.path = path
        self.form = form
        self.result = result
        self.caller = caller
        self.text = text
        self.detail = detail
    }
}

/// What the Mac's "Received information" settings show.
public struct InboundStatus: Sendable, Equatable {
    public enum HomeRelay: Sendable, Equatable {
        /// No home relay set.
        case none
        case connecting
        case connected
        /// It does not answer; tried again on its own.
        case unreachable
        /// It answers, but is not in home mode (`RELAY_HOME_INBOUND` is off).
        case notHomeMode
    }

    public var homeRelayAddress: URL?
    public var homeRelay = HomeRelay.none
    /// The Mac's inbound name, once its keys exist.
    public var inboundName: String?
    public var sources: [InboundSource] = []
    /// Each source's secret address, when it has one (a home source needs the home relay).
    public var addresses: [UUID: URL] = [:]
    /// The last deliveries of each source, newest first.
    public var logs: [UUID: [InboundLogEntry]] = [:]

    public init() {}
}

// MARK: - Secrets

/// Where the sources' secrets are kept: the keychain, one item per source, never in the settings file or a log.
public protocol InboundSecretStore: Sendable {
    func secret(for source: UUID) -> String?
    /// Replaces it; nil removes it. False when it could not be saved.
    @discardableResult func setSecret(_ secret: String?, for source: UUID) -> Bool
}

public struct KeychainInboundSecrets: InboundSecretStore {
    public let service: String

    public init(service: String = "\(AppIdentity.name) received information") {
        self.service = service
    }

    private func base(_ source: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: source.uuidString]
    }

    public func secret(for source: UUID) -> String? {
        var query = base(source)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func setSecret(_ secret: String?, for source: UUID) -> Bool {
        SecItemDelete(base(source) as CFDictionary)
        guard let secret else { return true }
        var item = base(source)
        item[kSecValueData] = Data(secret.utf8)
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel] = "\(AppIdentity.name) — received information"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

/// In memory: for the tests and the still pictures of the screens.
public final class MemoryInboundSecrets: InboundSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [UUID: String] = [:]

    public init() {}

    public func secret(for source: UUID) -> String? {
        lock.withLock { secrets[source] }
    }

    @discardableResult
    public func setSecret(_ secret: String?, for source: UUID) -> Bool {
        lock.withLock { secrets[source] = secret }
        return true
    }
}

// MARK: - The host

/// Received information on the Mac. It keeps the sources (a file next to the link's) and their secrets (keychain),
/// stays registered with the home relay when one is set (an inbound registration, apart from the iPhones' relay),
/// answers each delivery at once, then has Maé say it (`Announcing`) or shows a notification.
public actor InboundHost {
    /// 64 KB of body at most, sent within 10 seconds.
    public static let maxBody = 64 * 1024
    /// Log entries kept per source, and for how long.
    public static let logLength = 20
    public static let logAge: TimeInterval = 7 * 86_400

    public nonisolated let status: AsyncStream<InboundStatus>
    private nonisolated let statusSink: AsyncStream<InboundStatus>.Continuation

    private let announcer: (any Announcing)?
    private let identityStore: any IdentityStore
    private let secrets: any InboundSecretStore
    private let storeURL: URL?
    private let requestTime: Duration
    /// One second of an announcement's expiry (shorter in the tests).
    private let expiryUnit: Duration
    private let now: @Sendable () -> Date

    private var state = InboundStatus()
    /// SHA-256 of each source's secret, compared in constant time.
    private var digests: [UUID: Data] = [:]
    /// The secrets themselves, for the addresses the settings show (read from the keychain once).
    private var known: [UUID: String] = [:]
    private var rules = InboundRules()
    private var limits = InboundRateLimit()
    private var identity: DeviceIdentity?
    private var registration: RelayRegistration?
    private var registrationTasks: [Task<Void, Never>] = []

    /// `announcer`: the engine (nil: notifications only). `storeURL`: nil keeps everything in memory (tests).
    /// `requestTime`: how long a caller has to send its request. `expiryUnit`: one second of an announcement's expiry
    /// (the tests shorten both).
    public init(announcer: (any Announcing)?, identityStore: any IdentityStore, secrets: any InboundSecretStore,
                storeURL: URL?, requestTime: Duration = .seconds(10), expiryUnit: Duration = .seconds(1),
                now: @escaping @Sendable () -> Date = { Date() })
    {
        self.announcer = announcer
        self.identityStore = identityStore
        self.secrets = secrets
        self.storeURL = storeURL
        self.requestTime = requestTime
        self.expiryUnit = expiryUnit
        self.now = now
        (status, statusSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        Task { await self.load() }
    }

    /// Next to the link's `link.json`.
    public static var defaultStoreURL: URL {
        LinkHost.defaultStoreURL.deletingLastPathComponent().appending(path: "received-information.json")
    }

    /// What the user typed for the home relay ("192.168.1.10:8080", "http://relais.local:8080/"), as an address; nil
    /// when it cannot be one.
    public static func homeRelayURL(from text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty, url.query == nil
        else { return nil }
        return url
    }

    // MARK: - Settings

    public func setHomeRelay(_ address: URL?) {
        guard address != state.homeRelayAddress else { return }
        state.homeRelayAddress = address
        save()
        stopRegistration()
        updateRegistration()
        publish()
    }

    /// Adds a source with a new secret address; returns its id.
    @discardableResult
    public func addSource(name: String, origin: InboundSource.Origin = .home, mode: InboundSource.Mode = .sayNow) -> UUID {
        let first = state.sources.isEmpty
        let source = InboundSource(name: name, origin: origin, mode: mode, created: now())
        setSecret(InboundSecret.generate(), for: source.id)
        state.sources.append(source)
        save()
        updateRegistration()
        publish()
        if first || mode == .notifyOnly {
            // What a source sends may end in a notification (not said in time, Maé not ready).
            let announcer = announcer
            Task { await announcer?.requestNotificationPermission() }
        }
        return source.id
    }

    /// Its name, mode, urgency and pause. A change of origin changes its address.
    public func updateSource(_ source: InboundSource) {
        guard let index = state.sources.firstIndex(where: { $0.id == source.id }) else { return }
        let previous = state.sources[index]
        state.sources[index] = source
        if source.origin != previous.origin { setSecret(InboundSecret.generate(), for: source.id) }
        if source.mode == .notifyOnly, previous.mode != .notifyOnly {
            let announcer = announcer
            Task { await announcer?.requestNotificationPermission() }
        }
        save()
        publish()
    }

    public func removeSource(_ id: UUID) {
        state.sources.removeAll { $0.id == id }
        state.logs[id] = nil
        setSecret(nil, for: id)
        rules.forget(id)
        save()
        publish()
    }

    /// "Change the address": a new secret; the old address stops working at once.
    public func changeAddress(_ id: UUID) {
        guard state.sources.contains(where: { $0.id == id }) else { return }
        setSecret(InboundSecret.generate(), for: id)
        rules.forget(id)
        publish()
    }

    /// "Send a test": Maé says « Ceci est un essai de la source <name>. » as if the source had sent it.
    public func sendTest(_ id: UUID) async {
        guard let source = state.sources.first(where: { $0.id == id }) else { return }
        let message = InboundMessage(form: .text, title: nil, text: InboundPhrases.test(source: source.name),
                                     language: .french)
        let entry = log(InboundLogEntry(date: now(), path: nil, form: .text, result: .queued, text: message.full),
                        for: source.id)
        await say(message, from: source, entry: entry, urgent: false, expiresAfter: InboundRules.defaultExpiry)
    }

    // MARK: - Deliveries

    /// One delivery, over a tube the home relay opened (or, later, the public relay or the internal door): reads the
    /// request, answers at once, then has the information said or notified.
    public func serve(_ transport: any LinkTransport, from caller: String, path: InboundPath) async {
        DebugLog.log("received information: a delivery arrives (\(path.rawValue))")
        let exchange = Exchange(transport)
        let watchdog = Task { [requestTime] in
            try? await Task.sleep(for: requestTime)
            guard !Task.isCancelled else { return }
            exchange.answer(HTTPResponse.json(408, ["error": "The request took too long to arrive."]))
        }
        defer { watchdog.cancel() }
        var reader = HTTPRequestReader(maxBody: Self.maxBody)
        var accepted: InboundSource?
        for await input in transport.incoming {
            guard !exchange.isAnswered else { break }
            switch input {
            case .bytes(let data): reader.append(data)
            case .datagram: continue
            case .closed: break
            }
            if case .closed = input { break }
            do throws(HTTPReadError) {
                if accepted == nil {
                    guard let head = try reader.readHead() else { continue }
                    switch check(head, path: path, caller: caller) {
                    case .refuse(let response):
                        exchange.answer(response)
                        return
                    case .proceed(let source):
                        accepted = source
                    }
                }
                guard let source = accepted, let head = reader.head, let body = try reader.readBody() else { continue }
                watchdog.cancel()
                exchange.answer(await handle(head, body: body, from: source, path: path, caller: caller))
                return
            } catch {
                let response: Data
                switch error {
                case .tooLarge:
                    if let source = accepted {
                        log(InboundLogEntry(date: now(), path: path, result: .tooLarge, caller: caller), for: source.id)
                    }
                    response = HTTPResponse.json(413, ["error": "The body is over 64 KB."])
                case .headersTooLarge: response = HTTPResponse.json(431, ["error": "The headers are too large."])
                case .unsupportedEncoding: response = HTTPResponse.json(501, ["error": "Only chunked transfer encoding is supported."])
                case .badRequest: response = HTTPResponse.json(400, ["error": "This is not an HTTP/1.1 request."])
                }
                // An address that is not known learns nothing more than 404.
                exchange.answer(accepted == nil && error != .headersTooLarge ? Self.notFound : response)
                return
            }
        }
        if exchange.isAnswered, let source = accepted {
            log(InboundLogEntry(date: now(), path: path, result: .timedOut, caller: caller), for: source.id)
        }
    }

    private static let notFound = HTTPResponse.json(404, ["error": "Unknown address."])

    /// The state as last published (tests).
    var current: InboundStatus { state }

    private enum HeadCheck {
        case refuse(Data)
        case proceed(InboundSource)
    }

    /// The address first: an unknown one, a paused or deleted source, or the wrong path for its origin all answer 404,
    /// whatever the method or the body. Then the method and the source's limits.
    private func check(_ head: HTTPRequestHead, path: InboundPath, caller: String) -> HeadCheck {
        guard let secret = Self.secret(in: head.path), let source = source(matching: secret) else {
            return .refuse(Self.notFound)
        }
        guard source.accepts(path) else {
            log(InboundLogEntry(date: now(), path: path, result: .wrongPath, caller: caller), for: source.id)
            return .refuse(Self.notFound)
        }
        guard !source.paused else {
            log(InboundLogEntry(date: now(), path: path, result: .paused, caller: caller), for: source.id)
            return .refuse(Self.notFound)
        }
        guard head.method == "POST" || head.method == "GET" else {
            log(InboundLogEntry(date: now(), path: path, result: .methodRefused, caller: caller), for: source.id)
            return .refuse(HTTPResponse.json(405, ["error": "Send with POST, or GET with ?text=."]))
        }
        guard limits.allow(source.id, now: now()) else {
            log(InboundLogEntry(date: now(), path: path, result: .rateLimited, caller: caller), for: source.id)
            return .refuse(HTTPResponse.json(429, ["error": "Too many deliveries: at most 6 a minute and 60 an hour."]))
        }
        return .proceed(source)
    }

    /// The last segment of `…/in/<secret>`.
    static func secret(in path: String) -> String? {
        guard let range = path.range(of: "/in/", options: .backwards) else { return nil }
        let secret = String(path[range.upperBound...])
        return secret.isEmpty || secret.contains("/") ? nil : secret.removingPercentEncoding ?? secret
    }

    /// Compares the secret's digest with every source's, without stopping at the first that matches.
    private func source(matching secret: String) -> InboundSource? {
        let digest = InboundSecret.digest(secret)
        var found: InboundSource?
        for source in state.sources {
            if let known = digests[source.id], InboundSecret.same(known, digest) { found = source }
        }
        return found
    }

    /// Reads the delivery, decides, and returns the answer; what is to be said starts right after the answer.
    private func handle(_ head: HTTPRequestHead, body: Data, from source: InboundSource, path: InboundPath,
                        caller: String) async -> Data
    {
        let request = InboundRequest(method: head.method, query: head.query, headers: head.headers, body: body)
        let message: InboundMessage
        switch InboundParser.parse(request) {
        case .failure(let refusal):
            let noText = refusal == .noText
            log(InboundLogEntry(date: now(), path: path, form: noText ? .json : nil, result: noText ? .noText : .unreadable,
                                caller: caller, detail: refusal.explanation), for: source.id)
            return HTTPResponse.json(noText ? 422 : 400, ["error": refusal.explanation])
        case .success(let read):
            message = read
        }
        let ready = await announcer?.canAnnounce() ?? false
        let decision = rules.decide(message, from: source, ready: ready, now: now())
        let result: InboundLogEntry.Result = switch decision.outcome {
        case .queued: .queued
        case .kept: .kept
        case .notified: .notified
        case .duplicate: .duplicate
        }
        let entry = log(InboundLogEntry(date: now(), path: path, form: message.form, result: result, caller: caller,
                                        text: message.full), for: source.id)
        DebugLog.log("received information: \(decision.outcome.rawValue)\(decision.urgent ? " (urgent)" : "")")
        switch decision.outcome {
        case .duplicate:
            return HTTPResponse.json(200, ["status": "duplicate"])
        case .notified, .kept:
            notify(message, from: source)
            return HTTPResponse.json(202, ["status": decision.outcome.rawValue])
        case .queued:
            Task { await self.say(message, from: source, entry: entry, urgent: decision.urgent,
                                  expiresAfter: decision.expiresAfter) }
            return HTTPResponse.json(202, ["status": "queued"])
        }
    }

    /// Has Maé say it, after the chime, as soon as nobody speaks; if it is not said in time, a notification instead.
    private func say(_ message: InboundMessage, from source: InboundSource, entry: UUID, urgent: Bool,
                     expiresAfter: Int) async
    {
        guard let announcer, await announcer.canAnnounce() else {
            notify(message, from: source)
            update(entry, of: source.id, to: .notified)
            return
        }
        let id = UUID()
        let note = InboundPhrases.note(source: source.name, receivedAt: now())
        guard await announcer.announce(message.spoken, note: note, language: message.language, chime: true,
                                       urgent: urgent, id: id)
        else {
            notify(message, from: source)
            update(entry, of: source.id, to: .notified)
            return
        }
        let deadline = ContinuousClock.now + expiryUnit * expiresAfter
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: min(.milliseconds(250), expiryUnit * expiresAfter))
            if await !announcer.announcementWaits(id) {
                update(entry, of: source.id, to: .said)
                return
            }
        }
        // Never said late.
        if await announcer.withdrawAnnouncement(id) {
            notify(message, from: source)
            update(entry, of: source.id, to: .expired)
        } else {
            update(entry, of: source.id, to: .said)
        }
    }

    private func notify(_ message: InboundMessage, from source: InboundSource) {
        let announcer = announcer
        let title = message.title ?? source.name
        let body = message.text
        Task { await announcer?.notify(title: title, body: body) }
    }

    // MARK: - Log

    @discardableResult
    private func log(_ entry: InboundLogEntry, for source: UUID) -> UUID {
        var entries = state.logs[source] ?? []
        entries.insert(entry, at: 0)
        state.logs[source] = Self.pruned(entries, now: now())
        save()
        publish()
        return entry.id
    }

    private func update(_ entry: UUID, of source: UUID, to result: InboundLogEntry.Result) {
        guard let index = state.logs[source]?.firstIndex(where: { $0.id == entry }) else { return }
        state.logs[source]?[index].result = result
        save()
        publish()
    }

    private static func pruned(_ entries: [InboundLogEntry], now: Date) -> [InboundLogEntry] {
        Array(entries.filter { now.timeIntervalSince($0.date) < logAge }.prefix(logLength))
    }

    // MARK: - Home relay

    private func updateRegistration() {
        guard let relay = state.homeRelayAddress else {
            stopRegistration()
            return
        }
        guard registration == nil, let identity = loadIdentity() else { return }
        let registration = RelayRegistration(relay: relay, identity: identity, inbound: true)
        self.registration = registration
        state.homeRelay = .connecting
        registrationTasks = [
            Task { [weak self] in
                for await status in registration.status { await self?.setHomeRelay(status) }
            },
            Task { [weak self] in
                for await delivery in registration.deliveries {
                    Task { [weak self] in
                        do {
                            let transport = try await RelayClient.accept(relay: relay, tube: delivery.tube)
                            await self?.serve(transport, from: delivery.from, path: .homeRelay)
                        } catch {
                            DebugLog.log("received information: could not accept a delivery (\(error))")
                        }
                    }
                }
            },
        ]
        Task { await registration.start() }
    }

    private func stopRegistration() {
        registrationTasks.forEach { $0.cancel() }
        registrationTasks = []
        if let registration { Task { await registration.stop() } }
        registration = nil
        state.homeRelay = .none
    }

    private func setHomeRelay(_ status: RelayRegistration.Status) {
        guard registration != nil else { return }
        state.homeRelay = switch status {
        case .connecting: state.homeRelay == .none ? .connecting : state.homeRelay
        case .registered: .connected
        case .unreachable: .unreachable
        case .inboundOff: .notHomeMode
        }
        publish()
    }

    /// The Mac's keys, made now if no iPhone was ever added: the inbound name comes from them.
    private func loadIdentity() -> DeviceIdentity? {
        if let identity { return identity }
        do {
            identity = try identityStore.loadOrCreate()
        } catch {
            DebugLog.log("received information: cannot read or make the Mac's keys (\(error))")
        }
        state.inboundName = identity.map { InboundName.make(signingKey: $0.signingKey.publicKey.rawRepresentation) }
        return identity
    }

    // MARK: - Storage

    private struct Stored: Codable {
        var homeRelay: URL?
        var sources: [InboundSource] = []
        var logs: [UUID: [InboundLogEntry]] = [:]
    }

    private func load() {
        if let storeURL, let data = try? Data(contentsOf: storeURL),
           let stored = try? JSONDecoder().decode(Stored.self, from: data)
        {
            state.homeRelayAddress = stored.homeRelay
            state.sources = stored.sources
            state.logs = stored.logs.mapValues { Self.pruned($0, now: now()) }
        }
        for source in state.sources {
            if let secret = secrets.secret(for: source.id) {
                digests[source.id] = InboundSecret.digest(secret)
                known[source.id] = secret
            } else {
                // Lost from the keychain: a new address, which the user will see changed.
                setSecret(InboundSecret.generate(), for: source.id)
            }
        }
        if let existing = try? identityStore.load() {
            identity = existing
            state.inboundName = InboundName.make(signingKey: existing.signingKey.publicKey.rawRepresentation)
        }
        updateRegistration()
        publish()
    }

    private func save() {
        guard let storeURL else { return }
        let stored = Stored(homeRelay: state.homeRelayAddress, sources: state.sources, logs: state.logs)
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: storeURL, options: .atomic)
        } catch {
            DebugLog.log("received information: cannot save the sources (\(error))")
        }
    }

    private func setSecret(_ secret: String?, for source: UUID) {
        if !secrets.setSecret(secret, for: source) {
            DebugLog.log("received information: the keychain refused a source's secret")
        }
        digests[source] = secret.map(InboundSecret.digest)
        known[source] = secret
    }

    private func publish() {
        state.addresses = [:]
        if let relay = state.homeRelayAddress, let name = state.inboundName {
            for source in state.sources where source.origin == .home {
                guard let secret = known[source.id] else { continue }
                state.addresses[source.id] = relay.appending(path: name).appending(path: "in").appending(path: secret)
            }
        }
        statusSink.yield(state)
    }
}

/// One delivery's connection: a single answer, which is given time to reach the caller before the connection closes.
private final class Exchange: @unchecked Sendable {
    private let transport: any LinkTransport
    private let lock = NSLock()
    private var answered = false

    init(_ transport: any LinkTransport) {
        self.transport = transport
    }

    var isAnswered: Bool { lock.withLock { answered } }

    /// False when an answer was already given (the request took too long meanwhile).
    @discardableResult
    func answer(_ response: Data) -> Bool {
        let first = lock.withLock {
            defer { answered = true }
            return !answered
        }
        guard first else { return false }
        transport.send(response)
        let transport = transport
        // The relay closes the tube once it has read the answer; closing at once could drop it on its way.
        Task {
            try? await Task.sleep(for: .seconds(2))
            transport.close()
        }
        return true
    }
}
#endif
