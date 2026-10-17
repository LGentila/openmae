import CryptoKit
import Foundation
import Testing

@testable import VoiceCore

@Suite("Received information")
struct ReceivedInformationTests {
    private func parse(_ body: String, contentType: String? = nil, headers: [String: String] = [:],
                       method: String = "POST", query: [String: String] = [:]) -> Result<InboundMessage, InboundRefusal>
    {
        var headers = headers
        if let contentType { headers["Content-Type"] = contentType }
        return InboundParser.parse(InboundRequest(method: method, query: query, headers: headers, body: Data(body.utf8)))
    }

    private func message(_ result: Result<InboundMessage, InboundRefusal>) throws -> InboundMessage {
        try result.get()
    }

    // MARK: - Form 1, a plain sentence

    @Test func plainText() throws {
        let m = try message(parse("La porte du garage est restée ouverte.", contentType: "text/plain"))
        #expect(m.form == .text)
        #expect(m.text == "La porte du garage est restée ouverte.")
        #expect(m.title == nil && !m.urgent && m.expires == nil && !m.news)
        #expect(m.language == .french)
    }

    @Test func plainTextWithoutContentTypeAndGetWithText() throws {
        #expect(try message(parse("Le lave-linge a fini son cycle.")).text == "Le lave-linge a fini son cycle.")
        let get = try message(parse("", method: "GET", query: ["text": "Le courrier est arrivé"]))
        #expect(get.form == .text && get.text == "Le courrier est arrivé")
    }

    @Test func ntfyHeaders() throws {
        let m = try message(parse("Fumée détectée dans la cuisine", headers: ["Title": "Alarme", "Priority": "urgent"]))
        #expect(m.title == "Alarme" && m.urgent)
        #expect(m.full == "Alarme\u{00A0}: Fumée détectée dans la cuisine")
        #expect(try message(parse("x y z", headers: ["X-Priority": "5"])).urgent)
        #expect(try message(parse("x y z", headers: ["Priority": "4"])).urgent)
        #expect(try message(parse("x y z", headers: ["Priority": "high"])).urgent)
        #expect(try message(parse("x y z", headers: ["Priority": "max"])).urgent)
        #expect(try !message(parse("x y z", headers: ["Priority": "3"])).urgent)
        #expect(try !message(parse("x y z", headers: ["Priority": "default"])).urgent)
    }

    // MARK: - Form 2, JSON

    @Test func slack() throws {
        let body = #"{"text": "*Alerte* : la <https://example.com/cam|caméra du portail> a vu quelqu'un <@U123>"}"#
        let m = try message(parse(body, contentType: "application/json"))
        #expect(m.form == .json)
        #expect(m.text == "Alerte : la caméra du portail a vu quelqu'un")
    }

    @Test func discord() throws {
        let plain = try message(parse(#"{"content": "Le serveur a redémarré", "username": "bot"}"#,
                                      contentType: "application/json"))
        #expect(plain.text == "Le serveur a redémarré")
        let embeds = #"{"content": "", "embeds": [{"title": "Sauvegarde", "description": "Terminée sans erreur."}]}"#
        let withEmbeds = try message(parse(embeds, contentType: "application/json"))
        #expect(withEmbeds.title == "Sauvegarde" && withEmbeds.text == "Terminée sans erreur.")
        #expect(withEmbeds.full == "Sauvegarde\u{00A0}: Terminée sans erreur.")
        let titleOnly = try message(parse(#"{"embeds": [{"title": "Sauvegarde terminée"}]}"#, contentType: "application/json"))
        #expect(titleOnly.text == "Sauvegarde terminée" && titleOnly.title == nil)
    }

    @Test func gotify() throws {
        let m = try message(parse(#"{"title": "Box", "message": "Connexion internet rétablie", "priority": 8}"#,
                                  contentType: "application/json"))
        #expect(m.title == "Box" && m.text == "Connexion internet rétablie" && m.urgent)
        #expect(try !message(parse(#"{"message": "Mise à jour disponible", "priority": 5}"#,
                                   contentType: "application/json")).urgent)
    }

    @Test func ntfyJSON() throws {
        let m = try message(parse(#"{"topic": "maison", "message": "Il pleut, ferme les fenêtres", "priority": 4}"#,
                                  contentType: "application/json"))
        #expect(m.text == "Il pleut, ferme les fenêtres" && m.urgent)
        #expect(try !message(parse(#"{"topic": "maison", "message": "Tout va bien", "priority": 3}"#)).urgent)
    }

    @Test func homeAssistantPayload() throws {
        // What `{{ {'text': texte, 'news': nouvelles | default(false)} | to_json }}` gives.
        let m = try message(parse(#"{"text": "Essai depuis Home Assistant", "news": false}"#, contentType: "application/json"))
        #expect(m.text == "Essai depuis Home Assistant" && !m.news)
        let news = try message(parse(#"{"text": "Bonjour", "news": true, "expires": 5000}"#, contentType: "application/json"))
        #expect(news.news && news.expires == 3600)
        #expect(try message(parse(#"{"text": "Bonjour", "expires": 3}"#)).expires == 10)
        #expect(try message(parse(#"{"text": "Bonjour", "expires": 120}"#)).expires == 120)
    }

    @Test func firstFieldThatHoldsText() throws {
        #expect(try message(parse(#"{"text": "  ", "message": "Le message"}"#)).text == "Le message")
        #expect(try message(parse(#"{"body": "Le corps", "content": "Le contenu"}"#)).text == "Le corps")
    }

    @Test func refusals() {
        #expect(parse(#"{"text": "oups""#, contentType: "application/json") == .failure(.unreadable("The body is not a valid JSON object.")))
        #expect(parse("{broken") == .failure(.unreadable("The body is not a valid JSON object.")))
        #expect(parse("", contentType: "text/plain") == .failure(.unreadable("There is no text to say.")))
        #expect(parse("   \n") == .failure(.unreadable("There is no text to say.")))
        // A GitHub payload: JSON without any of the fields.
        #expect(parse(#"{"action": "opened", "issue": {"number": 1}}"#, contentType: "application/json") == .failure(.noText))
        #expect(parse(#"[1, 2]"#, contentType: "application/json") == .failure(.unreadable("The body is not a valid JSON object.")))
        #expect(InboundParser.parse(InboundRequest(method: "POST", body: Data([0xFF, 0xFE]))) == .failure(.unreadable("The body is not UTF-8 text.")))
    }

    // MARK: - Cleaning

    @Test func cleaning() {
        #expect(InboundText.clean("**Gras** et _italique_ et ~barré~ et `code`") == "Gras et italique et barré et code")
        #expect(InboundText.clean("Voir [le tableau de bord](https://ha.local/lovelace) maintenant") == "Voir le tableau de bord maintenant")
        #expect(InboundText.clean("# Titre\n> citation\nsuite") == "Titre citation suite")
        #expect(InboundText.clean("Détails sur https://example.com/a?b=c et www.example.org") == "Détails sur et")
        #expect(InboundText.clean("<!here> Réunion dans <#C123|général>") == "Réunion dans général")
        #expect(InboundText.clean("le_capteur_2 reste tel quel") == "le_capteur_2 reste tel quel")
        #expect(InboundText.clean("Il fait 30 degrés ☀️ dehors") == "Il fait 30 degrés dehors")
    }

    @Test func longTextStopsAtTheLastCompleteSentence() {
        let sentence = "Ceci est une phrase de test assez longue pour remplir le message. "
        let long = String(repeating: sentence, count: 6).trimmingCharacters(in: .whitespaces)  // ~400 characters
        let m = InboundMessage(form: .text, title: nil, text: long)
        #expect(m.spoken.count <= 280)
        #expect(m.spoken.hasSuffix("message."))
        #expect(m.full == long)  // the log keeps it all
        let words = String(repeating: "mot ", count: 100)
        let cut = InboundText.shortened(words)
        #expect(cut.count <= 281 && cut.hasSuffix("mot…"))
    }

    @Test func languageIsGuessedFromTheText() throws {
        #expect(try message(parse("The garage door has been left open for ten minutes.")).language == .english)
        #expect(try message(parse("La porte du garage est ouverte depuis dix minutes.")).language == .french)
        let english = try message(parse("The washing machine is done", headers: ["Title": "Laundry"]))
        #expect(english.full == "Laundry: The washing machine is done")
    }

    // MARK: - Rules

    private let home = InboundSource(name: "Home Assistant", origin: .home, mode: .sayNow)

    @Test func sayRightAwayAndNotificationOnly() {
        var rules = InboundRules()
        let m = InboundMessage(form: .text, title: nil, text: "Le courrier est arrivé")
        let said = rules.decide(m, from: home, ready: true)
        #expect(said == InboundDecision(outcome: .queued, expiresAfter: 60))
        var notifying = home
        notifying.mode = .notifyOnly
        var other = InboundRules()
        let notified = other.decide(m, from: notifying, ready: true)
        #expect(notified.outcome == .notified)
    }

    @Test func urgency() {
        let urgent = InboundMessage(form: .text, title: nil, text: "Fumée détectée", urgent: true)
        var notifying = home
        notifying.mode = .notifyOnly
        var rules = InboundRules()
        // Not allowed: like the others (here, a notification).
        let notAllowed = rules.decide(urgent, from: notifying, ready: true)
        #expect(notAllowed.outcome == .notified)
        notifying.id = UUID()
        notifying.mayBeUrgent = true
        // Allowed: said at once whatever the mode.
        let allowed = rules.decide(urgent, from: notifying, ready: true)
        #expect(allowed == InboundDecision(outcome: .queued, urgent: true))
        // A non-urgent one from an allowed source follows the mode.
        let calm = InboundMessage(form: .text, title: nil, text: "Tout va bien")
        let calmDecision = rules.decide(calm, from: notifying, ready: true)
        #expect(calmDecision == InboundDecision(outcome: .notified))
    }

    @Test func expiry() {
        var rules = InboundRules()
        let soon = InboundMessage(form: .json, title: nil, text: "Le bus arrive", expires: 30)
        let first = rules.decide(soon, from: home, ready: true)
        #expect(first.expiresAfter == 30)
        let usual = InboundMessage(form: .json, title: nil, text: "Le train arrive")
        let second = rules.decide(usual, from: home, ready: true)
        #expect(second.expiresAfter == InboundRules.defaultExpiry)
    }

    @Test func notReadyBecomesANotification() {
        var rules = InboundRules()
        let m = InboundMessage(form: .text, title: nil, text: "Le courrier est arrivé", urgent: true)
        var urgentHome = home
        urgentHome.mayBeUrgent = true
        let decision = rules.decide(m, from: urgentHome, ready: false)
        #expect(decision.outcome == .notified)
    }

    @Test func duplicatesWithinTwoMinutes() {
        var rules = InboundRules()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let m = InboundMessage(form: .text, title: nil, text: "Le courrier est arrivé")
        let other = InboundMessage(form: .text, title: nil, text: "Le colis est arrivé")
        let second = InboundSource(name: "Gladys")
        var outcomes: [InboundOutcome] = []
        outcomes.append(rules.decide(m, from: home, ready: true, now: start).outcome)
        outcomes.append(rules.decide(m, from: home, ready: true, now: start + 30).outcome)
        outcomes.append(rules.decide(m, from: home, ready: true, now: start + 119).outcome)
        outcomes.append(rules.decide(m, from: home, ready: true, now: start + 121).outcome)
        // Another text, or the same text from another source, is not a duplicate.
        outcomes.append(rules.decide(other, from: home, ready: true, now: start + 122).outcome)
        outcomes.append(rules.decide(m, from: second, ready: true, now: start + 122).outcome)
        #expect(outcomes == [.queued, .duplicate, .duplicate, .queued, .queued, .queued])
    }

    @Test func rateLimitPerSource() {
        var limit = InboundRateLimit()
        let source = UUID()
        let start = Date(timeIntervalSince1970: 2_000_000)
        var firstMinute: [Bool] = []
        for i in 0..<7 { firstMinute.append(limit.allow(source, now: start + Double(i))) }
        #expect(firstMinute == [true, true, true, true, true, true, false])
        let another = limit.allow(UUID(), now: start + 10)
        #expect(another)  // another source
        // Then 6 a minute, until 60 in the hour.
        var t = start + 61
        var allowed = 6
        while t < start + 3500 {
            if limit.allow(source, now: t) { allowed += 1 }
            t += 1
        }
        #expect(allowed == 60)
    }

    @Test func compartmentalisation() {
        let homeSource = InboundSource(name: "HA", origin: .home)
        #expect(homeSource.accepts(.homeRelay) && homeSource.accepts(.internalDoor) && !homeSource.accepts(.publicRelay))
        let internet = InboundSource(name: "Shortcuts", origin: .internet)
        #expect(internet.accepts(.publicRelay) && !internet.accepts(.homeRelay) && !internet.accepts(.internalDoor))
    }

    // MARK: - Addresses

    /// The same vector as the relay's Go test: the public key 00 01 … 1f.
    @Test func inboundNameVector() {
        let key = Data((0..<32).map { UInt8($0) })
        #expect(InboundName.make(signingKey: key) == "4zvomamapw57cf63xyx4cjb3qe")
        #expect(InboundName.base32(Data(SHA256.hash(data: key).prefix(16))) == "mmg42klgyqzwneiskrelxms3j4")  // its device id
    }

    @Test func secrets() {
        let secret = InboundSecret.generate()
        #expect(secret.count == 43)
        #expect(secret.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(secret != InboundSecret.generate())
        let digest = InboundSecret.digest(secret)
        #expect(InboundSecret.same(digest, InboundSecret.digest(secret)))
        #expect(!InboundSecret.same(digest, InboundSecret.digest(secret + "x")))
        #expect(!InboundSecret.same(digest, Data()))
    }

    @Test func noteForTheModel() {
        let date = ISO8601DateFormatter().date(from: "2026-10-17T07:05:00Z")!
        #expect(InboundPhrases.note(source: "Home Assistant", receivedAt: date, timeZone: TimeZone(identifier: "UTC")!)
            == "(Information de la source « Home Assistant », reçue à 7 h 05, dite à l’utilisateur.)")
        #expect(InboundPhrases.test(source: "Home Assistant") == "Ceci est un essai de la source Home Assistant.")
    }
}

// MARK: - Announcements that must never be said late

@Suite("Received information in the pipeline", .serialized)
struct InboundAnnouncementTests {
    let speech = [Float](repeating: 0.5, count: 512)
    let silence = [Float](repeating: 0, count: 512)

    func push(_ pipeline: VoicePipeline, _ pattern: String) async {
        for c in pattern { await pipeline.push(c == "1" ? speech : silence) }
    }

    func waitFor(_ condition: () async -> Bool) async {
        for _ in 0..<400 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// While the user speaks, an announcement waits; taken back at its deadline, it is never said.
    @Test func anAnnouncementWaitsForTheUserAndCanBeTakenBack() async throws {
        let (model, speaker) = (ScriptedModel(answer: ["D’accord."]), FakeSpeaker())
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(), model: model,
                                     synthesizer: FakeSynthesizer(), output: speaker)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "11111")  // the user is speaking
        let id = UUID()
        await pipeline.announce("Le courrier est arrivé.", note: "(note)", language: .french, id: id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await speaker.played == 0)  // never while the user speaks
        #expect(await pipeline.announcementWaits(id))
        #expect(await pipeline.withdrawAnnouncement(id))  // its deadline: taken back
        #expect(await !pipeline.announcementWaits(id))
        await push(pipeline, "11111" + String(repeating: "0", count: 20))  // the user ends; Maé answers
        await waitFor {
            let state = await log.states.last
            let played = await speaker.played
            return state == .listening && played > 0
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await !log.pieces.contains("Le courrier est arrivé."))
        #expect(await !pipeline.withdrawAnnouncement(id))
    }

    /// At rest, an announcement starts at once, after the chime; it can no longer be taken back.
    @Test func atRestAnAnnouncementStartsAtOnce() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(), model: model,
                                     synthesizer: FakeSynthesizer(), output: speaker)
        try await pipeline.start()
        let id = UUID()
        await pipeline.announce("Le courrier est arrivé.", note: "(note)", language: .french, id: id)
        #expect(await !pipeline.announcementWaits(id))
        #expect(await !pipeline.withdrawAnnouncement(id))
        await waitFor { await speaker.played > 0 }
        #expect(await speaker.played > 0)
    }
}
