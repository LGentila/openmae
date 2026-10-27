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

    /// « J’allume le salon » and « Allumer le salon », for Home Assistant's common actions; nil for another one.
    static func home(_ name: String, _ a: [String: JSONValue]) -> (sentence: String, title: String)? {
        let domains = strings(a["domain"])
        let classes = strings(a["device_class"])
        let cover = domains.contains { ["cover", "valve"].contains($0) }
            || classes.contains { ["awning", "blind", "curtain", "damper", "door", "garage", "gate", "shade", "shutter",
                                    "window"].contains($0) }
        let lock = domains.contains("lock")
        func verb(_ first: String, _ infinitive: String, _ target: String) -> (String, String) {
            let elided = "aeéèêiouh".contains(first.first ?? "x") ? "J’\(first)" : "Je \(first)"
            return ("\(elided) \(target)", "\(infinitive) \(target)")
        }
        switch name {
        case "HassTurnOn":
            let t = target(a)
            return cover ? verb("ouvre", "Ouvrir", t) : lock ? verb("verrouille", "Verrouiller", t)
                : verb("allume", "Allumer", t)
        case "HassTurnOff":
            let t = target(a)
            return cover ? verb("ferme", "Fermer", t) : lock ? verb("déverrouille", "Déverrouiller", t)
                : verb("éteins", "Éteindre", t)
        case "HassToggle":
            return verb("change", "Changer", "l’état \(de(target(a)))")
        case "HassLightSet":
            let t = target(a, noun: "la lumière")
            if let level = number(a["brightness"]) { return verb("règle", "Régler", "\(t) à \(level)\(nb)%") }
            if let color = a["color"]?.text { return verb("mets", "Mettre", "\(t) en \(color)") }
            if let kelvin = number(a["temperature"]) { return verb("règle", "Régler", "la teinte \(de(t)) à \(kelvin)\(nb)K") }
            return verb("règle", "Régler", t)
        case "HassClimateSetTemperature":
            let t = target(a, noun: "le chauffage")
            guard let degrees = number(a["temperature"]) else { return verb("règle", "Régler", t) }
            return verb("règle", "Régler", "\(t) à \(degrees)\(nb)degrés")
        case "HassSetPosition":
            let t = target(a, noun: "le volet")
            switch a["position"]?.integer {
            case 0?: return verb("ferme", "Fermer", t)
            case 100?: return verb("ouvre", "Ouvrir", t)
            default:
                guard let position = number(a["position"]) else { return verb("règle", "Régler", t) }
                return verb("règle", "Régler", "\(t) à \(position)\(nb)%")
            }
        case "HassMediaPause": return verb("mets", "Mettre", "\(target(a, noun: "la musique")) en pause")
        case "HassMediaUnpause": return verb("relance", "Relancer", target(a, noun: "la musique"))
        case "HassMediaNext": return verb("passe", "Passer", "à la suite sur \(target(a, noun: "le lecteur"))")
        case "HassMediaPrevious": return verb("reviens", "Revenir", "en arrière sur \(target(a, noun: "le lecteur"))")
        case "HassSetVolume":
            let t = target(a, noun: "le lecteur")
            guard let level = number(a["volume_level"]) else { return verb("règle", "Régler", "le volume \(de(t))") }
            return verb("règle", "Régler", "le volume \(de(t)) à \(level)\(nb)%")
        default: return nil
        }
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
        "lustre", "climatiseur", "chauffe-eau", "lit", "rideau", "patio", "perron", "studio", "living",
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
