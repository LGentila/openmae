import Foundation
import Testing

@testable import VoiceCore

private let paris = TimeZone(identifier: "Europe/Paris")!
/// Thursday 15 October 2026, 18:42 in Paris: the benchmark's reference time.
private let now = LocalDateTime.parse("2026-10-15T18:42", in: paris)!.date

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = paris
    calendar.locale = Locale(identifier: "fr_FR")
    return calendar
}()

/// The moment the words give, written "2026-10-16T15:00" (or "2026-10-16" for a day alone), then the end and the
/// length when they give one. `base`: the item a change starts from.
private func moment(_ text: String, base: String? = nil, at reference: Date = now) throws -> String {
    let base = base.flatMap { LocalDateTime.parse($0, in: paris) }.map { FrenchDates.Base(date: $0.date, hasTime: $0.hasTime) }
    let moment = try FrenchDates.moment(text, now: reference, calendar: calendar, base: base)
    var written = LocalDateTime.format(moment.start, in: paris, withTime: moment.hasTime)
    if let end = moment.end { written += " → " + LocalDateTime.format(end, in: paris, withTime: moment.hasTime) }
    if let duration = moment.duration { written += " (\(duration) s)" }
    return written
}

private func period(_ text: String) throws -> String {
    let (start, end) = try FrenchDates.period(text, now: now, calendar: calendar)
    return LocalDateTime.format(start, in: paris) + " → " + LocalDateTime.format(end, in: paris)
}

private func problem(_ text: String, base: String? = nil) -> FrenchDates.Problem? {
    do {
        _ = try moment(text, base: base)
        return nil
    } catch {
        return error as? FrenchDates.Problem
    }
}

@Suite("French dates")
struct FrenchDatesTests {
    /// The moments of the benchmark's corpus, as a model copies them from the user's words.
    @Test func momentsOfTheCorpus() throws {
        let cases = [
            ("demain à 15 h", "2026-10-16T15:00"),
            ("samedi à 20 h", "2026-10-17T20:00"),
            ("lundi à 9 h 30", "2026-10-19T09:30"),
            ("vendredi à 18 h pendant une heure et demie", "2026-10-16T18:00 (5400 s)"),
            ("le 3 novembre", "2026-11-03"),
            ("vendredi à 14 h", "2026-10-16T14:00"),
            ("demain de 10 h à midi", "2026-10-16T10:00 → 2026-10-16T12:00"),
            ("ce soir à 19 h", "2026-10-15T19:00"),
            ("dimanche à 15 h", "2026-10-18T15:00"),
            ("mardi à 20 h 30", "2026-10-20T20:30"),
            ("le 8 novembre à 21 h", "2026-11-08T21:00"),
            ("dans trois semaines à 10 h", "2026-11-05T10:00"),
            ("après-demain à 11 h", "2026-10-17T11:00"),
            ("le 28 octobre à 16 h 15", "2026-10-28T16:15"),
            ("demain à midi et demi", "2026-10-16T12:30"),
            ("du 20 au 24 décembre", "2026-12-20 → 2026-12-25"),
            ("demain à 7 h du matin", "2026-10-16T07:00"),
            ("vendredi 23 octobre à 17 h 45", "2026-10-23T17:45"),
            ("vendredi soir à 21 h", "2026-10-16T21:00"),
            ("le samedi 12 juin", "2027-06-12"),
            ("mardi prochain à 8 h 45", "2026-10-20T08:45"),
            ("dans une heure", "2026-10-15T19:42"),
            ("dans 20 minutes", "2026-10-15T19:02"),
            ("vendredi", "2026-10-16"),
            ("samedi matin à 9 h", "2026-10-17T09:00"),
            ("ce soir à 21 h", "2026-10-15T21:00"),
            ("demain midi", "2026-10-16T12:00"),
            ("le 1er novembre", "2026-11-01"),
            ("le 15 décembre à 9 h", "2026-12-15T09:00"),
            ("dans deux jours", "2026-10-17"),
            ("vendredi à 3 h de l'après-midi", "2026-10-16T15:00"),
            ("demain matin à 7 h 30", "2026-10-16T07:30"),
            ("à 23 h", "2026-10-15T23:00"),
            ("dans une demi-heure", "2026-10-15T19:12"),
            ("mercredi prochain à 14 h", "2026-10-21T14:00"),
        ]
        for (text, expected) in cases { #expect(try moment(text) == expected, "\(text)") }
    }

    @Test func days() throws {
        let cases = [
            ("aujourd'hui", "2026-10-15"), ("d'aujourd'hui", "2026-10-15"), ("demain", "2026-10-16"),
            ("après demain", "2026-10-17"), ("hier", "2026-10-14"), ("dans quinze jours", "2026-10-30"),
            ("dans un mois", "2026-11-15"),
            // A weekday is the next one; today's (Thursday) is next week's.
            ("samedi", "2026-10-17"), ("ce samedi", "2026-10-17"), ("lundi prochain", "2026-10-19"),
            ("vendredi prochain", "2026-10-16"), ("jeudi", "2026-10-22"), ("jeudi prochain", "2026-10-22"),
            ("samedi en huit", "2026-10-24"), ("samedi de la semaine prochaine", "2026-10-24"),
            ("samedi dernier", "2026-10-10"),
            // A date without its year is the next one; without its month, this month's or the next.
            ("le premier novembre", "2026-11-01"), ("le 12 juin", "2027-06-12"), ("le 20", "2026-10-20"),
            ("le 3", "2026-11-03"), ("lundi 19", "2026-10-19"), ("le lundi 19 octobre 2026", "2026-10-19"),
            ("17/10", "2026-10-17"), ("Noël", "2026-12-25"), ("le jour de l'an", "2027-01-01"),
            ("fin octobre", "2026-10-31"), ("la semaine prochaine", "2026-10-19"), ("ce week-end", "2026-10-17"),
        ]
        for (text, expected) in cases { #expect(try moment(text) == expected, "\(text)") }
    }

    @Test func times() throws {
        let cases = [
            // As speech recognition and the models write them.
            ("demain 15h", "2026-10-16T15:00"), ("demain à 15 heures", "2026-10-16T15:00"),
            ("demain à quinze heures", "2026-10-16T15:00"), ("demain à 9h30", "2026-10-16T09:30"),
            ("demain à 17:45", "2026-10-16T17:45"), ("demain à dix-sept heures quarante-cinq", "2026-10-16T17:45"),
            ("demain à neuf heures et quart", "2026-10-16T09:15"), ("demain à 8 h moins le quart", "2026-10-16T07:45"),
            ("demain à 9 h moins 10", "2026-10-16T08:50"), ("demain midi trente", "2026-10-16T12:30"),
            ("demain vers 15 h", "2026-10-16T15:00"),
            // Without a day: the next time it is that time.
            ("à 9 h", "2026-10-16T09:00"), ("à minuit", "2026-10-16T00:00"), ("à 20h00", "2026-10-15T20:00"),
            // The part of the day tells the morning from the evening.
            ("ce soir à 9 h", "2026-10-15T21:00"), ("demain soir à 7 h 30", "2026-10-16T19:30"),
            ("à 7 h du soir", "2026-10-15T19:00"), ("à 2 h du matin", "2026-10-16T02:00"),
            ("cette nuit à 2 h", "2026-10-16T02:00"), ("demain à 8 h", "2026-10-16T08:00"),
            // A part of the day alone: its usual hour.
            ("ce soir", "2026-10-15T19:00"), ("demain matin", "2026-10-16T09:00"),
            ("demain après-midi", "2026-10-16T14:00"), ("demain en fin d'après-midi", "2026-10-16T17:00"),
            ("cette nuit", "2026-10-15T22:00"),
        ]
        for (text, expected) in cases { #expect(try moment(text) == expected, "\(text)") }
        // "Ce soir" once the evening has begun: the next full hour.
        let evening = LocalDateTime.parse("2026-10-15T19:30", in: paris)!.date
        #expect(try moment("ce soir", at: evening) == "2026-10-15T20:00")
    }

    @Test func offsetsRangesAndLengths() throws {
        let cases = [
            ("dans un quart d'heure", "2026-10-15T18:57"), ("dans 1 h 30", "2026-10-15T20:12"),
            ("dans 2 heures et demie", "2026-10-15T21:12"), ("d'ici une heure", "2026-10-15T19:42"),
            ("maintenant", "2026-10-15T18:42"),
            ("demain de 14 h à 18 h", "2026-10-16T14:00 → 2026-10-16T18:00"),
            ("demain 9h-10h", "2026-10-16T09:00 → 2026-10-16T10:00"),
            ("demain de 10 à 12 h", "2026-10-16T10:00 → 2026-10-16T12:00"),
            ("demain entre 14 h et 16 h", "2026-10-16T14:00 → 2026-10-16T16:00"),
            ("demain de 3 h à 5 h de l'après-midi", "2026-10-16T15:00 → 2026-10-16T17:00"),
            ("demain de 10 h à 2 h", "2026-10-16T10:00 → 2026-10-16T14:00"),
            ("du lundi au mercredi", "2026-10-19 → 2026-10-22"),
            ("entre le 3 et le 5 novembre", "2026-11-03 → 2026-11-06"),
            ("lundi à 9 h, 30 minutes", "2026-10-19T09:00 (1800 s)"),
            ("demain à 16 h, d'une heure", "2026-10-16T16:00 (3600 s)"),
            ("toute la journée demain", "2026-10-16"),
        ]
        for (text, expected) in cases { #expect(try moment(text) == expected, "\(text)") }
    }

    @Test func whatTheModelMayWriteInstead() throws {
        #expect(try moment("2026-10-17T20:00") == "2026-10-17T20:00")
        #expect(try moment("2026-10-17") == "2026-10-17")
        #expect(try moment("2026-10-17T20:00:00Z") == "2026-10-17T20:00")
        #expect(try moment("17/10 à 20h") == "2026-10-17T20:00")
        #expect(try moment("samedi 17 octobre à 20 h") == "2026-10-17T20:00")
        #expect(try moment("demain à 15h00 (2026-10-16T15:00)") == "2026-10-16T15:00")
        #expect(try moment("Rappelle-moi lundi à 8 h d'envoyer le dossier à Marc") == "2026-10-19T08:00")
    }

    /// From 1 to 7, an hour said without the morning or the afternoon is not guessed.
    @Test func ambiguousHoursAreNotGuessed() throws {
        #expect(problem("à 3 h") == .ambiguousHour(hour: 3, minute: 0))
        #expect(problem("lundi à 7 h") == .ambiguousHour(hour: 7, minute: 0))
        #expect(problem("demain à 1 h 30") == .ambiguousHour(hour: 1, minute: 30))
        #expect(problem("demain de 2 h à 4 h") == .ambiguousHour(hour: 2, minute: 0))
        #expect(try moment("lundi à 3 h du matin") == "2026-10-19T03:00")
        #expect(try moment("lundi à 3 h de l'après-midi") == "2026-10-19T15:00")
        #expect(try moment("lundi après-midi à 3 h") == "2026-10-19T15:00")
        #expect(try moment("demain de 2 h à 16 h") == "2026-10-16T14:00 → 2026-10-16T16:00")  // the end tells
    }

    @Test func problems() {
        let thursday = LocalDateTime.parse("2026-10-22", in: paris)!.date
        #expect(problem("dimanche 22 octobre") == .wrongWeekday(thursday))
        #expect(problem("samedi 18 octobre à 20 h") != nil)
        #expect(problem("bientôt") == .notUnderstood)
        #expect(problem("") == .notUnderstood)
        #expect(problem("le 31 novembre") == .notUnderstood)
        #expect(problem("à 25 h") == .notUnderstood)
        #expect(problem("demain samedi") == .contradiction)
        #expect(problem("à la même heure") == .notUnderstood)  // no item to take it from
    }

    /// A change starts from the item: Friday 16 October at 15:00.
    @Test func changes() throws {
        let item = "2026-10-16T15:00"
        #expect(try moment("à 16 h", base: item) == "2026-10-16T16:00")
        #expect(try moment("samedi à la même heure", base: item) == "2026-10-17T15:00")
        #expect(try moment("samedi", base: item) == "2026-10-17T15:00")
        #expect(try moment("une heure plus tard", base: item) == "2026-10-16T16:00")
        #expect(try moment("30 minutes plus tôt", base: item) == "2026-10-16T14:30")
        #expect(try moment("deux jours plus tard", base: item) == "2026-10-18T15:00")
        #expect(try moment("le lendemain", base: item) == "2026-10-17T15:00")
        #expect(try moment("à 11 h", base: "2026-10-16T10:00") == "2026-10-16T11:00")
        #expect(try moment("lundi", base: "2026-10-16") == "2026-10-19")  // a day alone stays a day alone
        #expect(problem("d'une heure", base: item) == .noDirection)
    }

    @Test func periods() throws {
        let cases = [
            ("demain", "2026-10-16T00:00 → 2026-10-17T00:00"),
            ("aujourd'hui", "2026-10-15T00:00 → 2026-10-16T00:00"),
            ("pour aujourd'hui", "2026-10-15T00:00 → 2026-10-16T00:00"),
            ("samedi", "2026-10-17T00:00 → 2026-10-18T00:00"),
            ("cette semaine", "2026-10-15T00:00 → 2026-10-19T00:00"),
            ("la semaine prochaine", "2026-10-19T00:00 → 2026-10-26T00:00"),
            ("ce week-end", "2026-10-17T00:00 → 2026-10-19T00:00"),
            ("ce soir", "2026-10-15T18:00 → 2026-10-16T00:00"),
            ("demain matin", "2026-10-16T00:00 → 2026-10-16T12:00"),
            ("demain de 14 h à 18 h", "2026-10-16T14:00 → 2026-10-16T18:00"),
            ("du 20 au 24 décembre", "2026-12-20T00:00 → 2026-12-25T00:00"),
            ("en novembre", "2026-11-01T00:00 → 2026-12-01T00:00"),
            ("les 3 prochains jours", "2026-10-15T00:00 → 2026-10-18T00:00"),
            ("jusqu'à vendredi", "2026-10-15T18:42 → 2026-10-17T00:00"),
            ("hier", "2026-10-14T00:00 → 2026-10-15T00:00"),
            ("2026-10-16T00:00", "2026-10-16T00:00 → 2026-10-17T00:00"),
        ]
        for (text, expected) in cases { #expect(try period(text) == expected, "\(text)") }
    }

    @Test func wordsAreTheUsersOrNot() {
        let said = ["Ajoute un rendez-vous demain à 15 h chez le médecin"]
        #expect(FrenchDates.wordsAreTheUser("demain à 15 h", said: said))
        #expect(FrenchDates.wordsAreTheUser("demain à quinze heures", said: said))  // same words, spelled otherwise
        #expect(!FrenchDates.wordsAreTheUser("vendredi à 15 h", said: said))
        #expect(!FrenchDates.wordsAreTheUser("demain à 15 h 30", said: said))
        #expect(!FrenchDates.wordsAreTheUser("2026-10-16T15:00", said: said))
        #expect(FrenchDates.saysWhen(said[0]))
        #expect(!FrenchDates.saysWhen("De l'après-midi"))
        #expect(FrenchDates.lengthSaid("Mets un minuteur d'une heure et quart") == 4500)
        #expect(FrenchDates.lengthSaid("Rendez-vous vendredi à 18 h pendant une heure et demie") == 5400)
        #expect(FrenchDates.lengthSaid("Rendez-vous vendredi à 18 h") == nil)
    }

    /// Words that say when relative to something the app cannot place leave the hour open, unless they give one; the
    /// moment is read without them (a forecast's day), and the app refuses it for an event or a reminder.
    @Test func wordsItCannotPlaceLeaveTheHourOpen() throws {
        let open = [
            "jeudi après le travail", "après le travail", "demain après le boulot", "samedi après la piscine",
            "mardi après manger", "lundi après mon rendez-vous", "vendredi avant de partir", "demain avant le dîner",
            "jeudi pendant la pause", "lundi lors du déjeuner", "demain en sortant du bureau", "jeudi en rentrant",
            "lundi à la sortie de l'école", "demain à l'heure du déjeuner", "jeudi au retour", "vendredi à mon retour",
            "demain au réveil", "demain dès que je rentre", "demain quand je rentre",
            "Ajoute un rendez-vous chez le coiffeur après le travail dans mon calendrier Perso.",
        ]
        for text in open { #expect(FrenchDates.leavesTheHourOpen(text), "\(text)") }
        // With an hour of their own, or a part of the day.
        let placed = ["jeudi après le travail à 18 h", "après le travail vers 18 h 30", "jeudi 18 h, après le travail",
                      "demain soir après le travail", "après le travail ce soir", "dans 20 minutes, en sortant"]
        for text in placed { #expect(!FrenchDates.leavesTheHourOpen(text), "\(text)") }
        // A moment follows, or nothing the moment is relative to; the phrases read today.
        let plain = ["après 18 h", "avant vendredi", "avant le 15", "après le 3 novembre", "avant midi", "après minuit",
                     "avant la semaine prochaine", "pendant le week-end", "pendant une heure", "deux jours après",
                     "après-demain", "après demain matin", "d'après la météo", "la semaine d'après", "en avant",
                     "après tout", "jeudi, après on verra", "demain matin", "samedi soir", "lundi prochain à 9 h",
                     "vendredi", "dans deux jours"]
        for text in plain { #expect(!FrenchDates.leavesTheHourOpen(text), "\(text)") }
        #expect(try moment("jeudi après le travail") == "2026-10-22")
        #expect(problem("après le travail") == .notUnderstood)
        // An hour before them is an hour, not a shift (« 18 h après » used to be 18 hours from now).
        #expect(try moment("jeudi à 18 h après le travail") == "2026-10-22T18:00")
        #expect(try moment("demain 18 h après le boulot") == "2026-10-16T18:00")
        #expect(try moment("une heure après", base: "2026-10-16T15:00") == "2026-10-16T16:00")
        #expect(try moment("deux jours avant", base: "2026-10-16T15:00") == "2026-10-14T15:00")
        #expect(FrenchDates.saysTheHour("jeudi soir") && FrenchDates.saysTheHour("dans 20 minutes")
                && FrenchDates.saysTheHour("à la même heure") && FrenchDates.saysTheHour("2026-10-16T18:00"))
        #expect(!FrenchDates.saysTheHour("jeudi") && !FrenchDates.saysTheHour("dans deux jours")
                && !FrenchDates.saysTheHour("2026-10-22") && !FrenchDates.saysTheHour("après le travail"))
    }

    @Test func lengths() {
        let cases: [(String, Int?)] = [
            ("une heure et quart", 4500), ("une heure et demie", 5400), ("1 h 30", 5400), ("1h30", 5400),
            ("une heure 15", 4500), ("1 heure et 15 minutes", 4500), ("trois quarts d'heure", 2700),
            ("un quart d'heure", 900), ("une demi-heure", 1800), ("45 secondes", 45), ("10 minutes", 600),
            ("10 min", 600), ("deux minutes trente", 150), ("deux heures", 7200), ("d'une heure et quart s'il te plaît", 4500),
            ("5", nil), ("deux mois", nil), ("bientôt", nil),
        ]
        for (text, seconds) in cases { #expect(FrenchDates.duration(text) == seconds, "\(text)") }
    }
}
