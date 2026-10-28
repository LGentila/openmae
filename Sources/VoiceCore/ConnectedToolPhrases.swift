import Foundation

/// What Maé says about the connected tools' actions, in French: the sentence before "On y va ?", the line of the log.
/// Home Assistant's common actions get sentences of their own, from their arguments (« J’allume le salon avec Home
/// Assistant. »); any other action a sentence with the tool's name, the action and its arguments.
public enum ConnectedToolPhrases {
    static let nb = "\u{00A0}"

    /// The sentence before the user's "oui", with the question.
    public static func confirm(_ tool: MCPTool, _ arguments: [String: JSONValue], toolName: String) -> String {
        let doing = home(ConnectedTools.homeAssistantName(tool.name), arguments).map { "\($0.sentence) avec \(toolName)." }
            ?? "Je demande à \(toolName)\(nb): «\(nb)\(tool.title ?? tool.name)\(nb)»\(details(arguments))."
        return doing + " On y va\(nb)?"
    }

    /// The log's line: « Allumer le salon ».
    public static func title(_ tool: MCPTool, _ arguments: [String: JSONValue]) -> String {
        let name = ConnectedTools.homeAssistantName(tool.name)
        if let home = home(name, arguments) { return home.title }
        if name == "GetLiveContext" { return "Lire l’état de la maison" }
        return (tool.title ?? tool.name) + details(arguments)
    }

    /// What the card under Maé's sentence shows of an action (`ConnectedToolAction`).
    public struct CardWords: Sendable, Codable, Equatable {
        /// What it does: « Allumer ».
        public var verb: String
        /// What it acts on: « Salon »; nil when the call names nothing.
        public var target: String?
        /// What is true once it is done: « Salon allumé »; nil when there are no such words (the card shows the log's
        /// line then).
        public var result: String?

        public init(verb: String, target: String?, result: String?) {
            self.verb = verb
            self.target = target
            self.result = result
        }
    }

    /// The card's words: « Allumer » · « Salon », then « Salon allumé », for Home Assistant's common actions; for any
    /// other action, its title and its arguments' values.
    public static func card(_ tool: MCPTool, _ arguments: [String: JSONValue]) -> CardWords {
        let name = ConnectedTools.homeAssistantName(tool.name)
        if let home = home(name, arguments) { return CardWords(verb: home.verb, target: home.target, result: home.result) }
        if name == "GetLiveContext" { return CardWords(verb: "Lire l’état de la maison", target: nil, result: nil) }
        let values = arguments.keys.sorted().compactMap { key -> String? in
            let text: String = switch arguments[key] {
            case .array(let items)?: items.compactMap(\.text).joined(separator: ", ")
            case .object?, .null?, nil: ""
            case let value?: value.text ?? ""
            }
            return text.isEmpty ? nil : text
        }.joined(separator: ", ")
        let target = values.count > 60 ? String(values.prefix(59)) + "…" : values
        return CardWords(verb: tool.title ?? tool.name, target: target.isEmpty ? nil : target, result: nil)
    }

    public static let done = "C’est fait."

    public static func failed(_ toolName: String) -> String { "\(toolName) n’a pas pu le faire." }

    public static func cannotUndo(_ toolName: String) -> String {
        "Je ne peux pas défaire ce que j’ai demandé à \(toolName)."
    }

    /// Said when the service could not be asked.
    public static func unavailable(_ error: MCPError, _ toolName: String) -> String {
        switch error {
        case .noAnswer: "\(toolName) ne répond pas."
        case .unreachable: "Je n’arrive pas à joindre \(toolName)."
        case .unauthorized: "\(toolName) refuse l’accès. Reconnecte-le dans les réglages."
        case .notMCP, .refused: failed(toolName)
        }
    }

    /// What the model reads of it.
    static func errorForModel(_ error: MCPError, _ toolName: String) -> String {
        let why = switch error {
        case .noAnswer: "\(toolName) ne répond pas"
        case .unreachable: "\(toolName) est injoignable"
        case .unauthorized: "\(toolName) refuse l'accès"
        case .notMCP(let what): "\(toolName) a répondu autre chose (\(what))"
        case .refused(let message): "\(toolName) a refusé : \(message)"
        }
        return why + ". Rien n'est fait : ne dis pas que c'est fait."
    }

    // MARK: - Home Assistant

    /// One of Home Assistant's common actions, in words.
    struct HomeAction {
        /// « J’allume le salon ».
        var sentence: String
        /// The log's line: « Allumer le salon ».
        var title: String
        /// The card's: « Allumer » · « Salon », then « Salon allumé » (`CardWords`).
        var verb: String
        var target: String?
        var result: String?
    }

    /// « J’allume le salon », « Allumer le salon » and the card's words, for Home Assistant's common actions; nil for
    /// another one.
    static func home(_ name: String, _ a: [String: JSONValue]) -> HomeAction? {
        let domains = strings(a["domain"])
        let classes = strings(a["device_class"])
        let cover = domains.contains { ["cover", "valve"].contains($0) }
            || classes.contains { ["awning", "blind", "curtain", "damper", "door", "garage", "gate", "shade", "shutter",
                                    "window"].contains($0) }
        let lock = domains.contains("lock")
        /// `object`: what the sentence and the title say after the verb. On the card, `verb` (the infinitive unless
        /// said), what it acts on (`target`, the object unless said) and, once done, `done` after it (a participle that
        /// agrees with it), or the object itself when `objectIsResult` (« Lumière du salon à 50 % »).
        func verb(_ first: String, _ infinitive: String, _ object: String, card: String? = nil, target: String? = nil,
                  done: String? = nil, objectIsResult: Bool = false) -> HomeAction
        {
            let elided = "aeéèêiouh".contains(first.first ?? "x") ? "J’\(first)" : "Je \(first)"
            let acted = target ?? object
            let result = objectIsResult ? shown(object) : done.flatMap { agreed(acted, $0) }
            return HomeAction(sentence: "\(elided) \(object)", title: "\(infinitive) \(object)", verb: card ?? infinitive,
                              target: shown(acted), result: result)
        }
        switch name {
        case "HassTurnOn":
            let t = target(a)
            return cover ? verb("ouvre", "Ouvrir", t, done: "ouvert")
                : lock ? verb("verrouille", "Verrouiller", t, done: "verrouillé")
                : verb("allume", "Allumer", t, done: "allumé")
        case "HassTurnOff":
            let t = target(a)
            return cover ? verb("ferme", "Fermer", t, done: "fermé")
                : lock ? verb("déverrouille", "Déverrouiller", t, done: "déverrouillé")
                : verb("éteins", "Éteindre", t, done: "éteint")
        case "HassToggle":
            let t = target(a)
            return verb("change", "Changer", "l’état \(de(t))", card: "Changer l’état", target: t)
        case "HassLightSet":
            let t = target(a, noun: "la lumière")
            if let level = number(a["brightness"]) {
                return verb("règle", "Régler", "\(t) à \(level)\(nb)%", objectIsResult: true)
            }
            if let color = a["color"]?.text { return verb("mets", "Mettre", "\(t) en \(color)", objectIsResult: true) }
            if let kelvin = number(a["temperature"]) {
                return verb("règle", "Régler", "la teinte \(de(t)) à \(kelvin)\(nb)K", objectIsResult: true)
            }
            return verb("règle", "Régler", t)
        case "HassClimateSetTemperature":
            let t = target(a, noun: "le chauffage")
            guard let degrees = number(a["temperature"]) else { return verb("règle", "Régler", t) }
            return verb("règle", "Régler", "\(t) à \(degrees)\(nb)degrés", objectIsResult: true)
        case "HassSetPosition":
            let t = target(a, noun: "le volet")
            switch a["position"]?.integer {
            case 0?: return verb("ferme", "Fermer", t, done: "fermé")
            case 100?: return verb("ouvre", "Ouvrir", t, done: "ouvert")
            default:
                guard let position = number(a["position"]) else { return verb("règle", "Régler", t) }
                return verb("règle", "Régler", "\(t) à \(position)\(nb)%", objectIsResult: true)
            }
        case "HassMediaPause":
            let t = target(a, noun: "la musique")
            return verb("mets", "Mettre", "\(t) en pause", card: "Mettre en pause", target: t, objectIsResult: true)
        case "HassMediaUnpause": return verb("relance", "Relancer", target(a, noun: "la musique"), done: "relancé")
        case "HassMediaNext":
            let t = target(a, noun: "le lecteur")
            return verb("passe", "Passer", "à la suite sur \(t)", card: "Passer à la suite", target: t)
        case "HassMediaPrevious":
            let t = target(a, noun: "le lecteur")
            return verb("reviens", "Revenir", "en arrière sur \(t)", card: "Revenir en arrière", target: t)
        case "HassSetVolume":
            let t = target(a, noun: "le lecteur")
            guard let level = number(a["volume_level"]) else { return verb("règle", "Régler", "le volume \(de(t))") }
            return verb("règle", "Régler", "le volume \(de(t)) à \(level)\(nb)%", objectIsResult: true)
        default: return nil
        }
    }

    /// What a phrase names, as the card shows it: without its article, with a capital: « le salon » → « Salon », « les
    /// lumières de la cuisine » → « Lumières de la cuisine », « «Nova» » → « Nova »; nil for « ça » (nothing named).
    static func shown(_ phrase: String) -> String? {
        guard phrase != "ça" else { return nil }
        var text = phrase
        for article in ["le ", "la ", "les ", "l’"] where text.hasPrefix(article) {
            text.removeFirst(article.count)
            break
        }
        text = text.replacingOccurrences(of: "«\(nb)", with: "").replacingOccurrences(of: "\(nb)»", with: "")
        guard let first = text.first else { return nil }
        return first.uppercased() + text.dropFirst()
    }

    /// The phrase as the card shows it, then `participle` agreeing with it: (« la cuisine », « allumé ») → « Cuisine
    /// allumée », (« toutes les lumières », « éteint ») → « Toutes les lumières éteintes ». nil when its gender cannot be
    /// told (a name between quotes, a word the lists do not know).
    static func agreed(_ phrase: String, _ participle: String) -> String? {
        guard let shown = shown(phrase) else { return nil }
        let words = phrase.split(separator: " ").map(String.init)
        func gender(_ noun: String) -> Bool? {
            let noun = noun.lowercased()
            return Self.feminine.contains(noun) ? true : Self.masculine.contains(noun) ? false : nil
        }
        let isFeminine: Bool?
        var plural = false
        if phrase.hasPrefix("toutes les ") {
            isFeminine = true
            plural = true
        } else if phrase.hasPrefix("tous les ") {
            isFeminine = false
            plural = true
        } else if phrase.hasPrefix("les "), words.count > 1 {
            plural = true
            let noun = words[1].lowercased()
            isFeminine = noun.hasSuffix("s") || noun.hasSuffix("x") ? gender(String(noun.dropLast())) : gender(noun)
        } else if phrase.hasPrefix("la ") {
            isFeminine = true
        } else if phrase.hasPrefix("le ") {
            isFeminine = false
        } else if phrase.hasPrefix("l’"), let first = words.first {
            isFeminine = gender(String(first.dropFirst(2)))
        } else {
            isFeminine = nil
        }
        guard let isFeminine else { return nil }
        return "\(shown) \(participle)\(isFeminine ? "e" : "")\(plural ? "s" : "")"
    }

    /// What a Home Assistant call names: « le salon », « la lampe du salon », « les lumières de la cuisine », « toutes
    /// les lumières ».
    static func target(_ a: [String: JSONValue], noun: String? = nil) -> String {
        let domain = strings(a["domain"]).compactMap { domainNouns[$0] }.first
        let place = (a["area"]?.text ?? a["floor"]?.text).flatMap { $0.isEmpty ? nil : withArticle($0) }
        if let name = a["name"]?.text, !name.isEmpty {
            let named = withArticle(name)
            guard let place, !folded(named).contains(folded(bare(place))) else { return named }
            return "\(named) \(de(place))"
        }
        if let place {
            guard let domain else { return noun.map { "\($0) \(de(place))" } ?? place }
            return "\(domain.plural) \(de(place))"
        }
        if let domain { return "\(domain.feminine ? "toutes" : "tous") \(domain.plural)" }
        return noun ?? "ça"
    }

    private static let domainNouns: [String: (plural: String, feminine: Bool)] = [
        "light": ("les lumières", true), "cover": ("les volets", false), "switch": ("les prises", true),
        "fan": ("les ventilateurs", false), "lock": ("les serrures", true), "media_player": ("les lecteurs", false),
        "climate": ("les chauffages", false), "valve": ("les vannes", true), "vacuum": ("les aspirateurs", false),
    ]

    private static let feminine: Set<String> = [
        "cuisine", "chambre", "salle", "entrée", "lampe", "lumière", "terrasse", "cave", "buanderie", "véranda",
        "mezzanine", "prise", "télé", "télévision", "tv", "porte", "fenêtre", "serrure", "pièce", "maison", "suspension",
        "guirlande", "applique", "bibliothèque", "baie", "musique", "vanne", "chaudière", "clim", "climatisation",
        "piscine", "cour", "allée", "veilleuse", "enceinte", "bande", "led",
    ]
    private static let masculine: Set<String> = [
        "salon", "séjour", "bureau", "couloir", "garage", "jardin", "grenier", "sous-sol", "plafonnier", "volet", "store",
        "portail", "chauffage", "radiateur", "thermostat", "ventilateur", "lampadaire", "spot", "ruban", "éclairage",
        "rez-de-chaussée", "étage", "palier", "dressing", "cellier", "hall", "balcon", "abri", "atelier", "lecteur",
        "lustre", "climatiseur", "chauffe-eau", "lit", "rideau", "patio", "perron", "studio", "living", "aspirateur",
    ]

    /// With its article: « salon » → « le salon », « cuisine » → « la cuisine », « Lampe Nova » → « la lampe Nova »; a
    /// name it cannot tell, between quotes: « «Nova» ».
    static func withArticle(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.prefix(1).lowercased() + text.dropFirst()
        for article in ["le ", "la ", "les ", "l’", "l'"] where lower.hasPrefix(article) {
            return lower.replacingOccurrences(of: "l'", with: "l’", options: .anchored)
        }
        let first = String(lower.split(separator: " ").first ?? "").lowercased()
        let vowel = "aeiouyéèêâîôûh".contains(first.first ?? "x")
        let singular = String(first.dropLast())
        if ["wc", "toilettes"].contains(first)
            || (first.hasSuffix("s") || first.hasSuffix("x")) && (feminine.contains(singular) || masculine.contains(singular))
        {
            return "les \(lower)"
        }
        if feminine.contains(first) { return vowel ? "l’\(lower)" : "la \(lower)" }
        if masculine.contains(first) { return vowel ? "l’\(lower)" : "le \(lower)" }
        return "«\(nb)\(text)\(nb)»"
    }

    /// « le salon » → « du salon », « la cuisine » → « de la cuisine », « les volets » → « des volets ».
    static func de(_ phrase: String) -> String {
        if phrase.hasPrefix("le ") { return "du " + phrase.dropFirst(3) }
        if phrase.hasPrefix("les ") { return "des " + phrase.dropFirst(4) }
        return "de " + phrase
    }

    private static func bare(_ phrase: String) -> String {
        for article in ["le ", "la ", "les ", "l’"] where phrase.hasPrefix(article) { return String(phrase.dropFirst(article.count)) }
        return phrase.trimmingCharacters(in: CharacterSet(charactersIn: "«» \u{00A0}"))
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        switch value {
        case .array(let items)?: items.compactMap(\.text)
        case .string(let text)?: [text]
        default: []
        }
    }

    /// 20 → « 20 », 20.5 → « 20,5 ».
    static func number(_ value: JSONValue?) -> String? {
        switch value {
        case .int(let n)?: String(n)
        case .double(let d)?: d.rounded() == d ? String(Int(d)) : String(d).replacingOccurrences(of: ".", with: ",")
        case .string(let s)?:
            Double(s.replacingOccurrences(of: ",", with: ".")).map { $0.rounded() == $0 ? String(Int($0)) : s }
        default: nil
        }
    }

    /// « (name : salon, brightness : 50) », or nothing without arguments.
    static func details(_ arguments: [String: JSONValue]) -> String {
        let shown = arguments.keys.sorted().compactMap { key -> String? in
            guard let value = arguments[key] else { return nil }
            let text: String = switch value {
            case .array(let items): items.compactMap(\.text).joined(separator: ", ")
            case .object, .null: ""
            default: value.text ?? ""
            }
            return text.isEmpty ? nil : "\(key)\(nb): \(text)"
        }
        return shown.isEmpty ? "" : " (\(shown.joined(separator: ", ")))"
    }
}
