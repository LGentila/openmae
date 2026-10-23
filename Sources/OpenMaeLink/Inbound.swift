#if os(macOS)
import CryptoKit
import Foundation
import Security
import VoiceCore

// Received information, the Mac's side: the sources and their secret addresses, the home relay registration, the
// internet path (the public relay passing TLS through to the Mac's own certificate, InboundInternet.swift), the
// deliveries' HTTP exchange, and what becomes of them (said, kept for later in the news, notified, ignored), with a log
// per source.

/// A delivery in its source's log: when, by which path, in which form, what became of it, from which address, and
/// its text, cleaned. Never the body as it came.
public struct InboundLogEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Result: String, Codable, Sendable {
        /// Waiting to be said.
        case queued
        case said
        /// Not said in time: kept for later (the news) instead.
        case expired
        case notified
        /// Kept for later, in the news: by its source's mode, the quiet hours, the announcements switched off, Maé not
        /// ready, or an announcement stopped before its end.
        case kept
        /// Urgent, and Maé could not say it (the announcements switched off, or Maé not ready): shown in a
        /// notification, and kept for later in the news as well.
        case notifiedAndKept
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

    /// The internet path: the public relay (the one the iPhones use) passes deliveries from the internet through to
    /// this Mac without reading them, encrypted to a certificate the Mac holds.
    public enum InternetPath: Sendable, Equatable {
        /// Reading what the relay offers.
        case checking
        /// No relay is chosen, or the relay does not take deliveries from the internet.
        case notOffered
        /// The relay does not answer; tried again on its own.
        case unreachable
        /// Offered, and not used: no internet source.
        case available
        /// Getting the certificate (or waiting to try again, with `certificateProblem`).
        case gettingCertificate
        case ready
    }

    public var homeRelayAddress: URL?
    public var homeRelay = HomeRelay.none
    /// The relay the iPhones use, which is the internet path's; nil when none is chosen.
    public var publicRelayAddress: URL?
    public var internetPath = InternetPath.notOffered
    /// The relay's inbound domain, once known: internet sources' addresses are `https://<inbound name>.<domain>/in/…`.
    public var inboundDomain: String?
    /// Why the last try to get the certificate failed, while it is tried again.
    public var certificateProblem: String?
    /// When the certificate stops being valid (it is renewed well before).
    public var certificateExpiry: Date?
    /// The Mac's inbound name, once its keys exist.
    public var inboundName: String?
    public var sources: [InboundSource] = []
    /// The announcements switch and the quiet hours, for every source.
    public var preferences = InboundPreferences()
    /// Each source's secret address, when it has one (a home source needs the home relay, an internet source a relay
    /// with an inbound domain).
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
/// answers each delivery at once, then has Maé say it (`Announcing`), keeps it for later in the news (a file next to
/// the sources', `NewsStore`), or shows a notification. While a source exists, the engine offers the news to the model
/// (lire_nouvelles, « Quoi de neuf ? »).
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
    /// What Maé keeps for later.
    public nonisolated let news: NewsStore
    /// Whether the engine was last given the news (a source exists), and the hand-over under way.
    private var newsOffered = false
    private var newsHandOver: Task<Void, Never>?

    // The internet path.
    private let keys: any InboundKeyStore
    private let acme: ACMEServer
    private var publicRelay: URL?
    private var publicRegistration: RelayRegistration?
    private var publicTasks: [Task<Void, Never>] = []
    /// Reads the relay's offer, again now and then while it is not used.
    private var offerTask: Task<Void, Never>?
    private var certificate: InboundCertificate?
    private var certificateTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var certificateFailures = 0
    private nonisolated let tlsServer: InboundTLSServer

    /// `announcer`: the engine (nil: notifications only). `storeURL`: nil keeps everything in memory (tests).
    /// `keys`: the internet path's keys (nil: in memory). `acme`: where its certificate comes from.
    /// `requestTime`: how long a caller has to send its request. `expiryUnit`: one second of an announcement's expiry
    /// (the tests shorten both).
    public init(announcer: (any Announcing)?, identityStore: any IdentityStore, secrets: any InboundSecretStore,
                storeURL: URL?, keys: (any InboundKeyStore)? = nil, acme: ACMEServer = .letsEncrypt,
                requestTime: Duration = .seconds(10), expiryUnit: Duration = .seconds(1),
                now: @escaping @Sendable () -> Date = { Date() })
    {
        self.announcer = announcer
        self.identityStore = identityStore
        self.secrets = secrets
        self.storeURL = storeURL
        news = NewsStore(url: storeURL?.deletingLastPathComponent().appending(path: "news.json"), now: now)
        self.keys = keys ?? MemoryInboundKeys()
        self.acme = acme
        self.requestTime = requestTime
        self.expiryUnit = expiryUnit
        self.now = now
        (status, statusSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        let host = HostReference()
        tlsServer = InboundTLSServer { transport, caller in
            Task { await host.value?.serve(transport, from: caller, path: .publicRelay) }
        }
        host.value = self
        Task { await self.load() }
    }

    /// The host, for the HTTPS server's connections, without a cycle.
    private final class HostReference: @unchecked Sendable {
        weak var value: InboundHost?
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

    /// The announcements switch and the quiet hours.
    public func setPreferences(_ preferences: InboundPreferences) {
        guard preferences != state.preferences else { return }
        state.preferences = preferences
        save()
        publish()
    }

    public func setHomeRelay(_ address: URL?) {
        guard address != state.homeRelayAddress else { return }
        state.homeRelayAddress = address
        save()
        stopRegistration()
        updateRegistration()
        publish()
    }

    /// The internet relay (Settings › Relay), which the iPhones use and the internet path goes through; nil when it is
    /// off.
    public func setPublicRelay(_ address: URL?) {
        guard address != publicRelay || state.publicRelayAddress != address else { return }
        publicRelay = address
        state.publicRelayAddress = address
        stopInternetPath()
        state.inboundDomain = nil
        updateInternetPath()
        publish()
    }

    /// Adds a source with a new secret address; returns its id.
    @discardableResult
    public func addSource(name: String, origin: InboundSource.Origin = .home, mode: InboundSource.Mode = .sayNow) -> UUID {
        let source = InboundSource(name: name, origin: origin, mode: mode, created: now())
        setSecret(InboundSecret.generate(), for: source.id)
        state.sources.append(source)
        save()
        updateRegistration()
        updateInternetPath()
        offerNews()
        publish()
        if Self.mayNotify(source) { requestNotificationPermission() }
        return source.id
    }

    /// Its name, mode, urgency and pause. A change of origin changes its address.
    public func updateSource(_ source: InboundSource) {
        guard let index = state.sources.firstIndex(where: { $0.id == source.id }) else { return }
        let previous = state.sources[index]
        state.sources[index] = source
        if source.origin != previous.origin { setSecret(InboundSecret.generate(), for: source.id) }
        if Self.mayNotify(source), !Self.mayNotify(previous) { requestNotificationPermission() }
        save()
        updateInternetPath()
        publish()
    }

    /// Only these sources' deliveries may end in a notification: "Notification only", and the urgent ones of a source
    /// that may ask for them, while Maé cannot say them. What else is not said is kept for later, in the news.
    private static func mayNotify(_ source: InboundSource) -> Bool {
        source.mode == .notifyOnly || source.mayBeUrgent
    }

    private func requestNotificationPermission() {
        let announcer = announcer
        Task { await announcer?.requestNotificationPermission() }
    }

    public func removeSource(_ id: UUID) {
        state.sources.removeAll { $0.id == id }
        state.logs[id] = nil
        setSecret(nil, for: id)
        rules.forget(id)
        save()
        updateInternetPath()
        offerNews()
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
        let item = await news.add(NewsItem(source: source.name, received: now(), text: message.spoken,
                                           language: message.language, state: .announcing))
        await say(message, from: source, entry: entry, item: item, urgent: false,
                  expiresAfter: InboundRules.defaultExpiry)
    }

    // MARK: - Deliveries

    /// One delivery, over a tube the home relay or the public relay opened: reads the request, answers at once, then
    /// has the information said or notified.
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
        let decision = rules.decide(message, from: source, ready: ready, preferences: state.preferences, now: now())
        let result: InboundLogEntry.Result = switch decision.outcome {
        case .queued: .queued
        case .kept: .kept
        case .notified: .notified
        case .notifiedAndKept: .notifiedAndKept
        case .duplicate: .duplicate
        }
        let entry = log(InboundLogEntry(date: now(), path: path, form: message.form, result: result, caller: caller,
                                        text: message.full), for: source.id)
        DebugLog.log("received information: \(decision.outcome.rawValue)\(decision.urgent ? " (urgent)" : "")")
        switch decision.outcome {
        case .duplicate:
            return HTTPResponse.json(200, ["status": "duplicate"])
        case .notified:
            notify(message, from: source)
            return HTTPResponse.json(202, ["status": "notified"])
        case .kept:
            await news.add(NewsItem(source: source.name, received: now(), text: message.spoken,
                                    language: message.language))
            return HTTPResponse.json(202, ["status": "kept"])
        case .notifiedAndKept:
            notify(message, from: source)
            await news.add(NewsItem(source: source.name, received: now(), text: message.spoken,
                                    language: message.language))
            return HTTPResponse.json(202, ["status": "notified"])
        case .queued:
            // In the news from now on, as being announced: should it not be said to its end, it stays there.
            let item = await news.add(NewsItem(source: source.name, received: now(), text: message.spoken,
                                               language: message.language, state: .announcing))
            Task { await self.say(message, from: source, entry: entry, item: item, urgent: decision.urgent,
                                  expiresAfter: decision.expiresAfter) }
            return HTTPResponse.json(202, ["status": "queued"])
        }
    }

    /// Has Maé say it, after the chime, as soon as nobody speaks; with "news": true (the welcome home), the news after it
    /// (`NewsPhrases.whileAway`). Said to its end, its item in the news is marked said, and the news it read are taken
    /// out. Not said in time (it is never said late), stopped before its end (the user spoke over it, the stop button…),
    /// or Maé not ready: it stays in the news, unread, and so do the news it was to read. An urgent one Maé is no longer
    /// ready to say is shown in a notification as well, as `InboundRules` has it when she is not ready on its arrival.
    private func say(_ message: InboundMessage, from source: InboundSource, entry: UUID, item: UUID, urgent: Bool,
                     expiresAfter: Int) async
    {
        var text = message.spoken
        var held: [UUID] = []
        if message.news {
            let (items, left) = await news.hold()
            if let away = NewsPhrases.whileAway(items, left: left, now: now(), language: message.language) {
                text += " " + away
                held = items.map(\.id)
            }
        }
        let news = news
        func ended(said: Bool, _ result: InboundLogEntry.Result) async {
            await news.set(item, to: said ? .said : .unread)
            await news.release(held, said: said)
            update(entry, of: source.id, to: result)
        }
        func notReady() async {
            if urgent { notify(message, from: source) }
            await ended(said: false, urgent ? .notifiedAndKept : .kept)
        }
        guard let announcer, await announcer.canAnnounce() else {
            await notReady()
            return
        }
        let id = UUID()
        let note = InboundPhrases.note(source: source.name, receivedAt: now())
        guard await announcer.announce(text, note: note, language: message.language, chime: true, urgent: urgent, id: id)
        else {
            await notReady()
            return
        }
        let wait = expiryUnit * expiresAfter
        let deadline = ContinuousClock.now + wait
        while true {
            try? await Task.sleep(for: min(.milliseconds(250), wait))
            switch await announcer.announcementState(id) {
            case .waiting:
                // Never said late. Taken back unless it has just started.
                if ContinuousClock.now >= deadline, await announcer.withdrawAnnouncement(id) {
                    DebugLog.log("received information: not said in time, kept for later")
                    await ended(said: false, .expired)
                    return
                }
            case .playing:
                continue
            case .said:
                await ended(said: true, .said)
                return
            case .stopped, .unknown:
                DebugLog.log("received information: stopped before its end, kept for later")
                await ended(said: false, .kept)
                return
            }
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

    // MARK: - Internet path

    /// `<inbound name>.<inbound domain>`: the name of the certificate and of the internet sources' addresses.
    private var internetHost: String? {
        guard let name = state.inboundName, let domain = state.inboundDomain else { return nil }
        return "\(name).\(domain)"
    }

    private var hasInternetSources: Bool { state.sources.contains { $0.origin == .internet } }

    /// What the relay was found to offer, before its inbound domain is known.
    private var offer = InboundStatus.InternetPath.checking
    private var publicRegistered = false
    private var publicUnreachable = false
    /// The name whose certificate the HTTPS server holds now.
    private var installedHost: String?
    private var nextCertificateTry: Date?
    private var retryTask: Task<Void, Never>?

    /// Follows the relay and the sources: reads what the relay offers, registers for deliveries from the internet while
    /// an internet source exists, gets the certificate and keeps it renewed.
    private func updateInternetPath() {
        defer { refreshInternetState() }
        guard let relay = publicRelay else {
            stopInternetPath()
            return
        }
        guard state.inboundDomain != nil else {
            // Asked while an internet source waits for it; otherwise only when the settings show it.
            if hasInternetSources { checkOffer(relay) }
            return
        }
        guard hasInternetSources else {
            stopInternetPath(keepOffer: true)
            return
        }
        guard let identity = loadIdentity() else { return }
        if publicRegistration == nil {
            let registration = RelayRegistration(relay: relay, identity: identity, passthrough: true)
            publicRegistration = registration
            let server = tlsServer
            publicTasks = [
                Task { [weak self] in
                    for await status in registration.status { await self?.setPublicStatus(status, of: registration) }
                },
                Task {
                    for await delivery in registration.deliveries {
                        Task {
                            do {
                                let tube = try await RelayClient.accept(relay: relay, tube: delivery.tube)
                                await server.pipe(tube, from: delivery.from)
                            } catch {
                                DebugLog.log("received information: could not accept a delivery from the internet (\(error))")
                            }
                        }
                    }
                },
            ]
            Task { await registration.start() }
        }
        ensureCertificate()
    }

    /// What the settings show: reads, once, whether the relay takes deliveries from the internet, if that is not
    /// known yet. Nothing is asked of the relay otherwise until an internet source exists.
    public func checkInternetOffer() {
        guard let relay = publicRelay, state.inboundDomain == nil else { return }
        checkOffer(relay)
    }

    /// Reads the relay's /v1/info until it says whether it takes deliveries from the internet; asks again every ten
    /// minutes while it does not (its operator may turn it on) and an internet source waits for it.
    private func checkOffer(_ relay: URL) {
        guard offerTask == nil else { return }
        offerTask = Task { [weak self] in
            var wait = 30.0
            while !Task.isCancelled {
                do {
                    let domain = try await RelayClient.info(relay).inbound?.domain
                    guard let self else { return }
                    if await self.offerRead(relay, domain: domain) { return }
                    wait = 600
                } catch {
                    guard let self else { return }
                    if await self.offerUnreachable(relay) { return }
                    wait = min(wait * 2, 600)
                }
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// True when there is no need to ask again: the relay offers the internet path, or no internet source waits for it.
    private func offerRead(_ relay: URL, domain: String?) -> Bool {
        guard relay == publicRelay else { return true }
        guard let domain = domain.flatMap(Self.validDomain) else {
            if offer != .notOffered { DebugLog.log("received information: the relay takes no deliveries from the internet") }
            offer = .notOffered
            refreshInternetState()
            publish()
            return stopAsking()
        }
        offerTask = nil
        state.inboundDomain = domain
        updateInternetPath()
        publish()
        return true
    }

    /// True when there is no need to ask again.
    private func offerUnreachable(_ relay: URL) -> Bool {
        guard relay == publicRelay else { return true }
        offer = .unreachable
        refreshInternetState()
        publish()
        return stopAsking()
    }

    /// Without an internet source, one answer is enough: the settings ask again when they show it.
    private func stopAsking() -> Bool {
        guard !hasInternetSources else { return false }
        offerTask = nil
        return true
    }

    /// An inbound domain as the relay gives it, if it is a DNS name.
    static func validDomain(_ text: String) -> String? {
        let domain = text.lowercased()
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, domain.count <= 200,
              labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } })
        else { return nil }
        return domain
    }

    private func setPublicStatus(_ status: RelayRegistration.Status, of registration: RelayRegistration) {
        guard publicRegistration === registration else { return }
        switch status {
        case .connecting:
            break
        case .registered:
            publicRegistered = true
            publicUnreachable = false
            ensureCertificate()
        case .unreachable:
            publicRegistered = false
            publicUnreachable = true
        case .inboundOff:
            // The relay no longer takes deliveries from the internet: read its offer again.
            stopInternetPath()
            state.inboundDomain = nil
            offer = .notOffered
            updateInternetPath()
        }
        refreshInternetState()
        publish()
    }

    /// Installs a valid certificate, and gets a new one when there is none or it is due for renewal.
    private func ensureCertificate() {
        guard let host = internetHost, publicRegistration != nil else { return }
        let usable = usableCertificate(for: host)
        if let usable, installedHost != host {
            installedHost = host
            let server = tlsServer
            let tls = usable.tls
            Task { [weak self] in
                do {
                    try await server.start(identity: tls.identity, chain: tls.chain)
                } catch {
                    DebugLog.log("received information: the HTTPS server cannot start (\(error))")
                    await self?.installFailed(host)
                }
                await self?.refreshAndPublish()
            }
        }
        if let renewal = usable?.renewal, now() < renewal {
            scheduleRenewal(at: renewal)
            return
        }
        guard publicRegistered, certificateTask == nil else { return }
        if let next = nextCertificateTry, now() < next { return }
        certificateTask = Task { await self.obtainCertificate(for: host) }
    }

    private func installFailed(_ host: String) {
        if installedHost == host { installedHost = nil }
    }

    private func refreshAndPublish() {
        refreshInternetState()
        publish()
    }

    /// The stored certificate when it is for `host`, from this ACME server, still valid, with its key.
    private func usableCertificate(for host: String) -> (tls: TLSIdentity, renewal: Date?)? {
        guard let certificate, certificate.domain == host, certificate.directory == acme.directory,
              let validity = certificate.validity, now() < validity.until,
              let keyData = keys.key("certificate"),
              let key = try? P256.Signing.PrivateKey(rawRepresentation: keyData),
              let (identity, chain) = certificate.identity(key: key)
        else { return nil }
        return (TLSIdentity(identity: identity, chain: chain), certificate.renewal)
    }

    /// A certificate with its key, as the HTTPS server takes it. Security's objects are immutable.
    private struct TLSIdentity: @unchecked Sendable {
        let identity: SecIdentity
        let chain: [SecCertificate]
    }

    private func obtainCertificate(for host: String) async {
        defer { certificateTask = nil }
        guard let registration = publicRegistration else { return }
        let accountKey: ACMEAccountKey
        if let data = keys.key("acme-account"), let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            accountKey = ACMEAccountKey(key: key)
        } else {
            accountKey = ACMEAccountKey()
            keys.setKey(accountKey.key.rawRepresentation, "acme-account")
        }
        let key = P256.Signing.PrivateKey()
        DebugLog.log("received information: getting the internet path's certificate from \(acme.directory.host() ?? "?")")
        refreshAndPublish()
        do {
            let chain = try await ACMEClient(server: acme, accountKey: accountKey)
                .certificate(for: host, key: key) { token, keyAuthorization in
                    try await registration.depositChallenge(token: token, keyAuthorization: keyAuthorization)
                }
            guard publicRegistration === registration else { return }  // stopped meanwhile
            keys.setKey(key.rawRepresentation, "certificate")
            certificate = InboundCertificate(domain: host, chain: chain, directory: acme.directory)
            certificateFailures = 0
            nextCertificateTry = nil
            state.certificateProblem = nil
            installedHost = nil  // the new one replaces the one being served
            save()
            DebugLog.log("received information: certificate obtained, valid until \(certificate?.validity?.until.description ?? "?")")
            ensureCertificate()
        } catch {
            guard publicRegistration === registration else { return }
            certificateFailures += 1
            // 5 minutes, then twice as long each time, up to 6 hours: Let's Encrypt limits failed validations.
            let delay = min(300 * pow(2, Double(certificateFailures - 1)), 6 * 3600)
            nextCertificateTry = now() + delay
            state.certificateProblem = "\(error)"
            DebugLog.log("received information: no certificate (\(error)); next try in \(Int(delay)) s")
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self?.ensureCertificateAndPublish()
            }
        }
        refreshAndPublish()
    }

    private func ensureCertificateAndPublish() {
        ensureCertificate()
        refreshAndPublish()
    }

    private func scheduleRenewal(at date: Date) {
        renewalTask?.cancel()
        renewalTask = Task { [weak self] in
            // Checked every hour rather than slept through: the Mac may sleep meanwhile.
            while !Task.isCancelled, date.timeIntervalSinceNow > 0 {
                try? await Task.sleep(for: .seconds(min(date.timeIntervalSinceNow, 3600)))
            }
            guard !Task.isCancelled else { return }
            await self?.ensureCertificateAndPublish()
        }
    }

    private func stopInternetPath(keepOffer: Bool = false) {
        publicTasks.forEach { $0.cancel() }
        publicTasks = []
        if let publicRegistration { Task { await publicRegistration.stop() } }
        publicRegistration = nil
        publicRegistered = false
        publicUnreachable = false
        certificateTask?.cancel()
        certificateTask = nil
        renewalTask?.cancel()
        renewalTask = nil
        retryTask?.cancel()
        retryTask = nil
        tlsServer.stop()
        installedHost = nil
        if !keepOffer {
            offerTask?.cancel()
            offerTask = nil
            offer = .checking
        }
    }

    private func refreshInternetState() {
        state.internetPath = if publicRelay == nil {
            .notOffered
        } else if state.inboundDomain == nil {
            offer
        } else if !hasInternetSources {
            .available
        } else if publicUnreachable {
            .unreachable
        } else if publicRegistered, installedHost != nil, installedHost == internetHost {
            .ready
        } else {
            .gettingCertificate
        }
    }

    // MARK: - Storage

    private struct Stored: Codable {
        var homeRelay: URL?
        var sources: [InboundSource] = []
        var logs: [UUID: [InboundLogEntry]] = [:]
        /// The internet path's certificate (public; its key is in the keychain).
        var certificate: InboundCertificate?
        /// Optional: a file written before the news has none.
        var preferences: InboundPreferences?
    }

    private func load() {
        if let storeURL, let data = try? Data(contentsOf: storeURL),
           let stored = try? JSONDecoder().decode(Stored.self, from: data)
        {
            state.homeRelayAddress = stored.homeRelay
            state.sources = stored.sources
            state.logs = stored.logs.mapValues { Self.pruned($0, now: now()) }
            state.preferences = stored.preferences ?? InboundPreferences()
            certificate = stored.certificate
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
        updateInternetPath()
        offerNews()
        publish()
    }

    /// The engine offers the news to the model while a source exists, paused or not; one hand-over after the other.
    private func offerNews() {
        let offered = !state.sources.isEmpty
        guard offered != newsOffered else { return }
        newsOffered = offered
        let (previous, announcer, news) = (newsHandOver, announcer, news)
        newsHandOver = Task {
            await previous?.value
            await announcer?.useNews(offered ? news : nil)
        }
    }

    private func save() {
        guard let storeURL else { return }
        let stored = Stored(homeRelay: state.homeRelayAddress, sources: state.sources, logs: state.logs,
                            certificate: certificate, preferences: state.preferences)
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
        if let host = internetHost {
            for source in state.sources where source.origin == .internet {
                guard let secret = known[source.id] else { continue }
                state.addresses[source.id] = URL(string: "https://\(host)/in/\(secret)")
            }
        }
        state.certificateExpiry = certificate?.domain == internetHost ? certificate?.validity?.until : nil
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
