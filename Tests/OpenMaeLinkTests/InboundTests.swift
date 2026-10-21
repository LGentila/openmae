import Foundation
import Testing
import VoiceCore

@testable import OpenMaeLink

// Received information, the Mac's side: the HTTP exchange of a delivery and what becomes of it, over a tube in memory.

/// One end of a tube: what the relay sends arrives in `incoming`; what the host answers collects in `response`.
private final class TubeEnd: LinkTransport, @unchecked Sendable {
    let path = LinkPath.relay
    let incoming: AsyncStream<TransportInput>
    private let sink: AsyncStream<TransportInput>.Continuation
    private let lock = NSLock()
    private var sent = Data()

    init() {
        (incoming, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func feed(_ text: String) { sink.yield(.bytes(Data(text.utf8))) }
    func feed(_ data: Data) { sink.yield(.bytes(data)) }
    func send(_ bytes: Data) { lock.withLock { sent.append(bytes) } }
    func sendDatagram(_ datagram: Data) {}

    func close() {
        sink.yield(.closed(nil))
        sink.finish()
    }

    var response: String { lock.withLock { String(decoding: sent, as: UTF8.self) } }

    var status: Int? {
        let line = response.split(separator: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        return parts.count >= 2 && parts[0] == "HTTP/1.1" ? Int(parts[1]) : nil
    }

    var json: [String: String]? {
        guard let range = response.range(of: "\r\n\r\n") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(response[range.upperBound...].utf8))) as? [String: String]
    }
}

/// The engine, as far as announcements go.
private actor FakeAnnouncer: Announcing {
    struct Said: Sendable {
        var text: String
        var note: String
        var urgent: Bool
        var language: SpeechLanguage
    }

    var ready = true
    /// The engine stops between the check and the announcement (a change of tier): `announce` refuses.
    var refusing = false
    /// Someone speaks: announcements wait.
    var holding = false
    /// The user stops what is said before its end (speaks over it, Escape…).
    var stopping = false
    /// What the engine was asked to say (whether it was said to its end or not).
    private(set) var said: [Said] = []
    private(set) var notifications: [(title: String, body: String)] = []
    private(set) var permissionRequests = 0
    private var states: [UUID: AnnouncementState] = [:]
    /// The news, while the engine offers lire_nouvelles; and each time it was given or taken away.
    private(set) var news: NewsStore?
    private(set) var newsOffers: [Bool] = []

    func set(ready: Bool) { self.ready = ready }
    func set(refusing: Bool) { self.refusing = refusing }
    func set(holding: Bool) { self.holding = holding }
    func set(stopping: Bool) { self.stopping = stopping }

    func canAnnounce() -> Bool { ready }

    func announce(_ text: String, note: String, language: SpeechLanguage, chime: Bool, urgent: Bool, id: UUID) -> Bool {
        guard ready, !refusing else { return false }
        said.append(Said(text: text, note: note, urgent: urgent, language: language))
        states[id] = holding ? .waiting : stopping ? .stopped : .said
        return true
    }

    func withdrawAnnouncement(_ id: UUID) -> Bool {
        guard states[id] == .waiting else { return false }
        states[id] = nil
        return true
    }

    func announcementState(_ id: UUID) -> AnnouncementState { states[id] ?? .unknown }

    func useNews(_ news: NewsStore?) {
        self.news = news
        newsOffers.append(news != nil)
    }

    func notify(title: String, body: String) { notifications.append((title, body)) }
    func requestNotificationPermission() { permissionRequests += 1 }
}

@Suite("Received information on the Mac")
struct InboundTests {
    private struct Rig {
        let host: InboundHost
        let announcer: FakeAnnouncer
        let source: UUID
        let secret: String

        var target: String { "/4zvomamapw57cf63xyx4cjb3qe/in/\(secret)" }

        func log() async -> [InboundLogEntry] {
            await host.current.logs[source] ?? []
        }

        /// Serves one delivery whose bytes are all there, and returns the answer.
        func deliver(_ raw: String, path: InboundPath = .homeRelay) async -> TubeEnd {
            let tube = TubeEnd()
            tube.feed(raw)
            await host.serve(tube, from: "192.168.1.20", path: path)
            return tube
        }

        func post(_ body: String, contentType: String = "application/json", path: InboundPath = .homeRelay,
                  extraHeaders: String = "") async -> TubeEnd
        {
            await deliver("POST \(target) HTTP/1.1\r\nHost: relay\r\nContent-Type: \(contentType)\r\n\(extraHeaders)"
                + "Content-Length: \(Data(body.utf8).count)\r\n\r\n\(body)", path: path)
        }
    }

    private func makeRig(requestTime: Duration = .seconds(10), configure: (inout InboundSource) -> Void = { _ in })
        async -> Rig
    {
        let announcer = FakeAnnouncer()
        let secrets = MemoryInboundSecrets()
        let identity = FileIdentityStore(url: FileManager.default.temporaryDirectory
            .appending(path: "inbound-tests-\(UUID().uuidString)/keys"))
        let host = InboundHost(announcer: announcer, identityStore: identity, secrets: secrets, storeURL: nil,
                               requestTime: requestTime, expiryUnit: .milliseconds(20))
        let id = await host.addSource(name: "Home Assistant")
        var source = await host.current.sources.first(where: { $0.id == id })!
        configure(&source)
        await host.updateSource(source)
        return Rig(host: host, announcer: announcer, source: id, secret: secrets.secret(for: id)!)
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    // MARK: - HTTP

    @Test func contentLength() async throws {
        let rig = await makeRig()
        let tube = await rig.post(#"{"text": "Essai depuis Home Assistant", "news": false}"#)
        #expect(tube.status == 202)
        #expect(tube.json == ["status": "queued"])
        #expect(await eventually { await rig.announcer.said.count == 1 })
        let said = try #require(await rig.announcer.said.first)
        #expect(said.text == "Essai depuis Home Assistant")
        #expect(said.note.hasPrefix("(Information de la source « Home Assistant », reçue à "))
        #expect(said.note.hasSuffix(", dite à l’utilisateur.)"))
        #expect(!said.urgent)
        // Logged: path, form, caller, the text; marked said once it started.
        #expect(await eventually { await rig.log().first?.result == .said })
        let entry = try #require(await rig.log().first)
        #expect(entry.path == .homeRelay && entry.form == .json && entry.caller == "192.168.1.20")
        #expect(entry.text == "Essai depuis Home Assistant")
    }

    @Test func chunkedInPieces() async {
        let rig = await makeRig()
        let tube = TubeEnd()
        let serving = Task { await rig.host.serve(tube, from: "192.168.1.20", path: .homeRelay) }
        tube.feed("POST \(rig.target) HTTP/1.1\r\nHost: relay\r\nTransfer-Encoding: chunked\r\n")
        tube.feed("Content-Type: text/plain\r\nTitle: Garage\r\n\r\n")
        tube.feed("e\r\nLa porte est o\r\n")
        tube.feed("8;ext=1\r\nuverte.\n\r\n")
        tube.feed("0\r\n\r\n")
        await serving.value
        #expect(tube.status == 202)
        #expect(await eventually { await rig.announcer.said.first?.text == "Garage\u{00A0}: La porte est ouverte." })
    }

    @Test func getWithText() async {
        let rig = await makeRig()
        let tube = await rig.deliver("GET \(rig.target)?text=Le+courrier+est+arriv%C3%A9 HTTP/1.1\r\nHost: relay\r\n\r\n")
        #expect(tube.status == 202)
        #expect(await eventually { await rig.announcer.said.first?.text == "Le courrier est arrivé" })
    }

    @Test func bodyOver64KB() async {
        let rig = await makeRig()
        let big = await rig.deliver("POST \(rig.target) HTTP/1.1\r\nHost: relay\r\nContent-Length: 70000\r\n\r\nabc")
        #expect(big.status == 413)
        // Chunked, past the limit as it arrives.
        let chunk = String(repeating: "a", count: 0x8000)
        let chunked = await rig.deliver("POST \(rig.target) HTTP/1.1\r\nHost: relay\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "8000\r\n\(chunk)\r\n8000\r\n\(chunk)\r\n1\r\na\r\n0\r\n\r\n")
        #expect(chunked.status == 413)
        #expect(await rig.log().first?.result == .tooLarge)
        // Exactly 64 KB is fine.
        let max = String(repeating: "a ", count: 32 * 1024)
        let ok = await rig.post(max, contentType: "text/plain")
        #expect(ok.status == 202)
    }

    @Test func slowSender() async {
        let rig = await makeRig(requestTime: .milliseconds(300))
        let tube = TubeEnd()
        let serving = Task { await rig.host.serve(tube, from: "192.168.1.20", path: .homeRelay) }
        tube.feed("POST \(rig.target) HTTP/1.1\r\nHost: relay\r\nContent-Length: 40\r\n\r\nLa porte")
        #expect(await eventually { tube.status == 408 })
        tube.feed(" du garage est restée ouverte.")  // too late
        await serving.value
        #expect(tube.status == 408)
        #expect(await rig.announcer.said.isEmpty)
    }

    @Test func unknownAddressOnlyGets404() async {
        let rig = await makeRig()
        let other = "/4zvomamapw57cf63xyx4cjb3qe/in/\(InboundSecret.generate())"
        for raw in [
            "POST \(other) HTTP/1.1\r\nHost: relay\r\nContent-Length: 5\r\n\r\nhello",
            "PUT \(other) HTTP/1.1\r\nHost: relay\r\nContent-Length: 5\r\n\r\nhello",
            "POST \(other) HTTP/1.1\r\nHost: relay\r\nContent-Length: 900000\r\n\r\n",
            "POST \(other) HTTP/1.1\r\nHost: relay\r\nContent-Length: 3\r\n\r\n{x}",
            "GET /4zvomamapw57cf63xyx4cjb3qe/in/ HTTP/1.1\r\nHost: relay\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: relay\r\n\r\n",
            "NONSENSE\r\n\r\n",
        ] {
            #expect(await rig.deliver(raw).status == 404, "\(raw)")
        }
        #expect(await rig.announcer.said.isEmpty)
        #expect(await rig.log().isEmpty)
    }

    @Test func pausedSourceGets404() async {
        let rig = await makeRig { $0.paused = true }
        let tube = await rig.post(#"{"text": "Bonjour"}"#)
        #expect(tube.status == 404)
        #expect(tube.json == ["error": "Unknown address."])
        #expect(await rig.log().first?.result == .paused)
        #expect(await rig.announcer.said.isEmpty)
    }

    @Test func removedSourceAndChangedAddressGet404() async {
        let rig = await makeRig()
        await rig.host.changeAddress(rig.source)
        #expect(await rig.post(#"{"text": "Bonjour"}"#).status == 404)  // the old address
        await rig.host.removeSource(rig.source)
        #expect(await rig.post(#"{"text": "Bonjour"}"#).status == 404)
    }

    @Test func wrongPathForTheOriginGets404() async {
        let rig = await makeRig()
        #expect(await rig.post(#"{"text": "Bonjour"}"#, path: .publicRelay).status == 404)
        #expect(await rig.log().first?.result == .wrongPath)
        #expect(await rig.post(#"{"text": "Bonjour"}"#, path: .homeRelay).status == 202)
    }

    @Test func tooManyDeliveries() async {
        let rig = await makeRig()
        for i in 0..<6 { #expect(await rig.post(#"{"text": "Message \#(i)"}"#).status == 202) }
        let seventh = await rig.post(#"{"text": "Message 7"}"#)
        #expect(seventh.status == 429)
        #expect(await rig.log().first?.result == .rateLimited)
    }

    @Test func methodsAndRefusals() async {
        let rig = await makeRig()
        let put = await rig.deliver("PUT \(rig.target) HTTP/1.1\r\nHost: relay\r\nContent-Length: 2\r\n\r\nhi")
        #expect(put.status == 405)
        #expect(put.response.contains("Allow: GET, POST"))
        let github = await rig.post(#"{"action": "opened", "repository": {"name": "x"}}"#)
        #expect(github.status == 422)
        #expect(github.json?["error"]?.contains("No text found") == true)
        #expect(await rig.log().first?.result == .noText)
        #expect(await rig.post("{\"text\": \"oops").status == 400)  // broken JSON
        #expect(await rig.post("", contentType: "text/plain").status == 400)
    }

    // MARK: - What becomes of a delivery

    @Test func duplicateIsIgnored() async {
        let rig = await makeRig()
        #expect(await rig.post(#"{"text": "Le courrier est arrivé"}"#).status == 202)
        let again = await rig.post(#"{"text": "Le courrier est arrivé"}"#)
        #expect(again.status == 200)
        #expect(again.json == ["status": "duplicate"])
        #expect(await rig.log().first?.result == .duplicate)
        // The first is said from a task of its own: wait for it, then give a second one time to show up.
        #expect(await eventually { await rig.announcer.said.count == 1 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await rig.announcer.said.count == 1)
    }

    @Test func notReadyIsKeptForLater() async {
        let rig = await makeRig()
        await rig.announcer.set(ready: false)
        let tube = await rig.post(#"{"title": "Garage", "text": "La porte est ouverte"}"#)
        #expect(tube.json == ["status": "kept"])
        #expect(await rig.log().first?.result == .kept)
        #expect(await rig.host.news.unread.map(\.text) == ["Garage\u{00A0}: La porte est ouverte"])
        #expect(await rig.host.news.unread.first?.source == "Home Assistant")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await rig.announcer.notifications.isEmpty)
        #expect(await rig.announcer.said.isEmpty)
    }

    @Test func notificationOnlySource() async {
        let rig = await makeRig { $0.mode = .notifyOnly }
        let tube = await rig.post(#"{"text": "Le lave-linge a fini"}"#)
        #expect(tube.status == 202 && tube.json == ["status": "notified"])
        #expect(await eventually { await rig.announcer.notifications.first?.title == "Home Assistant" })
    }

    @Test func expiredAnnouncementIsNeverSaidLate() async {
        let rig = await makeRig()
        await rig.announcer.set(holding: true)  // someone keeps speaking
        // 10 s at the least, here 10 × 20 ms.
        let tube = await rig.post(#"{"text": "Le bus passe dans deux minutes", "expires": 10}"#)
        #expect(tube.json == ["status": "queued"])
        // Not news while it waits to be said.
        #expect(await rig.host.news.unread.isEmpty)
        #expect(await eventually { await rig.log().first?.result == .expired })
        // Taken back from the engine: it will not be said; kept for later instead of a notification.
        #expect(await rig.announcer.said.count == 1)
        #expect(await rig.host.news.unread.map(\.text) == ["Le bus passe dans deux minutes"])
        #expect(await rig.announcer.notifications.isEmpty)
    }

    // MARK: - The news

    @Test func keepForLaterSource() async {
        let rig = await makeRig { $0.mode = .keepForLater }
        let tube = await rig.post(#"{"text": "Le linge est prêt"}"#)
        #expect(tube.status == 202 && tube.json == ["status": "kept"])
        #expect(await rig.log().first?.result == .kept)
        #expect(await rig.host.news.unread.map(\.text) == ["Le linge est prêt"])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await rig.announcer.said.isEmpty)
        #expect(await rig.announcer.notifications.isEmpty)
    }

    @Test func quietHoursAndTheAnnouncementsSwitch() async {
        let rig = await makeRig()
        // Quiet from an hour ago to an hour from now.
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        await rig.host.setPreferences(InboundPreferences(quietHours: QuietHours(enabled: true, start: (minute + 1380) % 1440,
                                                                                end: (minute + 60) % 1440)))
        let night = await rig.post(#"{"text": "La porte du garage est restée ouverte"}"#)
        #expect(night.json == ["status": "kept"])
        await rig.host.setPreferences(InboundPreferences(announcements: false))
        let off = await rig.post(#"{"text": "Le courrier est arrivé"}"#)
        #expect(off.json == ["status": "kept"])
        #expect(await rig.host.news.unread.map(\.text) == ["La porte du garage est restée ouverte",
                                                             "Le courrier est arrivé"])
        #expect(await rig.host.current.preferences == InboundPreferences(announcements: false))
        await rig.host.setPreferences(InboundPreferences())
        #expect(await rig.post(#"{"text": "Le colis est arrivé"}"#).json == ["status": "queued"])
    }

    @Test func saidAnnouncementIsMarkedSaid() async {
        let rig = await makeRig()
        _ = await rig.post(#"{"text": "Le courrier est arrivé"}"#)
        #expect(await eventually { await rig.log().first?.result == .said })
        #expect(await eventually { await rig.host.news.all.first?.state == .said })
        #expect(await rig.host.news.unread.isEmpty)  // never said again
    }

    @Test func interruptedAnnouncementIsKeptForLater() async {
        let rig = await makeRig()
        await rig.announcer.set(stopping: true)  // the user speaks over it
        _ = await rig.post(#"{"text": "Le lave-vaisselle a fini"}"#)
        #expect(await eventually { await rig.log().first?.result == .kept })
        #expect(await rig.host.news.unread.map(\.text) == ["Le lave-vaisselle a fini"])
        #expect(await rig.announcer.said.count == 1)
    }

    /// Two pieces of information kept for later, then the welcome home: its text, then the news, which are taken out
    /// once said; then « Quoi de neuf ? » has nothing new.
    @Test func welcomeHome() async throws {
        let rig = await makeRig { $0.mode = .keepForLater }
        _ = await rig.post(#"{"text": "La porte du garage est restée ouverte."}"#)
        _ = await rig.post(#"{"text": "Le linge est prêt."}"#)
        var source = try #require(await rig.host.current.sources.first)
        source.mode = .sayNow
        await rig.host.updateSource(source)
        let tube = await rig.post(#"{"text": "Bonsoir, bon retour.", "news": true}"#)
        #expect(tube.json == ["status": "queued"])
        #expect(await eventually { await rig.log().first?.result == .said })
        let said = try #require(await rig.announcer.said.last)
        #expect(said.text.hasPrefix("Bonsoir, bon retour. Pendant ton absence, deux nouvelles. Home Assistant, à "))
        #expect(said.text.contains(": la porte du garage est restée ouverte. Home Assistant, à "))
        #expect(said.text.hasSuffix(": le linge est prêt."))
        #expect(await eventually { await rig.host.news.unread.isEmpty })
        let (items, left) = await rig.host.news.read()
        #expect(items.isEmpty && left == 0)
        #expect(NewsPhrases.reading(items, left: left, now: Date(), language: .french) == "Rien de neuf pour le moment.")
    }

    @Test func welcomeHomeWithoutNewsSaysTheTextAlone() async throws {
        let rig = await makeRig()
        _ = await rig.post(#"{"text": "Bonsoir, bon retour.", "news": true}"#)
        #expect(await eventually { await rig.log().first?.result == .said })
        #expect(await rig.announcer.said.last?.text == "Bonsoir, bon retour.")
    }

    @Test func welcomeHomeStoppedKeepsTheNews() async throws {
        let rig = await makeRig { $0.mode = .keepForLater }
        _ = await rig.post(#"{"text": "Le linge est prêt."}"#)
        var source = try #require(await rig.host.current.sources.first)
        source.mode = .sayNow
        await rig.host.updateSource(source)
        await rig.announcer.set(stopping: true)
        _ = await rig.post(#"{"text": "Bonsoir, bon retour.", "news": true}"#)
        #expect(await eventually { await rig.log().first?.result == .kept })
        #expect(await rig.announcer.said.last?.text.contains("Pendant ton absence, une nouvelle.") == true)
        #expect(await rig.host.news.unread.map(\.text) == ["Le linge est prêt.", "Bonsoir, bon retour."])
    }

    @Test func theNewsAreOfferedWhileASourceExists() async throws {
        let rig = await makeRig()
        #expect(await eventually { await rig.announcer.newsOffers == [true] })
        #expect(await rig.announcer.news === rig.host.news)
        let second = await rig.host.addSource(name: "Gladys")
        await rig.host.removeSource(rig.source)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await rig.announcer.newsOffers == [true])  // a source still exists
        await rig.host.removeSource(second)
        #expect(await eventually { await rig.announcer.newsOffers == [true, false] })
        #expect(await rig.announcer.news == nil)
    }

    @Test func urgentFromAnAllowedSource() async {
        let rig = await makeRig {
            $0.mode = .notifyOnly
            $0.mayBeUrgent = true
        }
        let tube = await rig.post(#"{"text": "Fumée détectée dans la cuisine", "priority": "urgent"}"#)
        #expect(tube.json == ["status": "queued"])
        #expect(await eventually { await rig.announcer.said.first?.urgent == true })
    }

    @Test func urgentFromASourceNotAllowed() async {
        let rig = await makeRig()
        _ = await rig.post(#"{"text": "Fumée détectée dans la cuisine", "priority": "urgent"}"#)
        #expect(await eventually { await rig.announcer.said.count == 1 })
        #expect(await rig.announcer.said.first?.urgent == false)
    }

    /// An urgent delivery Maé cannot say, the announcements switched off: a notification, and the news as well.
    @Test func urgentWithTheAnnouncementsOffIsNotifiedAndKept() async {
        let rig = await makeRig { $0.mayBeUrgent = true }
        await rig.host.setPreferences(InboundPreferences(announcements: false))
        let tube = await rig.post(#"{"title": "Cuisine", "text": "Fumée détectée", "priority": "urgent"}"#)
        #expect(tube.status == 202 && tube.json == ["status": "notified"])
        #expect(await rig.log().first?.result == .notifiedAndKept)
        #expect(await rig.host.news.unread.map(\.text) == ["Cuisine\u{00A0}: Fumée détectée"])
        #expect(await eventually { await rig.announcer.notifications.count == 1 })
        let notification = await rig.announcer.notifications.first
        #expect(notification?.title == "Cuisine" && notification?.body == "Fumée détectée")
        // Not urgent: the news only.
        let calm = await rig.post(#"{"text": "Le courrier est arrivé"}"#)
        #expect(calm.json == ["status": "kept"])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await rig.announcer.notifications.count == 1)
        #expect(await rig.announcer.said.isEmpty)
    }

    /// An urgent delivery while Maé is not ready (models loading), or no longer ready when it was to be said: a
    /// notification, and the news as well.
    @Test func urgentWhileNotReadyIsNotifiedAndKept() async {
        let rig = await makeRig { $0.mayBeUrgent = true }
        await rig.announcer.set(ready: false)
        let tube = await rig.post(#"{"text": "Fumée détectée", "priority": "urgent"}"#)
        #expect(tube.json == ["status": "notified"])
        #expect(await rig.log().first?.result == .notifiedAndKept)
        #expect(await rig.host.news.unread.map(\.text) == ["Fumée détectée"])
        #expect(await eventually { await rig.announcer.notifications.first?.title == "Home Assistant" })
        // Ready when it arrives, but the engine stops before it is said.
        await rig.announcer.set(ready: true)
        await rig.announcer.set(refusing: true)
        let late = await rig.post(#"{"text": "Le détecteur de fumée sonne encore", "priority": "urgent"}"#)
        #expect(late.json == ["status": "queued"])
        #expect(await eventually { await rig.log().first?.result == .notifiedAndKept })
        #expect(await eventually { await rig.announcer.notifications.count == 2 })
        #expect(await rig.announcer.notifications.last?.body == "Le détecteur de fumée sonne encore")
        #expect(await rig.host.news.unread.map(\.text) == ["Fumée détectée", "Le détecteur de fumée sonne encore"])
        // Not urgent: kept, never notified.
        let calm = await rig.post(#"{"text": "Le courrier est arrivé"}"#)
        #expect(calm.json == ["status": "queued"])
        #expect(await eventually { await rig.log().first?.result == .kept })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await rig.announcer.notifications.count == 2)
        #expect(await rig.announcer.said.isEmpty)
    }

    /// The notification permission is asked when a source may end in a notification: "Notification only", or allowed
    /// urgent deliveries.
    @Test func notificationPermissionForTheSourcesThatMayNotify() async throws {
        let rig = await makeRig()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await rig.announcer.permissionRequests == 0)  // said right away: never a notification
        var source = try #require(await rig.host.current.sources.first)
        source.mayBeUrgent = true
        await rig.host.updateSource(source)
        #expect(await eventually { await rig.announcer.permissionRequests == 1 })
        source.mode = .notifyOnly  // asked already
        await rig.host.updateSource(source)
        _ = await rig.host.addSource(name: "Gladys", mode: .notifyOnly)
        #expect(await eventually { await rig.announcer.permissionRequests == 2 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(await rig.announcer.permissionRequests == 2)
    }

    @Test func sendTest() async {
        let rig = await makeRig()
        await rig.host.sendTest(rig.source)
        #expect(await rig.announcer.said.first?.text == "Ceci est un essai de la source Home Assistant.")
        #expect(await rig.log().first?.path == nil)
    }

    // MARK: - Pieces

    @Test func secretInPath() {
        #expect(InboundHost.secret(in: "/abc/in/s3cr3t") == "s3cr3t")
        #expect(InboundHost.secret(in: "/in/s3cr3t") == "s3cr3t")
        #expect(InboundHost.secret(in: "/abc/in/") == nil)
        #expect(InboundHost.secret(in: "/abc/in/a/b") == nil)
        #expect(InboundHost.secret(in: "/abc/out/x") == nil)
    }

    @Test func homeRelayAddress() {
        #expect(InboundHost.homeRelayURL(from: "192.168.1.10:8080")?.absoluteString == "http://192.168.1.10:8080")
        #expect(InboundHost.homeRelayURL(from: " http://relais.local:8080/ ")?.absoluteString == "http://relais.local:8080")
        #expect(InboundHost.homeRelayURL(from: "") == nil)
        #expect(InboundHost.homeRelayURL(from: "ftp://x") == nil)
    }

    @Test func addressOfAHomeSource() async throws {
        let announcer = FakeAnnouncer()
        let secrets = MemoryInboundSecrets()
        let keys = FileIdentityStore(url: FileManager.default.temporaryDirectory
            .appending(path: "inbound-tests-\(UUID().uuidString)/keys"))
        let identity = try keys.loadOrCreate()
        let host = InboundHost(announcer: announcer, identityStore: keys, secrets: secrets, storeURL: nil)
        let id = await host.addSource(name: "Home Assistant")
        await host.setHomeRelay(URL(string: "http://127.0.0.1:9")!)  // nothing listens: unreachable, the address is known
        let address = await host.current.addresses[id]
        let name = InboundName.make(signingKey: identity.signingKey.publicKey.rawRepresentation)
        #expect(address?.absoluteString == "http://127.0.0.1:9/\(name)/in/\(secrets.secret(for: id)!)")
        await host.setHomeRelay(nil)
    }

    @Test func storedSourcesAndLogSurviveARestart() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "inbound-tests-\(UUID().uuidString)")
        let store = folder.appending(path: "received-information.json")
        let secrets = MemoryInboundSecrets()
        let keys = FileIdentityStore(url: folder.appending(path: "keys"))
        let first = InboundHost(announcer: FakeAnnouncer(), identityStore: keys, secrets: secrets, storeURL: store)
        let id = await first.addSource(name: "Gladys")
        await first.sendTest(id)
        let second = InboundHost(announcer: FakeAnnouncer(), identityStore: keys, secrets: secrets, storeURL: store)
        _ = await eventually { await !second.current.sources.isEmpty }
        let status = await second.current
        #expect(status.sources.map(\.name) == ["Gladys"])
        #expect(status.logs[id]?.count == 1)
        let raw = try String(contentsOf: store, encoding: .utf8)
        #expect(!raw.contains(secrets.secret(for: id)!))  // the secret is never in the file
    }
}

@Suite("Minimal HTTP/1.1")
struct InboundHTTPTests {
    @Test func headThenBody() throws {
        var reader = HTTPRequestReader(maxBody: 100)
        reader.append(Data("POST /a/in/b?x=1&y=deux+mots HTTP/1.1\r\nHost: h\r\nX-A: 1\r\nX-A: 2\r\nContent-Length: 4\r\n".utf8))
        let incomplete = try reader.readHead()
        #expect(incomplete == nil)
        reader.append(Data("\r\nab".utf8))
        let complete = try reader.readHead()
        let head = try #require(complete)
        #expect(head.method == "POST" && head.path == "/a/in/b")
        #expect(head.query == ["x": "1", "y": "deux mots"])
        #expect(head.headers["x-a"] == "1, 2")
        #expect(try reader.readBody() == nil)
        reader.append(Data("cd".utf8))
        #expect(try reader.readBody() == Data("abcd".utf8))
    }

    @Test func chunkedWithTrailers() throws {
        var reader = HTTPRequestReader(maxBody: 100)
        reader.append(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\nX-T: 1\r\n".utf8))
        _ = try reader.readHead()
        #expect(try reader.readBody() == nil)
        reader.append(Data("\r\n".utf8))
        #expect(try reader.readBody() == Data("abc".utf8))
    }

    @Test func refusals() throws {
        var big = HTTPRequestReader(maxBody: 10)
        big.append(Data("POST / HTTP/1.1\r\nContent-Length: 11\r\n\r\n".utf8))
        _ = try big.readHead()  // the size is refused with the body, once the address is checked
        #expect(throws: HTTPReadError.tooLarge) { try big.readBody() }
        var gzip = HTTPRequestReader(maxBody: 10)
        gzip.append(Data("POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n".utf8))
        _ = try gzip.readHead()
        #expect(throws: HTTPReadError.unsupportedEncoding) { try gzip.readBody() }
        var headers = HTTPRequestReader(maxBody: 10)
        headers.append(Data(("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 20_000)).utf8))
        #expect(Self.headError(&headers) == .headersTooLarge)
        var junk = HTTPRequestReader(maxBody: 10)
        junk.append(Data("hello\r\n\r\n".utf8))
        #expect(Self.headError(&junk) == .badRequest)
    }

    private static func headError(_ reader: inout HTTPRequestReader) -> HTTPReadError? {
        do {
            _ = try reader.readHead()
            return nil
        } catch {
            return error
        }
    }
}
