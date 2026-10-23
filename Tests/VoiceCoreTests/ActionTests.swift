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

/// What the app's check refuses of a call (`ActionCatalog.check`); nil when it accepts it.
private func checkRefusal(_ call: ToolCall) -> ToolRefusal? {
    do {
        try ActionCatalog.check(call, context: context())
        return nil
    } catch {
        return error as? ToolRefusal
    }
}

/// For `RefusedCreation.creation(insteadOf:said:names:exists:)`: no item created in the conversation.
private func nothingCreated(_ reference: String) -> Bool { false }

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
        // Their answers only complete the refused words (« de l'après-midi », « le 25 »): no change stands for the
        // call (`RefusedCreation`).
        #expect(!hour.detailGivenAgain && !weekday.detailGivenAgain)
        // Words it cannot read: the model may write the date itself on its second try.
        let words = try #require(refusal("tomorrow at 3 pm"))
        #expect(words.retryable && words.forModel.contains("AAAA-MM-JJTHH:MM") && words.detailGivenAgain)
        // A moment already gone: asked to the user at once too, since only they can give another one; the model is told
        // to write the creation again once they do.
        let past = try #require(refusal("hier à 15 h"))
        #expect(past.forModel.contains("mercredi 14 octobre") && !past.retryable && past.detailGivenAgain)
        #expect(past.forModel.hasSuffix("appelle de nouveau creer_rappel avec ses mots (pas modifier_element : rien n'existe "
                                        + "encore)."))
        #expect(past.spoken == "Cette date est déjà passée. Tu peux me redire quand\(nb)?")
    }

    /// A creation refused for its moment, then a change of the "last" item, which was never created ("Demain à 16h.",
    /// as Gemma 4 26B writes it): the creation again, at the change's moment; only for the call right after it.
    @Test func changeRightAfterARefusedCreationCreatesIt() throws {
        let creation = ToolCall(name: "creer_evenement", arguments: ["titre": "Dentiste", "quand": "hier à 15 h"])
        let refusal = try #require(checkRefusal(creation))
        var refused = RefusedCreation()
        refused.checking(creation)
        refused.refused(creation, refusal)
        let change = ToolCall(name: "modifier_element", arguments: ["reference": "dernier", "debut": "demain à 16 h"])
        refused.checking(change)
        let made = refused.creation(insteadOf: change, exists: nothingCreated)
        let again = try #require(made)
        // The change's moment, under the creation's own word.
        #expect(again == ToolCall(name: "creer_evenement", arguments: ["titre": "Dentiste", "quand": "demain à 16 h"]))
        #expect(try ActionCatalog.eventTimes(again, context: context()).start == date("2026-10-16T16:00"))
        let twice = refused.creation(insteadOf: change, exists: nothingCreated)
        #expect(twice == nil)  // once
        // Another call in between, or a refusal for another reason: nothing kept.
        refused.refused(creation, refusal)
        refused.checking(ToolCall(name: "minuteur", arguments: ["duree": "5 minutes"]))
        refused.checking(change)
        let afterAnother = refused.creation(insteadOf: change, exists: nothingCreated)
        #expect(afterAnother == nil)
        refused.refused(creation, refusal)
        refused.refused(creation, ToolRefusal(forModel: "Il manque « titre ».", spoken: ""))
        let afterOther = refused.creation(insteadOf: change, exists: nothingCreated)
        #expect(afterOther == nil)
    }

    /// A calendar or a list that does not exist, words about time the app cannot place or none at all: the user's
    /// answer gives that detail again, and a change of the "last" item right after the refusal (as Gemma 4 26B writes
    /// it for « Mets-la dans Maison alors. » or « Demain à 18 h. ») is the refused creation with what the change gives.
    @Test func changeRightAfterACalendarOrTimeWordsRefusalCreatesIt() throws {
        func made(_ creation: ToolCall, _ refusal: ToolRefusal, then arguments: [String: JSONValue]) -> ToolCall? {
            var refused = RefusedCreation()
            refused.checking(creation)
            refused.refused(creation, refusal)
            let change = ToolCall(name: "modifier_element", arguments: arguments)
            refused.checking(change)
            return refused.creation(insteadOf: change, exists: nothingCreated)
        }
        // A calendar that does not exist, refused when the call is carried out (`CalendarTools`): the change's.
        var unknown = ToolRefusal(forModel: "Aucun calendrier modifiable ne s'appelle « Travail ». Calendriers : "
                                      + "Maison.",
                                  spoken: ActionPhrases.unknownCalendar("Travail", .french))
        unknown.detailGivenAgain = true
        let meeting = ToolCall(name: "creer_evenement",
                               arguments: ["titre": "Réunion", "quand": "demain à 10 h", "calendrier": "Travail"])
        let inHome = made(meeting, unknown, then: ["reference": "dernier", "calendrier": "Maison"])
        #expect(inHome == ToolCall(name: "creer_evenement",
                                   arguments: ["titre": "Réunion", "quand": "demain à 10 h", "calendrier": "Maison"]))
        // A reminder's list, whichever of the two words the change uses; an empty title leaves the reminder's.
        let bread = ToolCall(name: "creer_rappel", arguments: ["titre": "Pain", "liste": "Courses"])
        let inReminders = made(bread, unknown, then: ["reference": "dernier", "calendrier": "Rappels", "titre": ""])
        #expect(inReminders == ToolCall(name: "creer_rappel", arguments: ["titre": "Pain", "liste": "Rappels"]))
        // Words about time it cannot place: the change's moment.
        let hairdresser = ToolCall(name: "creer_evenement",
                                   arguments: ["titre": "Coiffeur", "quand": "après le travail"])
        let words = try #require(checkRefusal(hairdresser))
        let atSix = try #require(made(hairdresser, words, then: ["reference": "dernier", "quand": "demain à 18 h"]))
        #expect(atSix == ToolCall(name: "creer_evenement", arguments: ["titre": "Coiffeur", "quand": "demain à 18 h"]))
        #expect(try ActionCatalog.eventTimes(atSix, context: context()).start == date("2026-10-16T18:00"))
        // None at all: the change's.
        let noMoment = ToolCall(name: "creer_evenement", arguments: ["titre": "Coiffeur"])
        let missing = try #require(checkRefusal(noMoment))
        #expect(made(noMoment, missing, then: ["reference": "dernier", "quand": "demain à 18 h"]) == atSix)
        // Under `quand`, whichever word the change uses: a reminder does not read `debut`.
        let paul = ToolCall(name: "creer_rappel", arguments: ["titre": "Appeler Paul", "quand": "après le travail"])
        let paulRefused = try #require(checkRefusal(paul))
        let due = try #require(made(paul, paulRefused, then: ["reference": "dernier", "debut": "demain à 14 h"]))
        #expect(due == ToolCall(name: "creer_rappel", arguments: ["titre": "Appeler Paul", "quand": "demain à 14 h"]))
        #expect(try ActionCatalog.reminderDue(due, context: context())?.date == date("2026-10-16T14:00"))
        // Another moment replaces the refused one with its end; the length stays.
        let past = ToolCall(name: "creer_evenement", arguments: ["titre": "Dentiste", "debut": "2026-10-14T15:00",
                                                                  "fin": "2026-10-14T16:00", "duree": "2 heures"])
        let gone = try #require(checkRefusal(past))
        #expect(made(past, gone, then: ["reference": "dernier", "quand": "demain à 16 h"])
                == ToolCall(name: "creer_evenement", arguments: ["titre": "Dentiste", "quand": "demain à 16 h",
                                                                 "duree": "2 heures"]))

        // A change refused by the check (no reference) leaves the creation for its second try.
        var refused = RefusedCreation()
        refused.checking(meeting)
        refused.refused(meeting, unknown)
        let noReference = ToolCall(name: "modifier_element", arguments: ["calendrier": "Maison"])
        let withoutReference = try #require(checkRefusal(noReference))
        refused.checking(noReference)
        refused.refused(noReference, withoutReference)
        let corrected = ToolCall(name: "modifier_element", arguments: ["reference": "dernier", "calendrier": "Maison"])
        refused.checking(corrected)
        let secondTry = refused.creation(insteadOf: corrected, exists: nothingCreated)
        #expect(secondTry == inHome)
        // The creation a change was made into, refused in turn (another calendar that does not exist), is kept as it
        // was made: the next change starts from it.
        refused.checking(meeting)
        refused.refused(meeting, unknown)
        let toOffice = ToolCall(name: "modifier_element", arguments: ["reference": "dernier", "calendrier": "Bureau",
                                                                      "quand": "demain à 11 h"])
        refused.checking(toOffice)
        let madeForOffice = refused.creation(insteadOf: toOffice, exists: nothingCreated)
        let office = try #require(madeForOffice)
        refused.refused(office, unknown)
        refused.refused(toOffice, unknown)  // the change, refused with it
        let toHome = ToolCall(name: "modifier_element", arguments: ["reference": "dernier", "calendrier": "Maison"])
        refused.checking(toHome)
        let madeForHome = refused.creation(insteadOf: toHome, exists: nothingCreated)
        let atEleven: [String: JSONValue] = ["titre": "Réunion", "quand": "demain à 11 h", "calendrier": "Maison"]
        #expect(madeForHome == ToolCall(name: "creer_evenement", arguments: atEleven))

        // Not kept when the answer only completes the refused words (an hour that may be the morning, a weekday that
        // does not match the date), nor for a missing title.
        let kine = ToolCall(name: "creer_evenement",
                            arguments: ["titre": "Kiné", "quand": "dimanche 22 octobre à 10 h"])
        for creation in [ToolCall(name: "creer_rappel", arguments: ["titre": "Appeler Paul", "quand": "lundi à 3 h"]),
                         kine, ToolCall(name: "creer_rappel", arguments: ["quand": "demain à 9 h"])] {
            let refusal = try #require(checkRefusal(creation))
            #expect(made(creation, refusal, then: ["reference": "dernier", "quand": "demain à 15 h"]) == nil,
                    "\(creation.arguments)")
        }
    }

    /// « Rappelle-moi d'acheter du pain. », then a meeting refused for a calendar that does not exist: to « Mets-la dans
    /// Maison alors. », Gemma 4 26B takes the meeting for saved and writes a change of the last item. The last item is
    /// then the refused meeting, not the reminder created before it: the meeting, in that calendar. A change that names
    /// the reminder by its id is the reminder's; an id that names no item, the meeting's.
    @Test func lastItemRightAfterARefusedCreationIsThatCreation() throws {
        var unknown = ToolRefusal(forModel: "Aucun calendrier modifiable ne s'appelle « Travail ». Calendriers : "
                                      + "Maison.",
                                  spoken: ActionPhrases.unknownCalendar("Travail", .french))
        unknown.detailGivenAgain = true
        let meeting = ToolCall(name: "creer_evenement",
                               arguments: ["titre": "Réunion", "quand": "demain à 10 h", "calendrier": "Travail"])
        func made(then arguments: [String: JSONValue]) -> ToolCall? {
            var refused = RefusedCreation()
            refused.checking(meeting)
            refused.refused(meeting, unknown)
            let change = ToolCall(name: "modifier_element", arguments: arguments)
            refused.checking(change)
            return refused.creation(insteadOf: change, exists: { $0 == "r1" })  // the bread, created before
        }
        let inHome = ToolCall(name: "creer_evenement",
                              arguments: ["titre": "Réunion", "quand": "demain à 10 h", "calendrier": "Maison"])
        for last in ["dernier", "Dernière", "last"] {
            #expect(made(then: ["reference": .string(last), "calendrier": "Maison"]) == inHome, "\(last)")
        }
        #expect(made(then: ["reference": "e1", "calendrier": "Maison"]) == inHome)
        #expect(made(then: ["reference": "r1", "quand": "à 11 h"]) == nil)
    }

    /// A meeting refused for « Travail », a calendar that does not exist, then « Mets-la dans Maison alors. » and a
    /// change of the last item that leaves the calendar out (as Gemma 4 E4B wrote it): the meeting, in the calendar the
    /// answer names among the writable ones, not in « Travail » again. A calendar the change gives still counts; an
    /// answer that names none, or the request read again by a second try in the same turn, keeps the refused one.
    /// After a refusal for the moment (« Demain à 18 h. »), the calendar the user named first stays.
    @Test func aChangeThatLeavesTheCalendarOutTakesTheOneTheAnswerNames() throws {
        let request = "Ajoute une réunion demain à 10 h dans mon calendrier Travail."
        let meeting = ToolCall(name: "creer_evenement",
                               arguments: ["titre": "réunion", "quand": "vendredi à 10 h", "calendrier": "Travail"])
        let unknown = ActionCatalog.unknownCollection("Travail", event: true, names: ["Maison", "Perso"],
                                                      context: context())
        func made(_ creation: ToolCall, _ refusal: ToolRefusal, then arguments: [String: JSONValue], said: [String],
                  refusedAfter: [String] = [request]) -> ToolCall? {
            var refused = RefusedCreation()
            refused.checking(creation)
            refused.refused(creation, refusal, said: refusedAfter)
            let change = ToolCall(name: "modifier_element", arguments: arguments)
            refused.checking(change)
            return refused.creation(insteadOf: change, said: said, names: { $0 ? ["Maison", "Perso"] : ["Rappels"] },
                                    exists: nothingCreated)
        }
        let titleOnly: [String: JSONValue] = ["reference": "dernier", "titre": "réunion"]
        func inCalendar(_ calendar: String) -> ToolCall {
            ToolCall(name: "creer_evenement",
                     arguments: ["titre": "réunion", "quand": "vendredi à 10 h", "calendrier": .string(calendar)])
        }
        #expect(made(meeting, unknown, then: titleOnly, said: ["Mets-la dans Maison alors.", request])
                == inCalendar("Maison"))
        for answer in ["Maison.", "Dans le calendrier maison.", "C'est le calendrier Perso.", "Pas Travail, Perso."] {
            let calendar = answer.contains("erso") ? "Perso" : "Maison"
            #expect(made(meeting, unknown, then: titleOnly, said: [answer, request]) == inCalendar(calendar), "\(answer)")
        }
        // The change's own calendar.
        #expect(made(meeting, unknown, then: ["reference": "dernier", "calendrier": "Perso"],
                     said: ["Mets-la dans Maison alors.", request]) == inCalendar("Perso"))
        // No calendar named, or two: the refused one, which the app refuses again. Nor in the same turn.
        for answer in ["Mets-la où tu veux.", "Dans le calendrier par défaut.", "Maison ou Perso, je ne sais pas."] {
            #expect(made(meeting, unknown, then: titleOnly, said: [answer, request]) == inCalendar("Travail"),
                    "\(answer)")
        }
        #expect(made(meeting, unknown, then: titleOnly, said: [request]) == inCalendar("Travail"))
        let maisonRequest = "Ajoute le ménage de la maison demain à 10 h dans mon calendrier Travail."
        #expect(made(meeting, unknown, then: titleOnly, said: [maisonRequest], refusedAfter: [maisonRequest])
                == inCalendar("Travail"))
        // A reminder's list.
        let bread = ToolCall(name: "creer_rappel", arguments: ["titre": "pain", "liste": "Courses"])
        let noList = ActionCatalog.unknownCollection("Courses", event: false, names: ["Rappels"], context: context())
        #expect(made(bread, noList, then: ["reference": "dernier", "titre": "pain"],
                     said: ["Mets-le dans tes rappels alors.", "Ajoute du pain à ma liste de courses."])
                == ToolCall(name: "creer_rappel", arguments: ["titre": "pain", "liste": "Rappels"]))
        // Refused for its moment, in a calendar that exists: that calendar, whatever the answer.
        let perso = "Ajoute un rendez-vous chez le coiffeur après le travail dans mon calendrier Perso."
        let hairdresser = ToolCall(name: "creer_evenement",
                                   arguments: ["titre": "Coiffeur", "quand": "après le travail", "calendrier": "Perso"])
        let words = try #require(checkRefusal(hairdresser))
        #expect(made(hairdresser, words, then: ["reference": "dernier", "quand": "demain à 18 h"],
                     said: ["Demain à 18 h.", perso], refusedAfter: [perso])
                == ToolCall(name: "creer_evenement",
                            arguments: ["titre": "Coiffeur", "quand": "demain à 18 h", "calendrier": "Perso"]))
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
                ActionPhrases.earlierOrLater(language), ActionPhrases.atMost(3, language),
                ActionPhrases.undone(.deletion, language),
                ActionPhrases.undone(Array(repeating: ActionPhrases.undoneName(.timer, language), count: 2), language),
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

    /// Words about when that leave the hour open (« après le travail »), with a day or without: refused as words the
    /// app cannot place, so the model asks the user and the creation is kept for the answer; never saved for the whole
    /// day, whether the day is one the model took from the date line (today is Thursday) or the user's own.
    @Test func anHourLeftOpenIsAsked() throws {
        func said(_ sentences: [String]) -> ToolContext {
            ToolContext(now: now, timeZone: paris, language: .french, userSaid: sentences)
        }
        func refusal(_ quand: String?, said sentences: [String], tool: String = "creer_evenement") -> ToolRefusal? {
            var arguments: [String: JSONValue] = ["titre": "Rendez-vous chez le coiffeur"]
            if let quand { arguments["quand"] = .string(quand) }
            do {
                try ActionCatalog.check(ToolCall(name: tool, arguments: arguments), context: said(sentences))
                return nil
            } catch {
                return error as? ToolRefusal
            }
        }
        let request = "Ajoute un rendez-vous chez le coiffeur après le travail dans mon calendrier Perso."
        // A day from the date line, with the user's words or without, a date or an hour the model chose.
        for quand in ["jeudi après le travail", "jeudi", "2026-10-22", "2026-10-16T18:00", "demain à 18 h",
                      "après le travail"] {
            let refused = try #require(refusal(quand, said: [request]), "\(quand)")
            #expect(refused.retryable && refused.detailGivenAgain && refused.spoken == ActionPhrases.badTime(.french)
                    && refused.forModel.hasPrefix("Je ne comprends pas « quand »"), "\(quand)")
        }
        // The weekday the user said, with the rest or without, an hour the model added, or no moment in the call.
        let own = "Ajoute un rendez-vous chez le coiffeur jeudi après le travail."
        for quand in ["jeudi après le travail", "jeudi", "jeudi à 18 h", nil] {
            #expect(refusal(quand, said: [own])?.detailGivenAgain == true, "\(quand ?? "none")")
        }
        let paul = "Rappelle-moi d'appeler Paul jeudi après le travail"
        #expect(refusal("jeudi après le travail", said: [paul], tool: "creer_rappel") != nil)
        #expect(refusal(nil, said: [paul], tool: "creer_rappel") != nil)
        #expect(refusal("jeudi après le travail", said: []) != nil)  // the words alone
        // A change: the item's time is not the hour the user left open either.
        func change(_ quand: String, said sentence: String) throws -> (start: Date, end: Date, allDay: Bool)? {
            try ActionCatalog.changedEvent(
                ToolCall(name: "modifier_element", arguments: ["reference": "e1", "quand": .string(quand)]),
                start: date("2026-10-16T15:00"), end: date("2026-10-16T16:00"), allDay: false,
                context: said([sentence]))
        }
        let move = "Décale-le à jeudi après le travail"
        #expect(throws: ToolRefusal.self) { try change("jeudi après le travail", said: move) }
        #expect(throws: ToolRefusal.self) { try change("jeudi", said: move) }
        #expect(try change("jeudi", said: "Décale-le à jeudi")?.start == date("2026-10-22T15:00"))

        // The hour in the user's words: saved. The answer to the question, an hour said with the rest (which
        // completes the model's words), a part of the day, an hour said in an earlier turn.
        func start(_ quand: String, said sentences: [String]) throws -> Date {
            let call = ToolCall(name: "creer_evenement", arguments: ["titre": "Coiffeur", "quand": .string(quand)])
            return try ActionCatalog.eventTimes(call, context: said(sentences)).start
        }
        #expect(try start("demain à 18 h", said: ["Demain à 18 h.", request]) == date("2026-10-16T18:00"))
        let withHour = "Ajoute un rendez-vous chez le coiffeur jeudi à 18 h après le travail."
        #expect(try start("jeudi à 18 h", said: [withHour]) == date("2026-10-22T18:00"))
        #expect(try start("jeudi après le travail", said: [withHour]) == date("2026-10-22T18:00"))
        #expect(try start("jeudi soir", said: ["Ajoute un rendez-vous chez le coiffeur jeudi soir après le travail."])
                == date("2026-10-22T19:00"))
        let atSix = "Ajoute un rendez-vous chez le coiffeur à 18 h."
        #expect(try start("jeudi à 18 h", said: ["Jeudi après le travail.", atSix]) == date("2026-10-22T18:00"))
        // Other words about when, as before.
        let bill = ToolCall(name: "creer_evenement", arguments: ["titre": "Facture", "quand": "vendredi"])
        let deadline = "Ajoute le paiement de la facture avant vendredi"
        let friday = try ActionCatalog.eventTimes(bill, context: said([deadline]))
        #expect(friday.allDay && friday.start == date("2026-10-16"))
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

    @Test func examplesAreExchangesTheAppCouldHaveHad() throws {
        let examples = ActionCatalog.examples(now: now, timeZone: paris)
        let exchange: [ChatMessage.Role] = [.user, .assistant, .tool, .assistant]
        #expect(examples.map(\.role) == exchange + exchange + exchange + exchange)
        #expect(examples.filter { $0.role == .user }.map(\.content)
                == [ActionCatalog.example.request, "Rappelle-moi d'acheter du lait",
                    "Ajoute un rendez-vous chez le kiné après la piscine dans mon calendrier Famille",
                    "Mardi à 18 h 15."])  // no date line
        // Each call comes at once, with the user's words.
        #expect(examples[1].content.isEmpty && examples[1].toolCalls == [ActionCatalog.example.call])
        // Even with a moment the app cannot place: the call is refused as the app refuses it, then a question about the
        // day and the hour alone. At the answer, the event's call again, with the request's title and calendar.
        let refused = try #require(examples[9].toolCalls.first)
        #expect(refused.arguments == ["titre": "Rendez-vous chez le kiné", "quand": "après la piscine",
                                      "calendrier": "Famille"])
        let refusal = try #require(checkRefusal(refused))
        #expect(refusal.detailGivenAgain && examples[10].toolResult == refusal.result(for: refused))
        #expect(examples[13].toolCalls.first?.arguments == ["titre": "Rendez-vous chez le kiné", "quand": "mardi à 18 h 15",
                                                             "calendrier": "Famille"])
        // The result and the sentence the app would have given (the coming Tuesday), with ids it never gives.
        #expect(examples[14].toolResult == ["id": "e0", "titre": "Rendez-vous chez le kiné", "debut": "2026-10-20T18:15",
                                            "fin": "2026-10-20T19:15", "calendrier": "Famille"])
        #expect(examples.compactMap { $0.toolResult?.objectID } == ["t0", "r0", "e0"])
        #expect(examples.filter { $0.role == .assistant && $0.toolCalls.isEmpty }.map(\.content)
                == ["C’est parti pour 5 minutes\(nb): le thé. Je te préviens à la fin.",
                    "C’est noté dans tes rappels\(nb): acheter du lait.",
                    "Quel jour et à quelle heure, pour ce rendez-vous\(nb)?",
                    "C’est dans ton calendrier «\(nb)Famille\(nb)»\(nb): Rendez-vous chez le kiné, mardi 20 octobre de "
                        + "18\(nb)h\(nb)15 à 19\(nb)h\(nb)15."])
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

    func undoneName(_ token: UndoToken, language: SpeechLanguage) -> String? { ActionPhrases.undoneName(.reminder, language) }
}

/// The calendar's tools with the app's checks (`ActionCatalog.check`), and two calendars, « Maison » and « Perso »: an
/// item "saved" only gets an id ("r1", "e1"), and an event in another calendar is refused when the call is carried out,
/// as `CalendarTools` refuses a calendar it does not find. A change of an item saved (the last one, or one named by its
/// id) gives it the change's arguments. Right after a creation refused for a detail the user gives again, a change of
/// the last item, or of one never created, is that creation (`RefusedCreation`, around the check and the carrying out
/// of each call, as in the app's providers). A creation whose call names no calendar gets the one the user's words
/// name, or the one of the same creation refused just before, or, when that one does not exist, the one the user's
/// answer names (`ActionCatalog.withCollectionSaid`), and an hour alone that refused creation's day when its words left
/// the hour open (`RefusedCreation.withRefusedDay`), as in the app.
actor CheckedCalendar: ToolProvider {
    nonisolated let identifier = "calendar"
    static let calendars = ["Maison", "Perso"]
    private(set) var created: [ToolCall] = []
    /// The items saved, by id: their creations, with the arguments of their changes.
    private(set) var items: [String: ToolCall] = [:]
    private var lastCreated: String?
    private var refusedCreation = RefusedCreation()

    func tools() -> [ToolSpec] { ActionCatalog.calendarTools(movingItems: true) }

    func check(_ call: ToolCall, context: ToolContext) throws {
        refusedCreation.checking(call)
        do {
            try ActionCatalog.check(refusedCreation.withRefusedDay(call, said: context.userSaid), context: context)
        } catch let refusal as ToolRefusal {
            refusedCreation.refused(completed(call, context), refusal, said: context.userSaid)
            throw refusal
        }
    }

    private func completed(_ call: ToolCall, _ context: ToolContext) -> ToolCall {
        ActionCatalog.withCollectionSaid(refusedCreation.withRefusedDay(call, said: context.userSaid), context: context,
                                         again: refusedCreation.collection(before: call),
                                         answer: refusedCreation.answer(before: call, said: context.userSaid)) {
            $0 ? Self.calendars : ["Rappels"]
        }
    }

    func perform(_ call: ToolCall, context: ToolContext) throws -> ToolOutcome {
        let call = completed(call, context)
        do {
            if call.name == ActionCatalog.changeItem.name {
                if let creation = refusedCreation.creation(insteadOf: call, said: context.userSaid,
                                                           names: { $0 ? Self.calendars : ["Rappels"] },
                                                           exists: { items[$0] != nil })
                {
                    return try perform(creation, context: context)
                }
                let reference = call.text("reference") ?? "dernier"
                guard let id = ActionCatalog.meansLastItem(reference) ? lastCreated : reference, var item = items[id]
                else {
                    throw ToolRefusal(forModel: "Aucun élément « \(reference) » créé dans cette conversation.",
                                      spoken: ActionPhrases.nothingToChange(context.language))
                }
                for (key, value) in call.arguments where key != "reference" { item.arguments[key] = value }
                items[id] = item
                return ToolOutcome(spoken: "C’est modifié\(nb): \(item.text("titre") ?? "").", forModel: ["id": .string(id)])
            }
            try ActionCatalog.check(call, context: context)
            if let name = call.text("calendrier"), !Self.calendars.contains(name) {
                var refusal = ToolRefusal(forModel: "Aucun calendrier modifiable ne s'appelle « \(name) ». "
                                              + "Calendriers : Maison, Perso.",
                                          spoken: ActionPhrases.unknownCalendar(name, context.language))
                refusal.detailGivenAgain = true
                throw refusal
            }
            created.append(call)
            let reminder = call.name == ActionCatalog.createReminder.name
            let id = (reminder ? "r" : "e") + "\(created.filter { $0.name == call.name }.count)"
            items[id] = call
            lastCreated = id
            let spoken = (reminder ? "C’est noté" : "C’est dans ton agenda") + "\(nb): \(call.text("titre") ?? "")."
            return ToolOutcome(spoken: spoken, forModel: ["id": .string(id)])
        } catch let refusal as ToolRefusal {
            refusedCreation.refused(call, refusal, said: context.userSaid)
            throw refusal
        }
    }
}

/// A search whose results the model sums up (`ToolOutcome.modelSpeaks`), as the web search's.
actor SummedSearch: ToolProvider {
    nonisolated let identifier = "summed"
    static let fallback = "Je n’ai rien trouvé de clair."
    private(set) var queries: [String] = []

    func tools() -> [ToolSpec] {
        [ToolSpec(name: "chercher", description: "Cherche.",
                  parameters: [ToolParameter("requete", .string, "Quoi.", required: true)], risk: .read)]
    }

    func perform(_ call: ToolCall, context: ToolContext) throws -> ToolOutcome {
        queries.append(call.text("requete") ?? "")
        return ToolOutcome(spoken: Self.fallback, forModel: ["resultats": "Beau temps demain à Paris."], modelSpeaks: true)
    }
}

/// What the timers told the app, in the order they told it (from inside the timers' actor, as the app gets it).
private final class TimerReports: @unchecked Sendable {
    private let lock = NSLock()
    private var runningReports: [Bool] = []
    private var finishedTexts: [String] = []
    var running: [Bool] { lock.withLock { runningReports } }
    var finished: [String] { lock.withLock { finishedTexts } }
    func record(running: Bool) { lock.withLock { runningReports.append(running) } }
    func record(finished: String) { lock.withLock { finishedTexts.append(finished) } }
}

@Suite("Timers")
struct TimerToolTests {
    func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func timer(seconds: Int) -> ToolCall { ToolCall(name: "minuteur", arguments: ["duree_secondes": .int(seconds)]) }

    /// The app keeps the Mac awake from the start of the first timer to the end of the last one.
    @Test func saysWhileATimerRuns() async throws {
        let timers = TimerTools()
        let reports = TimerReports()
        await timers.observe(onFinish: { reports.record(finished: $0.text) }, onRunning: { reports.record(running: $0) })
        #expect(reports.running.isEmpty)
        _ = try await timers.perform(timer(seconds: 1), context: context())
        let long = try await timers.perform(timer(seconds: 600), context: context())
        #expect(reports.running == [true])  // once, for both
        await waitFor { reports.finished.count == 1 }
        #expect(reports.running == [true])  // the short one rang, the long one still runs
        // Through the protocol, as the app does: called on the actor itself, an async caller would get the protocol's
        // default implementation instead of the timers' own (which is synchronous).
        let provider: any ToolProvider = timers
        _ = try await provider.undo(try #require(long.undo), context: context())
        #expect(reports.running == [true, false])  // "annule": none runs any more
        #expect(await timers.count == 0)

        _ = try await timers.perform(timer(seconds: 1), context: context())
        #expect(reports.running == [true, false, true])
        // A timer that rings reports that none runs any more, then that it rang: wait for both.
        await waitFor { reports.running.count == 4 && reports.finished.count == 2 }
        #expect(reports.running == [true, false, true, false])  // it rang
        #expect(reports.finished.count == 2)
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
        #expect(unknown.forModel == ["erreur": .string("Outil inconnu : effacer. Les outils existants sont : noter, lancer. "
                                                       + ToolRefusal.secondTry("effacer"))])
        #expect(await tools.performed.count == 1)
    }

    /// A call refused for its arguments: the model reads why, that nothing was created or changed, and what the app waits
    /// for: another call, or the user's answer. Without it, Gemma 4 26B began most of its second tries with « C'est
    /// noté… » for an item never saved. A creation's also says that nothing exists to change yet. A refusal asked to the
    /// user at once (no second try) keeps its own words.
    @Test func refusalTellsTheModelNothingWasDone() async {
        let creation = ToolRefusal.secondTry("creer_evenement")
        #expect(creation.hasPrefix("Rien n'est créé : ") && creation.contains("appelle de nouveau creer_evenement (pas "
                                                                               + "modifier_element : rien n'existe encore)"))
        let change = ToolRefusal.secondTry("modifier_element")
        #expect(change.hasPrefix("Rien n'est créé ni changé : ") && !change.contains("rien n'existe encore"))
        #expect(ToolRefusal.secondTry("creer_rappel").contains("pas modifier_element"))
        #expect(ToolRefusal.secondTry("lire_agenda") == change)

        let runner = ToolRunner(providers: [CheckedCalendar()])
        _ = await runner.tools()
        func event(_ when: String) -> ToolCall {
            ToolCall(name: "creer_evenement", arguments: ["titre": "Kiné", "quand": .string(when)])
        }
        let weekday = await runner.handle(event("dimanche 22 octobre à 10 h"), context: context())
        #expect(weekday.retryable)
        #expect(weekday.forModel == ["erreur": .string("« dimanche 22 octobre à 10 h » : le 22 octobre est un jeudi. "
                                                       + creation)])
        #expect(weekday.spoken == "Le 22 octobre tombe un jeudi. Tu peux me redire la date\(nb)?")
        let noReference = await runner.handle(ToolCall(name: "modifier_element", arguments: ["quand": "à 16 h"]),
                                              context: context())
        #expect(noReference.retryable)
        #expect(noReference.forModel == ["erreur": .string("Il manque « reference ». " + change)])
        // Asked to the user at once: no second try, and the refusal's own words.
        for when in ["hier à 15 h", "lundi à 3 h"] {
            let refused = await runner.handle(event(when), context: context())
            #expect(!refused.retryable)
            #expect(refused.forModel["erreur"]?.text?.contains(creation) == false, "\(when)")
        }
        let past = await runner.handle(event("hier à 15 h"), context: context())
        #expect(past.forModel["erreur"]?.text?.contains("Rien n'est créé : l'app demande un autre moment") == true)
    }

    /// A reminder, then a meeting refused for a calendar that does not exist: the change of the last item that answers
    /// it (« Mets-la dans Maison alors. ») creates the meeting in that calendar and leaves the reminder as it was. Right
    /// after another refused meeting, a change that names the reminder by its id (« Laisse tomber, décale plutôt mon
    /// rappel à 11 h. ») moves the reminder.
    @Test func changeOfTheLastItemAfterARefusedCreationLeavesTheEarlierItem() async {
        let calendar = CheckedCalendar()
        let runner = ToolRunner(providers: [calendar])
        _ = await runner.tools()
        let bread = ToolCall(name: "creer_rappel", arguments: ["titre": "Acheter du pain"])
        let saved = await runner.handle(bread, context: context())
        #expect(saved.forModel == ["id": "r1"])
        let meeting = ToolCall(name: "creer_evenement",
                               arguments: ["titre": "Réunion", "quand": "demain à 10 h", "calendrier": "Travail"])
        let refused = await runner.handle(meeting, context: context())
        #expect(refused.retryable)
        let toHome = ToolCall(name: "modifier_element", arguments: ["reference": "dernier", "calendrier": "Maison"])
        let made = await runner.handle(toHome, context: context())
        #expect(made.forModel == ["id": "e1"])
        let inHome = ToolCall(name: "creer_evenement",
                              arguments: ["titre": "Réunion", "quand": "demain à 10 h", "calendrier": "Maison"])
        #expect(await calendar.items == ["r1": bread, "e1": inHome])

        let refusedAgain = await runner.handle(meeting, context: context())
        #expect(refusedAgain.retryable)
        let moveBread = ToolCall(name: "modifier_element", arguments: ["reference": "r1", "quand": "à 11 h"])
        let moved = await runner.handle(moveBread, context: context())
        #expect(moved.forModel == ["id": "r1"])
        #expect(await calendar.items["r1"] == ToolCall(name: "creer_rappel",
                                                       arguments: ["titre": "Acheter du pain", "quand": "à 11 h"]))
        #expect(await calendar.created.count == 2)  // no meeting made of that change
    }

    /// « Ajoute une réunion demain à 10 h dans mon calendrier Travail. », refused for « Travail », which does not
    /// exist, then « Mets-la dans Perso alors. »: a change of the last item that leaves the calendar out, or the
    /// creation written again without it, saves the meeting in « Perso », the calendar the answer names, not in
    /// « Travail » again (refused) nor in the default one. Written again without it by a second try in the same turn,
    /// the creation still goes to the default one: the request names no other.
    @Test func theAnswerToAnUnknownCalendarSavesTheItemInTheOneItNames() async {
        let request = "Ajoute une réunion demain à 10 h dans mon calendrier Travail."
        let first = ToolContext(now: now, timeZone: paris, language: .french, userSaid: [request])
        let answer = ToolContext(now: now, timeZone: paris, language: .french,
                                 userSaid: ["Mets-la dans Perso alors.", request])
        let call = ToolCall(name: "creer_evenement",
                            arguments: ["titre": "Réunion", "quand": "demain à 10 h", "calendrier": "Travail"])
        let again = ToolCall(name: "creer_evenement", arguments: ["titre": "Réunion", "quand": "demain à 10 h"])
        var inPerso = again
        inPerso.arguments["calendrier"] = "Perso"
        for next in [ToolCall(name: "modifier_element", arguments: ["reference": "dernier", "titre": "Réunion"]), again] {
            let calendar = CheckedCalendar()
            let runner = ToolRunner(providers: [calendar])
            _ = await runner.tools()
            let refused = await runner.handle(call, context: first)
            #expect(refused.retryable)
            let made = await runner.handle(next, context: answer)
            #expect(made.forModel == ["id": "e1"], "\(next.name)")
            #expect(await calendar.created == [inPerso], "\(next.name)")
        }
        let calendar = CheckedCalendar()
        let runner = ToolRunner(providers: [calendar])
        _ = await runner.tools()
        _ = await runner.handle(call, context: first)
        _ = await runner.handle(again, context: first)
        #expect(await calendar.created == [again])
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

/// The calendar or the list the user's words name, for a creation whose call names none (`ActionCatalog.withCollectionSaid`).
@Suite("Calendar or list in the user's words")
struct CollectionSaidTests {
    func said(_ sentence: String, event: Bool = false, among names: [String]) -> String? {
        ActionCatalog.collectionSaid(in: sentence, event: event, among: names).map { names[$0] }
    }

    @Test func findsTheListTheUserNames() {
        let lists = ["Rappels", "Courses", "Maison", "Idées cadeaux", "À faire"]
        for sentence in ["Ajoute du pain à ma liste de courses.", "Ajoute du pain à la liste des courses.",
                         "Mets du lait sur ma liste Courses, merci.", "Dans la liste de mes courses, ajoute du pain.",
                         "Ajoute du pain à ma liste de course pour samedi."] {  // as a name in a call: « course »
            #expect(said(sentence, among: lists) == "Courses", "\(sentence)")
        }
        #expect(said("Note un livre dans ma liste idées cadeaux.", among: lists) == "Idées cadeaux")
        #expect(said("Ajoute appeler le plombier à ma liste à faire.", among: lists) == "À faire")
        #expect(said("Ajoute du pain sur la liste appelée Maison.", among: lists) == "Maison")
        // A name that begins with the word itself; the longest name that is all there; one that goes on.
        #expect(said("Ajoute du pain à ma liste de courses.", among: ["Rappels", "Liste de courses"]) == "Liste de courses")
        #expect(said("Ajoute du pain à ma liste de courses.", among: ["Courses", "Liste de courses"]) == "Liste de courses")
        #expect(said("Ajoute du pain à ma liste de courses.", among: ["Rappels", "Courses du week-end"])
                == "Courses du week-end")
        #expect(said("Ajoute du pain à ma liste de courses.", among: ["Rappels", "🛒 Courses"]) == "🛒 Courses")
        // In English.
        #expect(said("Add milk to my shopping list.", among: ["Reminders", "Shopping"]) == "Shopping")
        #expect(said("Add milk to the Groceries list", among: ["Reminders", "Groceries"]) == "Groceries")
        #expect(said("Add milk to my shopping list.", among: ["Reminders", "Shopping list"]) == "Shopping list")
        #expect(said("Put it on the list Groceries.", among: ["Reminders", "Groceries"]) == "Groceries")
    }

    /// No list of that name, none named, or a list named only as something to do.
    @Test func findsNoListTheUserDoesNotName() {
        let lists = ["Rappels", "Invités", "Courses", "Maison"]
        for sentence in ["Rappelle-moi de faire la liste des invités.", "Rappelle-moi de vider ma liste de courses.",
                         "Ajoute du pain à ma liste.", "Ajoute du pain à ma liste pour demain.", "Ajoute à ma liste, du pain.",
                         "Rappelle-moi d'acheter du pain.", "Rappelle-moi de ranger la maison.",
                         "Ajoute du pain dans mon calendrier Maison."] {
            #expect(said(sentence, among: lists) == nil, "\(sentence)")
        }
        #expect(said("Ajoute du pain à ma liste de courses.", among: ["Rappels"]) == nil)
        #expect(said("Ajoute une réunion demain à 10 h dans mon calendrier Travail.", among: ["Rappels"]) == nil)
    }

    @Test func findsTheCalendarTheUserNames() {
        let calendars = ["Maison", "Travail", "Famille Dupont", "Professionnel"]
        func calendar(_ sentence: String) -> String? { said(sentence, event: true, among: calendars) }
        #expect(calendar("Ajoute une réunion demain à 10 h dans mon calendrier Travail.") == "Travail")
        #expect(calendar("Ajoute une réunion dans le calendrier du travail demain à 10 h.") == "Travail")
        #expect(calendar("Mets le match au calendrier famille Dupont samedi.") == "Famille Dupont")
        #expect(calendar("Note-le dans l'agenda pro.") == "Professionnel")
        #expect(said("Add the meeting to my work calendar.", event: true, among: ["Home", "Work"]) == "Work")
        for sentence in ["Ajoute une réunion demain à 10 h dans mon calendrier.",
                         "Ajoute une réunion dans mon calendrier demain à 10 h.",
                         "Ajoute à mon calendrier le match de foot dimanche à 15 h au stade",
                         "Rappelle-moi de regarder le calendrier Travail.", "Ajoute une réunion à ma liste Travail.",
                         "J'ai une réunion avec l'équipe lundi à 9 h 30, note-la dans mon calendrier"] {
            #expect(calendar(sentence) == nil, "\(sentence)")
        }
    }

    /// An answer to « Tu peux me redire son nom ? », after a calendar or a list that does not exist: the name may come
    /// alone, without « calendrier » or « liste » before it.
    @Test func findsTheNameAnAnswerGives() {
        let calendars = ["Maison", "Perso", "Famille", "Famille Dupont", "Calendrier"]
        func answered(_ sentence: String) -> String? {
            ActionCatalog.collectionAnswered(in: sentence, event: true, among: calendars).map { calendars[$0] }
        }
        #expect(answered("Mets-la dans Maison alors.") == "Maison")
        #expect(answered("Maison.") == "Maison")
        #expect(answered("Celui de la maison.") == "Maison")
        #expect(answered("C'est le calendrier perso.") == "Perso")
        #expect(answered("Mets-la dans mon calendrier Perso.") == "Perso")  // as in a request
        #expect(answered("Dans famille Dupont.") == "Famille Dupont")  // the longest
        #expect(answered("Pas dans Travail, dans Maison.") == "Maison")  // « Travail » is not there
        #expect(answered("Dans Maison, pas Perso.") == "Maison")  // the one behind « dans »
        for sentence in ["Où tu veux.", "Maison ou Perso, je ne sais pas.", "Dans Maison ou dans Perso.",
                         "Dans le calendrier par défaut.", "Demain à 18 h."] {
            #expect(answered(sentence) == nil, "\(sentence)")
        }
        #expect(ActionCatalog.collectionAnswered(in: "Mets-le dans tes rappels alors.", event: false,
                                                 among: ["Rappels", "Courses"]) == 0)
        #expect(ActionCatalog.collectionAnswered(in: "Add it to Home then.", event: true, among: ["Home", "Work"]) == 0)
    }

    /// Only a creation that names none, from this turn's sentence, else from the same creation refused just before; a
    /// name among the ones there are.
    @Test func putsItInACreationThatNamesNone() {
        let names: (Bool) -> [String] = { $0 ? ["Maison", "Travail", "Perso"] : ["Rappels", "Courses"] }
        func amended(_ call: ToolCall, said: [String], again: String? = nil) -> ToolCall {
            ActionCatalog.withCollectionSaid(call, context: ToolContext(now: now, timeZone: paris, language: .french,
                                                                         userSaid: said),
                                             again: again, names: names)
        }
        let bread = ToolCall(name: "creer_rappel", arguments: ["titre": "pain"])
        let shopping = "Ajoute du pain à ma liste de courses."
        #expect(amended(bread, said: [shopping]) == ToolCall(name: "creer_rappel",
                                                             arguments: ["titre": "pain", "liste": "Courses"]))
        let named = ToolCall(name: "creer_rappel", arguments: ["titre": "pain", "liste": "Rappels"])
        #expect(amended(named, said: [shopping]) == named)  // the model's own
        #expect(amended(bread, said: ["Rappelle-moi d'appeler Paul.", shopping]) == bread)  // another request's
        let meeting = ToolCall(name: "creer_evenement", arguments: ["titre": "Réunion", "quand": "demain à 10 h"])
        #expect(amended(meeting, said: ["Ajoute une réunion demain à 10 h dans mon calendrier Travail."])
                == ToolCall(name: "creer_evenement",
                            arguments: ["titre": "Réunion", "quand": "demain à 10 h", "calendrier": "Travail"]))
        #expect(amended(meeting, said: [shopping]) == meeting)  // a list, not a calendar
        for other in [ToolCall(name: "minuteur", arguments: ["duree": "5 minutes"]),
                      ToolCall(name: "modifier_element", arguments: ["reference": "dernier", "quand": "à 11 h"])] {
            #expect(amended(other, said: ["Ajoute-le à mon calendrier Travail."], again: "Travail") == other)
        }
        // The refused creation's, when the call is written again without it: only one there is.
        let hairdresser = ToolCall(name: "creer_evenement", arguments: ["titre": "Coiffeur", "quand": "demain à 18 h"])
        var perso = hairdresser
        perso.arguments["calendrier"] = "Perso"
        #expect(amended(hairdresser, said: ["Demain à 18 h."], again: "perso") == perso)
        #expect(amended(hairdresser, said: ["Demain à 18 h."], again: "Bureau") == hairdresser)
        #expect(amended(hairdresser, said: ["Demain à 18 h dans mon calendrier Travail."], again: "Perso").text("calendrier")
                == "Travail")  // what the user says now first
        // The refused one does not exist: the one the user's answer names, even alone; only an answer.
        let answer = "Mets-la dans Maison alors."
        func answered(_ said: String?, again: String?) -> ToolCall {
            ActionCatalog.withCollectionSaid(meeting, context: ToolContext(now: now, timeZone: paris, language: .french,
                                                                            userSaid: [answer]),
                                             again: again, answer: said, names: names)
        }
        #expect(answered(answer, again: "Bureau").text("calendrier") == "Maison")
        #expect(answered(nil, again: "Bureau") == meeting)  // the request, read again by a second try
        #expect(answered(answer, again: "Perso").text("calendrier") == "Perso")  // refused for something else
        #expect(answered(answer, again: nil) == meeting)
    }

    /// A change that names no calendar and no list, with the one this turn's sentence names: a calendar for an event, a
    /// list for a reminder, among the ones there are, its own too (the provider then says the item is already there).
    @Test func putsItInAChangeThatNamesNone() {
        let names: (Bool) -> [String] = { $0 ? ["Travail", "Maison"] : ["Rappels", "Courses"] }
        func amended(_ call: ToolCall, event: Bool = true, said: [String]) -> ToolCall {
            ActionCatalog.withCollectionSaid(change: call, event: event,
                                             context: ToolContext(now: now, timeZone: paris, language: .french,
                                                                  userSaid: said),
                                             names: names)
        }
        let meeting = ToolCall(name: "modifier_element",
                               arguments: ["reference": "e1", "titre": "réunion", "quand": "vendredi à 10 h"])
        var inHome = meeting
        inHome.arguments["calendrier"] = "Maison"
        #expect(amended(meeting, said: ["Mets la réunion dans mon calendrier Maison."]) == inHome)
        #expect(amended(meeting, said: ["Mets-la dans mon calendrier Travail."]).text("calendrier") == "Travail")
        let bare = ToolCall(name: "modifier_element", arguments: ["reference": "dernier"])
        #expect(amended(bare, said: ["Mets-la dans l'agenda maison."])
                == ToolCall(name: "modifier_element", arguments: ["reference": "dernier", "calendrier": "Maison"]))
        let bread = ToolCall(name: "modifier_element", arguments: ["reference": "r1", "titre": "acheter du pain"])
        #expect(amended(bread, event: false, said: ["Mets-le dans ma liste de courses."])
                == ToolCall(name: "modifier_element",
                            arguments: ["reference": "r1", "titre": "acheter du pain", "liste": "Courses"]))
        #expect(amended(bread, event: false, said: ["Mets-le dans ma liste Rappels."]).text("liste") == "Rappels")
        // A calendar for a reminder, a list for an event: nothing.
        #expect(amended(bread, event: false, said: ["Mets-le dans mon calendrier Maison."]) == bread)
        #expect(amended(meeting, said: ["Mets la réunion dans ma liste Courses."]) == meeting)
        // A sentence that names none, or one that does not exist; an earlier one; none (one of several actions).
        for said in [["Mets la réunion à la même heure."], ["Mets la réunion dans mon calendrier."],
                     ["Mets la réunion dans mon calendrier Famille."],
                     ["La réunion de demain à 10 h.", "Mets la réunion dans mon calendrier Maison."], []] {
            #expect(amended(meeting, said: said) == meeting, "\(said)")
        }
        // The model's own, under either word; a creation (`withCollectionSaid(_:context:again:answer:names:)`).
        for own: [String: JSONValue] in [["calendrier": "Travail"], ["liste": "Travail"]] {
            var named = meeting
            named.arguments.merge(own) { $1 }
            #expect(amended(named, said: ["Mets la réunion dans mon calendrier Maison."]) == named, "\(own)")
        }
        let creation = ToolCall(name: "creer_evenement", arguments: ["titre": "Réunion", "quand": "demain à 10 h"])
        #expect(amended(creation, said: ["Ajoute une réunion demain à 10 h dans mon calendrier Maison."]) == creation)
    }

    /// The same creation written again right after it was refused gets the refused one's calendar or list; another call
    /// does not.
    @Test func aCreationWrittenAgainKeepsTheRefusedOnesCollection() throws {
        let refusedCall = ToolCall(name: "creer_evenement",
                                   arguments: ["titre": "Coiffeur", "quand": "après le travail", "calendrier": "Perso"])
        let refusal = try #require(checkRefusal(refusedCall))
        let again = ToolCall(name: "creer_evenement", arguments: ["titre": "Coiffeur", "quand": "demain à 18 h"])
        var refused = RefusedCreation()
        refused.checking(refusedCall)
        refused.refused(refusedCall, refusal)
        refused.checking(again)
        #expect(refused.collection(before: again) == "Perso")
        #expect(refused.collection(before: ToolCall(name: "creer_rappel", arguments: ["titre": "Pain"])) == nil)
        refused.checking(ToolCall(name: "minuteur", arguments: ["duree": "5 minutes"]))
        #expect(refused.collection(before: again) == nil)  // only right after it
        refused.refused(refusedCall, refusal)
        refused.checking(ToolCall(name: "creer_rappel", arguments: ["titre": "Pain"]))
        refused.checking(again)
        #expect(refused.collection(before: again) == nil)
    }

    /// « Ajoute un rendez-vous chez le coiffeur après le travail dans mon calendrier Perso. », its call without the
    /// calendar, refused for its moment, then « Demain à 18 h. »: a change of the last item, or the creation written
    /// again without the calendar, creates it in « Perso ».
    @Test func theAnswerCreatesTheRefusedItemInTheCalendarTheUserNamed() async {
        let request = "Ajoute un rendez-vous chez le coiffeur après le travail dans mon calendrier Perso."
        let first = ToolContext(now: now, timeZone: paris, language: .french, userSaid: [request])
        let answer = ToolContext(now: now, timeZone: paris, language: .french, userSaid: ["Demain à 18 h.", request])
        let call = ToolCall(name: "creer_evenement", arguments: ["titre": "Coiffeur", "quand": "après le travail"])
        let inPerso = ToolCall(name: "creer_evenement",
                               arguments: ["titre": "Coiffeur", "quand": "demain à 18 h", "calendrier": "Perso"])
        for next in [ToolCall(name: "modifier_element", arguments: ["reference": "dernier", "quand": "demain à 18 h"]),
                     ToolCall(name: "creer_evenement", arguments: ["titre": "Coiffeur", "quand": "demain à 18 h"])] {
            let calendar = CheckedCalendar()
            let runner = ToolRunner(providers: [calendar])
            _ = await runner.tools()
            let refused = await runner.handle(call, context: first)
            #expect(refused.retryable)
            let made = await runner.handle(next, context: answer)
            #expect(made.forModel == ["id": "e1"], "\(next.name)")
            #expect(await calendar.created == [inPerso], "\(next.name)")
        }
    }

    /// « jeudi après le travail », refused for the hour it leaves open, then the hour alone (« À 18 h. »), in a change
    /// of the last item or in the creation written again: the refused words with the hour, on the Thursday the user
    /// said, not the next 18:00 (Friday). A moment with a day of its own still replaces the refused one.
    @Test func anHourAloneKeepsTheRefusedDay() throws {
        let thursday = ToolCall(name: "creer_evenement",
                                arguments: ["titre": "Coiffeur", "quand": "jeudi après le travail", "calendrier": "Perso"])
        let refusal = try #require(checkRefusal(thursday))
        func kept(_ next: ToolCall) -> ToolCall? {
            var refused = RefusedCreation()
            refused.checking(thursday)
            refused.refused(thursday, refusal)
            refused.checking(next)
            if next.name == "modifier_element" { return refused.creation(insteadOf: next, exists: nothingCreated) }
            return refused.withRefusedDay(next, said: [])
        }
        func start(_ call: ToolCall?) throws -> Date {
            try ActionCatalog.eventTimes(try #require(call), context: context()).start
        }
        let atSix: [String: JSONValue] = ["titre": "Coiffeur", "quand": "jeudi après le travail à 18 h",
                                          "calendrier": "Perso"]
        // A change of the last item, under whichever word: the refused creation, with both words.
        for key in ["quand", "debut"] {
            let change = ToolCall(name: "modifier_element", arguments: ["reference": "dernier", key: "à 18 h"])
            #expect(kept(change) == ToolCall(name: "creer_evenement", arguments: atSix), "\(key)")
        }
        // The creation written again: its own words, after the refused ones.
        let again = ToolCall(name: "creer_evenement", arguments: ["titre": "Coiffeur", "quand": "à 18 h"])
        #expect(kept(again) == ToolCall(name: "creer_evenement",
                                        arguments: ["titre": "Coiffeur", "quand": "jeudi après le travail à 18 h"]))
        #expect(try start(kept(again)) == date("2026-10-22T18:00"))
        let underStart = ToolCall(name: "creer_evenement", arguments: ["titre": "Coiffeur", "debut": "18 h 30"])
        #expect(try start(kept(underStart)) == date("2026-10-22T18:30"))
        // A day of its own, or an hour counted from now: replaces the refused moment, as before.
        let tomorrow = ToolCall(name: "modifier_element", arguments: ["reference": "dernier", "quand": "demain à 18 h"])
        #expect(try start(kept(tomorrow)) == date("2026-10-16T18:00"))
        let tomorrowAgain = ToolCall(name: "creer_evenement", arguments: ["titre": "Coiffeur", "quand": "demain à 18 h"])
        #expect(kept(tomorrowAgain) == tomorrowAgain)
        let thursdayAgain = ToolCall(name: "creer_evenement", arguments: ["titre": "Coiffeur", "quand": "jeudi à 18 h"])
        #expect(kept(thursdayAgain) == thursdayAgain)
        let soon = ToolCall(name: "creer_evenement", arguments: ["titre": "Coiffeur", "quand": "dans 2 heures"])
        #expect(kept(soon) == soon)
        // A date of the model's own, for which the app would read the user's answer alone: that answer, after the
        // refused words. Not for the user's own words, nor for an answer with a day.
        let request = "Ajoute un rendez-vous chez le coiffeur jeudi après le travail dans mon calendrier Perso."
        var refusedThursday = RefusedCreation()
        refusedThursday.checking(thursday)
        refusedThursday.refused(thursday, refusal)
        let own = ToolCall(name: "creer_evenement",
                           arguments: ["titre": "Coiffeur", "quand": "jeudi 15 octobre 2026 à 18 h"])
        refusedThursday.checking(own)
        #expect(refusedThursday.withRefusedDay(own, said: ["À 18 h.", request]).text("quand")
                == "jeudi après le travail À 18 h.")
        #expect(refusedThursday.withRefusedDay(own, said: ["Demain à 18 h.", request]) == own)
        #expect(refusedThursday.withRefusedDay(own, said: []) == own)
        #expect(refusedThursday.withRefusedDay(thursdayAgain, said: ["À 18 h.", request]) == thursdayAgain)
        // Another creation, or words refused for another reason: not kept.
        let reminder = ToolCall(name: "creer_rappel", arguments: ["titre": "Coiffeur", "quand": "à 18 h"])
        #expect(kept(reminder) == reminder)
        let past = ToolCall(name: "creer_evenement", arguments: ["titre": "Dentiste", "quand": "hier à 15 h"])
        let gone = try #require(checkRefusal(past))
        var refused = RefusedCreation()
        refused.checking(past)
        refused.refused(past, gone)
        refused.checking(again)
        #expect(refused.withRefusedDay(again, said: []) == again)
        // A reminder's due date, as an event's start.
        let paul = ToolCall(name: "creer_rappel", arguments: ["titre": "Appeler Paul", "quand": "jeudi après le travail"])
        let paulRefused = try #require(checkRefusal(paul))
        var refusedPaul = RefusedCreation()
        refusedPaul.checking(paul)
        refusedPaul.refused(paul, paulRefused)
        let paulAgain = ToolCall(name: "creer_rappel", arguments: ["titre": "Appeler Paul", "quand": "à 18 h"])
        refusedPaul.checking(paulAgain)
        let due = try ActionCatalog.reminderDue(refusedPaul.withRefusedDay(paulAgain, said: []), context: context())
        #expect(due?.date == date("2026-10-22T18:00"))
    }

    /// « Ajoute un rendez-vous chez le coiffeur jeudi après le travail dans mon calendrier Perso. », refused, then
    /// « À 18 h. »: a change of the last item with « à 18 h » (as Gemma 4 E4B once wrote it), the creation written again
    /// with it or with « jeudi à 18 h » (as the models write it), or with a date the model worked out (« jeudi
    /// 15 octobre 2026 à 18 h », today's, as Gemma 4 E4B once wrote it: the app reads the user's answer instead) save
    /// Thursday 22 October at 18:00 in « Perso »; « Demain à 18 h. » saves Friday 16 October at 18:00. When the user
    /// never said « jeudi » (the model took it from the date line), « À 18 h. » is the next 18:00, as before.
    @Test func theHourAloneSavesTheRefusedDay() async throws {
        let thursday = "Ajoute un rendez-vous chez le coiffeur jeudi après le travail dans mon calendrier Perso."
        let call = ToolCall(name: "creer_evenement", arguments: ["titre": "Coiffeur", "quand": "jeudi après le travail"])
        func start(_ next: ToolCall, answer: String = "À 18 h.", request: String = thursday) async throws -> Date {
            let first = ToolContext(now: now, timeZone: paris, language: .french, userSaid: [request])
            let answer = ToolContext(now: now, timeZone: paris, language: .french, userSaid: [answer, request])
            let calendar = CheckedCalendar()
            let runner = ToolRunner(providers: [calendar])
            _ = await runner.tools()
            let refused = await runner.handle(call, context: first)
            #expect(refused.retryable && refused.spoken == ActionPhrases.badTime(.french))
            let made = await runner.handle(next, context: answer)
            #expect(made.forModel == ["id": "e1"], "\(next.arguments)")
            let created = await calendar.created
            #expect(created.count == 1 && created.first?.text("calendrier") == "Perso", "\(next.arguments)")
            let times = try ActionCatalog.eventTimes(try #require(created.first), context: answer)
            #expect(!times.allDay, "\(next.arguments)")
            return times.start
        }
        func change(_ quand: String) -> ToolCall {
            ToolCall(name: "modifier_element", arguments: ["reference": "dernier", "quand": .string(quand)])
        }
        func again(_ quand: String) -> ToolCall {
            ToolCall(name: "creer_evenement", arguments: ["titre": "Coiffeur", "quand": .string(quand)])
        }
        for next in [change("à 18 h"), again("à 18 h"), again("jeudi à 18 h"), again("jeudi 15 octobre 2026 à 18 h"),
                     again("2026-10-16T18:00"), change("2026-10-16T18:00")] {
            #expect(try await start(next) == date("2026-10-22T18:00"), "\(next.arguments)")
        }
        for next in [change("demain à 18 h"), again("demain à 18 h")] {
            #expect(try await start(next, answer: "Demain à 18 h.") == date("2026-10-16T18:00"), "\(next.arguments)")
        }
        let noDay = "Ajoute un rendez-vous chez le coiffeur après le travail dans mon calendrier Perso."
        for next in [change("à 18 h"), again("à 18 h"), again("jeudi 15 octobre 2026 à 18 h")] {
            #expect(try await start(next, request: noDay) == date("2026-10-16T18:00"), "\(next.arguments)")
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
              filler: Bool = false, others: [any ToolProvider] = []) -> VoicePipeline
    {
        var config = PipelineConfig()
        config.toolCallFiller = filler
        return VoicePipeline(detector: LoudnessDetector(), transcriber: transcriber, model: model,
                             synthesizer: FakeSynthesizer(), output: speaker,
                             tools: ToolRunner(providers: [tools] + others), config: config)
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

    /// Two actions asked at once: the model writes the first call, then goes on to another one, which `MLXChatModel` does
    /// not write (`moreToolCalls`); another model may write both calls. The first is carried out, the app says it does
    /// one thing at a time, and the history keeps the first call and its result.
    @Test(arguments: [false, true])
    func oneActionPerTurnAndHistoryKeepsTheCall(bothCallsWritten: Bool) async throws {
        let then: ModelOutput = bothCallsWritten ? .toolCall(ToolCall(name: "noter", arguments: ["titre": "Lait"]))
            : .moreToolCalls
        let two = Self.note + [then]
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

    /// Two actions asked at once, the first one's result summed up by the model (a search's results, an agent's
    /// report): the turn still ends saying that the app does one thing at a time, once, after the model's summary or
    /// after the app's own sentence when the model says nothing. The history keeps the call, its result and what the
    /// user heard.
    @Test(arguments: [true, false])
    func oneActionPerTurnWhenTheFirstIsSummedUp(modelSums: Bool) async throws {
        let ask: [ModelOutput] = [.toolCallStarted,
                                  .toolCall(ToolCall(name: "chercher", arguments: ["requete": "météo demain Paris"])),
                                  .moreToolCalls]
        let summary: [ModelOutput] = modelSums ? [.text("Demain, il fera beau à Paris.")] : []
        let thanks: [ModelOutput] = [.text("Avec plaisir, à ton service.")]
        let (model, speaker, tools, search) = (ScriptedModel(scripts: [ask, summary, thanks]), FakeSpeaker(),
                                               RecordingTools(), SummedSearch())
        let pipeline = make(model, ScriptedTranscriber(["Cherche la météo de demain à Paris et mets un minuteur",
                                                        "Merci beaucoup"]),
                            speaker, tools, others: [search])
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.finished.count == 1 }
        #expect(await search.queries == ["météo demain Paris"])
        #expect(await model.requests.count == 2)
        let oneThing = ActionPhrases.oneThingAtATime(.french)
        let summed = modelSums ? "Demain, il fera beau à Paris." : SummedSearch.fallback
        let heard = await log.pieces.joined(separator: " ")
        #expect(heard == summed + " " + oneThing)
        #expect(heard.components(separatedBy: oneThing).count == 2)  // said once
        #expect(await log.finished.first?.assistantText == summed + " " + oneThing)
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await model.requests.count == 3 }
        let history = try #require(await model.requests.last)
        #expect(history.map(\.role) == [.system, .user, .assistant, .tool, .assistant, .user])
        #expect(history[2].toolCalls.first?.name == "chercher")
        #expect(history[3].toolResult == ["resultats": "Beau temps demain à Paris."])
        #expect(history[4].content == summed + " " + oneThing)
        #expect(await tools.performed.isEmpty)
    }

    /// Two actions asked at once, the first one refused for its arguments: the model's second try writes the corrected
    /// call alone. It is carried out, and the app still says, once, that it does one thing at a time.
    @Test func oneActionPerTurnAfterASecondTry() async throws {
        let bad: [ModelOutput] = [.toolCall(ToolCall(name: "noter")), .moreToolCalls]
        let thanks: [ModelOutput] = [.text("Avec plaisir, à ton service.")]
        let (model, speaker, tools) = (ScriptedModel(scripts: [bad, Self.note, thanks]), FakeSpeaker(), RecordingTools())
        let pipeline = make(model, ScriptedTranscriber(["Note le pain et mets un minuteur", "Merci beaucoup"]), speaker,
                            tools)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.finished.count == 1 }
        #expect(await model.requests.count == 2)
        #expect(await tools.performed.map { $0.text("titre") } == ["Pain"])
        let oneThing = ActionPhrases.oneThingAtATime(.french)
        let heard = await log.pieces.joined(separator: " ")
        #expect(heard == "C’est noté\(nb): Pain. " + oneThing)
        #expect(heard.components(separatedBy: oneThing).count == 2)  // said once
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await model.requests.count == 3 }
        // The turn as the model then sees it: the refused call, why, the corrected call, its result, what was said.
        let history = try #require(await model.requests.last)
        #expect(history.map(\.role) == [.system, .user, .assistant, .tool, .assistant, .tool, .assistant, .user])
        #expect(history[6].content == "C’est noté\(nb): Pain. " + oneThing)
    }

    /// Two actions asked at once, the first one refused for its arguments, and the model's second try writes no call:
    /// after the app's question (or what the model says itself), the user also hears that the app does one thing at a
    /// time, since the second action was not done either.
    @Test(arguments: ["", "Que veux-tu que je note ?"])
    func oneActionPerTurnWhenTheSecondTryWritesNoCall(says text: String) async throws {
        let bad: [ModelOutput] = [.toolCall(ToolCall(name: "noter")), .moreToolCalls]
        let secondTry: [ModelOutput] = text.isEmpty ? [] : [.text(text)]
        let (model, speaker, tools) = (ScriptedModel(scripts: [bad, secondTry]), FakeSpeaker(), RecordingTools())
        let pipeline = make(model, ScriptedTranscriber(["Note et mets un minuteur"]), speaker, tools)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.finished.count == 1 }
        #expect(await model.requests.count == 2)
        let answer = text.isEmpty ? ActionPhrases.missingTitle(.french) : text
        #expect(await log.pieces.joined(separator: " ") == answer + " " + ActionPhrases.oneThingAtATime(.french))
        #expect(await tools.performed.isEmpty)
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
        // The question is two sentences, so two pieces, and the recorder reads the events on its own task: wait for
        // the turn to be over, not for its first piece.
        await waitFor { await log.finished.count == 1 }
        #expect(await model.requests.count == 2)
        let second = try #require(await model.requests.last)
        #expect(second.suffix(2).map(\.role) == [.assistant, .tool])  // the model sees why it was refused
        #expect(second.last?.toolResult == ["erreur": .string("Il manque « titre ». " + ToolRefusal.secondTry("noter"))])
        #expect(await log.pieces.joined(separator: " ") == ActionPhrases.missingTitle(.french))
        #expect(await tools.performed.isEmpty)
    }

    /// The second try after a refused call writes no call. When it says nothing at all (the model ends its answer at
    /// once), the user hears the app's question for the refusal rather than silence, after the waiting phrase if there
    /// was one, and the history keeps that question as the answer. What the model says itself is left as it is.
    @Test(arguments: ["", "Que veux-tu que je note ?"], [false, true])
    func secondTryWithoutACall(says text: String, filler: Bool) async throws {
        let bad: [ModelOutput] = [.toolCallStarted, .toolCall(ToolCall(name: "noter"))]
        let secondTry: [ModelOutput] = text.isEmpty ? [] : [.text(text)]
        let thanks: [ModelOutput] = [.text("Avec plaisir, à ton service.")]
        let (model, speaker, tools) = (ScriptedModel(scripts: [bad, secondTry, thanks]), FakeSpeaker(),
                                       RecordingTools())
        let pipeline = make(model, ScriptedTranscriber(["Note", "Merci"]), speaker, tools, filler: filler)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.finished.count == 1 }
        #expect(await model.requests.count == 2)
        let answer = text.isEmpty ? ActionPhrases.missingTitle(.french) : text
        let heard = (filler ? [ActionPhrases.oneMoment(.french)] : []) + [answer]
        #expect(await log.pieces.joined(separator: " ") == heard.joined(separator: " "))
        #expect(await log.finished.first?.assistantText == answer)
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await model.requests.count == 3 }
        // The first turn as the model then sees it: its call, why it was refused, and what the user heard.
        let history = try #require(await model.requests.last)
        #expect(history.map(\.role) == [.system, .user, .assistant, .tool, .assistant, .user])
        #expect(history[4].content == answer)
        #expect(await tools.performed.isEmpty)
    }

    /// A moment already gone: the app asks the user for another one at once (a second try could only make one up), and
    /// the call stays in the history, so the model still has the event when the user gives that moment.
    @Test func pastMomentIsAskedToTheUserWithTheCallKept() async throws {
        func event(_ when: String) -> [ModelOutput] {
            [.toolCall(ToolCall(name: "creer_evenement", arguments: ["titre": "Dentiste", "quand": .string(when)]))]
        }
        let (model, speaker, calendar) = (ScriptedModel(scripts: [event("hier à 15 h"), event("demain à 16 h")]),
                                          FakeSpeaker(), CheckedCalendar())
        var config = PipelineConfig()
        config.toolCallFiller = false
        let pipeline = VoicePipeline(detector: LoudnessDetector(),
                                     transcriber: ScriptedTranscriber(["Ajoute le dentiste hier à 15 h", "Demain à 16 h"]),
                                     model: model, synthesizer: FakeSynthesizer(), output: speaker,
                                     tools: ToolRunner(providers: [calendar]), config: config)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.finished.count == 1 }  // the question is two pieces: wait for the turn to be over
        #expect(await log.pieces.joined(separator: " ") == ActionPhrases.datePassed(.french))
        #expect(await model.requests.count == 1)  // no second try
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await calendar.created.count == 1 }
        #expect(await calendar.created.first?.arguments["quand"] == "demain à 16 h")
        // The first turn as the model then sees it: its call, why it was refused, and the app's question.
        let turn = Array(try #require(await model.requests.last).suffix(5))
        #expect(turn.map(\.role) == [.user, .assistant, .tool, .assistant, .user])
        #expect(turn[1].toolCalls.first?.arguments["titre"] == "Dentiste")
        guard case .object(let result)? = turn[2].toolResult else { Issue.record("no result"); return }
        #expect(result["erreur"]?.text?.contains("déjà passé") == true)
        // No second try: the refusal's own words.
        #expect(result["erreur"]?.text?.contains(ToolRefusal.secondTry("creer_evenement")) == false)
        #expect(turn[3].content == ActionPhrases.datePassed(.french))
    }

    @Test func cancelIsHandledWithoutTheModel() async throws {
        let (model, speaker, tools) = (ScriptedModel(scripts: [Self.note]), FakeSpeaker(), RecordingTools())
        let pipeline = make(model, ScriptedTranscriber(["Rappelle-moi le pain", "Annule."]), speaker, tools)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await tools.performed.count == 1 }
        // The recorder reads the events on its own task: without this, its first state (at rest) could pass for the
        // end of the turn, and « Annule. » would come while the confirmation is still said.
        await waitFor { await log.finished.count == 1 }
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await tools.undone.count == 1 }
        #expect(await tools.undone == ["n1"])
        #expect(await model.requests.count == 1)  // "annule" never reached the model
    }

    /// A calendar that does not exist: the creation is refused when it is carried out, and the model's second try asks
    /// about it. To « Mets-la dans Maison alors. », the model takes the meeting for saved and writes a change of the
    /// last item with « calendrier : Maison », as Gemma 4 26B did in 6 to 9 runs of 10: the meeting is created in that
    /// calendar, at the refused call's moment, and the model reads the change's result as the saved meeting.
    @Test func changeAfterACalendarRefusedCreatesTheEventThere() async throws {
        let meeting = ToolCall(name: "creer_evenement",
                               arguments: ["titre": "Réunion", "quand": "demain à 10 h", "calendrier": "Travail"])
        let question = "Je ne trouve pas ton calendrier Travail. Je la mets dans Maison\(nb)?"
        let change = ToolCall(name: "modifier_element", arguments: ["reference": "dernier", "calendrier": "Maison"])
        let thanks: [ModelOutput] = [.text("Avec plaisir, à ton service.")]
        let model = ScriptedModel(scripts: [[.toolCall(meeting)], [.text(question)], [.toolCall(change)], thanks])
        let (speaker, calendar) = (FakeSpeaker(), CheckedCalendar())
        var config = PipelineConfig()
        config.toolCallFiller = false
        let sentences = ["Ajoute une réunion demain à 10 h dans mon calendrier Travail.", "Mets-la dans Maison alors.",
                         "Merci"]
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: ScriptedTranscriber(sentences),
                                     model: model, synthesizer: FakeSynthesizer(), output: speaker,
                                     tools: ToolRunner(providers: [calendar]), config: config)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.finished.count == 1 }
        #expect(await calendar.created.isEmpty)
        #expect(await model.requests.count == 2)  // the refused call, then the second try
        #expect(await log.pieces.joined(separator: " ") == question)
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.finished.count == 2 }
        #expect(await calendar.created == [ToolCall(name: "creer_evenement", arguments: [
            "titre": "Réunion", "quand": "demain à 10 h", "calendrier": "Maison"])])
        #expect(await model.requests.count == 3)  // carried out: no second try
        #expect(await log.pieces.last == "C’est dans ton agenda\(nb): Réunion.")
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await model.requests.count == 4 }
        // The second turn as the model then sees it: its change, and the meeting saved.
        let turn = Array(try #require(await model.requests.last).suffix(5))
        #expect(turn.map(\.role) == [.user, .assistant, .tool, .assistant, .user])
        #expect(turn[1].toolCalls == [change])
        #expect(turn[2].toolResult == ["id": "e1"])
        #expect(turn[3].content == "C’est dans ton agenda\(nb): Réunion.")
    }

    /// A meeting saved in the default calendar, then « Mets-la dans mon calendrier Maison. », the calendar it is in: the
    /// model's change changes nothing, and the app says at once where the meeting is, without a second try (Gemma 4 26B's
    /// said « C'est fait. La réunion est maintenant dans ton calendrier test temp. »). The model then reads, in the
    /// history, that its call changed nothing, and what the user heard.
    @Test func changeIntoItsOwnCalendarIsAnsweredByTheApp() async throws {
        let meeting = ToolCall(name: "creer_evenement", arguments: ["titre": "Réunion", "quand": "demain à 10 h"])
        let change = ToolCall(name: "modifier_element", arguments: ["reference": "e1", "calendrier": "maison"])
        let thanks: [ModelOutput] = [.text("Avec plaisir, à ton service.")]
        let model = ScriptedModel(scripts: [[.toolCall(meeting)], [.toolCall(change)], thanks])
        let (speaker, calendar) = (FakeSpeaker(), MemoryCalendar())
        var config = PipelineConfig()
        config.toolCallFiller = false
        let sentences = ["Ajoute une réunion demain à 10 h.", "Mets-la dans mon calendrier Maison.", "Merci"]
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: ScriptedTranscriber(sentences),
                                     model: model, synthesizer: FakeSynthesizer(), output: speaker,
                                     tools: ToolRunner(providers: [calendar]), config: config)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.finished.count == 1 }
        #expect(await calendar.creations == ["e1"])
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.finished.count == 2 }
        #expect(await model.requests.count == 2)  // no second try
        let answer = try #require(await log.finished.last?.assistantText)
        #expect(answer.hasPrefix("C’est déjà dans ton calendrier «\(nb)Maison\(nb)»\(nb): Réunion, "))
        #expect(!answer.contains("fait") && !answer.contains("modifié") && !answer.contains("déplacé"))
        #expect(await calendar.touched.isEmpty)
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await model.requests.count == 3 }
        // The second turn as the model then sees it: its change, why it changed nothing, and the app's sentence.
        let turn = Array(try #require(await model.requests.last).suffix(5))
        #expect(turn.map(\.role) == [.user, .assistant, .tool, .assistant, .user])
        #expect(turn[1].toolCalls == [change])
        guard case .object(let result)? = turn[2].toolResult else { Issue.record("no result"); return }
        #expect(result["erreur"]?.text?.hasPrefix("Cet appel ne change rien : « e1 » est déjà comme il le demande.") == true)
        #expect(result["erreur"]?.text?.contains(ToolRefusal.secondTry("modifier_element")) == false)
        #expect(turn[3].content == answer)
    }

    /// The same request answered with the meeting's creation written again, as Gemma 4 E4B wrote it in 8 runs of 10 of
    /// voice-cli dialogue-bench: the meeting is not saved a second time, the app says at once where it is, without
    /// another pass of the model, and the model then reads, in the history, the meeting it already has as its call's
    /// result, and what the user heard.
    @Test func creationOfAnItemAlreadyThereIsAnsweredByTheApp() async throws {
        let meeting = ToolCall(name: "creer_evenement", arguments: ["titre": "Réunion", "quand": "demain à 10 h"])
        let again = ToolCall(name: "creer_evenement",
                             arguments: ["titre": "réunion", "quand": "demain à 10 h", "calendrier": "maison"])
        let thanks: [ModelOutput] = [.text("Avec plaisir, à ton service.")]
        let model = ScriptedModel(scripts: [[.toolCall(meeting)], [.toolCall(again)], thanks])
        let (speaker, calendar) = (FakeSpeaker(), MemoryCalendar())
        var config = PipelineConfig()
        config.toolCallFiller = false
        let sentences = ["Ajoute une réunion demain à 10 h.", "Mets-la dans mon calendrier Maison.", "Merci"]
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: ScriptedTranscriber(sentences),
                                     model: model, synthesizer: FakeSynthesizer(), output: speaker,
                                     tools: ToolRunner(providers: [calendar]), config: config)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.finished.count == 1 }
        let created = try #require(await log.finished.last?.assistantText)
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.finished.count == 2 }
        #expect(await calendar.creations == ["e1"])  // not saved again
        #expect(await model.requests.count == 2)  // no other pass
        let answer = try #require(await log.finished.last?.assistantText)
        #expect(answer.hasPrefix("C’est déjà dans ton calendrier «\(nb)Maison\(nb)»\(nb): Réunion, "))
        #expect(answer.dropFirst("C’est déjà dans ton calendrier «\(nb)Maison\(nb)»".count)
                == created.dropFirst("C’est dans ton calendrier «\(nb)Maison\(nb)»".count))  // the same meeting
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await model.requests.count == 3 }
        // The second turn as the model then sees it: its creation, the meeting it already has, the app's sentence.
        let turn = Array(try #require(await model.requests.last).suffix(5))
        #expect(turn.map(\.role) == [.user, .assistant, .tool, .assistant, .user])
        #expect(turn[1].toolCalls == [again])
        #expect(turn[2].toolResult?["id"] == "e1" && turn[2].toolResult?["calendrier"] == "Maison")
        #expect(turn[2].toolResult?["statut"] == .string(ActionCatalog.alreadyCreated))
        #expect(turn[3].content == answer)
    }

    /// On a tier whose change offers no calendar (Gemma 4 E4B's, E2B's), « Mets la réunion dans mon calendrier Maison. »
    /// answered with the meeting as it is, as E4B wrote it: the meeting is moved to « Maison », the calendar the user's
    /// sentence of this turn names, at once.
    @Test func changeThatLeavesTheCalendarOutMovesItWhereTheUserSays() async throws {
        let meeting = ToolCall(name: "creer_evenement", arguments: ["titre": "réunion", "quand": "demain à 10 h"])
        let change = ToolCall(name: "modifier_element",
                              arguments: ["reference": "e1", "titre": "réunion", "quand": "demain à 10 h"])
        let model = ScriptedModel(scripts: [[.toolCall(meeting)], [.toolCall(change)]])
        let (speaker, calendar) = (FakeSpeaker(), MemoryCalendar(movingItems: false))
        await calendar.use(calendars: ["Travail", "Maison"], lists: nil)
        var config = PipelineConfig()
        config.toolCallFiller = false
        let sentences = ["Ajoute une réunion demain à 10 h.", "Mets la réunion dans mon calendrier Maison."]
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: ScriptedTranscriber(sentences),
                                     model: model, synthesizer: FakeSynthesizer(), output: speaker,
                                     tools: ToolRunner(providers: [calendar]), config: config)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.finished.count == 1 }
        let created = try #require(await log.finished.last?.assistantText)
        #expect(created.hasPrefix("C’est dans ton calendrier «\(nb)Travail\(nb)»\(nb): réunion, "))
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.finished.count == 2 }
        #expect(await model.requests.count == 2)  // no second try
        let answer = try #require(await log.finished.last?.assistantText)
        #expect(answer.hasPrefix("C’est déplacé dans ton calendrier «\(nb)Maison\(nb)»\(nb): réunion, "))
        #expect(await calendar.touched == ["réunion"])
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

    /// The iPhone that has the conversation lost its connection: the timer waits for it to be back.
    @Test func timerAnnouncementWaitsForTheVoiceToBeHeard() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(), model: model,
                                     synthesizer: FakeSynthesizer(), output: speaker)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await pipeline.setOutputReachable(false)
        await pipeline.announce("Ton minuteur de 10 minutes est terminé.", note: "(Le minuteur a sonné.)",
                                language: .french)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await speaker.played == 0)
        #expect(await log.pieces.isEmpty)
        await waitFor { await !log.states.isEmpty }  // the recorder reads the events on its own task
        #expect(await log.states == [.listening])
        await pipeline.setOutputReachable(true)  // it is back: the chime, then the sentence
        await waitFor { await log.pieces.contains("Ton minuteur de 10 minutes est terminé.") }
        await waitFor { await speaker.played >= Chime.samples(sampleRate: 1000).count + 500 }
        #expect(await speaker.played == Chime.samples(sampleRate: 1000).count + 500)
    }
}

// MARK: - Changes: another calendar or list, and changes that change nothing

@Suite("Changes")
struct ChangeTests {
    /// A meeting in « Travail », tomorrow from 10 h to 11 h.
    let meeting = ActionCatalog.SavedItem(isEvent: true, title: "Réunion", date: date("2026-10-16T10:00"),
                                          end: date("2026-10-16T11:00"), hasTime: true, collection: "Travail")
    let bread = ActionCatalog.SavedItem(isEvent: false, title: "Acheter du pain", date: date("2026-10-16T10:00"),
                                        hasTime: true, collection: "Rappels")

    func change(_ arguments: [String: JSONValue]) -> ToolCall {
        var all: [String: JSONValue] = ["reference": "e1"]
        all.merge(arguments) { $1 }
        return ToolCall(name: "modifier_element", arguments: all)
    }

    /// What `ActionCatalog.changed` refuses of a change; nil when it changes something.
    func refusal(_ item: ActionCatalog.SavedItem, _ arguments: [String: JSONValue], collection: String? = nil,
                 collectionName: String? = nil, _ language: SpeechLanguage = .french) -> ToolRefusal?
    {
        do {
            _ = try ActionCatalog.changed(item, by: change(arguments), collection: collection,
                                          collectionName: collectionName, reference: "e1", context: context(language))
            return nil
        } catch {
            return error as? ToolRefusal
        }
    }

    /// As for a creation: by its name, whatever the case and accents, else a name that contains it or that it contains;
    /// the item's own first, when it fits as well. Either word, for either kind of item.
    @Test func calendarsAndListsAreFoundByName() {
        let names = ["Travail", "Maison", "Maison de campagne"]
        #expect(ActionCatalog.collectionIndex(named: "maison", among: names) == 1)
        #expect(ActionCatalog.collectionIndex(named: "Ma maison", among: ["Travail", "Maison"]) == 1)
        #expect(ActionCatalog.collectionIndex(named: "campagne", among: names) == 2)
        #expect(ActionCatalog.collectionIndex(named: "Famille", among: names) == nil)
        #expect(ActionCatalog.collectionIndex(named: " ", among: names) == nil)
        // Two of the same name (in two accounts): the item's own, which it then stays in.
        #expect(ActionCatalog.collectionIndex(named: "Maison", among: ["Maison", "Travail", "Maison"], current: 2) == 2)
        #expect(ActionCatalog.collectionIndex(named: "Maison", among: ["Maison", "Travail", "Maison"]) == 0)
        // Its own fitting less well does not win.
        #expect(ActionCatalog.collectionIndex(named: "Maison", among: names, current: 2) == 1)
        let calendar = ActionCatalog.unknownCollection("Famille", event: true, names: ["Travail", "Maison"],
                                                       context: context())
        #expect(calendar.forModel == "Aucun calendrier modifiable ne s'appelle « Famille ». Calendriers : Travail, Maison.")
        #expect(calendar.retryable && calendar.spoken == ActionPhrases.unknownCalendar("Famille", .french))
        let list = ActionCatalog.unknownCollection("Courses", event: false, names: ["Rappels"], context: context())
        #expect(list.forModel == "Aucune liste de rappels ne s'appelle « Courses ». Listes : Rappels.")
        #expect(list.spoken == ActionPhrases.unknownList("Courses", .french))
        #expect(ActionCatalog.collectionNamed(in: change(["calendrier": "Maison"]), event: true) == "Maison")
        #expect(ActionCatalog.collectionNamed(in: change(["liste": "Maison"]), event: true) == "Maison")
        #expect(ActionCatalog.collectionNamed(in: change(["calendrier": "Courses"]), event: false) == "Courses")
        #expect(ActionCatalog.collectionNamed(in: change(["quand": "à 11 h"]), event: false) == nil)
    }

    /// The calendar and the list are offered on Gemma 4 26B's tiers only; the smaller ones keep the tool without them.
    @Test func onlyTheLargerModelsAreOfferedTheMove() {
        func change(on tier: HardwareTier) -> ToolSpec? {
            ActionCatalog.calendarTools(on: tier).first { $0.name == ActionCatalog.changeItem.name }
        }
        for tier in [HardwareTier.comfort, .max] {
            let parameters = change(on: tier)?.parameters.map(\.name) ?? []
            #expect(ActionCatalog.movesItems(on: tier) && parameters.contains("calendrier") && parameters.contains("liste"))
            #expect(change(on: tier) == ActionCatalog.changeItemMoving)
        }
        for tier in [HardwareTier.minimum, .standard] {
            let parameters = change(on: tier)?.parameters.map(\.name) ?? []
            #expect(!ActionCatalog.movesItems(on: tier) && !parameters.contains("calendrier") && !parameters.contains("liste"))
            #expect(change(on: tier) == ActionCatalog.changeItem)
        }
        // The same tools otherwise, in the same order.
        #expect(ActionCatalog.calendarTools(on: .minimum).map(\.name) == ActionCatalog.calendarTools(on: .comfort).map(\.name))
    }

    /// Alone or with the rest, and said as a move to that calendar or list.
    @Test func changeMovesToAnotherCalendarOrList() throws {
        let moved = try ActionCatalog.changed(meeting, by: change(["calendrier": "Maison"]), collection: "Maison",
                                              reference: "e1", context: context())
        var inHome = meeting
        inHome.collection = "Maison"
        #expect(moved == inHome && !moved.moved(from: meeting))
        let later = try ActionCatalog.changed(meeting, by: change(["calendrier": "Maison", "quand": "à 11 h"]),
                                              collection: "Maison", reference: "e1", context: context())
        #expect(later.collection == "Maison" && later.date == date("2026-10-16T11:00")
                && later.end == date("2026-10-16T12:00") && later.moved(from: meeting))
        let groceries = try ActionCatalog.changed(bread, by: change(["liste": "Courses"]), collection: "Courses",
                                                  reference: "r1", context: context())
        var inGroceries = bread
        inGroceries.collection = "Courses"
        #expect(groceries == inGroceries)
        #expect(ActionPhrases.eventChanged(title: "Réunion", start: date("2026-10-16T10:00"), end: date("2026-10-16T11:00"),
                                           allDay: false, moved: false, calendarName: "Maison", context())
                == "C’est déplacé dans ton calendrier «\(nb)Maison\(nb)»\(nb): Réunion, vendredi 16 octobre de 10\(nb)h à 11\(nb)h.")
        #expect(ActionPhrases.reminderChanged(title: "Acheter du pain", due: nil, hasTime: false, moved: false,
                                              listName: "Courses", context())
                == "C’est déplacé dans ta liste «\(nb)Courses\(nb)»\(nb): Acheter du pain.")
        #expect(ActionPhrases.eventChanged(title: "Meeting", start: date("2026-10-16T10:00"), end: date("2026-10-16T11:00"),
                                           allDay: false, moved: false, calendarName: "Home", context(.english))
                .hasPrefix("Moved to your “Home” calendar: Meeting, "))
        // Without a calendar, as before.
        #expect(ActionPhrases.eventChanged(title: "Réunion", start: date("2026-10-16T10:00"), end: date("2026-10-16T11:00"),
                                           allDay: false, moved: false, context()).hasPrefix("C’est modifié\(nb): Réunion"))
    }

    /// What it gives is already the item's, or does not apply to it: refused, never « C'est modifié », and answered by
    /// the app at once, without a second try: where the item is when the call names its own calendar or list, else that
    /// nothing was changed and what can be. The model reads why in the history. Given nothing to change, it is refused by
    /// the check, and answered the same way.
    @Test func changeThatChangesNothingIsAnsweredByTheApp() throws {
        let inWork = try #require(refusal(meeting, ["calendrier": "Travail"], collection: "Travail"))
        #expect(!inWork.retryable)
        #expect(inWork.forModel == "Cet appel ne change rien : « e1 » est déjà comme il le demande. On peut changer son "
                + "titre (titre), son moment (quand), sa durée (duree), son lieu (lieu) ou son calendrier (calendrier).")
        #expect(inWork.spoken
                == "C’est déjà dans ton calendrier «\(nb)Travail\(nb)»\(nb): Réunion, vendredi 16 octobre de 10\(nb)h à 11\(nb)h.")
        // The history keeps why, without the request for another call.
        #expect(inWork.result(for: change(["calendrier": "Travail"])) == ["erreur": .string(inWork.forModel)])
        // Found as the provider tells calendars apart (EventKit's identifier), said by its name.
        var inAnAccount = meeting
        inAnAccount.collection = "5E1C9A0B-calendar"
        #expect(refusal(inAnAccount, ["calendrier": "travail"], collection: inAnAccount.collection,
                        collectionName: "Travail")?.spoken == inWork.spoken)
        // With other things the item already is: the same.
        #expect(refusal(meeting, ["calendrier": "Travail", "titre": "Réunion", "quand": "demain à 10 h"],
                        collection: "Travail")?.spoken == inWork.spoken)
        #expect(refusal(meeting, ["calendrier": "Travail"], collection: "Travail", .english)?.spoken
                == "It’s already in your “Travail” calendar: Réunion, Friday, October 16 from 10\(nb)AM to 11\(nb)AM.")
        // Only its title or its moment, as they are: nothing was changed, and what can be.
        for arguments: [String: JSONValue] in [["titre": "Réunion"], ["quand": "à 10 h"],
                                               ["quand": "demain à 10 h", "duree": "une heure"],
                                               ["titre": "Réunion", "quand": "vendredi à 10 h"]] {
            let same = try #require(refusal(meeting, arguments), "\(arguments)")
            #expect(!same.retryable && same.spoken == ActionPhrases.nothingChanged(event: true, .french), "\(arguments)")
            #expect(same.forModel.hasPrefix("Cet appel ne change rien : « e1 » est déjà comme il le demande."),
                    "\(arguments)")
        }
        #expect(refusal(meeting, ["titre": "Réunion d'équipe"]) == nil)
        #expect(refusal(meeting, ["lieu": "Salle 3"]) == nil)
        #expect(refusal(meeting, ["calendrier": "Maison"], collection: "Maison") == nil)
        // A reminder in its own list; a reminder has no place nor length; already due then.
        let inReminders = try #require(refusal(bread, ["liste": "rappels"], collection: "Rappels"))
        #expect(!inReminders.retryable)
        #expect(inReminders.spoken
                == "C’est déjà dans ta liste «\(nb)Rappels\(nb)»\(nb): Acheter du pain, vendredi 16 octobre à 10\(nb)h.")
        #expect(inReminders.forModel.hasSuffix("On peut changer son titre (titre), son moment (quand) ou sa liste (liste)."))
        var undated = bread
        undated.date = nil
        undated.hasTime = false
        #expect(refusal(undated, ["calendrier": "Rappels"], collection: "Rappels")?.spoken
                == "C’est déjà dans ta liste «\(nb)Rappels\(nb)»\(nb): Acheter du pain.")
        #expect(refusal(undated, ["liste": "Rappels"], collection: "Rappels", .english)?.spoken
                == "It’s already in your “Rappels” list: Acheter du pain.")
        let place = try #require(refusal(bread, ["lieu": "Boulangerie"]))
        #expect(!place.retryable && place.spoken == ActionPhrases.nothingChanged(event: false, .french))
        #expect(refusal(bread, ["duree": "une heure"])?.spoken == ActionPhrases.nothingChanged(event: false, .french))
        #expect(refusal(bread, ["quand": "demain à 10 h"])?.spoken == ActionPhrases.nothingChanged(event: false, .french))
        #expect(refusal(bread, ["quand": "demain à 11 h"]) == nil)
        for arguments: [String: JSONValue] in [["reference": "e1"], ["reference": "dernier", "titre": " "],
                                               ["reference": "e1", "journee_entiere": true]] {
            let empty = try #require(checkRefusal(ToolCall(name: "modifier_element", arguments: arguments)), "\(arguments)")
            #expect(!empty.retryable && empty.spoken == ActionPhrases.nothingChanged(event: nil, .french), "\(arguments)")
            #expect(empty.forModel.hasPrefix("Cet appel ne change rien. On peut changer"), "\(arguments)")
        }
        #expect(checkRefusal(ToolCall(name: "modifier_element", arguments: ["reference": "e1", "duree_minutes": 90])) == nil)
        #expect(checkRefusal(ToolCall(name: "modifier_element", arguments: ["reference": "e1", "liste": "Courses"])) == nil)
        for language in SpeechLanguage.allCases {
            var sentences = ([true, false, nil] as [Bool?]).map { ActionPhrases.nothingChanged(event: $0, language) }
            sentences += [refusal(meeting, ["calendrier": "Travail"], collection: "Travail", language),
                          refusal(undated, ["liste": "Rappels"], collection: "Rappels", language)].compactMap { $0?.spoken }
            #expect(sentences.count == 5)
            for sentence in sentences {
                #expect(!sentence.contains("modifié") && !sentence.contains("Changed"), "\(sentence)")
                #expect(ActionPhrases.wordCount(SpeakableText.forVoice(sentence, language: language)) >= 5, "\(sentence)")
            }
        }
    }

    /// voice-cli's calendar in memory, as the app's (through the runner, as dialogue-bench uses it): a meeting created in
    /// the default calendar, then moved to another by name, then « annule »: back where it was. A calendar that does not
    /// exist is refused with a second try, a change that changes nothing is answered by the app at once (as by
    /// `CalendarTools`: `ActionCatalog.changed`), and both leave it as it was. The same for a reminder and its list.
    @Test func memoryCalendarMovesAndUndoesTheMove() async throws {
        let calendar = MemoryCalendar()
        await calendar.use(calendars: ["Travail", "Maison"], lists: ["Rappels", "Courses"])
        let runner = ToolRunner(providers: [calendar])
        _ = await runner.tools()
        let meeting = ToolCall(name: "creer_evenement", arguments: ["titre": "Réunion", "quand": "demain à 10 h"])
        let created = await runner.handle(meeting, context: context())
        #expect(created.forModel["calendrier"] == "Travail")
        #expect(created.spoken
                == "C’est dans ton calendrier «\(nb)Travail\(nb)»\(nb): Réunion, vendredi 16 octobre de 10\(nb)h à 11\(nb)h.")
        let unknown = await runner.handle(change(["reference": "dernier", "calendrier": "Famille"]), context: context())
        #expect(unknown.retryable && unknown.spoken == ActionPhrases.unknownCalendar("Famille", .french))
        let same = await runner.handle(change(["calendrier": "travail"]), context: context())
        #expect(!same.retryable && same.refusal != nil)
        #expect(same.spoken
                == "C’est déjà dans ton calendrier «\(nb)Travail\(nb)»\(nb): Réunion, vendredi 16 octobre de 10\(nb)h à 11\(nb)h.")
        #expect(same.forModel["erreur"]?.text?.hasPrefix("Cet appel ne change rien : « e1 » est déjà") == true)
        #expect(same.forModel["erreur"]?.text?.contains(ToolRefusal.secondTry("modifier_element")) == false)
        for arguments: [String: JSONValue] in [["titre": "Réunion"], ["reference": "dernier", "quand": "demain à 10 h"]] {
            let unchanged = await runner.handle(change(arguments), context: context())
            #expect(!unchanged.retryable && unchanged.spoken == ActionPhrases.nothingChanged(event: true, .french),
                    "\(arguments)")
        }
        let nothing = await runner.handle(change([:]), context: context())
        #expect(!nothing.retryable && nothing.spoken == ActionPhrases.nothingChanged(event: nil, .french))
        #expect(await calendar.touched.isEmpty)  // none of them changed it

        let moved = await runner.handle(change(["calendrier": "maison"]), context: context())
        #expect(!moved.retryable)
        #expect(moved.spoken
                == "C’est déplacé dans ton calendrier «\(nb)Maison\(nb)»\(nb): Réunion, vendredi 16 octobre de 10\(nb)h à 11\(nb)h.")
        #expect(moved.forModel["calendrier"] == "Maison" && moved.forModel["debut"] == "2026-10-16T10:00")
        let at = now.addingTimeInterval(30)
        #expect(await runner.interception(for: "Annule", now: at) == .undo)
        #expect(await runner.resolve(.undo, context: context(at: at))?.spoken == ActionPhrases.undone(.change, .french))
        let renamed = await runner.handle(change(["titre": "Réunion d'équipe"]), context: context())
        #expect(renamed.forModel["calendrier"] == "Travail" && renamed.forModel["titre"] == "Réunion d'équipe")
        #expect(renamed.spoken.hasPrefix("C’est modifié\(nb): Réunion d'équipe"))

        let reminder = ToolCall(name: "creer_rappel", arguments: ["titre": "Acheter du pain"])
        #expect(await runner.handle(reminder, context: context()).forModel["liste"] == "Rappels")
        let noList = await runner.handle(change(["reference": "r1", "liste": "Bricolage"]), context: context())
        #expect(noList.retryable && noList.spoken == ActionPhrases.unknownList("Bricolage", .french))
        let toGroceries = await runner.handle(change(["reference": "dernier", "calendrier": "Courses"]), context: context())
        #expect(toGroceries.spoken == "C’est déplacé dans ta liste «\(nb)Courses\(nb)»\(nb): Acheter du pain.")
        #expect(toGroceries.forModel["liste"] == "Courses")
        #expect(await runner.interception(for: "annule", now: at) == .undo)
        _ = await runner.resolve(.undo, context: context(at: at))
        let place = await runner.handle(change(["reference": "r1", "lieu": "Boulangerie"]), context: context())
        #expect(!place.retryable && place.spoken == ActionPhrases.nothingChanged(event: false, .french))
        let inReminders = await runner.handle(change(["reference": "r1", "liste": "Rappels"]), context: context())
        #expect(!inReminders.retryable
                && inReminders.spoken == "C’est déjà dans ta liste «\(nb)Rappels\(nb)»\(nb): Acheter du pain.")
        let back = await runner.handle(change(["reference": "r1", "quand": "demain à 9 h"]), context: context())
        #expect(back.forModel["liste"] == "Rappels")
        #expect(await calendar.touched == ["Réunion", "Réunion", "Acheter du pain", "Acheter du pain"])
    }

    /// voice-cli's calendar in memory, as dialogue-bench's « a Work calendar that does not exist »: the meeting refused
    /// for « Travail », then « Mets-la dans Maison alors. » and a change of the last item without the calendar (as
    /// Gemma 4 E4B wrote it on 2026-10-22), or the creation written again without it: the meeting, in « Maison », not
    /// refused again, nor in « Perso », the default calendar.
    @Test func memoryCalendarSavesTheRefusedMeetingWhereTheAnswerSays() async throws {
        let request = "Ajoute une réunion demain à 10 h dans mon calendrier Travail."
        let first = ToolContext(now: now, timeZone: paris, language: .french, userSaid: [request])
        let answer = ToolContext(now: now, timeZone: paris, language: .french,
                                 userSaid: ["Mets-la dans Maison alors.", request])
        let meeting = ToolCall(name: "creer_evenement",
                               arguments: ["calendrier": "Travail", "quand": "vendredi à 10 h", "titre": "réunion"])
        for next in [ToolCall(name: "modifier_element", arguments: ["reference": "dernier", "titre": "réunion"]),
                     ToolCall(name: "creer_evenement", arguments: ["quand": "vendredi à 10 h", "titre": "réunion"])] {
            let calendar = MemoryCalendar(movingItems: false)
            await calendar.use(calendars: ["Perso", "Maison"], lists: nil)
            let runner = ToolRunner(providers: [calendar])
            _ = await runner.tools()
            let refused = await runner.handle(meeting, context: first)
            #expect(refused.retryable && refused.spoken == ActionPhrases.unknownCalendar("Travail", .french))
            let made = await runner.handle(next, context: answer)
            #expect(made.forModel["calendrier"] == "Maison" && made.forModel["debut"] == "2026-10-16T10:00",
                    "\(next.name)")
            #expect(made.spoken.hasPrefix("C’est dans ton calendrier «\(nb)Maison\(nb)»\(nb): réunion"), "\(next.name)")
            #expect(await calendar.creations == ["e1"], "\(next.name)")
        }
    }

    /// voice-cli's calendar in memory, through the runner as dialogue-bench uses it, without the move in the tool (Gemma 4
    /// E4B's and E2B's tiers) or with it: a change that names no calendar and no list takes the one the user's sentence of
    /// this turn names, as if it named it (as `CalendarTools`: `ActionCatalog.withCollectionSaid(change:…)`). The meeting as
    /// it is, as E4B and E2B wrote it, to « Mets-la dans mon calendrier Travail. »: where it already is; to « Mets la
    /// réunion dans mon calendrier Maison. »: moved there, and « annule » puts it back. A change that gives nothing else is
    /// not refused by the check. The same for a reminder and a list. A sentence that names no calendar, or one that does
    /// not exist, an earlier sentence, none (one of several actions), a calendar for a reminder: what it gave before.
    @Test(arguments: [false, true])
    func memoryCalendarMovesAnItemWhereTheUserSays(movingItems: Bool) async throws {
        let calendar = MemoryCalendar(movingItems: movingItems)
        await calendar.use(calendars: ["Travail", "Maison"], lists: ["Rappels", "Courses"])
        let runner = ToolRunner(providers: [calendar])
        let tool = await runner.tools().first { $0.name == ActionCatalog.changeItem.name }
        #expect(tool == (movingItems ? ActionCatalog.changeItemMoving : ActionCatalog.changeItem))
        func said(_ sentences: String...) -> ToolContext {
            ToolContext(now: now, timeZone: paris, language: .french, userSaid: sentences)
        }
        let request = "Ajoute une réunion demain à 10 h."
        let meeting = ToolCall(name: "creer_evenement", arguments: ["titre": "Réunion", "quand": "demain à 10 h"])
        #expect(await runner.handle(meeting, context: said(request)).forModel["calendrier"] == "Travail")
        let asItIs = change(["titre": "Réunion", "quand": "vendredi à 10 h"])
        let own = await runner.handle(asItIs, context: said("Mets-la dans mon calendrier Travail.", request))
        #expect(!own.retryable && own.refusal != nil)
        #expect(own.spoken
                == "C’est déjà dans ton calendrier «\(nb)Travail\(nb)»\(nb): Réunion, vendredi 16 octobre de 10\(nb)h à 11\(nb)h.")
        #expect(own.forModel["erreur"]?.text?.hasPrefix("Cet appel ne change rien : « e1 » est déjà") == true)
        for context in [said("Change la réunion.", request), said("Mets la réunion dans mon calendrier Famille.", request),
                        said("La réunion de demain à 10 h.", "Mets la réunion dans mon calendrier Maison."), said()] {
            let unchanged = await runner.handle(asItIs, context: context)
            #expect(!unchanged.retryable && unchanged.spoken == ActionPhrases.nothingChanged(event: true, .french),
                    "\(context.userSaid)")
        }
        let nothing = await runner.handle(change([:]), context: said("Change la réunion.", request))
        #expect(!nothing.retryable && nothing.spoken == ActionPhrases.nothingChanged(event: nil, .french))
        #expect(await calendar.touched.isEmpty)

        let moved = await runner.handle(asItIs, context: said("Mets la réunion dans mon calendrier Maison.", request))
        #expect(moved.refusal == nil)
        #expect(moved.spoken
                == "C’est déplacé dans ton calendrier «\(nb)Maison\(nb)»\(nb): Réunion, vendredi 16 octobre de 10\(nb)h à 11\(nb)h.")
        #expect(moved.forModel["calendrier"] == "Maison" && moved.forModel["debut"] == "2026-10-16T10:00")
        let at = now.addingTimeInterval(30)
        #expect(await runner.interception(for: "Annule", now: at) == .undo)
        #expect(await runner.resolve(.undo, context: context(at: at))?.spoken == ActionPhrases.undone(.change, .french))
        let bare = await runner.handle(change(["reference": "dernier"]), context: said("Mets-la dans l'agenda Maison."))
        #expect(bare.spoken.hasPrefix("C’est déplacé dans ton calendrier «\(nb)Maison\(nb)»\(nb): Réunion, "))
        let later = await runner.handle(change(["quand": "à 11 h"]), context: said("Décale-la à 11 h dans mon calendrier Maison."))
        #expect(later.spoken == "C’est déplacé\(nb): Réunion, vendredi 16 octobre de 11\(nb)h à midi.")  // its own now
        #expect(later.forModel["calendrier"] == "Maison")

        let breadRequest = "Rappelle-moi d'acheter du pain."
        let bread = ToolCall(name: "creer_rappel", arguments: ["titre": "acheter du pain"])
        #expect(await runner.handle(bread, context: said(breadRequest)).forModel["liste"] == "Rappels")
        let breadAsItIs = change(["reference": "r1", "titre": "acheter du pain"])
        let inReminders = await runner.handle(breadAsItIs, context: said("Mets-le dans ma liste Rappels.", breadRequest))
        #expect(!inReminders.retryable && inReminders.spoken == "C’est déjà dans ta liste «\(nb)Rappels\(nb)»\(nb): acheter du pain.")
        for context in [said("Mets-le dans mon calendrier Maison.", breadRequest),
                        said("Mets-le dans ma liste Bricolage.", breadRequest)] {
            let unchanged = await runner.handle(breadAsItIs, context: context)
            #expect(unchanged.spoken == ActionPhrases.nothingChanged(event: false, .french), "\(context.userSaid)")
        }
        let groceries = await runner.handle(breadAsItIs, context: said("Mets-le dans ma liste de courses.", breadRequest))
        #expect(groceries.spoken == "C’est déplacé dans ta liste «\(nb)Courses\(nb)»\(nb): acheter du pain.")
        #expect(groceries.forModel["liste"] == "Courses")
        #expect(await calendar.touched == ["Réunion", "Réunion", "Réunion", "acheter du pain"])
        #expect(await calendar.creations == ["e1", "r1"])
    }
}

// MARK: - A creation of an item already there

@Suite("Creations of an item already there")
struct RepeatedCreationTests {
    /// A meeting in « Travail », tomorrow from 10 h to 11 h, and a reminder without a date in « Rappels ».
    let meeting = ActionCatalog.SavedItem(isEvent: true, title: "Réunion", date: date("2026-10-16T10:00"),
                                          end: date("2026-10-16T11:00"), hasTime: true, collection: "Travail")
    let bread = ActionCatalog.SavedItem(isEvent: false, title: "Acheter du pain", date: nil, hasTime: false,
                                        collection: "Rappels")

    func repeats(_ new: ActionCatalog.SavedItem, _ item: ActionCatalog.SavedItem) -> Bool {
        ActionCatalog.repeats(new, item, calendar: context().calendar)
    }

    /// Of the same kind, in the same calendar or list, with the same title whatever the case and accents, at the same
    /// moment, and no place the item does not have: the same item. Anything else given (another title, moment, length,
    /// place, calendar or kind): another one.
    @Test func aCreationRepeatsAnItemOnlyWhenItGivesNothingElse() {
        var same = meeting
        same.title = " reunion "
        #expect(repeats(meeting, meeting) && repeats(same, meeting))
        same.date = date("2026-10-16T10:00").addingTimeInterval(20)  // seconds, as EventKit may keep them
        #expect(repeats(same, meeting))
        func other(_ change: (inout ActionCatalog.SavedItem) -> Void) -> ActionCatalog.SavedItem {
            var item = meeting
            change(&item)
            return item
        }
        #expect(!repeats(other { $0.title = "Réunion d'équipe" }, meeting))
        #expect(!repeats(other { $0.date = date("2026-10-16T11:00"); $0.end = date("2026-10-16T12:00") }, meeting))
        #expect(!repeats(other { $0.end = date("2026-10-16T12:00") }, meeting))  // two hours
        #expect(!repeats(other { $0.collection = "Maison" }, meeting))  // a copy in another calendar
        #expect(!repeats(other { $0.isEvent = false }, meeting))
        // A place the item does not have makes another one; none, or the item's own, the same.
        let placed = other { $0.place = "Salle 3" }
        #expect(!repeats(placed, meeting))
        #expect(repeats(other { $0.place = "salle 3" }, placed) && repeats(meeting, placed))
        #expect(repeats(other { $0.place = " " }, meeting))
        // The whole day, as EventKit may end it (23:59:59) or as the app does (the next midnight).
        let birthday = ActionCatalog.SavedItem(isEvent: true, title: "Anniversaire", date: date("2026-10-17T00:00"),
                                               end: date("2026-10-18T00:00"), hasTime: false, collection: "Travail")
        var read = birthday
        read.end = date("2026-10-17T23:59").addingTimeInterval(59)
        #expect(repeats(birthday, read) && repeats(read, birthday))
        var twoDays = birthday
        twoDays.end = date("2026-10-19T00:00")
        #expect(!repeats(twoDays, birthday))
        var atMidnight = birthday
        atMidnight.hasTime = true
        #expect(!repeats(atMidnight, birthday))
        // A reminder: without a date, or due at the same moment.
        #expect(repeats(bread, bread))
        var due = bread
        due.date = date("2026-10-16T10:00")
        due.hasTime = true
        #expect(repeats(due, due) && !repeats(due, bread) && !repeats(bread, due))
        var later = due
        later.date = date("2026-10-16T11:00")
        #expect(!repeats(later, due))
        var onTheDay = bread
        onTheDay.date = date("2026-10-16T00:00")
        var nextDay = onTheDay
        nextDay.date = date("2026-10-17T00:00")
        #expect(repeats(onTheDay, onTheDay) && !repeats(nextDay, onTheDay) && !repeats(onTheDay, due))
        // Among the items created in the conversation: the latest one it repeats.
        let items = ["e1": meeting, "r1": bread, "e2": placed, "e10": meeting, "r2": due]
        let calendar = context().calendar
        #expect(ActionCatalog.repeated(same, among: items, calendar: calendar)?.reference == "e10")
        #expect(ActionCatalog.repeated(placed, among: items, calendar: calendar)?.reference == "e2")
        #expect(ActionCatalog.repeated(bread, among: items, calendar: calendar)?.reference == "r1")
        #expect(ActionCatalog.repeated(later, among: items, calendar: calendar) == nil)
        #expect(ActionCatalog.repeated(meeting, among: [:], calendar: calendar) == nil)
    }

    /// Answered as a change that names the calendar or the list the item is already in: where it is. The model reads the
    /// item, with its id, and that it was not created again; « annule » is left to what was done before.
    @Test func aCreationOfAnItemAlreadyThereIsAnsweredWithIt() {
        let outcome = ActionCatalog.alreadyThere(meeting, described: ["id": "e1", "titre": "Réunion"],
                                                 collectionName: "Travail", context: context())
        #expect(outcome.spoken
                == "C’est déjà dans ton calendrier «\(nb)Travail\(nb)»\(nb): Réunion, vendredi 16 octobre de 10\(nb)h à 11\(nb)h.")
        #expect(outcome.forModel == ["id": "e1", "titre": "Réunion", "statut": .string(ActionCatalog.alreadyCreated)])
        #expect(outcome.nothingDone && outcome.undo == nil && !outcome.modelSpeaks)
        // The same sentence as for that change.
        let change = ToolCall(name: "modifier_element", arguments: ["reference": "e1", "calendrier": "Travail"])
        #expect(throws: Never.self) {
            do {
                _ = try ActionCatalog.changed(meeting, by: change, collection: "Travail", reference: "e1", context: context())
            } catch let refusal as ToolRefusal {
                #expect(refusal.spoken == outcome.spoken)
            }
        }
        // Found as the provider tells them apart (EventKit's identifier), said by its name.
        var inAnAccount = bread
        inAnAccount.collection = "5E1C9A0B-list"
        let reminder = ActionCatalog.alreadyThere(inAnAccount, described: ["id": "r1"], collectionName: "Rappels",
                                                  context: context())
        #expect(reminder.spoken == "C’est déjà dans ta liste «\(nb)Rappels\(nb)»\(nb): Acheter du pain.")
        #expect(ActionCatalog.alreadyThere(inAnAccount, described: ["id": "r1"], collectionName: "Rappels",
                                           context: context(.english)).spoken
                == "It’s already in your “Rappels” list: Acheter du pain.")
    }

    /// voice-cli's calendar in memory, as the app's (through the runner, as dialogue-bench uses it), as dialogue-bench's
    /// « meeting put in the calendar it is already in »: the meeting created in « Travail », the default calendar, then
    /// its creation written again for « Mets-la dans mon calendrier Travail. », as Gemma 4 E4B wrote it: not saved again,
    /// the app says where it is, the model gets the meeting, e1, and « annule » takes back its creation, as after a change
    /// that changes nothing. Another title, moment, length, place or calendar: saved as before. The same for a reminder
    /// and its list (as `CalendarTools`: `ActionCatalog.repeated` and `alreadyThere`).
    @Test func memoryCalendarDoesNotSaveAnItemAgain() async throws {
        let calendar = MemoryCalendar()
        await calendar.use(calendars: ["Travail", "Maison"], lists: ["Rappels", "Courses"])
        let runner = ToolRunner(providers: [calendar])
        _ = await runner.tools()
        let meeting = ToolCall(name: "creer_evenement", arguments: ["titre": "Réunion", "quand": "demain à 10 h"])
        #expect(await runner.handle(meeting, context: context()).forModel["id"] == "e1")
        let again = ToolCall(name: "creer_evenement",
                             arguments: ["titre": "réunion", "quand": "vendredi à 10 h", "calendrier": "Travail"])
        let answer = ToolContext(now: now, timeZone: paris, language: .french,
                                 userSaid: ["Mets-la dans mon calendrier Travail.", "Ajoute une réunion demain à 10 h."])
        let same = await runner.handle(again, context: answer)
        #expect(same.refusal == nil && !same.retryable && same.confirms)
        #expect(same.spoken
                == "C’est déjà dans ton calendrier «\(nb)Travail\(nb)»\(nb): Réunion, vendredi 16 octobre de 10\(nb)h à 11\(nb)h.")
        #expect(same.forModel == ["id": "e1", "titre": "Réunion", "debut": "2026-10-16T10:00", "fin": "2026-10-16T11:00",
                                  "calendrier": "Travail", "statut": .string(ActionCatalog.alreadyCreated)])
        // Written again as it was, without a calendar: the same, in the default one.
        #expect(await runner.handle(meeting, context: context()).forModel["id"] == "e1")
        #expect(await calendar.creations == ["e1"])
        // « annule »: the meeting's creation is taken back; then it is created again.
        let at = now.addingTimeInterval(30)
        #expect(await runner.interception(for: "Annule", now: at) == .undo)
        #expect(await runner.resolve(.undo, context: context(at: at))?.spoken == ActionPhrases.undone(.event, .french))
        #expect(await runner.handle(meeting, context: context()).forModel["id"] == "e2")
        // Anything else given: another item, saved as before (a copy in another calendar too).
        let others: [[String: JSONValue]] = [
            ["titre": "Réunion d'équipe", "quand": "demain à 10 h"], ["titre": "Réunion", "quand": "demain à 11 h"],
            ["titre": "Réunion", "quand": "demain à 10 h", "duree": "2 heures"],
            ["titre": "Réunion", "quand": "demain à 10 h", "lieu": "Salle 3"],
            ["titre": "Réunion", "quand": "demain à 10 h", "calendrier": "Maison"],
        ]
        for (index, arguments) in others.enumerated() {
            let made = await runner.handle(ToolCall(name: "creer_evenement", arguments: arguments), context: context())
            #expect(made.forModel["id"] == .string("e\(index + 3)") && made.forModel["statut"] == nil, "\(arguments)")
            #expect(made.spoken.hasPrefix("C’est dans "), "\(arguments)")
        }
        #expect(await calendar.creations == ["e1", "e2", "e3", "e4", "e5", "e6", "e7"])
        #expect(await calendar.touched.isEmpty)

        let bread = ToolCall(name: "creer_rappel", arguments: ["titre": "acheter du pain"])
        #expect(await runner.handle(bread, context: context()).forModel["liste"] == "Rappels")
        let inReminders = await runner.handle(
            ToolCall(name: "creer_rappel", arguments: ["titre": "Acheter du pain", "liste": "rappels"]), context: context())
        #expect(inReminders.spoken == "C’est déjà dans ta liste «\(nb)Rappels\(nb)»\(nb): acheter du pain.")
        #expect(inReminders.forModel == ["id": "r1", "titre": "acheter du pain", "liste": "Rappels",
                                         "statut": .string(ActionCatalog.alreadyCreated)])
        #expect(await runner.handle(bread, context: context()).forModel["id"] == "r1")
        let groceries = ToolCall(name: "creer_rappel", arguments: ["titre": "acheter du pain", "liste": "Courses"])
        #expect(await runner.handle(groceries, context: context()).forModel["id"] == "r2")
        let tomorrow = ToolCall(name: "creer_rappel", arguments: ["titre": "acheter du pain", "quand": "demain à 9 h"])
        #expect(await runner.handle(tomorrow, context: context()).forModel["id"] == "r3")
        #expect(await runner.handle(tomorrow, context: context()).forModel["id"] == "r3")
        #expect(await calendar.creations.suffix(3) == ["r1", "r2", "r3"])
    }

    /// The model got the item as its call's result: « dernier » is that item now, not one created after it. A deleted
    /// item is not there any more: its creation saves it again.
    @Test func theItemAlreadyThereIsTheLastOne() async throws {
        let calendar = MemoryCalendar()
        let runner = ToolRunner(providers: [calendar])
        _ = await runner.tools()
        let meeting = ToolCall(name: "creer_evenement", arguments: ["titre": "Réunion", "quand": "demain à 10 h"])
        _ = await runner.handle(meeting, context: context())
        _ = await runner.handle(ToolCall(name: "creer_rappel", arguments: ["titre": "acheter du pain"]), context: context())
        #expect(await runner.handle(meeting, context: context()).forModel["id"] == "e1")
        let later = await runner.handle(ToolCall(name: "modifier_element",
                                                 arguments: ["reference": "dernier", "quand": "à 11 h"]),
                                        context: context())
        #expect(later.spoken == "C’est déplacé\(nb): Réunion, vendredi 16 octobre de 11\(nb)h à midi.")
        #expect(await calendar.touched == ["Réunion"])
        let deleted = await runner.handle(ToolCall(name: "supprimer_element", arguments: ["reference": "e1"]),
                                          context: context())
        #expect(deleted.spoken == ActionPhrases.deleted(event: true, title: "Réunion", .french))
        let moved = ToolCall(name: "creer_evenement", arguments: ["titre": "Réunion", "quand": "demain à 11 h"])
        #expect(await runner.handle(moved, context: context()).forModel["id"] == "e2")
        #expect(await calendar.creations == ["e1", "r1", "e2"])
    }
}
