import Foundation

/// Recognizes the user's short answers — "oui", "non", "annule" — with closed lists, without the model.
/// A sentence that is not one of them goes to the model as usual.
public enum ReplyMatcher {
    public enum Reply: Equatable, Sendable { case yes, no, cancel }

    private static let yes: Set<String> = [
        "oui", "ouais", "oui oui", "oui vas y", "vas y", "allez vas y", "d accord", "ok", "okay", "ok vas y",
        "c est bon", "go", "confirme", "je confirme", "oui je confirme", "oui c est bon", "oui d accord",
        "oui merci", "oui s il te plait", "c est parti", "bien sur", "oui bien sur", "parfait", "exactement",
        "yes", "yeah", "yep", "sure", "go ahead", "do it", "confirm", "okay go ahead", "yes please",
    ]
    private static let no: Set<String> = [
        "non", "non merci", "non non", "annule", "laisse tomber", "attends", "stop", "arrete", "non laisse tomber",
        "non annule", "pas maintenant", "non pas maintenant", "surtout pas", "no", "nope", "cancel", "never mind",
        "wait", "don t",
        // How speech recognition sometimes hears "annule".
        "a nul", "a nulle", "anule", "anul", "un nul", "en nul",
    ]
    private static let cancel: Set<String> = [
        "annule", "annule ca", "annule le", "annule la", "annule tout", "non annule", "en fait annule",
        "finalement annule", "annule cette action", "annule ce que tu viens de faire", "laisse tomber annule",
        "annule le minuteur", "annule ce minuteur", "undo", "undo that", "cancel", "cancel that", "cancel it",
        "a nul", "a nulle", "anule", "anul", "un nul", "en nul",  // how speech recognition sometimes hears "annule"
        // Not here: "annule le rendez-vous", "supprime ce rappel"… Naming the item means deleting it, which the
        // model does with its delete tool; right after a change, "annule" alone would only undo the change.
    ]

    /// The answer to "On y va ?": yes, no, or nil when the sentence says something else.
    public static func confirmation(_ text: String) -> Reply? {
        let n = normalized(text)
        if yes.contains(n) { return .yes }
        if no.contains(n) { return .no }
        return nil
    }

    /// "annule" and its variants, said right after an action.
    public static func isCancel(_ text: String) -> Bool {
        cancel.contains(normalized(text))
    }

    /// Lower case, no accents, no punctuation, single spaces; fillers at both ends dropped ("euh", "merci").
    static func normalized(_ text: String) -> String {
        var s = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        s = s.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        var words = s.split(separator: " ").map(String.init)
        let fillers: Set<String> = ["euh", "heu", "ben", "bah", "hmm", "alors", "mae", "hey", "he", "please"]
        while let first = words.first, fillers.contains(first) { words.removeFirst() }
        while let last = words.last, fillers.contains(last) { words.removeLast() }
        // Politeness at the end: "annule ça, s'il te plaît" = "annule ça".
        for polite in [["s", "il", "te", "plait"], ["s", "il", "vous", "plait"], ["stp"], ["merci"]]
        where words.count > polite.count && Array(words.suffix(polite.count)) == polite {
            words.removeLast(polite.count)
        }
        return words.joined(separator: " ")
    }
}
