import Foundation

// A reminder's title as the user would write it in the Reminders app: without the « de » or « d' » that comes before the
// thing to do in their sentence (« Rappelle-moi d'appeler le plombier. »).

extension ActionCatalog {
    /// `title`, a reminder's title in a creation (`title(_:_:context:)`) or a change (`changed`), without the « de » or
    /// « d' » of the user's words before the thing to do: « D'appeler le plombier » is saved as « appeler le plombier »,
    /// « De racheter du café » as « racheter du café », « de ne pas oublier les clés » as « ne pas oublier les clés ».
    /// What follows is kept as the model wrote it, its first letter's case too. Any other title is kept as it is.
    ///
    /// The rule: the title starts with « de » and a space, or with « d' » (straight, curly or modifier apostrophe), in
    /// any case, and an infinitive follows (`isInfinitive`), maybe after « ne » or « n' » (and « pas », « plus »,
    /// « jamais » or « rien ») and after pronouns that are never an article: « me », « te », « se », « nous », « vous »,
    /// « lui », « y », « en » and their elided forms (« de s'inscrire », « d'y aller »); « le », « la », « les », « l' »
    /// and « leur » only after one of these (« de ne pas le perdre », « de me le dire »), since right after « de » they
    /// are an article or a determiner (« De la bière », « De leur dîner »). So « De Gaulle », « Des œufs », « De l'eau »,
    /// « De bonne heure », « De plus en plus » are kept.
    ///
    /// Its limits: « de le rappeler » keeps its « de » (« le » first could be an article), as does a title whose verb
    /// comes after another word (« de bien fermer la porte ») or is written with a capital, and an infinitive the rules
    /// miss; a noun or an adjective in « -er » or « -ir » they do not list loses it (« D'oranger »). A title starting so
    /// with anything but a verb is rare: what to remind is something to do.
    ///
    /// Asked « Rappelle-moi demain à 9 h. », then « D'appeler le plombier. » to the question of what to remind, Gemma 4
    /// E2B wrote `creer_rappel {titre: D'appeler le plombier}` (13 times) or « d'appeler le plombier » (15) in 40 runs of
    /// voice-cli dialogue-bench on 2026-10-25, and Gemma 4 E4B « D'appeler le plombier » in 2 of 40, though the parameter
    /// says « sans « rappelle-moi de » »: the user heard « C’est noté : vendredi 16 octobre à 9 h, D'appeler le
    /// plombier. », and the Reminders app showed it so. Without its « de », no saved title kept it (0 of 40 on E2B and
    /// on E4B, 0 of 10 on Gemma 4 26B), and the reminder was saved as often (40 of 40 on E2B; 38 of 40 on E4B against
    /// 39, its misses a title « rappeler » to the request and a tool name that does not exist).
    static func withoutLeadingDe(_ title: String) -> String {
        guard let rest = afterLeadingDe(title) else { return title }
        let words = leadingWords(rest, count: 6)
        var index = 0
        var pronounBefore = false
        if index < words.count, negation.contains(words[index].lowercased()) {
            index += 1
            pronounBefore = true
            if index < words.count, negationWords.contains(words[index].lowercased()) { index += 1 }
        }
        while index < words.count {
            let word = words[index].lowercased()
            guard neverArticles.contains(word) || (pronounBefore && articlesAfterAPronoun.contains(word)) else { break }
            pronounBefore = true
            index += 1
        }
        guard index < words.count, !words[index].hasSuffix("'"), isInfinitive(words[index]) else { return title }
        return String(rest)
    }

    /// What follows a title's first « de » and its spaces, or its first « d' » (`apostrophes`), in any case; nil when it
    /// starts with neither (« Des œufs », « Dentiste ») or nothing follows.
    private static func afterLeadingDe(_ title: String) -> Substring? {
        var rest = title[...]
        guard let first = rest.popFirst(), first == "d" || first == "D", let second = rest.popFirst() else { return nil }
        if !apostrophes.contains(second) {
            guard second == "e" || second == "E", rest.first?.isWhitespace == true else { return nil }
        }
        rest = rest.drop(while: \.isWhitespace)
        return rest.isEmpty ? nil : rest
    }

    /// The first `count` words of `text`, cut at spaces and after an elided word's apostrophe (« s'inscrire » gives « s' »
    /// and « inscrire »), which is then written « ' », whatever its form.
    private static func leadingWords(_ text: Substring, count: Int) -> [String] {
        var words: [String] = []
        var word = ""
        for character in text {
            guard words.count < count else { break }
            if character.isWhitespace {
                if !word.isEmpty { words.append(word) }
                word = ""
            } else if apostrophes.contains(character), !word.isEmpty, word.allSatisfy(\.isLetter) {
                words.append(word + "'")
                word = ""
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty, words.count < count { words.append(word) }
        return words
    }

    /// Whether `word`, as written, is a French infinitive for `withoutLeadingDe`: in lower case from its first letter (a
    /// capital marks a name: « De Pierre », « D'Olivier »), letters then nothing but punctuation (« appeler, »), of four
    /// letters or more, ending (whatever the accents) in « -er » or « -ir », unless it is one of the nouns and adjectives
    /// listed (`notInfinitives`: « hier », « premier », « plaisir »…); in « -oir », only a verb listed (`verbsInOir`:
    /// « voir », « devoir »…, the others are nouns: « soir », « couloir »); in « -re », only a verb's ending
    /// (`verbEndingsInRe`: « faire », « prendre », « écrire », « connaître »…) or a verb listed (`verbsInRe`: « être »,
    /// « lire », « boire »…), as most words in « -re » are not verbs (« père », « mémoire », « notre », « autre »).
    static func isInfinitive(_ word: String) -> Bool {
        guard let first = word.first, first.isLetter, first.isLowercase else { return false }
        let letters = word.prefix(while: \.isLetter)
        guard !word.dropFirst(letters.count).contains(where: \.isLetter) else { return false }
        let plain = String(letters).folding(options: [.caseInsensitive, .diacriticInsensitive],
                                            locale: Locale(identifier: "fr_FR"))
        guard plain.count >= 4, !notInfinitives.contains(plain) else { return false }
        if plain.hasSuffix("oir") { return verbsInOir.contains(plain) }
        if plain.hasSuffix("er") || plain.hasSuffix("ir") { return true }
        guard plain.hasSuffix("re") else { return false }
        return verbsInRe.contains(plain) || verbEndingsInRe.contains { plain.hasSuffix($0) }
    }

    /// The forms of the apostrophe of « d' »: straight, curly, and the modifier letter.
    private static let apostrophes: Set<Character> = ["'", "’", "ʼ"]
    private static let negation: Set<String> = ["ne", "n'"]
    private static let negationWords: Set<String> = ["pas", "plus", "jamais", "rien"]
    /// Pronouns that may come between « de » and its infinitive and are never an article or a determiner.
    private static let neverArticles: Set<String> = ["me", "m'", "te", "t'", "se", "s'", "nous", "vous", "lui", "y", "en"]
    /// Pronouns that are also articles or a determiner: before an infinitive only after a negation or another pronoun.
    private static let articlesAfterAPronoun: Set<String> = ["le", "la", "les", "l'", "leur"]
    /// Nouns and adjectives that end as an infinitive does (without their accents), and could follow « de ».
    private static let notInfinitives: Set<String> = [
        "hier", "hiver", "cher", "fier", "amer", "enfer", "premier", "dernier", "entier", "leger", "papier", "cahier",
        "panier", "metier", "quartier", "janvier", "fevrier", "acier", "plaisir", "desir", "loisir", "avenir", "soupir",
        "cuir", "saphir", "affaire", "maitre", "contremaitre", "traitre",
    ]
    /// The verbs in « -oir » (without their accents).
    private static let verbsInOir: Set<String> = [
        "voir", "revoir", "prevoir", "entrevoir", "pourvoir", "avoir", "ravoir", "devoir", "pouvoir", "savoir", "vouloir",
        "valoir", "prevaloir", "falloir", "recevoir", "apercevoir", "concevoir", "decevoir", "percevoir", "pleuvoir",
        "asseoir", "rasseoir", "mouvoir", "emouvoir", "promouvoir", "surseoir",
    ]
    /// Verbs in « -re » whose ending other words share (without their accents).
    private static let verbsInRe: Set<String> = [
        "etre", "lire", "relire", "elire", "boire", "croire", "rire", "sourire", "plaire", "deplaire", "taire",
        "distraire", "extraire", "soustraire", "suffire", "frire", "confire", "croitre", "accroitre", "decroitre",
    ]
    /// Endings of verbs in « -re » that no common noun has (without their accents): « prendre », « attendre »,
    /// « descendre », « répondre », « mettre », « écrire », « connaître », « conduire », « peindre »…
    private static let verbEndingsInRe = [
        "faire", "dire", "crire", "vivre", "suivre", "rendre", "vendre", "tendre", "scendre", "fendre", "pendre", "pondre",
        "fondre", "perdre", "mordre", "tordre", "coudre", "moudre", "soudre", "battre", "mettre", "aitre", "uire", "clure",
        "eindre", "aindre", "oindre", "aincre", "ompre",
    ]
}
