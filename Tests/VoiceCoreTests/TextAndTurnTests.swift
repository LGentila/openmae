import Testing

@testable import VoiceCore

@Suite("End of turn")
struct TurnDetectorTests {
    /// 1 = speech chunk, 0 = silence chunk (32 ms each).
    func events(_ pattern: String, config: TurnDetectorConfig = .init()) -> [TurnEvent] {
        var detector = TurnDetector(config: config)
        return pattern.compactMap { detector.process(probability: $0 == "1" ? 0.9 : 0.0) }
    }

    @Test func shortNoiseIsIgnored() {
        #expect(events("1110000000000000000000") == [])  // 96 ms < 160 ms
    }

    @Test func speechThenSilenceEndsTheTurn() {
        // 5 speech chunks (160 ms), then 16 silent chunks (512 ms ≥ 500 ms).
        #expect(events("11111" + String(repeating: "0", count: 16)) == [.speechStarted, .pause, .endOfTurn])
    }

    @Test func resumingAfterAPauseCancelsTheSpeculation() {
        let pattern = "11111" + "0000000" + "111" + String(repeating: "0", count: 16)
        #expect(events(pattern) == [.speechStarted, .pause, .resumed, .pause, .endOfTurn])
    }

    @Test func overTheAssistantSpeechMustLastTheBargeInDuration() {
        var detector = TurnDetector()
        for _ in 0..<8 { #expect(detector.process(probability: 0.9, bargeInMinSpeechMs: 288) == nil) }  // 256 ms
        #expect(detector.process(probability: 0.9, bargeInMinSpeechMs: 288) == .speechStarted)
    }

    @Test func inBetweenProbabilitiesDoNotCountAsSilence() {
        var detector = TurnDetector()
        for _ in 0..<5 { _ = detector.process(probability: 0.9) }
        for _ in 0..<40 { #expect(detector.process(probability: 0.4) == nil) }
        #expect(detector.isInUtterance)
    }
}

@Suite("Text for the voice")
struct TextForSpeechTests {
    @Test func gemmaThoughtBlockIsRemovedEvenWhenSplit() {
        var filter = ReasoningFilter()
        let pieces = ["Bon", "jour <|chan", "nel>thought\nje réfléchis", " encore<chan", "nel|> à toi !"]
        let out = pieces.map { filter.push($0) }.joined() + filter.flush()
        #expect(out == "Bonjour  à toi !")
    }

    @Test func qwenThinkBlockAndStrayTagsAreRemoved() {
        var filter = ReasoningFilter()
        let out = filter.push("<think>hmm</think>Salut<|im_end|> !") + filter.flush()
        #expect(out == "Salut !")
    }

    @Test func ordinaryLessThanSignIsKept() {
        var filter = ReasoningFilter()
        let out = filter.push("3 < 5 et 2 <") + filter.flush()
        #expect(out == "3 < 5 et 2 <")
    }

    @Test func firstPieceMayEndAtACommaThenSentencesOnly() {
        var chunker = SentenceChunker()
        var pieces = chunker.push("Bien sûr, pour ce soir tu peux faire des pâtes, ")
        pieces += chunker.push("c'est rapide. Et ensuite, un dessert !")
        pieces += chunker.flush()
        // "c'est rapide." is too short to be spoken alone: it goes with the next sentence.
        #expect(pieces == ["Bien sûr, pour ce soir tu peux faire des pâtes,", "c'est rapide. Et ensuite, un dessert !"])
    }

    @Test func shortOpeningSentenceIsSpokenWithTheNextOne() {
        var chunker = SentenceChunker()
        var pieces = chunker.push("Salut toi. La lumière du soleil contient toutes les couleurs. ")
        pieces += chunker.push("Voilà pourquoi le ciel est bleu.")
        pieces += chunker.flush()
        #expect(pieces == ["Salut toi. La lumière du soleil contient toutes les couleurs.",
                           "Voilà pourquoi le ciel est bleu."])
    }

    @Test func veryShortFirstClauseIsNotCut() {
        var chunker = SentenceChunker()
        let pieces = chunker.push("Oui, ")
        #expect(pieces.isEmpty)
    }

    @Test func markdownEmojisAndLinksAreNotSpoken() {
        #expect(SpeakableText.clean("**Super** idée 😄 ! Voir https://exemple.fr") == "Super idée ! Voir")
        #expect(SpeakableText.clean("- des pâtes\n- du riz") == "des pâtes du riz")
    }

    /// The mark of a cut (an ellipsis in brackets), alone or in runs, is neither said nor shown nor kept: as the model
    /// wrote it after answers cut off, dozens in a row. An ellipsis of its own stays; several in a row are one.
    @Test func cutOffMarksAreNotSpoken() {
        #expect(SpeakableText.clean("Pour assurer la survie. […]") == "Pour assurer la survie.")
        #expect(SpeakableText.clean("Toute la ruche travaille. […] […] […] [...] (…) ( ... ) [..]")
            == "Toute la ruche travaille.")
        #expect(SpeakableText.clean(String(repeating: "[…] ", count: 54)) == "")
        #expect(SpeakableText.clean("[…][…][…]") == "")
        #expect(SpeakableText.clean("Il était une fois […] un roi.") == "Il était une fois un roi.")
        #expect(SpeakableText.clean("Euh… je ne sais pas.") == "Euh… je ne sais pas.")
        #expect(SpeakableText.clean("Je ne sais pas… … …") == "Je ne sais pas…")
        #expect(SpeakableText.clean("Attends... ... ...") == "Attends…")
        #expect(SpeakableText.forVoice(SpeakableText.clean("Bien sûr. [...] Voici la suite."), language: .french)
            == "Bien sûr. Voici la suite.")
        // Out of the history too, with the paragraphs the model wrote.
        #expect(SpeakableText.clean("C'est la fin. […]\n\nLa suite.", keepingLineBreaks: true) == "C'est la fin.\n\nLa suite.")
        var answer = ""
        SpeakableText.record("Je suis attentif. Que veux-tu me dire ?", in: &answer)
        SpeakableText.record("[…] […] […] […] […] […] […]", after: " ", in: &answer)
        #expect(answer == "Je suis attentif. Que veux-tu me dire ?")
    }

    /// The history keeps the answer as the model wrote it, paragraphs included (its memory of the answer then still
    /// matches the next request), while the voice and the interface get the same pieces as before.
    @Test func historyKeepsTheWhiteSpaceTheModelWrote() {
        let written = "C'est une très belle idée.\n\nIl était une fois un vieil horloger nommé Elias. Il vivait seul.\n"
            + "Un jour, un enfant frappa à sa porte."
        var chunker = SentenceChunker()
        var pieces = chunker.pieces(adding: String(written.prefix(60)))
        pieces += chunker.pieces(adding: String(written.dropFirst(60)))
        pieces += chunker.remainingPieces()
        #expect(pieces == [
            .init("C'est une très belle idée."),
            .init("Il était une fois un vieil horloger nommé Elias.", after: "\n\n"),
            .init("Il vivait seul.\nUn jour, un enfant frappa à sa porte.", after: " "),
        ])
        var answer = ""
        for piece in pieces { SpeakableText.record(piece.text, after: piece.separator, in: &answer) }
        #expect(answer == written)
        #expect(SpeakableText.clean(pieces[2].text) == "Il vivait seul. Un jour, un enfant frappa à sa porte.")
        // What the voice never says stays out of the history too; the app's own sentences follow after a space.
        #expect(SpeakableText.clean("**Super** idée  😄 !\n\nVoir", keepingLineBreaks: true) == "Super idée !\n\nVoir")
        SpeakableText.record("C'est noté.", in: &answer)
        #expect(answer.hasSuffix("porte. C'est noté."))
    }
}

@Suite("Language")
struct LanguageGuesserTests {
    @Test func detectsEnglishAndFrench() {
        #expect(LanguageGuesser.guess("Hey, can you tell me a fun fact about octopuses?") == .english)
        #expect(LanguageGuesser.guess("Tu peux me donner une idée de recette pour ce soir ?") == .french)
    }

    @Test func shortPhrasesKeepThePreviousLanguage() {
        #expect(LanguageGuesser.guess("OK", previous: .english) == .english)
        #expect(LanguageGuesser.guess("Merci", previous: .french) == .french)
    }
}

@Suite("Tiers and conversation")
struct TierAndConversationTests {
    @Test func tiersFollowMemory() {
        func tier(_ gb: Double, _ chip: String = "Apple M1") -> HardwareTier {
            HardwareTier.recommended(for: HardwareProfile(memoryGiB: gb, chipName: chip))
        }
        #expect(tier(8) == .minimum)
        #expect(tier(16) == .standard)
        #expect(tier(24) == .standard)
        #expect(tier(32, "Apple M1 Pro") == .comfort)
        #expect(tier(36) == .comfort)
        #expect(tier(64) == .max)
        #expect(tier(32, "Intel(R) Core(TM) i9") == .unsupported)
        #expect(HardwareTier.comfort.isTested && !HardwareTier.standard.isTested)
    }

    /// An answer cut off goes into the history as it went to the voice, without any mark of the cut in its words (the
    /// model copied such a mark into its own answers); the next message says it, after the user's words, before the
    /// date line and the language hint, and stays in the history with it.
    @Test func englishHintStaysInHistoryAndTheMessageAfterACutSaysSo() {
        var c = Conversation(systemPrompt: "S")
        c.record(user: "Hello there my friend", language: .english, assistant: "Hi", interrupted: true)
        #expect(c.messages.map(\.content) == ["S", "Hello there my friend" + Conversation.englishHint, "Hi"])
        #expect(c.endsCutOff)
        let next = c.messages(addingUser: "Sorry, go on", language: .english).last?.content
        #expect(next == "Sorry, go on\n" + Conversation.cutOffNote + Conversation.englishHint)
        c.record(user: "Sorry, go on", language: .english, assistant: "Sure.", interrupted: false)
        #expect(c.messages.last(where: { $0.role == .user })?.content == next)
        #expect(!c.endsCutOff)
        #expect(c.messages(addingUser: "Thanks", language: .english).last?.content == "Thanks" + Conversation.englishHint)
        // The answer cut off dropped, the note about it goes too.
        let dropped = c.dropOldestExchange()
        #expect(dropped)
        #expect(c.messages.map(\.content) == ["S", "Sorry, go on" + Conversation.englishHint, "Sure."])
        let droppedNext = c.dropOldestExchange()
        #expect(droppedNext)
        #expect(c.messages.count == 1)
        let droppedAgain = c.dropOldestExchange()
        #expect(!droppedAgain)
    }

    /// With the actions on, the date line still ends the message after a cut; an announcement's note says it too; a new
    /// conversation forgets it.
    @Test func theNoteOfACutComesBeforeTheDateLine() {
        let dateLine = "(Nous sommes le jeudi 15 octobre 2026, il est 18:42.)"
        let message = Conversation.userMessage("Attends, attends.", language: .french, dateLine: dateLine, afterCutOff: true)
        #expect(message.content == "Attends, attends.\n" + Conversation.cutOffNote + "\n" + dateLine)
        #expect(message.content.components(separatedBy: "\n").first == "Attends, attends.")  // the user's words alone
        #expect(Conversation.noteMessage("(Le minuteur a sonné.)", afterCutOff: true).content
            == "(Le minuteur a sonné.)\n" + Conversation.cutOffNote)
        #expect(Conversation.noteMessage("(Le minuteur a sonné.)").content == "(Le minuteur a sonné.)")
        var c = Conversation(systemPrompt: "S")
        c.record(user: "Raconte-moi une histoire.", language: .french, assistant: "Il était une fois", interrupted: true)
        c.clear()
        #expect(!c.endsCutOff)
        #expect(c.messages(addingUser: "Bonjour", language: .french).last?.content == "Bonjour")
    }
}
