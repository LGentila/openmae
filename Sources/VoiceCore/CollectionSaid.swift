import Foundation

// The calendar or the reminder list the user's own words name, for a creation whose call names none.

extension ActionCatalog {
    /// A creation (`creer_evenement`, `creer_rappel`) whose call names no calendar or no list, with the one the user's
    /// sentence of this turn names (`collectionSaid`), else the one of the same creation refused just before (`again`,
    /// from `RefusedCreation.collection(before:)`), when it is among `names`: the model left it out. Any other call,
    /// unchanged. `names(event)`: the calendars (`event`) or the lists an item of that kind can go in, the ones the
    /// provider finds a name the model gives among; the name put in the call is one of them, which the provider then
    /// finds as it finds the model's.
    ///
    /// Shown its example exchanges (`examples`), Gemma 4 E2B left out the list of « Ajoute du pain à ma liste de
    /// courses. » in 10 runs of 10 of voice-cli dialogue-bench, and Gemma 4 E4B, without them, in 4 to 6 of 10: the
    /// reminder went to the default list, even with a « Courses » list there. Only this turn's sentence: an earlier one
    /// may have named a list for another item (« Ajoute du lait à ma liste de courses. », then « Rappelle-moi d'appeler
    /// Paul. »). The refused creation's own covers a request in two turns: « Ajoute un rendez-vous chez le coiffeur
    /// après le travail dans mon calendrier Perso. », refused for its moment, then « Demain à 18 h. » and the call again
    /// without the calendar. A calendar or a list that does not exist is never put in: the app could only refuse it.
    public static func withCollectionSaid(_ call: ToolCall, context: ToolContext, again: String? = nil,
                                          names: (_ event: Bool) -> [String]) -> ToolCall
    {
        let event = call.name == createEvent.name
        guard event || call.name == createReminder.name else { return call }
        let key = event ? "calendrier" : "liste"
        guard call.text(key) == nil else { return call }
        let all = names(event)
        let index = context.userSaid.first.flatMap { collectionSaid(in: $0, event: event, among: all) }
            ?? again.flatMap { collectionMatch($0, among: all) }
        guard let index else { return call }
        var said = call
        said.arguments[key] = .string(all[index])
        DebugLog.log("calendar: \(event ? "calendar" : "list") “\(all[index])” taken from the user's words")
        return said
    }

    /// Where among `names` the calendar (`event`) or the reminder list is that `sentence` names as the place of an item:
    /// the words after « liste » (a list), « calendrier » or « agenda » (a calendar), behind « à », « dans », « sur »…
    /// with or without « ma », « mon », « la »… before them, and « de », « du »… or not after them (« à ma liste de
    /// courses », « dans mon calendrier Travail », « au calendrier Famille »); in English, the words between « to my »,
    /// « in the »… and « list » or « calendar » (« to my shopping list »). A name whose words are all there, the longest
    /// (« Liste de courses » before « Courses »); else, as a name in a call is found, the first one that contains the
    /// first of those words or that it contains (« course » for « Courses », « courses » for « Courses du week-end »).
    /// nil when the sentence names none of them, or names a list only as something to do (« Rappelle-moi de faire la
    /// liste des invités. »: no « à », « dans »… before it).
    public static func collectionSaid(in sentence: String, event: Bool, among names: [String]) -> Int? {
        let words = placeWords(sentence)
        let nameWords = names.map { placeWords($0).filter { $0 != "|" } }
        let keywords: Set<String> = event ? ["calendrier", "calendriers", "agenda", "agendas", "calendar", "calendars"]
            : ["liste", "listes", "list", "lists"]
        var best: (index: Int, count: Int)?
        var loose: Int?
        /// The names whose words are all there from `start` (and end at `end`, when given): the longest so far is kept.
        /// `minimum`: how many words such a name has at least.
        func fit(from start: Int, endingAt end: Int? = nil, minimum: Int = 1) {
            for (index, name) in nameWords.enumerated() where name.count >= minimum && name.count > (best?.count ?? 0) {
                let stop = start + name.count
                guard start >= 0, stop <= words.count, end.map({ $0 == stop }) ?? true,
                      words[start..<stop].elementsEqual(name)
                else { continue }
                best = (index, name.count)
            }
        }
        /// As a name in a call is found (`collectionMatch`): a word that may begin a name.
        func looseFit(_ word: String) {
            guard loose == nil, word.count >= 2, !notNames.contains(word) else { return }
            loose = collectionMatch(word, among: names)
        }
        for (i, word) in words.enumerated() where keywords.contains(word) {
            // After it: « à ma liste de courses », « dans mon calendrier Travail », « to the list Groceries ».
            if placed(before: i, words) {
                var first = i + 1
                while first < words.count, linking.contains(words[first]) { first += 1 }
                fit(from: i, minimum: 2)  // a name that begins with it, « Liste de courses »: more than the word itself
                fit(from: i + 1)
                fit(from: first)
                if first < words.count { looseFit(words[first]) }
            }
            // Before it, in English: « to my shopping list », « in the Work calendar ».
            guard ["list", "lists", "calendar", "calendars"].contains(word) else { continue }
            var first = i
            while first > 0, i - first < 4, words[first - 1] != "|", !placeBefore.contains(words[first - 1]),
                  !determiners.contains(words[first - 1])
            {
                first -= 1
            }
            guard first < i, placed(before: first, words) else { continue }
            for start in first..<i {
                fit(from: start, endingAt: i)
                fit(from: start, endingAt: i + 1)  // with it: « Shopping list »
            }
            looseFit(words[i - 1])
        }
        return best?.index ?? loose
    }

    /// Where among `names` the one is that `name` stands for, as the providers find a calendar or a list a call names:
    /// the same whatever the case and accents, else the first one that contains it or that it contains.
    public static func collectionMatch(_ name: String, among names: [String]) -> Int? {
        func folded(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let key = folded(name)
        guard !key.isEmpty else { return nil }
        let all = names.map(folded)
        return all.firstIndex(of: key) ?? all.firstIndex { !$0.isEmpty && ($0.contains(key) || key.contains($0)) }
    }

    /// The words of a text, without case or accents, and "|" where a comma, a full stop… cuts the sentence: a name never
    /// runs over it.
    static func placeWords(_ text: String) -> [String] {
        var words: [String] = []
        var word = ""
        for character in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) {
            if character.isLetter || character.isNumber {
                word.append(character)
                continue
            }
            if !word.isEmpty {
                words.append(word)
                word = ""
            }
            if ",.;:!?()[]«»\"“”".contains(character), !words.isEmpty, words.last != "|" { words.append("|") }
        }
        if !word.isEmpty { words.append(word) }
        return words
    }

    /// Whether the words before `index` make it the place of an item: « à », « dans », « sur »… right before it, or
    /// with « ma », « mon », « la »… in between (« à ma liste », « dans l'agenda », « au calendrier », « to my »).
    private static func placed(before index: Int, _ words: [String]) -> Bool {
        guard index >= 1 else { return false }
        if placeBefore.contains(words[index - 1]) { return true }
        return index >= 2 && determiners.contains(words[index - 1]) && placeBefore.contains(words[index - 2])
    }

    private static let placeBefore: Set<String> = ["a", "au", "aux", "dans", "sur", "en", "pour", "vers",
                                                   "to", "on", "in", "into", "onto", "for", "at"]
    private static let determiners: Set<String> = [
        "ma", "mon", "mes", "ta", "ton", "tes", "sa", "son", "ses", "notre", "nos", "votre", "vos", "leur", "leurs", "la",
        "le", "les", "l", "ce", "cet", "cette", "un", "une", "my", "the", "your", "our", "his", "her", "their",
    ]
    /// Between the word for a list or a calendar and its name: « liste de courses », « calendrier du club », « la liste
    /// appelée Courses ».
    private static let linking: Set<String> = [
        "de", "des", "du", "d", "la", "le", "les", "l", "ma", "mon", "mes", "ta", "ton", "tes", "sa", "son", "ses",
        "notre", "nos", "votre", "vos", "leur", "leurs", "appelee", "appele", "nommee", "nomme", "of", "the", "my", "your",
        "our", "called", "named",
    ]
    /// Words that follow « liste » or « calendrier » without being a name (« dans mon calendrier demain à 10 h »).
    private static let notNames: Set<String> = [
        "a", "au", "aux", "pour", "avec", "sans", "dans", "sur", "en", "et", "ou", "puis", "alors", "aussi", "demain",
        "aujourd", "hui", "ce", "cet", "cette", "ces", "ici", "qui", "que", "quand", "si", "il", "elle", "stp", "svp",
        "merci", "maintenant", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche", "matin", "soir",
        "midi", "minuit", "prochain", "prochaine", "for", "with", "and", "or", "then", "tomorrow", "today", "tonight",
        "please", "thanks", "too", "now", "at", "on", "in", "to", "by", "monday", "tuesday", "wednesday", "thursday",
        "friday", "saturday", "sunday", "next",
    ]
}
