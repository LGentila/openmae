import Foundation
import Testing

@testable import VoiceCore

/// The pieces a chunker gives for `text` written `size` characters at a time (as a model streams it), with the
/// sentences it left out.
private func chunked(_ text: String, by size: Int = .max, leavesOut: Bool = true)
    -> (pieces: [SentenceChunker.Piece], leftOut: [String])
{
    var chunker = SentenceChunker()
    chunker.leavesOutSaveClaims = leavesOut
    var pieces: [SentenceChunker.Piece] = []
    var rest = text[...]
    while !rest.isEmpty {
        let part = rest.prefix(size)
        rest = rest.dropFirst(part.count)
        pieces += chunker.pieces(adding: String(part))
    }
    pieces += chunker.remainingPieces()
    return (pieces, chunker.leftOutClaims)
}

@Suite("Claims of a save, left out of what Maé says")
struct SaveClaimsTests {
    @Test func whatClaimsASave() {
        for sentence in [
            "C'est noté.", "C’est bien noté pour ta taille.", "D'accord, c'est noté.", "Noté, merci.",
            "J'ai bien retenu que tu fais du 38.", "Je note que tu as arrêté de fumer il y a trois mois.",
            "Je la garde en mémoire.", "Je prends note de ça.", "Je m'en souviendrai.", "Je vais le noter.",
            "Je l'ai bien enregistrée dans ma mémoire.", "Je retiens que ton deuxième chat s'appelle Pistache.",
            "I've noted that.",
        ] {
            #expect(SaveClaims.claims(sentence), "\(sentence)")
        }
        // Questions and offers promise nothing; « je peux » says nothing was.
        for sentence in [
            "Tu veux que je le note ?", "Tu veux que je retienne cette information\u{00A0}?", "Si tu veux, je le retiens.",
            "Je peux la noter pour toi.", "C'est une bonne nouvelle.", "Je ne m'en souviens pas.",
            "If you want, I'll remember it.",
        ] {
            #expect(!SaveClaims.claims(sentence), "\(sentence)")
        }
        #expect(SaveClaims.sentences("Bonne nouvelle !\nJe la note… Et toi ?") == ["Bonne nouvelle !", "Je la note…", "Et toi ?"])
        #expect(SaveClaims.claimingSentences(in: "C'est une jolie nouvelle. Je la note. Tu veux autre chose ?")
            == ["Je la note."])
        #expect(SaveClaims.saysItWasSaved("Super. J'ai bien noté ton manager.") && !SaveClaims.saysItWasSaved("Super."))
    }

    /// Gemma 4 E2B's answers to facts said in passing, and Gemma 4 26B's: the claim goes, the rest is said, and the
    /// history keeps what is said.
    @Test func theClaimIsLeftOutTheRestIsSaid() {
        let e2b = "C'est une bonne nouvelle. Je note que tu as arrêté de fumer il y a trois mois. (2026-10-15T18:42)"
        #expect(SaveClaims.spoken(e2b).said == "C'est une bonne nouvelle.")
        #expect(SaveClaims.spoken(e2b).leftOut == ["Je note que tu as arrêté de fumer il y a trois mois."])
        let big = "D'accord, c'est noté. Tu veux que je retienne cette information ?"
        #expect(chunked(big).pieces == [SentenceChunker.Piece("Tu veux que je retienne cette information ?")])
        #expect(chunked(big).leftOut == ["D'accord, c'est noté."])
        // Everything left out: nothing at all to say.
        #expect(chunked("C'est noté pour ta taille. Je l'ai bien enregistrée dans ma mémoire.").pieces.isEmpty)
        // Between paragraphs, the white space after the sentence left out goes with it.
        #expect(chunked("Bravo pour ton permis de conduire.\n\nJe le note.\n\nTu veux fêter ça ?").pieces
            == [SentenceChunker.Piece("Bravo pour ton permis de conduire."),
                SentenceChunker.Piece("Tu veux fêter ça ?", after: "\n\n")])
        #expect(SaveClaims.spoken("C'est une jolie nouvelle. Je la note. Tu veux autre chose ?").said
            == "C'est une jolie nouvelle. Tu veux autre chose ?")
    }

    @Test func questionsAndOffersAreKept() {
        for answer in ["Tu veux que je le note ?", "Si tu veux, je le note pour toi.",
                       "C'est une bonne nouvelle. Je peux la noter pour toi si tu me le demandes.",
                       "D'accord. Tu veux que je le garde en mémoire ?"]
        {
            #expect(chunked(answer).leftOut.isEmpty, "\(answer)")
            #expect(chunked(answer).pieces.map(\.text).joined(separator: " ") == answer, "\(answer)")
        }
    }

    /// What is left must still be heard: nothing gives the acknowledgement, a piece too short for the voice gets the
    /// thanks after it, in the same piece; anything longer stays as it is.
    @Test func whatIsLeftIsHeard() {
        #expect(SaveClaims.ending([], language: .french) == [SentenceChunker.Piece(MemoryPhrases.acknowledged(.french))])
        #expect(SaveClaims.ending([SentenceChunker.Piece("(2026-10-15T18:42)")], language: .french)
            == [SentenceChunker.Piece(MemoryPhrases.acknowledged(.french))])
        let short = SaveClaims.spoken("C'est une bonne nouvelle. Je note que tu as arrêté de fumer. (2026-10-15T18:42)")
        #expect(SaveClaims.ending(short.pieces, language: .french).map { SpeakableText.clean($0.text) }
            == ["C'est une bonne nouvelle. Merci de me le dire."])
        let long = SaveClaims.spoken("Bravo, c'est une très bonne nouvelle pour toi. Je le note.").pieces
        #expect(SaveClaims.ending(long, language: .french) == long)
        #expect(SentenceChunker.words(in: "C'est une bonne nouvelle.") == 4)
        #expect(SentenceChunker.words(in: "Il fait trente-huit degrés.") == 4)
        #expect(SentenceChunker.words(in: MemoryPhrases.thanks(.french)) >= 5)
        #expect(SentenceChunker.words(in: MemoryPhrases.acknowledged(.french)) >= 5)
    }

    /// Off (the memory not offered, or something saved in the turn): nothing is left out.
    @Test func offItLeavesNothingOut() {
        let answer = "C'est une bonne nouvelle. Je note que tu as arrêté de fumer."
        #expect(chunked(answer, leavesOut: false).leftOut.isEmpty)
        #expect(chunked(answer, leavesOut: false).pieces.map(\.text) == [answer])
    }

    /// Written a few characters at a time, as the model streams it, the answer gives the same pieces as written at once.
    @Test(arguments: [1, 2, 3, 7])
    func streamedTheSame(size: Int) {
        for answer in [
            "C'est une bonne nouvelle. Je note que tu as arrêté de fumer il y a trois mois. (2026-10-15T18:42)",
            "D'accord, c'est noté. Tu veux que je retienne cette information ?",
            "La capitale du Portugal est Lisbonne, une ville magnifique au bord du Tage. Je la note pour toi.",
            "C'est une très bonne nouvelle, je note que tu as arrêté de fumer. Comment te sens-tu ?",
            "Bravo pour ton permis de conduire.\n\nJe le note.\n\nTu veux fêter ça ?",
            "Si tu veux, je le note pour toi, d'accord ?",
        ] {
            let whole = chunked(answer)
            let streamed = chunked(answer, by: size)
            #expect(streamed.pieces == whole.pieces, "\(answer)")
            #expect(streamed.leftOut == whole.leftOut, "\(answer)")
        }
    }

    /// The first piece still goes at its comma as soon as it is written, when nothing in it says so: the voice starts as
    /// early as without the claims left out. Its sentence's end, when it claims a save, is left out.
    @Test func theFirstPieceStillGoesAtItsComma() {
        var chunker = SentenceChunker()
        chunker.leavesOutSaveClaims = true
        #expect(chunker.pieces(adding: "La capitale du Portugal est Lisbonne, une ville")
            == [SentenceChunker.Piece("La capitale du Portugal est Lisbonne,")])
        var claiming = SentenceChunker()
        claiming.leavesOutSaveClaims = true
        #expect(claiming.pieces(adding: "C'est une très bonne nouvelle, je note que tu as arrêté de fumer.")
            == [SentenceChunker.Piece("C'est une très bonne nouvelle,")])
        #expect(claiming.pieces(adding: " Comment te sens-tu ?").isEmpty)
        #expect(claiming.remainingPieces() == [SentenceChunker.Piece("Comment te sens-tu ?", after: " ")])
        #expect(claiming.leftOutClaims == ["C'est une très bonne nouvelle, je note que tu as arrêté de fumer."])
        // A first clause that says it waits for the sentence's end, and goes with it.
        var waiting = SentenceChunker()
        waiting.leavesOutSaveClaims = true
        #expect(waiting.pieces(adding: "Je note que tu aimes beaucoup le thé vert, c'est").isEmpty)
        #expect(waiting.pieces(adding: " une bonne idée. Bonne soirée à toi !").isEmpty)
        #expect(waiting.remainingPieces() == [SentenceChunker.Piece("Bonne soirée à toi !")])
    }
}

/// The pipeline leaves the claims out while nothing was saved in the turn, with the memory offered.
@Suite("Claims of a save in the pipeline", .serialized)
struct SaveClaimsPipelineTests {
    func waitFor(_ condition: () async -> Bool) async {
        for _ in 0..<400 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func make(_ model: ScriptedModel, memory: Bool = true) -> (VoicePipeline, EventRecorder) {
        let store = TransientMemoryStore()
        var config = PipelineConfig()
        config.toolCallFiller = false
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(), model: model,
                                     synthesizer: FakeSynthesizer(), output: FakeSpeaker(),
                                     tools: ToolRunner(providers: [TimerTools(), MemoryTools(store: store, enabled: memory)]),
                                     config: config)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        return (pipeline, log)
    }

    /// A fact said in passing: the claim is neither said nor kept in the history; the rest is.
    @Test func aClaimWithNothingSavedIsLeftOut() async throws {
        let model = ScriptedModel(scripts: [
            [.text("Bravo, c'est une très bonne nouvelle pour toi. "), .text("Je note que tu as arrêté "),
             .text("de fumer.")],
            [.text("Avec plaisir, bonne soirée à toi.")],
        ])
        let (pipeline, log) = make(model)
        try await pipeline.start()
        await pipeline.submit(text: "J'ai arrêté de fumer il y a trois mois.")
        await waitFor { await log.finished.count == 1 }
        #expect(await log.pieces == ["Bravo, c'est une très bonne nouvelle pour toi."])
        #expect(await log.finished.first?.assistantText == "Bravo, c'est une très bonne nouvelle pour toi.")
        await pipeline.submit(text: "Merci beaucoup.")
        await waitFor { await model.requests.count == 2 }
        let history = try #require(await model.requests.last)
        #expect(history[history.count - 2].content == "Bravo, c'est une très bonne nouvelle pour toi.")
        await pipeline.stop()
    }

    /// What is left is too short for the voice to say it surely: the thanks go with it.
    @Test func aShortRestGetsTheThanks() async throws {
        let model = ScriptedModel(scripts: [[.text("C'est une bonne nouvelle. Je la note. (2026-10-15T18:42)")]])
        let (pipeline, log) = make(model)
        try await pipeline.start()
        await pipeline.submit(text: "Au fait, mon fils a eu son permis de conduire.")
        await waitFor { await log.finished.count == 1 }
        #expect(await log.pieces == ["C'est une bonne nouvelle. Merci de me le dire."])
        await pipeline.stop()
    }

    /// Nothing but the claim: the app takes what the user said, rather than silence.
    @Test func nothingLeftSaysTheAcknowledgement() async throws {
        let model = ScriptedModel(scripts: [[.text("C'est noté.")]])
        let (pipeline, log) = make(model)
        try await pipeline.start()
        await pipeline.submit(text: "Je fais du 38 en pantalon maintenant.")
        await waitFor { await log.finished.count == 1 }
        #expect(await log.pieces == [MemoryPhrases.acknowledged(.french)])
        #expect(await model.requests.count == 1)  // not asked once more: it did write something
        await pipeline.stop()
    }

    /// Once the turn saved something, the model may say so: nothing is left out.
    @Test func nothingIsLeftOutOnceSaved() async throws {
        let call = ToolCall(name: MemoryCatalog.name, arguments: ["action": "retenir", "texte": "préfère le thé vert"])
        let model = ScriptedModel(scripts: [[.toolCallStarted, .toolCall(call), .text("C'est bien noté pour ton thé.")]])
        let (pipeline, log) = make(model)
        try await pipeline.start()
        await pipeline.submit(text: "Retiens que je préfère le thé vert.")
        await waitFor { await log.finished.count == 1 }
        #expect(await log.pieces == [MemoryPhrases.remembered(.french), "C'est bien noté pour ton thé."])
        await pipeline.stop()
    }

    /// The memory not offered: the app leaves nothing out.
    @Test func withoutTheMemoryNothingIsLeftOut() async throws {
        let model = ScriptedModel(scripts: [[.text("C'est une bonne nouvelle. Je note que tu as arrêté de fumer.")]])
        let (pipeline, log) = make(model, memory: false)
        try await pipeline.start()
        await pipeline.submit(text: "J'ai arrêté de fumer il y a trois mois.")
        await waitFor { await log.finished.count == 1 }
        #expect(await log.pieces.joined(separator: " ") == "C'est une bonne nouvelle. Je note que tu as arrêté de fumer.")
        await pipeline.stop()
    }
}
