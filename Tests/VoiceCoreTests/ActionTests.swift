import Foundation
import Testing

@testable import VoiceCore

private let paris = TimeZone(identifier: "Europe/Paris")!
/// Thursday 15 October 2026, 18:42 in Paris.
private let now = LocalDateTime.parse("2026-10-15T18:42", in: paris)!.date
private let nb = "\u{00A0}"

private func context(_ language: SpeechLanguage = .french, at date: Date = now) -> ToolContext {
    ToolContext(now: date, timeZone: paris, language: language)
}

private func date(_ text: String) -> Date { LocalDateTime.parse(text, in: paris)!.date }

@Suite("Action dates and sentences")
struct ActionPhraseTests {
    @Test func readsLocalDates() throws {
        let full = try #require(LocalDateTime.parse("2026-10-16T10:00", in: paris))
        #expect(full.hasTime)
        #expect(LocalDateTime.format(full.date, in: paris) == "2026-10-16T10:00")
        #expect(LocalDateTime.parse("2026-10-16", in: paris)?.hasTime == false)
        #expect(LocalDateTime.parse("2026-10-16T10:00:00Z", in: paris)?.date == full.date)  // the suffix is ignored
        #expect(LocalDateTime.parse("2026-02-30T10:00", in: paris) == nil)
        #expect(LocalDateTime.parse("demain 10h", in: paris) == nil)
    }

    @Test func refusesDatesInThePastOrTooFar() {
        func check(_ value: String) throws {
            _ = try ActionCatalog.reminderDue(ToolCall(name: "creer_rappel", arguments: ["quand": .string(value)]),
                                              context: context())
        }
        #expect(throws: Never.self) { try check("2026-10-15T19:00") }
        #expect(throws: Never.self) { try check("2026-10-15") }  // today, no time
        #expect(throws: Never.self) { try check("ce soir à 20 h") }
        #expect(throws: ToolRefusal.self) { try check("2026-10-15T09:00") }
        #expect(throws: ToolRefusal.self) { try check("ce matin à 9 h") }
        #expect(throws: ToolRefusal.self) { try check("hier") }
        #expect(throws: ToolRefusal.self) { try check("2027-11-01T09:00") }
        #expect(throws: ToolRefusal.self) { try check("bientôt") }
        #expect(throws: ToolRefusal.self) {
            _ = try ActionCatalog.eventTimes(ToolCall(name: "creer_evenement", arguments: ["titre": "Yoga"]), context: context())
        }
    }

    /// The app works the date out from the user's words; what it cannot decide, it asks.
    @Test func refusalsSayWhatIsWrong() throws {
        func refusal(_ value: String) -> ToolRefusal? {
            do {
                _ = try ActionCatalog.reminderDue(ToolCall(name: "creer_rappel", arguments: ["quand": .string(value)]),
                                                  context: context())
                return nil
            } catch {
                return error as? ToolRefusal
            }
        }
        // An hour that may be the morning or the afternoon: asked to the user at once, not to the model.
        let hour = try #require(refusal("lundi à 3 h"))
        #expect(!hour.retryable)
        #expect(hour.spoken == "Tu veux dire 3\(nb)h du matin, ou 15\(nb)h\(nb)?")
        let weekday = try #require(refusal("dimanche 22 octobre"))
        #expect(weekday.retryable)
        #expect(weekday.spoken == "Le 22 octobre tombe un jeudi. Tu peux me redire la date\(nb)?")
        // Words it cannot read: the model may write the date itself on its second try.
        let words = try #require(refusal("tomorrow at 3 pm"))
        #expect(words.retryable && words.forModel.contains("AAAA-MM-JJTHH:MM"))
        #expect(try #require(refusal("hier à 15 h")).forModel.contains("mercredi 14 octobre"))
    }

    @Test func saysDatesInFull() {
        let c = context()
        #expect(ActionPhrases.moment(date("2026-10-16T10:00"), hasTime: true, c) == "vendredi 16 octobre à 10\(nb)h")
        #expect(ActionPhrases.moment(date("2026-11-01T10:30"), hasTime: true, c) == "dimanche 1er novembre à 10\(nb)h\(nb)30")
        #expect(ActionPhrases.time(date("2026-10-16T03:00"), c) == "3\(nb)h du matin")
        #expect(ActionPhrases.time(date("2026-10-16T12:00"), c) == "midi")
        #expect(ActionPhrases.day(date("2027-01-04T10:00"), c) == "lundi 4 janvier 2027")  // not this year
        #expect(ActionPhrases.moment(date("2026-10-16T15:00"), hasTime: true, context(.english))
                == "Friday, October 16 at 3\(nb)PM")
    }

    @Test func confirmsWhatWasSaved() {
        let c = context()
        #expect(ActionPhrases.eventCreated(title: "Rendez-vous chez le médecin", start: date("2026-10-16T15:00"),
                                           end: date("2026-10-16T16:00"), allDay: false, calendarName: nil, c)
                == "C’est dans ton agenda\(nb): Rendez-vous chez le médecin, vendredi 16 octobre de 15\(nb)h à 16\(nb)h.")
        #expect(ActionPhrases.reminderCreated(title: "prendre rendez-vous chez le médecin", due: date("2026-10-16T10:00"),
                                              hasTime: true, listName: nil, c)
                == "C’est noté\(nb): vendredi 16 octobre à 10\(nb)h, prendre rendez-vous chez le médecin.")
        #expect(ActionPhrases.eventCreated(title: "Vacances", start: date("2026-12-20"), end: date("2026-12-25"),
                                           allDay: true, calendarName: "Maison", c)
                == "C’est dans ton calendrier «\(nb)Maison\(nb)»\(nb): Vacances, du dimanche 20 décembre au jeudi 24 décembre.")
    }

    @Test func readsAtMostFourItems() {
        let c = context()
        let items = (8...13).map { ActionPhrases.Item(title: "Point \($0)", date: date("2026-10-16T\($0):00"), hasTime: true) }
        let text = ActionPhrases.agenda(items, from: date("2026-10-16"), to: date("2026-10-17"), c)
        #expect(text == "Demain, tu as six choses\(nb): Point 8 à 8\(nb)h, Point 9 à 9\(nb)h, Point 10 à 10\(nb)h, "
                + "Point 11 à 11\(nb)h et deux autres.")
        #expect(ActionPhrases.agenda([], from: date("2026-10-15"), to: date("2026-10-16"), c)
                == "Aujourd’hui, rien de prévu dans ton agenda.")
        #expect(ActionPhrases.reminders([ActionPhrases.Item(title: "Pain", date: nil, hasTime: false)], from: nil, to: nil, c)
                == "Tu as un seul rappel\(nb): Pain.")
        // Today: a reminder without a time is said by its title; one left over from yesterday is only counted,
        // or read with its day when nothing is due today.
        let today = [ActionPhrases.Item(title: "Facture", date: date("2026-10-14T10:00"), hasTime: true),
                     ActionPhrases.Item(title: "Pain", date: date("2026-10-15"), hasTime: false),
                     ActionPhrases.Item(title: "Linge", date: date("2026-10-15T20:00"), hasTime: true)]
        #expect(ActionPhrases.reminders(today, from: now, to: date("2026-10-16"), c)
                == "Tu as deux rappels pour aujourd’hui\(nb): Pain et Linge à 20\(nb)h, plus un en retard.")
        #expect(ActionPhrases.reminders(Array(today.prefix(1)), from: now, to: date("2026-10-16"), c)
                == "Rien de prévu pour aujourd’hui, mais un rappel en retard\(nb): Facture le mercredi 14 octobre à 10\(nb)h.")
    }

    /// The voice renders texts of fewer than five words as silence.
    @Test func everyFixedSentenceHasFiveWords() {
        for language in SpeechLanguage.allCases {
            let sentences = [
                ActionPhrases.oneMoment(language), ActionPhrases.declined(language), ActionPhrases.cannotUndo(language),
                ActionPhrases.cannotUndoShortcut(language), ActionPhrases.oneThingAtATime(language),
                ActionPhrases.badTime(language), ActionPhrases.datePassed(language), ActionPhrases.dateTooFar(language),
                ActionPhrases.badDuration(language), ActionPhrases.missingTitle(language),
                ActionPhrases.nothingToChange(language), ActionPhrases.notUnderstood(language),
                ActionPhrases.saveFailed(language), ActionPhrases.undone(.event, language),
                ActionPhrases.undone(.reminder, language), ActionPhrases.undone(.change, language),
                ActionPhrases.undone(.timer, language), ActionPhrases.askingAccess(.calendar, language),
                ActionPhrases.deleted(event: true, title: "Yoga", language),
                ActionPhrases.timerStarted(seconds: 60, label: nil, language),
                ActionPhrases.timerFinished(seconds: 60, label: nil, language),
                ActionPhrases.shortcutDone(name: "Salon", output: nil, language),
                ActionPhrases.confirmShortcut(name: "Salon", language),
                ActionPhrases.morningOrAfternoon(hour: 3, minute: 0, context(language)),
                ActionPhrases.wrongWeekday(date("2026-10-22"), context(language)),
                ActionPhrases.earlierOrLater(language),
            ]
            for sentence in sentences {
                #expect(ActionPhrases.wordCount(SpeakableText.forVoice(sentence, language: language)) >= 5, "\(sentence)")
            }
        }
    }

    @Test func voiceReadsTimesInWords() {
        #expect(SpeakableText.forVoice("jeudi à 10\(nb)h\(nb)30, puis 1\(nb)h et 21h", language: .french)
                == "jeudi à 10 heures 30, puis 1 heure et 21 heures")
        #expect(SpeakableText.forVoice("j’ai lancé «\(nb)Salon\(nb)».", language: .french) == "j'ai lancé Salon.")
        #expect(SpeakableText.forVoice("about 10\(nb)h", language: .english) == "about 10 h")
    }

    @Test func copiedDateLineIsNotSpoken() {
        #expect(SpeakableText.clean("Il est dix-huit heures. (2026-10-15T18:42)") == "Il est dix-huit heures.")
        #expect(SpeakableText.clean("Bonne idée [2026-10-15 18:42] !") == "Bonne idée !")
        // In words, as the smallest model writes it (a piece of its own, once the answer is cut into sentences).
        #expect(SpeakableText.clean("(jeudi 15 octobre 2026 à 18:42)").isEmpty)
        #expect(SpeakableText.clean("Je note ta réunion. (Jeudi 15 octobre 2026 à 18h42)") == "Je note ta réunion.")
        #expect(SpeakableText.clean("Tu dois acheter quoi ? (jeudi 15 octobre 2026 à 18\(nb)h\(nb)42)") == "Tu dois acheter quoi ?")
        #expect(SpeakableText.clean("Bonsoir ! (Nous sommes le jeudi 15 octobre 2026, il est 18:42.)") == "Bonsoir !")
        // What is meant to be said stays.
        #expect(SpeakableText.clean("Nous sommes le jeudi 15 octobre 2026.") == "Nous sommes le jeudi 15 octobre 2026.")
        #expect(SpeakableText.clean("Le concert (le 8 novembre à 21 h) est noté.") == "Le concert (le 8 novembre à 21 h) est noté.")
    }

    @Test func durations() {
        #expect(ActionPhrases.duration(seconds: 600, .french) == "10 minutes")
        #expect(ActionPhrases.duration(seconds: 4500, .french) == "1 heure et 15 minutes")
        #expect(ActionPhrases.duration(seconds: 90, .english) == "1 minute and 30 seconds")
    }
}

@Suite("Action calls")
struct ActionCallTests {
    @Test func eventLastsAnHourByDefault() throws {
        func times(_ arguments: [String: JSONValue]) throws -> (start: Date, end: Date, allDay: Bool) {
            var all: [String: JSONValue] = ["titre": "Yoga"]
            all.merge(arguments) { $1 }
            return try ActionCatalog.eventTimes(ToolCall(name: "creer_evenement", arguments: all), context: context())
        }
        let plain = try times(["quand": "vendredi à 18 h"])
        #expect(plain.start == date("2026-10-16T18:00") && plain.end == date("2026-10-16T19:00") && !plain.allDay)
        #expect(try times(["quand": "vendredi à 18 h", "duree": "une heure et demie"]).end == date("2026-10-16T19:30"))
        #expect(try times(["quand": "vendredi à 18 h pendant une heure et demie"]).end == date("2026-10-16T19:30"))
        #expect(try times(["quand": "demain de 10 h à midi"]).end == date("2026-10-16T12:00"))
        let day = try times(["quand": "le 3 novembre"])
        #expect(day.allDay && day.start == date("2026-11-03") && day.end == date("2026-11-04"))
        let holidays = try times(["quand": "du 20 au 24 décembre"])
        #expect(holidays.allDay && holidays.start == date("2026-12-20") && holidays.end == date("2026-12-25"))
        // Written the model's own way: dates and minutes.
        #expect(try times(["debut": "2026-10-16T18:00", "duree_minutes": "90"]).end == date("2026-10-16T19:30"))
        #expect(try times(["debut": "2026-11-03"]).allDay)
        #expect(throws: ToolRefusal.self) { try times(["quand": "vendredi à 18 h", "duree": "90"]) }  // no unit
    }

    @Test func timersAndReadingsUseTheUsersWords() throws {
        func seconds(_ arguments: [String: JSONValue]) throws -> Int {
            try ActionCatalog.timerSeconds(ToolCall(name: "minuteur", arguments: arguments), context: context())
        }
        #expect(try seconds(["duree": "une heure et quart"]) == 4500)
        #expect(try seconds(["duree": "45 secondes"]) == 45)
        #expect(try seconds(["duree_secondes": 600]) == 600)
        #expect(throws: ToolRefusal.self) { try seconds(["duree": "10"]) }
        #expect(throws: ToolRefusal.self) { try seconds(["duree": "deux jours"]) }  // more than a day
        let week = try #require(try ActionCatalog.period(ToolCall(name: "lire_agenda", arguments: ["quand": "cette semaine"]),
                                                         context: context(), required: true))
        #expect(week.0 == date("2026-10-15") && week.1 == date("2026-10-19"))
        #expect(try ActionCatalog.period(ToolCall(name: "lister_rappels"), context: context(), required: false) == nil)
        let old = try #require(try ActionCatalog.period(
            ToolCall(name: "lire_agenda", arguments: ["debut": "2026-10-16T00:00", "fin": "2026-10-16T23:59"]),
            context: context(), required: true))
        #expect(old.0 == date("2026-10-16") && old.1 == date("2026-10-17"))
        #expect(throws: ToolRefusal.self) {
            try ActionCatalog.period(ToolCall(name: "lire_agenda", arguments: ["quand": "l'année prochaine"]),
                                     context: context(), required: true)
        }
    }

    /// When the model changed the user's words, the app reads the moment from what the user said.
    @Test func theUsersWordsWinOverTheModels() throws {
        func due(_ quand: String, said: [String]) throws -> Date? {
            try ActionCatalog.reminderDue(ToolCall(name: "creer_rappel", arguments: ["titre": "x", "quand": .string(quand)]),
                                          context: ToolContext(now: now, timeZone: paris, language: .french, userSaid: said))?.date
        }
        // A day taken from the date line ("jeudi": next Thursday for the app), a weekday instead of "demain" that lost
        // "du matin", a date the model worked out.
        #expect(try due("jeudi à 23 h", said: ["Rappelle-moi à 23 h de fermer la fenêtre"]) == date("2026-10-15T23:00"))
        #expect(try due("vendredi à 7 h", said: ["Rappelle-moi demain à 7 h du matin d'aller courir"]) == date("2026-10-16T07:00"))
        #expect(try due("2026-10-15T15:00", said: ["Rappelle-moi demain à 15 h d'appeler Léo"]) == date("2026-10-16T15:00"))
        // Copied without what settled the hour: the user's sentence settles it; when it cannot, the user is asked.
        #expect(try due("demain à 7 h 30", said: ["Rappelle-moi demain matin à 7 h 30 de prendre mes médicaments"])
                == date("2026-10-16T07:30"))
        #expect(throws: ToolRefusal.self) { try due("lundi à 3 h", said: ["Rappelle-moi lundi à 3 h d'appeler Paul"]) }
        // The answer to the app's question completes the words the model copied from the request.
        #expect(try due("demain à 6 h", said: ["Du matin", "Rappelle-moi demain à 6 h de partir à l'aéroport"])
                == date("2026-10-16T06:00"))
        #expect(try due("vendredi à 6 h", said: ["Du matin", "Rappelle-moi demain à 6 h de partir à l'aéroport"])
                == date("2026-10-16T06:00"))
        // The model's words are the user's, said in an earlier turn: kept.
        #expect(try due("lundi à 3 h de l'après-midi", said: ["De l'après-midi", "Rappelle-moi lundi à 3 h d'appeler Paul"])
                == date("2026-10-19T15:00"))
        // Left out by the model: the user's. Not for a change, where no moment means it does not move.
        let withoutWhen = ToolCall(name: "creer_rappel", arguments: ["titre": "x"])
        #expect(try ActionCatalog.reminderDue(withoutWhen, context: ToolContext(
            now: now, timeZone: paris, language: .french, userSaid: ["Rappelle-moi demain à 9 h d'appeler Léo"]))?.date
                == date("2026-10-16T09:00"))
        #expect(try ActionCatalog.reminderDue(withoutWhen, context: ToolContext(
            now: now, timeZone: paris, language: .french, userSaid: ["Rappelle-moi d'acheter du pain"])) == nil)
        #expect(try ActionCatalog.changedDue(ToolCall(name: "modifier_element", arguments: ["titre": "Réunion de 15 h"]),
                                             due: (date("2026-10-16T10:00"), true), context: ToolContext(
            now: now, timeZone: paris, language: .french, userSaid: ["Change le titre en réunion de 15 h"])) == nil)
        // Two moments in the user's sentence: the model's choice stays.
        #expect(try due("demain", said: ["Rappelle-moi demain d'appeler le resto pour samedi"]) == date("2026-10-16"))
        let timer = ToolCall(name: "minuteur", arguments: ["duree": "1 h 30"])
        #expect(try ActionCatalog.timerSeconds(timer, context: ToolContext(
            now: now, timeZone: paris, language: .french, userSaid: ["Minuteur d'une heure et quart s'il te plaît"])) == 4500)
        let reading = try #require(try ActionCatalog.period(
            ToolCall(name: "lire_agenda", arguments: ["quand": "vendredi 16 octobre"]),
            context: ToolContext(now: now, timeZone: paris, language: .french, userSaid: ["Qu'est-ce que j'ai demain ?"]),
            required: true))
        #expect(reading.0 == date("2026-10-16") && reading.1 == date("2026-10-17"))
    }

    /// "Décale-le à 16 h" keeps the day of the item, "samedi à la même heure" its time, its length goes along.
    @Test func changesStartFromTheItem() throws {
        func change(_ arguments: [String: JSONValue]) throws -> (start: Date, end: Date, allDay: Bool)? {
            var all: [String: JSONValue] = ["reference": "e1"]
            all.merge(arguments) { $1 }
            return try ActionCatalog.changedEvent(ToolCall(name: "modifier_element", arguments: all),
                                                  start: date("2026-10-16T15:00"), end: date("2026-10-16T16:30"),
                                                  allDay: false, context: context())
        }
        let later = try #require(try change(["quand": "à 16 h"]))
        #expect(later.start == date("2026-10-16T16:00") && later.end == date("2026-10-16T17:30"))
        #expect(try change(["quand": "samedi à la même heure"])?.start == date("2026-10-17T15:00"))
        #expect(try change(["duree": "2 heures"])?.end == date("2026-10-16T17:00"))
        #expect(try change(["titre": "Dentiste"]) == nil)
        let due = try ActionCatalog.changedDue(ToolCall(name: "modifier_element", arguments: ["quand": "plutôt à 11 h"]),
                                               due: (date("2026-10-16T10:00"), true), context: context())
        #expect(due?.date == date("2026-10-16T11:00"))
    }

    @Test func emptyTitleOrUnknownShortcutIsRefused() {
        #expect(throws: ToolRefusal.self) {
            try ActionCatalog.check(ToolCall(name: "creer_rappel", arguments: ["titre": " "]), context: context())
        }
        #expect(throws: ToolRefusal.self) {
            try ActionCatalog.check(ToolCall(name: "lancer_raccourci", arguments: ["nom": "Inconnu"]), context: context(),
                                    shortcuts: ["Salon"])
        }
        #expect(throws: Never.self) {
            try ActionCatalog.check(ToolCall(name: "minuteur", arguments: ["duree": "10 minutes"]), context: context())
        }
    }

    @Test func recognizesShortAnswers() {
        #expect(ReplyMatcher.confirmation("Oui, vas-y !") == .yes)
        #expect(ReplyMatcher.confirmation("Euh… d’accord.") == .yes)
        #expect(ReplyMatcher.confirmation("Non merci.") == .no)
        #expect(ReplyMatcher.confirmation("Laisse tomber") == .no)
        #expect(ReplyMatcher.confirmation("Oui mais d’abord dis-moi l’heure") == nil)
        #expect(ReplyMatcher.isCancel("Annule !"))
        #expect(ReplyMatcher.isCancel("Annule ça, s’il te plaît"))
        #expect(ReplyMatcher.isCancel("À nul."))  // how speech recognition heard it in a real test
        #expect(!ReplyMatcher.isCancel("Annule mon rendez-vous de lundi"))  // not in the list: the model handles it
        #expect(!ReplyMatcher.isCancel("Rappelle-moi ce que tu disais"))
    }

    @Test func olderSettingsStayReadable() throws {
        let old = #"{"audioMode":"headphones","pushToTalk":true}"#
        let settings = try JSONDecoder().decode(AssistantSettings.self, from: Data(old.utf8))
        #expect(settings.audioMode == .headphones && settings.listening == .pushToTalk)
        #expect(!settings.actionsEnabled && settings.shortcutsToConfirm.isEmpty && !settings.wakeLog)
        let handsFree = #"{"audioMode":"speakers","pushToTalk":false}"#
        #expect(try JSONDecoder().decode(AssistantSettings.self, from: Data(handsFree.utf8)).listening == .handsFree)
    }

    @Test func historyDropsAnExchangeWithItsToolCall() {
        var c = Conversation(systemPrompt: "S")
        let call = ToolCall(name: "creer_rappel", arguments: ["titre": "Pain"])
        c.record(user: ChatMessage(.user, "Rappelle-moi le pain"), steps: [.call(call), .result(of: call, ["id": "r1"])],
                 assistant: "C’est noté.", interrupted: false)
        c.record(user: "Merci", language: .french, assistant: "Avec plaisir.", interrupted: false)
        #expect(c.messages.count == 7)
        c.dropOldestExchange()
        #expect(c.messages.map(\.content) == ["S", "Merci", "Avec plaisir."])
    }

    @Test func dateLineNamesTheDay() {
        #expect(ActionCatalog.dateLine(now, timeZone: paris) == "(Nous sommes le jeudi 15 octobre 2026, il est 18:42.)")
    }

    @Test func promptShowsAnExampleCallWhenTheModelCanWriteOne() {
        let rules = ActionCatalog.promptAddendum(exampleCall: nil)
        #expect(!rules.contains("Exemple"))
        #expect(rules.contains("pas même la première phrase courte"))  // the main prompt's opening sentence
        let withExample = ActionCatalog.promptAddendum(exampleCall: "<call>")
        #expect(withExample.hasPrefix(rules))
        #expect(withExample.hasSuffix("« Mets un minuteur de 5 minutes pour le thé », ta réponse entière est <call>"))
    }

    @Test func examplesAreExchangesTheAppCouldHaveHad() {
        let examples = ActionCatalog.examples(now: now, timeZone: paris)
        let exchange: [ChatMessage.Role] = [.user, .assistant, .tool, .assistant]
        #expect(examples.map(\.role) == exchange + exchange + exchange)
        #expect(examples.filter { $0.role == .user }.map(\.content)
                == [ActionCatalog.example.request, "Rappelle-moi d'acheter du lait",
                    "Ajoute un rendez-vous chez le kiné mardi à 18 h 15"])  // no date line
        // Each call comes at once, with the user's words.
        #expect(examples[1].content.isEmpty && examples[1].toolCalls == [ActionCatalog.example.call])
        #expect(examples[9].toolCalls.first?.arguments == ["titre": "Rendez-vous chez le kiné", "quand": "mardi à 18 h 15"])
        // The result and the sentence the app would have given (the coming Tuesday), with ids it never gives.
        #expect(examples[10].toolResult == ["id": "e0", "titre": "Rendez-vous chez le kiné", "debut": "2026-10-20T18:15",
                                            "fin": "2026-10-20T19:15", "calendrier": "Maison"])
        #expect(examples.compactMap { $0.toolResult?.objectID } == ["t0", "r0", "e0"])
        #expect(examples.filter { $0.role == .assistant && $0.toolCalls.isEmpty }.map(\.content)
                == ["C’est parti pour 5 minutes\(nb): le thé. Je te préviens à la fin.",
                    "C’est noté dans tes rappels\(nb): acheter du lait.",
                    "C’est dans ton agenda\(nb): Rendez-vous chez le kiné, mardi 20 octobre de 18\(nb)h\(nb)15 à 19\(nb)h\(nb)15."])
        #expect(ActionCatalog.showsExamples(on: .minimum) && !ActionCatalog.showsExamples(on: .comfort))
    }

    @Test func examplesStayWhenTheHistoryIsShortenedOrCleared() {
        var c = Conversation(systemPrompt: "S")
        c.examples = [ChatMessage(.user, "Exemple"), ChatMessage(.assistant, "Réponse.")]
        c.record(user: "Bonjour", language: .french, assistant: "Salut.", interrupted: false)
        c.record(user: "Merci", language: .french, assistant: "Avec plaisir.", interrupted: false)
        #expect(c.messages.map(\.content) == ["S", "Exemple", "Réponse.", "Bonjour", "Salut.", "Merci", "Avec plaisir."])
        #expect(c.exchanges.count == 4)  // the examples are not the user's exchanges
        c.dropOldestExchange()
        #expect(c.messages(adding: ChatMessage(.user, "Et toi ?")).map(\.content)
                == ["S", "Exemple", "Réponse.", "Merci", "Avec plaisir.", "Et toi ?"])
        c.dropOldestExchanges(5)
        #expect(c.messages.map(\.content) == ["S", "Exemple", "Réponse."])
        c.record(user: "Bonjour", language: .french, assistant: "Salut.", interrupted: false)
        c.clear()
        #expect(c.messages.map(\.content) == ["S", "Exemple", "Réponse."])
    }
}

private extension JSONValue {
    /// The "id" of an object.
    var objectID: String? {
        guard case .object(let fields) = self else { return nil }
        return fields["id"]?.text
    }
}

// MARK: - Runner and pipeline

/// Records what it is asked to do. "noter" is undoable, "lancer" needs a yes.
actor RecordingTools: ToolProvider {
    nonisolated let identifier = "test"
    private(set) var performed: [ToolCall] = []
    /// `ToolContext.userSaid` of each call performed.
    private(set) var said: [[String]] = []
    private(set) var undone: [String] = []

    func tools() -> [ToolSpec] {
        [ToolSpec(name: "noter", description: "Note.", parameters: [ToolParameter("titre", .string, "Quoi.", required: true)],
                  risk: .undoable),
         ToolSpec(name: "lancer", description: "Lance.", parameters: [], risk: .sensitive)]
    }

    func check(_ call: ToolCall, context: ToolContext) throws {
        if call.name == "noter", call.text("titre") == nil {
            throw ToolRefusal(forModel: "Il manque « titre ».", spoken: ActionPhrases.missingTitle(context.language))
        }
    }

    func summary(of call: ToolCall, context: ToolContext) -> String { "Je lance le test. On y va ?" }

    func perform(_ call: ToolCall, context: ToolContext) throws -> ToolOutcome {
        performed.append(call)
        said.append(context.userSaid)
        return ToolOutcome(spoken: "C’est noté\(nb): \(call.text("titre") ?? "le test est lancé").",
                           forModel: ["id": .string("n\(performed.count)")],
                           undo: UndoToken(provider: identifier, id: "n\(performed.count)"))
    }

    func undo(_ token: UndoToken, context: ToolContext) -> String {
        undone.append(token.id)
        return ActionPhrases.undone(.reminder, context.language)
    }
}

@Suite("Tool runner")
struct ToolRunnerTests {
    @Test func sensitiveActionWaitsForYes() async {
        let tools = RecordingTools()
        let runner = ToolRunner(providers: [tools])
        _ = await runner.tools()
        let asked = await runner.handle(ToolCall(name: "lancer"), context: context())
        #expect(asked.spoken.hasSuffix("On y va ?"))
        #expect(await tools.performed.isEmpty)
        #expect(await runner.interception(for: "Quelle heure est-il ?", now: now) == nil)  // still waiting
        #expect(await runner.interception(for: "oui", now: now) == .confirm)
        _ = await runner.resolve(.confirm, context: context())
        #expect(await tools.performed.count == 1)
        #expect(await runner.interception(for: "oui", now: now) == nil)  // nothing waits any more
    }

    @Test func noOrTimeDropsTheAction() async {
        let tools = RecordingTools()
        let runner = ToolRunner(providers: [tools])
        _ = await runner.tools()
        _ = await runner.handle(ToolCall(name: "lancer"), context: context())
        let reply = await runner.resolve(.decline, context: context())
        #expect(reply?.spoken == ActionPhrases.declined(.french))
        _ = await runner.handle(ToolCall(name: "lancer"), context: context())
        #expect(await runner.interception(for: "oui", now: now.addingTimeInterval(121)) == nil)  // expired
        #expect(await tools.performed.isEmpty)
    }

    @Test func cancelUndoesTheLastActionForTwoMinutes() async {
        let tools = RecordingTools()
        let runner = ToolRunner(providers: [tools])
        _ = await runner.tools()
        _ = await runner.handle(ToolCall(name: "noter", arguments: ["titre": "Pain"]), context: context())
        #expect(await runner.interception(for: "annule", now: now.addingTimeInterval(130)) == nil)
        #expect(await runner.interception(for: "Annule !", now: now.addingTimeInterval(60)) == .undo)
        let reply = await runner.resolve(.undo, context: context(at: now.addingTimeInterval(60)))
        #expect(reply?.spoken == ActionPhrases.undone(.reminder, .french))
        #expect(await tools.undone == ["n1"])
        #expect(await runner.interception(for: "annule", now: now.addingTimeInterval(61)) == nil)
    }

    @Test func refusedCallCanBeCorrected() async {
        let runner = ToolRunner(providers: [RecordingTools()])
        _ = await runner.tools()
        let reply = await runner.handle(ToolCall(name: "noter"), context: context())
        #expect(reply.retryable)
        #expect(reply.spoken == ActionPhrases.missingTitle(.french))
    }

    @Test func misspelledToolNameIsTheTools() async {
        let tools = RecordingTools()
        let runner = ToolRunner(providers: [tools])
        _ = await runner.tools()
        #expect(await runner.named(ToolCall(name: "Notre", arguments: ["titre": "Pain"])).name == "noter")
        _ = await runner.handle(ToolCall(name: "noteer", arguments: ["titre": "Pain"]), context: context())
        #expect(await tools.performed.map(\.name) == ["noter"])
        // Too far from any tool: refused, and the model is told the real names for its second try.
        let unknown = await runner.handle(ToolCall(name: "effacer", arguments: ["titre": "Pain"]), context: context())
        #expect(unknown.retryable)
        #expect(unknown.forModel == ["erreur": "Outil inconnu : effacer. Les outils existants sont : noter, lancer."])
        #expect(await tools.performed.count == 1)
    }
}

@Suite("Tool names")
struct ToolNameTests {
    let names = ActionCatalog.names(shortcuts: ["Salon"])

    @Test func slipsOfOneOrTwoLettersAreRead() {
        let slips = [
            "crer_rappel": "creer_rappel", "cerer_rappel": "creer_rappel", "créer_rappel": "creer_rappel",
            "Creer-Rappel": "creer_rappel", "creer rappel": "creer_rappel", "creer_rappels": "creer_rappel",
            "lister_rappel": "lister_rappels", "liste_rappels": "lister_rappels", "creer_événements": "creer_evenement",
            "lire_agendas": "lire_agenda", "modifer_element": "modifier_element", "suprimer_element": "supprimer_element",
            "minuteurs": "minuteur", "lancer_racourci": "lancer_raccourci",
        ]
        for (written, meant) in slips {
            #expect(ToolNames.match(written, among: names) == meant, "\(written)")
        }
    }

    /// Another word is not a slip: the model gets the real names and chooses again.
    @Test func otherWordsAreNotRead() {
        for written in ["lire_rappels", "cocher_rappel", "modifier_rappel", "supprimer_rappel", "lire_calendrier",
                        "rappel", "creer", ""] {
            #expect(ToolNames.match(written, among: names) == nil, "\(written)")
        }
        // A short name allows fewer slips.
        #expect(ToolNames.match("notr", among: ["noter"]) == "noter")
        #expect(ToolNames.match("note", among: ["notez"]) == "notez")
        #expect(ToolNames.match("not", among: ["noter"]) == nil)
        #expect(ToolNames.match("ab", among: ["abc"]) == nil)
    }

    @Test func aSlipNearTwoToolsIsNotRead() {
        let close = ["lire_agenda", "lire_agendas"]
        #expect(ToolNames.match("lire_agend", among: close) == nil)
        #expect(ToolNames.match("lire_agenda", among: close) == "lire_agenda")  // the exact name always wins
    }

    /// So that a slip of two letters can only stand for one of them.
    @Test func builtInToolsAreFarApart() {
        for (i, a) in names.enumerated() {
            for b in names[(i + 1)...] {
                #expect(ToolNames.distance(ToolNames.folded(a), ToolNames.folded(b)) >= 5, "\(a), \(b)")
            }
        }
    }

    @Test func unknownToolIsRefusedWithTheRealNames() throws {
        do {
            try ActionCatalog.check(ToolCall(name: "lire_rappels", arguments: ["quand": "demain"]), context: context())
            Issue.record("lire_rappels was accepted")
        } catch let refusal as ToolRefusal {
            #expect(refusal.retryable)
            #expect(refusal.forModel == "Outil inconnu : lire_rappels. Les outils existants sont : creer_rappel, "
                    + "lister_rappels, creer_evenement, lire_agenda, modifier_element, supprimer_element, minuteur.")
        }
    }
}

/// Returns the given sentences, one per turn.
actor ScriptedTranscriber: Transcriber {
    private var sentences: [String]
    init(_ sentences: [String]) { self.sentences = sentences }
    func transcribe(_ samples: [Float]) async throws -> String {
        sentences.count > 1 ? sentences.removeFirst() : sentences[0]
    }
}

@Suite("Pipeline with actions", .serialized)
struct PipelineActionTests {
    let speech = [Float](repeating: 0.5, count: 512)
    let silence = [Float](repeating: 0, count: 512)

    func push(_ pipeline: VoicePipeline, _ pattern: String) async {
        for c in pattern { await pipeline.push(c == "1" ? speech : silence) }
    }

    func waitFor(_ condition: () async -> Bool) async {
        for _ in 0..<400 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func make(_ model: ScriptedModel, _ transcriber: any Transcriber, _ speaker: FakeSpeaker, _ tools: RecordingTools,
              filler: Bool = false) -> VoicePipeline
    {
        var config = PipelineConfig()
        config.toolCallFiller = filler
        return VoicePipeline(detector: LoudnessDetector(), transcriber: transcriber, model: model,
                             synthesizer: FakeSynthesizer(), output: speaker, tools: ToolRunner(providers: [tools]),
                             config: config)
    }

    static let note: [ModelOutput] = [.toolCallStarted, .toolCall(ToolCall(name: "noter", arguments: ["titre": "Pain"]))]

    @Test func actionWaitsForTheEndOfTheTurn() async throws {
        let (model, speaker, tools) = (ScriptedModel(scripts: [Self.note]), FakeSpeaker(), RecordingTools())
        let pipeline = make(model, ScriptedTranscriber(["Rappelle-moi le pain"]), speaker, tools)
        try await pipeline.start()
        #expect(await model.tools.map(\.name) == ["noter", "lancer"])
        // A pause: the answer is prepared speculatively, the call is written… and must wait.
        await push(pipeline, "1111111111" + "00000000")
        try await Task.sleep(for: .milliseconds(150))
        #expect(await tools.performed.isEmpty)
        await push(pipeline, "11111")  // the user goes on: the speculative turn and its call are dropped
        try await Task.sleep(for: .milliseconds(50))
        #expect(await tools.performed.isEmpty)
        await push(pipeline, String(repeating: "0", count: 20))  // the turn is over
        await waitFor { await speaker.played > 0 }
        #expect(await tools.performed.count == 1)
        let request = try #require(await model.requests.last)
        #expect(request.count == 2)  // no example exchanges unless the config asks for them
        #expect(request.last?.content.contains("\n(Nous sommes le ") == true)  // the date line ends the message
        // The actions' part of the system prompt, with its example call written the model's way.
        #expect(request.first?.content.hasSuffix(ActionCatalog.promptAddendum(exampleCall: "[minuteur]")) == true)
    }

    @Test func oneActionPerTurnAndHistoryKeepsTheCall() async throws {
        let two = Self.note + [.toolCall(ToolCall(name: "noter", arguments: ["titre": "Lait"]))]
        let (model, speaker, tools) = (ScriptedModel(scripts: [two, [.text("Avec plaisir, à ton service.")]]),
                                       FakeSpeaker(), RecordingTools())
        let pipeline = make(model, ScriptedTranscriber(["Rappelle-moi le pain et le lait", "Merci beaucoup"]), speaker, tools)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.pieces.joined().contains("redis-moi") }
        #expect(await tools.performed.map { $0.text("titre") } == ["Pain"])
        #expect(await log.pieces.joined(separator: " ") == "C’est noté\(nb): Pain. " + ActionPhrases.oneThingAtATime(.french))
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await model.requests.count == 2 }
        let history = try #require(await model.requests.last)
        #expect(history.map(\.role) == [.system, .user, .assistant, .tool, .assistant, .user])
        #expect(history[2].toolCalls.first?.name == "noter")
        #expect(history[3].toolResult == ["id": "n1"])
    }

    @Test func examplesOpenTheConversationButAreNotTheUsers() async throws {
        let (model, speaker, tools) = (ScriptedModel(scripts: [[.text("Bonjour, je suis bien là.")], Self.note]),
                                       FakeSpeaker(), RecordingTools())
        var config = PipelineConfig()
        config.toolCallFiller = false
        config.actionExamples = true
        let pipeline = VoicePipeline(detector: LoudnessDetector(),
                                     transcriber: ScriptedTranscriber(["Bonjour", "Rappelle-moi le pain"]), model: model,
                                     synthesizer: FakeSynthesizer(), output: speaker, tools: ToolRunner(providers: [tools]),
                                     config: config)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.pieces.joined().contains("bien là") }
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await tools.performed.count == 1 }
        // Right after the system prompt, then the user's own exchanges.
        let request = try #require(await model.requests.last)
        let examples = ActionCatalog.examples(now: Date())
        #expect(request[1...examples.count].map(\.role) == examples.map(\.role))
        #expect(request[1].content == ActionCatalog.example.request)
        #expect(request[examples.count + 1].content.hasPrefix("Bonjour\n(Nous sommes le "))
        // The app reads the moment in the user's words: never in the examples'.
        #expect(await tools.said == [["Rappelle-moi le pain", "Bonjour"]])
        await waitFor { await log.pieces.joined().contains("Pain") }
        #expect(await log.pieces.joined(separator: " ") == "Bonjour, je suis bien là. C’est noté\(nb): Pain.")
    }

    @Test func misspelledToolNameIsCarriedOutAndNotSeenAgain() async throws {
        let slip: [ModelOutput] = [.toolCall(ToolCall(name: "noteer", arguments: ["titre": "Pain"]))]
        let (model, speaker, tools) = (ScriptedModel(scripts: [slip, [.text("Avec plaisir, à ton service.")]]),
                                       FakeSpeaker(), RecordingTools())
        let pipeline = make(model, ScriptedTranscriber(["Rappelle-moi le pain", "Merci beaucoup"]), speaker, tools)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.pieces.joined().contains("Pain") }
        #expect(await tools.performed.map(\.name) == ["noter"])
        #expect(await model.requests.count == 1)  // no second try needed
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await model.requests.count == 2 }
        let history = try #require(await model.requests.last)
        // The history holds the tool's real name: the model does not copy its slip in the next turns.
        #expect(history[2].toolCalls.first?.name == "noter")
        #expect(history[3].content == "noter")
    }

    @Test func fillerCoversTheTimeTheCallIsWritten() async throws {
        let (model, speaker, tools) = (ScriptedModel(scripts: [Self.note, [.text("Avec plaisir, à ton service.")]]),
                                       FakeSpeaker(), RecordingTools())
        let pipeline = make(model, ScriptedTranscriber(["Rappelle-moi le pain", "Merci"]), speaker, tools, filler: true)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.pieces.joined().contains("Pain") }
        #expect(await log.pieces.joined(separator: " ") == ActionPhrases.oneMoment(.french) + " C’est noté\(nb): Pain.")
        // The model never sees the filler as its own words (it would start saying it everywhere).
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await model.requests.count == 2 }
        let history = try #require(await model.requests.last)
        #expect(history.filter { $0.role == .assistant }.map(\.content) == ["", "C’est noté\(nb): Pain."])
    }

    @Test func refusedCallGetsOneMoreTryThenAQuestion() async throws {
        let bad: [ModelOutput] = [.toolCall(ToolCall(name: "noter"))]
        let (model, speaker, tools) = (ScriptedModel(scripts: [bad, bad]), FakeSpeaker(), RecordingTools())
        let pipeline = make(model, ScriptedTranscriber(["Note"]), speaker, tools)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { !(await log.pieces.isEmpty) }
        #expect(await model.requests.count == 2)
        let second = try #require(await model.requests.last)
        #expect(second.suffix(2).map(\.role) == [.assistant, .tool])  // the model sees why it was refused
        #expect(await log.pieces.joined(separator: " ") == ActionPhrases.missingTitle(.french))
        #expect(await tools.performed.isEmpty)
    }

    @Test func cancelIsHandledWithoutTheModel() async throws {
        let (model, speaker, tools) = (ScriptedModel(scripts: [Self.note]), FakeSpeaker(), RecordingTools())
        let pipeline = make(model, ScriptedTranscriber(["Rappelle-moi le pain", "Annule."]), speaker, tools)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await tools.performed.count == 1 }
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await tools.undone.count == 1 }
        #expect(await tools.undone == ["n1"])
        #expect(await model.requests.count == 1)  // "annule" never reached the model
    }

    @Test func timerAnnouncementWaitsForSilence() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(), model: model,
                                     synthesizer: FakeSynthesizer(), output: speaker)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "11111111")  // the user is speaking
        await pipeline.announce("Ton minuteur de 10 minutes est terminé.", note: "(Le minuteur a sonné.)",
                                language: .french)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await log.pieces.isEmpty)
        await push(pipeline, String(repeating: "0", count: 20))  // their turn ends, Maé answers…
        await waitFor { await log.pieces.contains("Ton minuteur de 10 minutes est terminé.") }  // …then the timer
        #expect(await log.pieces.last == "Ton minuteur de 10 minutes est terminé.")
    }
}
