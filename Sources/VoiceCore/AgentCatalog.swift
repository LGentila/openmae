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

    /// `promptAddendum` as it goes into the system prompt without the actions (Claude Code on its own, or with the web
    /// search and the built-in sources). The actions' part (`ActionCatalog.promptAddendum`) is then not there to say how
    /// to call a tool, so this one says it for the delegation: hand the work over at once, as asked, without asking about
    /// details (the user can add some later); say nothing before the call, not even the main prompt's short opening
    /// sentence (the app reads the task back); then, when the model can write one (`LanguageModel.toolCallText`), a
    /// whole answer that is a call, for `example`; and completer_tache only for a task handed over earlier in the
    /// conversation.
    ///
    /// In voice-cli actions-bench (Tests/Fixtures/agents-fr.json, --no-actions, 26 requests to hand over or ask about):
    /// with `promptAddendum` alone, Gemma 4 E4B asked about details or promised the work without calling (« Je peux faire
    /// ça pour toi. Je vais commencer la recherche maintenant. ») and got 6 right; with this part, 24 in each of three
    /// runs, but it then answered a question and called deleguer_tache after its answer 0, 3 and 1 times out of 26
    /// requests without a task (« Est-ce que Claude Code est payant ? »). A sentence telling it not to call after its own
    /// answer brought E4B down to 20 and 19. The rule to ask a short question when something essential is missing, as the
    /// actions' part has it, made E4B ask about details again (9 right). Gemma 4 E2B also needs `examples`.
    public static func promptAddendumWithoutActions(exampleCall: String?) -> String {
        let rules = """
            Tu peux confier un travail long ou lourd à un agent avec deleguer_tache : développer un site ou une \
            application, écrire ou corriger du code, faire une recherche approfondie, trier ou analyser des fichiers, \
            rédiger un long document. L'agent travaille sur ce Mac, avec des fichiers et des programmes : un travail sur \
            des fichiers se confie aussi, ne réponds pas que c'est impossible. \
            Ne délègue jamais une simple question, même sur l'informatique ou le code : réponds-y toi-même. \
            Quand l'utilisateur demande un tel travail, confie-le tout de suite, tel qu'il le demande, sans lui poser de \
            question, même si des détails manquent : l'agent fait au mieux, et l'utilisateur pourra préciser ensuite. \
            Ne dis rien avant l'appel, pas même la première phrase courte : ta réponse commence directement par l'appel \
            de deleguer_tache, et c'est l'app qui relit la tâche à voix haute.
            """
        let more = """
            Ne dis jamais que tu vas confier une tâche sans l'appeler. \
            completer_tache sert seulement à préciser une tâche confiée plus tôt dans cette conversation : une nouvelle \
            demande se confie avec deleguer_tache, même quand elle commence par « ajoute ». \
            L'agent ne voit pas la conversation : la consigne reprend fidèlement la demande, avec les détails donnés \
            par l'utilisateur, sans en inventer. \
            Pour savoir où en est une tâche, appelle etat_taches au lieu de deviner. \
            Quand etat_taches te donne le résultat d'une tâche, résume-le en une à trois phrases courtes, sans détails \
            techniques, et dis ce que l'agent n'a pas eu le droit de faire.
            """
        let shown = exampleCall.map { " Exemple : à « \(example.request) », ta réponse entière est \($0)" } ?? ""
        return rules + shown + " " + more
    }

    /// The request and the call `promptAddendumWithoutActions` shows as an example. Not a request of the benchmarks'
    /// corpora (see ActionCatalog): a model that copied it instead of the user's words must not be counted right.
    public static let example = (request: "Crée une application pour noter les scores de nos parties de cartes",
                                 call: ToolCall(name: delegateName, arguments: [
                                     "titre": "application des scores de cartes",
                                     "consigne": .string("Crée une application pour noter les scores des parties de "
                                         + "cartes de l'utilisateur."),
                                 ]))

    /// The exchanges conversations start with when the delegation is offered without the actions, on the tier whose
    /// model needs the actions' (`ActionCatalog.showsExamples`): three tasks of different kinds (an application, files,
    /// a document), each handed over at once with the user's words, as if it had happened. With `review` (the default
    /// setting), the call waits for the user's "oui", the app reads the task back, and the user says "Oui"; without it,
    /// the task starts at once ("d0", an id the app never gives). Unlike the actions' examples, each user message ends
    /// with the date line (at `now`), as the user's messages do.
    ///
    /// Gemma 4 E2B, with a part like `promptAddendumWithoutActions` but no example exchange, handed over 5 of the 26
    /// requests of voice-cli actions-bench (Tests/Fixtures/agents-fr.json, --no-actions): it said it would do the work
    /// (« Je lance le développement du site. ») and copied the date line into 41 of its 47 answers. With one example
    /// exchange 11 of 26; with these three without the date line 15 (the date line copied 28 times out of 32); with it,
    /// 22 in each of two runs with `promptAddendumWithoutActions` (copied 2 and 4 times out of 28), no request without a
    /// task called. Gemma 4 E4B did no better with them (24 of 26, and one remark taken for a task): it has none. The
    /// price, as for the actions' examples: asked what was handed over earlier, E2B may tell these tasks as if they had
    /// been.
    public static func examples(now: Date, timeZone: TimeZone = .current, agent: String, review: Bool) -> [ChatMessage] {
        let dateLine = ActionCatalog.dateLine(now, timeZone: timeZone)
        func said(_ text: String) -> ChatMessage { Conversation.userMessage(text, language: .french, dateLine: dateLine) }
        var messages: [ChatMessage] = []
        for (request, title, instruction) in exampleTasks {
            let call = ToolCall(name: delegateName, arguments: ["titre": .string(title), "consigne": .string(instruction)])
            if review {
                messages += [said(request), .call(call), .result(of: call, ["statut": "en attente du oui de l'utilisateur"]),
                             ChatMessage(.assistant, AgentPhrases.review(agent: agent, title: title, folder: nil, .french)),
                             said("Oui"), ChatMessage(.assistant, AgentPhrases.started(.french))]
            } else {
                messages += [said(request), .call(call),
                             .result(of: call, ["tache": "d0", "statut": "en cours", "agent": .string(agent)]),
                             ChatMessage(.assistant, AgentPhrases.started(.french))]
            }
        }
        return messages
    }

    /// The tasks of `examples`: the request, the title and the instruction. Not requests of the benchmarks' corpora.
    static let exampleTasks = [
        (example.request, "application des scores de cartes",
         "Crée une application pour noter les scores des parties de cartes de l'utilisateur."),
        ("Range les fichiers de mon bureau dans des dossiers par type", "rangement des fichiers du bureau",
         "Range les fichiers du bureau de l'utilisateur dans des dossiers, par type de fichier."),
        ("Prépare-moi un guide complet pour adopter un chat, avec les démarches et les coûts", "guide pour adopter un chat",
         "Prépare un guide complet pour adopter un chat, avec les démarches et les coûts."),
    ]

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
