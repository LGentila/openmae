import Foundation

// The calendar or the reminder list the user's own words name, for a creation or a change whose call names none, or for a
// creation refused for one that does not exist, whose answer names another.

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
    ///
    /// When the refused creation's own does not exist (« Travail », refused for it), the one the user's answer to the
    /// app's question names (`answer`, from `RefusedCreation.answer(before:said:)`), as `collectionAnswered` finds it:
    /// « Mets-la dans Maison alors. » names « Maison » without « calendrier » before it, and the creation written again
    /// without its calendar went to the default one, whichever the answer named.
    public static func withCollectionSaid(_ call: ToolCall, context: ToolContext, again: String? = nil,
                                          answer: String? = nil, names: (_ event: Bool) -> [String]) -> ToolCall
    {
        let event = call.name == createEvent.name
        guard event || call.name == createReminder.name else { return call }
        let key = event ? "calendrier" : "liste"
        guard call.text(key) == nil else { return call }
        let all = names(event)
        let index = context.userSaid.first.flatMap { collectionSaid(in: $0, event: event, among: all) }
            ?? again.flatMap { refused in
                collectionIndex(named: refused, among: all)
                    ?? answer.flatMap { collectionAnswered(in: $0, event: event, among: all) }
            }
        guard let index else { return call }
        var said = call
        said.arguments[key] = .string(all[index])
        DebugLog.log("calendar: \(event ? "calendar" : "list") “\(all[index])” taken from the user's words")
        return said
    }

    /// A change (`modifier_element`) of an event (`event`) or of a reminder, whose call names no calendar and no list
    /// (`collectionNamed`), with the one the user's sentence of this turn names (`collectionSaid`) among `names(event)`,
    /// the calendars or the lists an item of that kind can go in, as if the call named it: the provider then moves the
    /// item there, or, when it is the item's own, says it is already there (`changed`). The name put in the call is one
    /// of them, which the provider then finds as it finds the model's. Any other call, unchanged; a change too when the
    /// sentence names none of them (a calendar that does not exist: the change gives what it gave), or when there is no
    /// sentence (`ToolContext.userSaid` empty: one of several actions).
    ///
    /// On the tiers whose change offers no calendar and no list (`movesItems(on:)`), asked « Mets la réunion dans mon
    /// calendrier Maison. », Gemma 4 E4B moved the meeting in 3 runs of 40 of voice-cli dialogue-bench on 2026-10-23
    /// (when its change named the calendar all the same), Gemma 4 E2B in 0 of 20: their changes gave the meeting as it
    /// was (`{reference: e1, titre: réunion, quand: vendredi à 10 h}`, `{reference: e1, titre: Réunion}`), which changed
    /// nothing, and the app answered « Je n'ai rien changé… ». With the calendar of the sentence, every such change moved
    /// it (E4B 8 runs of 10, its two others wrote two calls at once or the calendar as `quand`; E2B 5 of 10, the others
    /// wrote the meeting's creation again in « Maison »). On every tier, as for a creation: only this turn's sentence,
    /// as an earlier one may have named a calendar or a list for another item; and only a calendar for an event, a list
    /// for a reminder.
    public static func withCollectionSaid(change call: ToolCall, event: Bool, context: ToolContext,
                                          names: (_ event: Bool) -> [String]) -> ToolCall
    {
        guard call.name == changeItem.name, collectionNamed(in: call, event: event) == nil,
              let sentence = context.userSaid.first
        else { return call }
        let all = names(event)
        guard let index = collectionSaid(in: sentence, event: event, among: all) else { return call }
        var said = call
        said.arguments[event ? "calendrier" : "liste"] = .string(all[index])
        DebugLog.log("calendar: \(event ? "calendar" : "list") “\(all[index])” of a change taken from the user's words")
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
        /// As a name in a call is found (`collectionIndex`): a word that may begin a name.
        func looseFit(_ word: String) {
            guard loose == nil, word.count >= 2, !notNames.contains(word) else { return }
            loose = collectionIndex(named: word, among: names)
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

    /// Where among `names` the calendar (`event`) or the list is that `sentence` names when it answers the app's
    /// question about one (« Je ne trouve pas le calendrier « Travail ». Tu peux me redire son nom ? »): as
    /// `collectionSaid` finds it, else a name whose words are all there, even without « calendrier » or « liste »
    /// before them (« Mets-la dans Maison alors. », « Maison. », « C'est le calendrier perso. »), the longest at its
    /// place (« Famille Dupont » before « Famille »). When the sentence has several, the only one behind « à »,
    /// « dans », « sur »… (« Dans Maison, pas Perso. »). nil when it names none, or several that nothing tells apart
    /// (« Maison ou Perso ? »). A name made only of such a word (a calendar called « Calendrier ») is not found so:
    /// « dans le calendrier par défaut » does not name it.
    ///
    /// Only for an answer: in a request, a name alone is often something else (« le ménage de la maison »).
    public static func collectionAnswered(in sentence: String, event: Bool, among names: [String]) -> Int? {
        if let said = collectionSaid(in: sentence, event: event, among: names) { return said }
        let words = placeWords(sentence)
        let nameWords = names.map { placeWords($0).filter { $0 != "|" } }
        var found: [(index: Int, placed: Bool)] = []
        var start = 0
        while start < words.count {
            // The longest name there, the first of that length (two calendars of the same name in two accounts).
            var longest: Int?
            for (index, name) in nameWords.enumerated()
                where !name.isEmpty && !name.allSatisfy(collectionWords.contains)
                    && name.count > (longest.map { nameWords[$0].count } ?? 0)
            {
                let stop = start + name.count
                if stop <= words.count, words[start..<stop].elementsEqual(name) { longest = index }
            }
            guard let longest else {
                start += 1
                continue
            }
            found.append((longest, placed(before: start, words)))
            start += nameWords[longest].count
        }
        let named = Set(found.map { $0.index })
        if named.count == 1 { return named.first }
        let placedNames = Set(found.filter { $0.placed }.map { $0.index })
        return placedNames.count == 1 ? placedNames.first : nil
    }

    /// The words for a calendar or a list, in both languages: what `collectionSaid` looks for a name after (or before).
    private static let collectionWords: Set<String> = [
        "calendrier", "calendriers", "agenda", "agendas", "calendar", "calendars", "liste", "listes", "list", "lists",
    ]

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
