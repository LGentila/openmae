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
    /// model copied such a mark into its own answers); a note of its own follows it, so that the model reads it before
    /// the user's next message, which stays their words (with the language hint). Dropping the exchange drops its note.
    @Test func englishHintStaysInHistoryAndANoteFollowsAnAnswerCutOff() {
        var c = Conversation(systemPrompt: "S")
        c.record(user: "Hello there my friend", language: .english, assistant: "Hi", interrupted: true)
        #expect(c.messages.map(\.content)
            == ["S", "Hello there my friend" + Conversation.englishHint, "Hi", Conversation.cutOffNote])
        #expect(c.messages.last == Conversation.cutOffMessage)
        #expect(Conversation.cutOffMessage.role == .system)
        let next = c.messages(addingUser: "Sorry, go on", language: .english)
        #expect(next.suffix(2)
            == [Conversation.cutOffMessage, ChatMessage(.user, "Sorry, go on" + Conversation.englishHint)])
        c.record(user: "Sorry, go on", language: .english, assistant: "Sure.", interrupted: false)
        #expect(c.messages == next + [ChatMessage(.assistant, "Sure.")])  // the history holds what the request read
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

    /// With the actions on, the message after a cut is the user's words then the date line: its first line is their words
    /// alone (`ToolContext.userSaid`); an announcement's note is its own too. The last exchange cut off, then dropped:
    /// nothing of it is left. A new conversation forgets the note.
    @Test func theMessageAfterACutIsTheUsersWordsAlone() {
        let dateLine = "(Nous sommes le jeudi 15 octobre 2026, il est 18:42.)"
        var c = Conversation(systemPrompt: "S")
        c.record(user: "Raconte-moi une histoire.", language: .french, assistant: "Il était une fois", interrupted: true)
        let message = c.nextUserMessage("Attends, attends.", language: .french, dateLine: dateLine)
        #expect(message == Conversation.userMessage("Attends, attends.", language: .french, dateLine: dateLine))
        #expect(message.content == "Attends, attends.\n" + dateLine)
        #expect(c.messages(adding: message).map(\.role) == [.system, .user, .assistant, .system, .user])
        #expect(c.nextNoteMessage("(Le minuteur a sonné.)") == ChatMessage(.user, "(Le minuteur a sonné.)"))
        var dropped = c
        let droppedIt = dropped.dropOldestExchange()
        #expect(droppedIt)
        #expect(dropped.messages.map(\.content) == ["S"])
        c.clear()
        #expect(c.messages(addingUser: "Bonjour", language: .french).map(\.content) == ["S", "Bonjour"])
    }

    /// The tier says where the note of an answer cut off goes: read ahead on Gemma 4 26B (comfort and max), after the
    /// user's words on E4B and E2B (standard and minimum). Unset, it goes where the tested tier puts it.
    @Test func theTierSaysWhereTheNoteOfACutGoes() {
        #expect(Conversation.cutOffPlacement(on: .comfort) == .ahead)
        #expect(Conversation.cutOffPlacement(on: .max) == .ahead)
        #expect(Conversation.cutOffPlacement(on: .standard) == .afterUserWords)
        #expect(Conversation.cutOffPlacement(on: .minimum) == .afterUserWords)
        #expect(Conversation().cutOffPlacement == Conversation.cutOffPlacement(on: .comfort))
        #expect(PipelineConfig().cutOffPlacement == Conversation.cutOffPlacement(on: .comfort))
    }

    /// After the user's words (E4B, E2B): nothing follows the answer cut off; the next message says it, after the user's
    /// words, before the language hint, and stays in the history with it. The message after an answer heard to its end
    /// says nothing of the kind. Dropping the exchange cut off takes the note out of the next message.
    @Test func afterTheUsersWordsTheNextMessageSaysSo() {
        var c = Conversation(systemPrompt: "S")
        c.cutOffPlacement = .afterUserWords
        c.record(user: "Hello there my friend", language: .english, assistant: "Hi", interrupted: true)
        #expect(c.messages.map(\.content) == ["S", "Hello there my friend" + Conversation.englishHint, "Hi"])
        let next = c.messages(addingUser: "Sorry, go on", language: .english).last
        #expect(next == ChatMessage(.user, "Sorry, go on\n" + Conversation.cutOffNote + Conversation.englishHint))
        c.record(user: "Sorry, go on", language: .english, assistant: "Sure.", interrupted: false)
        #expect(c.messages.last(where: { $0.role == .user }) == next)  // kept as the model read it
        #expect(c.messages(addingUser: "Thanks", language: .english).last?.content == "Thanks" + Conversation.englishHint)
        // The answer cut off dropped, the note about it goes too.
        let dropped = c.dropOldestExchange()
        #expect(dropped)
        #expect(c.messages.map(\.content) == ["S", "Sorry, go on" + Conversation.englishHint, "Sure."])
    }

    /// After the user's words, with the actions on: the note comes before the date line, which still ends the message, and
    /// their words stay its first line (`ToolContext.userSaid`); an announcement's note says it too. The last exchange
    /// dropped, or a new conversation, forgets it.
    @Test func afterTheUsersWordsTheNoteComesBeforeTheDateLine() {
        let dateLine = "(Nous sommes le jeudi 15 octobre 2026, il est 18:42.)"
        var c = Conversation(systemPrompt: "S")
        c.cutOffPlacement = .afterUserWords
        c.record(user: "Raconte-moi une histoire.", language: .french, assistant: "Il était une fois", interrupted: true)
        let message = c.nextUserMessage("Attends, attends.", language: .french, dateLine: dateLine)
        #expect(message.content == "Attends, attends.\n" + Conversation.cutOffNote + "\n" + dateLine)
        #expect(message.content.components(separatedBy: "\n").first == "Attends, attends.")  // the user's words alone
        #expect(c.messages(adding: message).map(\.role) == [.system, .user, .assistant, .user])
        #expect(c.nextNoteMessage("(Le minuteur a sonné.)").content == "(Le minuteur a sonné.)\n" + Conversation.cutOffNote)
        var dropped = c
        let droppedIt = dropped.dropOldestExchange()
        #expect(droppedIt)
        #expect(dropped.nextUserMessage("Bonjour", language: .french).content == "Bonjour")
        c.clear()
        #expect(c.nextUserMessage("Bonjour", language: .french).content == "Bonjour")
        #expect(c.nextNoteMessage("(Le minuteur a sonné.)").content == "(Le minuteur a sonné.)")
    }

    /// What happened meanwhile that the user learnt elsewhere (a task that ended, told by a notification) goes with the
    /// next message of the user's role: after their words (still its first line) and the note of an answer cut off, before
    /// the date line; an announcement's note carries it too. It is told once, with the message recorded: one made before
    /// it came (a turn already under way) is recorded without it, and it waits for the next. A new conversation forgets
    /// what was not told yet.
    @Test func whatHappenedMeanwhileGoesWithTheNextMessage() {
        let dateLine = "(Nous sommes le jeudi 15 octobre 2026, il est 18:42.)"
        let ended = "(Entre-temps, la tâche d1 « poème » confiée à Claude Code s'est terminée ; "
            + "l'utilisateur l'a appris par une notification.)"
        var c = Conversation(systemPrompt: "S")
        c.cutOffPlacement = .afterUserWords
        c.record(user: "Raconte-moi une histoire.", language: .french, assistant: "Il était une fois", interrupted: true)
        let early = c.nextUserMessage("Attends.", language: .french, dateLine: dateLine)  // before the task ended
        c.noteForNextMessage(ended)
        let message = c.nextUserMessage("Attends.", language: .french, dateLine: dateLine)
        #expect(message.content == "Attends.\n" + Conversation.cutOffNote + "\n" + ended + "\n" + dateLine)
        #expect(c.nextNoteMessage("(Le minuteur a sonné.)").content
            == "(Le minuteur a sonné.)\n" + Conversation.cutOffNote + "\n" + ended)
        #expect(c.nextUserMessage("Hello", language: .english).content == "Hello\n" + Conversation.cutOffNote + "\n"
            + ended + Conversation.englishHint)
        // Recorded without it: it waits for the next message.
        c.record(user: early, steps: [], assistant: "Oui ?", interrupted: false)
        let next = c.nextUserMessage("Rien.", language: .french)
        #expect(next.content == "Rien.\n" + ended)
        // Recorded with it: kept in the history as the model read it, and told once.
        c.record(user: next, steps: [], assistant: "D'accord.", interrupted: false)
        #expect(c.messages.suffix(2) == [next, ChatMessage(.assistant, "D'accord.")])
        #expect(c.nextUserMessage("Merci.", language: .french).content == "Merci.")
        c.noteForNextMessage(ended)
        c.clear()
        #expect(c.nextUserMessage("Bonjour", language: .french).content == "Bonjour")
        #expect(c.nextNoteMessage("(Le minuteur a sonné.)").content == "(Le minuteur a sonné.)")
    }

    /// An answer cut by a drop goes into the history as the pipeline gives it (as the model wrote it), then a note of its
    /// own says the link dropped, and how far the user heard it, not that the user cut it off
    /// (`Conversation.dropMessage`); the user's next message stays their words. An answer the user cuts off still gets
    /// its own note. Dropping the exchange drops its note.
    @Test func aNoteSaysTheDropCutTheAnswer() {
        let heard = "Il était une fois une fille."
        var c = Conversation(systemPrompt: "S")
        c.record(user: ChatMessage(.user, "Raconte-moi une histoire."), steps: [],
                 assistant: heard + "\n\nUn loup passait.", ending: .dropped(lastHeard: heard))
        let note = "(La liaison avec l'appareil a coupé : l'utilisateur n'a entendu ta réponse que jusqu'à « \(heard) ».)"
        #expect(Conversation.dropNote(lastHeard: heard) == note)
        #expect(c.messages.map(\.content)
            == ["S", "Raconte-moi une histoire.", heard + "\n\nUn loup passait.", note])
        #expect(c.messages.last == Conversation.dropMessage(lastHeard: heard))
        #expect(c.messages.last?.role == .system)
        #expect(c.nextUserMessage("Et alors ?", language: .french) == ChatMessage(.user, "Et alors ?"))
        c.record(user: "Et alors ?", language: .french, assistant: "Je reprends", interrupted: true)
        #expect(c.messages.suffix(3).map(\.content) == ["Et alors ?", "Je reprends", Conversation.cutOffNote])
        c.record(user: "Merci.", language: .french, assistant: "Avec plaisir.", interrupted: false)
        #expect(c.messages.last == ChatMessage(.assistant, "Avec plaisir."))
        let dropped = c.dropOldestExchange()
        #expect(dropped)
        #expect(c.messages.map(\.content)
            == ["S", "Et alors ?", "Je reprends", Conversation.cutOffNote, "Merci.", "Avec plaisir."])
    }

    /// The note of a drop quotes the last piece heard on one line; when the device heard none of the answer, it says so.
    @Test func theNoteOfADropSaysHowFarTheUserHeard() {
        #expect(Conversation.dropNote(lastHeard: "  Au départ,\n\nla tour ") == "(La liaison avec l'appareil a coupé : "
            + "l'utilisateur n'a entendu ta réponse que jusqu'à « Au départ, la tour ».)")
        #expect(Conversation.dropNote(lastHeard: nil)
            == "(La liaison avec l'appareil a coupé : l'utilisateur n'a pas entendu ta réponse.)")
        #expect(Conversation.dropNote(lastHeard: " ") == Conversation.dropNote(lastHeard: nil))
        #expect(!Conversation.dropNote(lastHeard: "Bonjour.").contains(Conversation.cutOffNote))
    }

    /// After the user's words (E4B, E2B): the note of a drop comes in the user's next message, after their words and
    /// before the date line, or after an announcement's note; the next answer cut off by the user gets its own note.
    /// Dropping the exchange cut by the drop takes its note out of the next message; a new conversation forgets it.
    @Test func afterTheUsersWordsTheNextMessageSaysTheDropCutTheAnswer() {
        let dateLine = "(Nous sommes le jeudi 15 octobre 2026, il est 18:42.)"
        let note = Conversation.dropNote(lastHeard: "Il était une fois.")
        var c = Conversation(systemPrompt: "S")
        c.cutOffPlacement = .afterUserWords
        c.record(user: ChatMessage(.user, "Raconte-moi une histoire."), steps: [],
                 assistant: "Il était une fois. Un loup passait.", ending: .dropped(lastHeard: "Il était une fois."))
        #expect(c.messages.map(\.content) == ["S", "Raconte-moi une histoire.", "Il était une fois. Un loup passait."])
        let message = c.nextUserMessage("Et alors ?", language: .french, dateLine: dateLine)
        #expect(message.content == "Et alors ?\n" + note + "\n" + dateLine)
        #expect(message.content.components(separatedBy: "\n").first == "Et alors ?")  // the user's words alone
        #expect(c.nextNoteMessage("(Le minuteur a sonné.)").content == "(Le minuteur a sonné.)\n" + note)
        var forgotten = c
        forgotten.clear()
        #expect(forgotten.nextUserMessage("Bonjour", language: .french).content == "Bonjour")
        c.record(user: message, steps: [], assistant: "Je reprends", ending: .cutOff)
        #expect(c.nextUserMessage("Pardon.", language: .french).content == "Pardon.\n" + Conversation.cutOffNote)
        let dropped = c.dropOldestExchange()
        #expect(dropped)
        #expect(c.messages.map(\.content) == ["S", "Et alors ?\n" + dateLine, "Je reprends"])
        #expect(c.nextUserMessage("Pardon.", language: .french).content == "Pardon.\n" + Conversation.cutOffNote)
        // The note last in a message (no date line): taken out too.
        var last = Conversation(systemPrompt: "S")
        last.cutOffPlacement = .afterUserWords
        last.record(user: ChatMessage(.user, "Raconte."), steps: [], assistant: "Un. Deux.",
                    ending: .dropped(lastHeard: "Un."))
        last.record(user: last.nextUserMessage("Et alors ?", language: .french), steps: [], assistant: "Trois.",
                    ending: .whole)
        let droppedLast = last.dropOldestExchange()
        #expect(droppedLast)
        #expect(last.messages.map(\.content) == ["S", "Et alors ?", "Trois."])
    }
}
