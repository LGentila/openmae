import Foundation

/// The delegation tools, as the model sees them, and the checks that need no task. Like the other actions
/// (ActionCatalog.swift), names, descriptions and the prompt are written in French on purpose. The benchmark
/// (`voice-cli actions-bench` with Tests/Fixtures/agents-fr.json) uses these same descriptions.
public enum AgentCatalog {
    public static let delegateName = "deleguer_tache"
    public static let statusName = "etat_taches"
    public static let followUpName = "completer_tache"
    public static let cancelName = "annuler_tache"

    /// What Claude Code is good at, in the tool's description.
    public static let claudeCodeDescription =
        "le code, les sites web et les applications, les recherches approfondies et le travail sur des fichiers"

    /// Appended to the system prompt when an agent is set up. In short: hand over long or heavy work (developing a
    /// site or an app, writing or fixing code, a thorough search, sorting or analysing files, a long document); the
    /// agent works on this Mac, with files and programs, so work on files is handed over too, never declared
    /// impossible; never a question, even about computing; call the tool rather than say a task will be handed over;
    /// the instruction repeats the request faithfully, with the user's details and nothing made up (the agent does
    /// not see the conversation); ask etat_taches instead of guessing how a task is going; sum up a finished task's
    /// result in one to three short sentences without technical details, saying what the agent was not allowed to do.
    public static let promptAddendum = """
        Tu peux aussi confier un travail long ou lourd à un agent avec deleguer_tache : développer un site ou une \
        application, écrire ou corriger du code, faire une recherche approfondie, trier ou analyser des fichiers, \
        rédiger un long document. L'agent travaille sur ce Mac, avec des fichiers et des programmes : un travail sur \
        des fichiers se confie aussi, ne réponds pas que c'est impossible. \
        Ne délègue jamais une simple question, même sur l'informatique ou le code : réponds-y toi-même. \
        Pour confier une tâche, appelle deleguer_tache ; ne dis jamais que tu vas la confier sans l'appeler. \
        L'agent ne voit pas la conversation : la consigne reprend fidèlement la demande, avec les détails donnés \
        par l'utilisateur, sans en inventer. \
        Pour savoir où en est une tâche, appelle etat_taches au lieu de deviner. \
        Quand etat_taches te donne le résultat d'une tâche, résume-le en une à trois phrases courtes, sans détails \
        techniques, et dis ce que l'agent n'a pas eu le droit de faire.
        """

    /// `agents`: each agent's name and what it is good at. `folders`: the names of the user's folders an agent may
    /// work in (otherwise each task gets a new folder).
    public static func delegate(agents: [(name: String, description: String)], folders: [String]) -> ToolSpec {
        var parameters: [ToolParameter] = []
        var description: String
        if let only = agents.first, agents.count == 1 {
            description = "Confie un travail long à \(only.name), un agent qui travaille seul et prévient quand il a "
                + "fini : \(only.description)."
        } else {
            description = "Confie un travail long à un agent qui travaille seul et prévient quand il a fini : "
                + agents.map { "\($0.name) pour \($0.description)" }.joined(separator: " ; ") + "."
            parameters.append(ToolParameter("agent", .oneOf(agents.map(\.name)),
                                            "L'agent qui convient, ou celui que l'utilisateur nomme.", required: true))
        }
        description += " Seulement quand l'utilisateur demande que ce travail soit fait."
        parameters += [
            ToolParameter("titre", .string, "Nom court de la tâche, de quatre à six mots, par exemple « site de la "
                          + "boulangerie ».", required: true),
            ToolParameter("consigne", .string, "Ce que l'agent doit faire, en français : la demande de l'utilisateur, "
                          + "fidèlement, avec les détails qu'il a donnés (l'agent ne voit pas la conversation).",
                          required: true),
        ]
        if !folders.isEmpty {
            parameters.append(ToolParameter("dossier", .oneOf(folders), "Le dossier où travailler, seulement si "
                                            + "l'utilisateur le nomme. Sinon, l'agent travaille dans un nouveau dossier."))
        }
        return ToolSpec(name: delegateName, description: description, parameters: parameters, risk: .sensitive)
    }

    public static let status = ToolSpec(
        name: statusName,
        description: "Dit où en sont les tâches confiées à un agent, ou leur résultat : « où en est le site ? », "
            + "« Claude Code a fini ? ».",
        parameters: [
            ToolParameter("reference", .string, "Quelques mots du titre de la tâche, ou son identifiant (par exemple "
                          + "d1). Absent pour les tâches en cours."),
        ],
        risk: .read)

    public static let followUp = ToolSpec(
        name: followUpName,
        description: "Ajoute une demande ou une précision à une tâche déjà confiée à un agent.",
        parameters: [
            ToolParameter("reference", .string, "Quelques mots du titre de la tâche, ou son identifiant (par exemple d1).",
                          required: true),
            ToolParameter("message", .string, "Ce qu'il faut ajouter, avec tous les détails : l'agent ne voit pas la "
                          + "conversation.", required: true),
        ],
        risk: .sensitive)

    public static let cancel = ToolSpec(
        name: cancelName,
        description: "Arrête une tâche confiée à un agent, quand l'utilisateur le demande.",
        parameters: [
            ToolParameter("reference", .string, "Quelques mots du titre de la tâche, ou son identifiant (par exemple d1).",
                          required: true),
        ],
        risk: .sensitive)

    /// The four tools, in the order the model sees them.
    public static func tools(agents: [(name: String, description: String)], folders: [String]) -> [ToolSpec] {
        guard !agents.isEmpty else { return [] }
        return [delegate(agents: agents, folders: folders), status, followUp, cancel]
    }

    public static let names: Set<String> = [delegateName, statusName, followUpName, cancelName]

    /// Checks a call against the rules that need no task (the benchmark's "would the app accept it").
    public static func check(_ call: ToolCall, context: ToolContext, agents: [String], folders: [String]) throws {
        let language = context.language
        func required(_ key: String) throws {
            guard call.text(key) != nil else {
                throw ToolRefusal(forModel: "Il manque « \(key) ».", spoken: AgentPhrases.notUnderstood(language))
            }
        }
        switch call.name {
        case delegateName:
            try required("titre")
            try required("consigne")
            if agents.count > 1 {
                let agent = call.text("agent") ?? ""
                guard agents.contains(agent) else {
                    throw ToolRefusal(forModel: "Agent inconnu : « \(agent) ». Agents : \(agents.joined(separator: ", ")).",
                                      spoken: AgentPhrases.notUnderstood(language))
                }
            }
            if let folder = call.text("dossier"), !folders.contains(folder) {
                throw ToolRefusal(forModel: "Dossier inconnu : « \(folder) ». Dossiers : \(folders.joined(separator: ", ")).",
                                  spoken: AgentPhrases.unknownFolder(folder, language))
            }
        case statusName:
            break
        case followUpName:
            try required("reference")
            try required("message")
        case cancelName:
            try required("reference")
        default:
            throw ToolRefusal(forModel: "Outil inconnu : \(call.name).", spoken: ActionPhrases.notUnderstood(language))
        }
    }
}
