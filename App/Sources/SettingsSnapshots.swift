#if DEBUG
import Foundation
import OpenMaeLink
import SwiftUI
import VoiceCore

/// Still pictures of the settings window (see `Snapshots`): every page in the states its design draws, named after the
/// design's screens (RgVoix, RgActionsRefuse…), each page whole, at its own height; then the states the design does
/// not draw (the Relay page, the sheets of received information, the pairing's expiry…), and the connected tools'
/// pages, drawn but not reachable yet. The scenes start from the default settings, not the user's.
extension Snapshots {
    private struct SettingsScene {
        var name: String
        var page: SettingsNavigation.Page
        var events: [AssistantEvent] = []
        var settings: (inout AssistantSettings) -> Void = { _ in }
        var phone = LinkStatus()
        var inbound = InboundStatus()
        var tools: [ConnectedTool] = []
        var prepare: @MainActor (SettingsNavigation, PhoneAccess, InboundAccess) -> Void = { _, _, _ in }
        /// What the model holds besides the engine's events (the shortcut to talk and its recording).
        var model: @MainActor (AssistantModel) -> Void = { _ in }
        /// A sheet that starts further on than the page can open it (adding a tool, half filled in).
        var sheet: AnyView?
        var sheetTop: CGFloat = 52
        var minHeight: CGFloat = 700
        /// The engine is ready (else: the scene's events say where it is).
        var startsReady = true
        /// The page a paged list shows (`PagedList`), from 0.
        var listPage = 0
    }

    @MainActor
    static func renderSettings(to folder: URL) async {
        let ready: [AssistantEvent] = [.ready(Demo.info), .storage(Demo.storage)]
        let now = Date()
        func ago(minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let shortcuts = ["Allumer le salon", "Mode concentration"]
        func actions(_ access: ActionsStatus.Access, shortcuts: [String] = shortcuts) -> AssistantEvent {
            .actions(ActionsStatus(calendar: access, reminders: access, shortcuts: shortcuts))
        }
        let claudeCodeReady = AssistantEvent.claudeCode(.ready(version: "2.1.206"))

        // iPhone and iPad
        let added = ISO8601DateFormatter().date(from: "2026-10-15T10:00:00Z") ?? now
        let iPhone = PairedDevice(publicKey: Data(repeating: 7, count: 32), name: "iPhone", model: "iPhone17,3",
                                  added: added)
        let iPad = PairedDevice(publicKey: Data(repeating: 8, count: 32), name: "iPad", model: "iPad14,1", added: added)
        let link = PairingLink(macID: String(repeating: "a", count: 26), macKey: Data(repeating: 1, count: 32),
                               relay: RelayClient.official, code: Data(repeating: 2, count: 32), macName: "MacBook Pro")
        var devices = LinkStatus()
        devices.devices = [iPhone, iPad]
        devices.stations = [iPad.id]
        devices.relay = .registered
        devices.local = true
        var noDevice = LinkStatus()
        noDevice.relayChoice = .none
        noDevice.relay = .off
        var homeOnly = devices
        homeOnly.relayChoice = .none
        homeOnly.relay = .off
        var relayDown = devices
        relayDown.relay = .unreachable
        var pairing = devices
        pairing.pairing = .waiting(link, expires: now.addingTimeInterval(272))
        var expired = devices
        expired.pairing = .expired
        var paired = devices
        paired.pairing = .added(iPhone)

        // Received information
        let relay = URL(string: "http://192.168.1.10:8080")!
        let inboundName = "q4mzfxk2v7hn3brt6wdpya5ce2"
        /// A secret as the host makes them (32 bytes in base64url), but always the same.
        func secret(_ seed: Int) -> String {
            Data((0..<32).map { UInt8(($0 * 37 + seed * 101 + 11) % 256) }).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let homeAssistant = InboundSource(name: "Home Assistant", mayBeUrgent: true, created: ago(minutes: 9000))
        let garage = InboundSource(name: "Porte du garage", mode: .notifyOnly, created: ago(minutes: 6000))
        let backups = InboundSource(name: "Script des sauvegardes", paused: true, created: ago(minutes: 3000))
        let washer = "La machine à laver a fini."
        let homeAssistantLog = [
            InboundLogEntry(date: ago(minutes: 1), path: .homeRelay, form: .json, result: .duplicate,
                            caller: "192.168.1.20", text: washer),
            InboundLogEntry(date: ago(minutes: 2), path: .homeRelay, form: .json, result: .said, caller: "192.168.1.20",
                            text: washer),
            InboundLogEntry(date: ago(minutes: 26), path: nil, form: .text, result: .said,
                            text: InboundPhrases.test(source: homeAssistant.name)),
            InboundLogEntry(date: ago(minutes: 48), path: .homeRelay, form: .json, result: .noText,
                            caller: "192.168.1.20", detail: InboundRefusal.noText.explanation),
            InboundLogEntry(date: ago(minutes: 75), path: .homeRelay, form: .json, result: .expired,
                            caller: "192.168.1.20", text: "Quelqu’un a sonné à la porte d’entrée."),
            InboundLogEntry(date: ago(minutes: 130), path: .homeRelay, form: .json, result: .notifiedAndKept,
                            caller: "192.168.1.20", text: "Fumée détectée dans la cuisine."),
        ]
        let garageLog = [
            InboundLogEntry(date: ago(minutes: 180), path: .homeRelay, form: .text, result: .notified,
                            caller: "192.168.1.35", text: "La porte du garage est restée ouverte."),
        ]
        var connected = InboundStatus()
        connected.homeRelayAddress = relay
        connected.homeRelay = .connected
        connected.inboundName = inboundName
        connected.sources = [homeAssistant, garage, backups]
        connected.logs = [homeAssistant.id: homeAssistantLog, garage.id: garageLog]
        for (i, source) in connected.sources.enumerated() {
            connected.addresses[source.id] = relay.appending(path: inboundName).appending(path: "in")
                .appending(path: secret(i))
        }
        connected.publicRelayAddress = URL(string: "https://relay.openmae.com")!
        connected.inboundDomain = "in.openmae.com"
        connected.internetPath = .available
        var relayUnreachable = connected
        relayUnreachable.homeRelay = .unreachable
        let webhook = InboundSource(name: "Alerte du serveur", origin: .internet, mayBeUrgent: true,
                                    created: ago(minutes: 2000))
        var internet = connected
        internet.internetPath = .ready
        internet.certificateExpiry = now.addingTimeInterval(80 * 86_400)
        internet.sources = [homeAssistant, webhook, garage]
        internet.addresses[webhook.id] = URL(string: "https://\(inboundName).in.openmae.com/in/\(secret(7))")!
        internet.logs[webhook.id] = [
            InboundLogEntry(date: ago(minutes: 12), path: .publicRelay, form: .json, result: .said, caller: "203.0.113.7",
                            text: "La sauvegarde de cette nuit a réussi."),
            InboundLogEntry(date: ago(minutes: 40), path: .homeRelay, form: .text, result: .wrongPath,
                            caller: "192.168.1.20"),
        ]
        var certificate = internet
        certificate.internetPath = .gettingCertificate
        certificate.certificateExpiry = nil
        certificate.certificateProblem = "refused: Fetching http://\(inboundName).in.openmae.com/.well-known/acme-challenge/…: 404"
        var notOffered = internet
        notOffered.internetPath = .notOffered
        notOffered.inboundDomain = nil
        notOffered.addresses[webhook.id] = nil
        var internetDown = internet
        internetDown.internetPath = .unreachable
        // The news: quiet hours, announcements off, a source kept for later.
        var quiet = connected
        quiet.preferences = InboundPreferences(quietHours: QuietHours(enabled: true))
        var silent = connected
        silent.preferences = InboundPreferences(announcements: false)
        let gladys = InboundSource(name: "Gladys", mode: .keepForLater, created: ago(minutes: 4000))
        var keeping = connected
        keeping.sources = [homeAssistant, gladys, garage]
        keeping.addresses[gladys.id] = relay.appending(path: inboundName).appending(path: "in").appending(path: secret(5))
        keeping.logs[gladys.id] = [
            InboundLogEntry(date: ago(minutes: 30), path: .homeRelay, form: .json, result: .kept, caller: "192.168.1.40",
                            text: "Le linge est prêt."),
            InboundLogEntry(date: ago(minutes: 140), path: .homeRelay, form: .json, result: .kept,
                            caller: "192.168.1.40", text: "Le lave-vaisselle a fini."),
        ]
        // A month of a source's deliveries, ten at a time.
        let station = InboundSource(name: "Station météo", created: ago(minutes: 50_000))
        let stationTexts: [(String, InboundLogEntry.Result)] = [
            ("Il a plu 4\u{00A0}mm cette nuit.", .said), ("Le vent dépasse 60\u{00A0}km/h.", .said),
            ("Il gèle dehors\u{00A0}: pense aux plantes.", .expired), ("Le vent dépasse 60\u{00A0}km/h.", .duplicate),
            ("Il fait 31\u{00A0}degrés au jardin.", .said), ("La batterie de la station est faible.", .kept),
        ]
        var month = connected
        month.sources = [homeAssistant, station, garage]
        month.addresses[station.id] = relay.appending(path: inboundName).appending(path: "in").appending(path: secret(6))
        month.logs[station.id] = (0..<37).map { i in
            let (text, result) = stationTexts[i % stationTexts.count]
            return InboundLogEntry(date: ago(minutes: 7 + Double(i) * 1_100), path: .homeRelay, form: .json,
                                   result: result, caller: "192.168.1.50", text: text)
        }

        // Memory: what Maé remembers, oldest first, as the engine sends it.
        let remembered = ["Allergique aux noix de cajou", "Sa fille s’appelle Inès", "Préfère le train à l’avion",
                     "Le garagiste s’appelle Rémi, à Pontivy", "Boit son café sans sucre",
                     "Anniversaire de sa mère le 3 mars", "Le voisin garde un double des clés",
                     "Va à la piscine le mardi soir", "Le chat s’appelle Biscotte", "Préfère les réponses courtes",
                     "Travaille de chez lui le vendredi", "Son dentiste est le docteur Le Gall",
                     "Ne mange pas de viande le lundi", "Contrôle technique de la voiture en mai",
                     "Aime le jazz manouche", "Son frère habite à Nantes", "Arrose les tomates tous les deux jours",
                     "Lit un roman de Pagnol en ce moment", "Joue au badminton le jeudi",
                     "Rendez-vous chez le notaire en novembre", "Préfère le thé vert l’après-midi",
                     "Réunion d’équipe le lundi à 9\u{00A0}h", "Aime randonner sur le GR34",
                     "Lave le linge à 30\u{00A0}degrés",
                     "Ses parents arrivent pour Noël"]
        func memory(_ entries: [String], exchanges: Int = 0) -> AssistantEvent {
            .memory(MemoryOverview(entries: entries, characters: entries.reduce(0) { $0 + $1.count },
                                   capacity: MemorySheet.capacity, exchanges: exchanges,
                                   folder: "/Users/me/Library/Application Support/OpenMaé/Memory"))
        }
        let memoryOn: (inout AssistantSettings) -> Void = { $0.memory.enabled = true }
        let journalOn: (inout AssistantSettings) -> Void = { s in
            s.memory.enabled = true
            s.memory.journal = true
        }
        // The same Mac on the standard tier, whose model is not offered the past conversations.
        var standardInfo = Demo.info
        standardInfo.tier = .standard
        standardInfo.languageModel = "Gemma 4 E4B"

        // Relay. As the user's own: the OpenMaé relay, two devices, a source from the internet, no home relay.
        let homeAssistantOnline = InboundSource(name: "Home Assistant", origin: .internet, mayBeUrgent: true,
                                                created: ago(minutes: 9000))
        var online = InboundStatus()
        online.publicRelayAddress = RelayClient.official
        online.inboundName = inboundName
        online.inboundDomain = "in.openmae.com"
        online.internetPath = .ready
        online.certificateExpiry = now.addingTimeInterval(80 * 86_400)
        online.sources = [homeAssistantOnline]
        online.addresses[homeAssistantOnline.id] = URL(string: "https://\(inboundName).in.openmae.com/in/\(secret(3))")!
        online.logs[homeAssistantOnline.id] = [
            InboundLogEntry(date: ago(minutes: 3), path: .publicRelay, form: .json, result: .said,
                            caller: "203.0.113.7", text: washer),
        ]
        let ownRelay = URL(string: "https://relais.example.org")!
        var ownLink = devices
        ownLink.relayChoice = .custom(ownRelay)
        var ownOnline = online
        ownOnline.publicRelayAddress = ownRelay
        ownOnline.inboundDomain = "in.example.org"
        ownOnline.addresses[homeAssistantOnline.id] =
            URL(string: "https://\(inboundName).in.example.org/in/\(secret(3))")!
        var noDomain = ownOnline
        noDomain.inboundDomain = nil
        noDomain.internetPath = .notOffered
        noDomain.certificateExpiry = nil
        noDomain.addresses[homeAssistantOnline.id] = nil
        var offline = online
        offline.publicRelayAddress = nil
        offline.inboundDomain = nil
        offline.internetPath = .notOffered
        offline.certificateExpiry = nil
        offline.addresses[homeAssistantOnline.id] = nil
        var relayConnecting = devices
        relayConnecting.relay = .connecting
        var checking = online
        checking.internetPath = .checking
        var onlineDown = online
        onlineDown.internetPath = .unreachable
        var gettingCertificate = online
        gettingCertificate.internetPath = .gettingCertificate
        gettingCertificate.certificateExpiry = nil
        var certificateFailing = gettingCertificate
        certificateFailing.certificateProblem = certificate.certificateProblem
        // Nothing uses the internet relay yet: what it offers was read.
        var unused = InboundStatus()
        unused.publicRelayAddress = RelayClient.official
        unused.inboundName = inboundName
        unused.inboundDomain = "in.openmae.com"
        unused.internetPath = .available
        var notHomeMode = relayUnreachable
        notHomeMode.homeRelay = .notHomeMode
        // Received information without the relays its sources need.
        var noRelay = InboundStatus()
        noRelay.inboundName = inboundName
        noRelay.sources = [homeAssistant, webhook]
        let relaysForSheets = RelayAccess(phone: PhoneAccess(link: nil, status: devices),
                                          inbound: InboundAccess(host: nil, status: online), passesInternetRelay: false)

        // Connected tools (made-up ones: the pictures do not ask a real service)
        func action(_ id: String, _ title: String, reads: Bool = false, on: Bool = true) -> ConnectedTool.Action {
            ConnectedTool.Action(id: id, title: title, reads: reads, enabled: on)
        }
        let homeActions = [action("GetLiveContext", "Lire l’état de la maison", reads: true),
                           action("HassTurnOn", "Allumer"), action("HassTurnOff", "Éteindre"),
                           action("HassLightSet", "Régler une lumière"),
                           action("HassClimateSetTemperature", "Régler le chauffage"),
                           action("HassSetPosition", "Ouvrir ou fermer", on: false)]
            + (1...8).map { action("HassAction\($0)", "Action \($0)") }
        let at = { (hour: Int, minute: Int) in
            Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        }
        let homeTool = ConnectedTool(name: "Home Assistant", icon: .home, color: Palette.turquoiseSoft, place: .home,
                                     connection: .service(address: "http://homeassistant.local:8123/api/mcp",
                                                          access: .token),
                                     actions: homeActions,
                                     log: [.init(date: at(11, 35), title: "Allumer le salon", result: .done),
                                           .init(date: at(11, 10), title: "Régler le chauffage à 19 °", result: .done),
                                           .init(date: at(10, 48), title: "Ouvrir le portail", result: .refusedByUser),
                                           .init(date: at(10, 21), title: "Éteindre la cuisine",
                                                 result: .failed("pas de réponse"))],
                                     lastTest: .works(actions: 14, seconds: 0.4),
                                     accessNote: "Seuls les comptes administrateur de Home Assistant peuvent se connecter.")
        let notes = ConnectedTool(name: "Notes", icon: .document, color: Palette.sunSoft, place: .thisMac,
                                  connection: .program(command: "npx -y @modelcontextprotocol/server-filesystem",
                                                       arguments: "~/Documents/Notes"),
                                  actions: (1...6).map { action("notes_\($0)", "Action \($0)", reads: $0 < 4) })
        let github = ConnectedTool(name: "GitHub", icon: .branch, color: Palette.azureSoft, place: .internet,
                                   connection: .service(address: "https://api.githubcopilot.com/mcp/", access: .account),
                                   state: .needsReconnect,
                                   actions: (1...9).map { action("github_\($0)", "Action \($0)") })
        let todoist = ConnectedTool(name: "Todoist", icon: .smallCheck, color: Palette.coralSoft, place: .internet,
                                    connection: .service(address: "https://ai.todoist.net/mcp", access: .token),
                                    state: .paused, enabled: false,
                                    actions: (1...12).map { action("todoist_\($0)", "Action \($0)") })
        var homeToolDown = homeTool
        homeToolDown.state = .unreachable
        homeToolDown.enabled = false
        homeToolDown.lastTest = .noAnswer
        homeToolDown.log.insert(.init(date: at(11, 42), title: "Allumer le salon", result: .failed("pas de réponse")),
                                at: 0)
        let tools = [homeTool, notes, github, todoist]
        let navigationForSheets = SettingsNavigation()
        let emptyTools = ConnectedToolsAccess()
        var service = ConnectedToolsAccess.Draft()
        service.name = "Home Assistant"
        service.address = "http://homeassistant.local:8123/api/mcp"
        var program = ConnectedToolsAccess.Draft()
        program.kind = .program
        program.name = "Notes"
        program.command = "npx -y @modelcontextprotocol/server-filesystem"
        program.arguments = "~/Documents/Notes"

        var downloading = DownloadProgress(doneBytes: 8_060_000_000, totalBytes: 17_520_000_000)
        downloading.currentModel = "Gemma 4 26B-A4B"
        // The first download: speech recognition and the voice are there, the language model on its way.
        var halfway = Demo.storage
        halfway.usedBytes = 8_050_000_000
        halfway.models[2].bytes = 5_900_000_000
        halfway.models[2].missingBytes = 9_470_000_000
        let setup: [AssistantEvent] = [.setupNeeded(Demo.setup), .downloadProgress(downloading), .storage(halfway)]
        // The comfort tier's models, and the minimum and standard tiers' language models kept from earlier tries.
        let bigStorage = AssistantEvent.storage(Demo.storageWithOtherTiers)
        let standardModel = ModelCatalog.languageModel(for: .standard)!
        var oneDeleted = Demo.storageWithOtherTiers
        oneDeleted.models.removeAll { $0.id == standardModel.id }
        oneDeleted.usedBytes -= standardModel.totalBytes
        func ownShortcut(_ model: AssistantModel) {
            model.talkShortcut = Demo.recordedShortcut
        }
        func wakeWordLog(_ s: inout AssistantSettings) {
            s.listening = .wakeWord
            s.wakeLog = true
        }
        func claudeCode(review: Bool, mode: AgentSettings.PermissionMode) -> (inout AssistantSettings) -> Void {
            { s in
                s.actionsEnabled = true
                s.claudeCode.enabled = true
                s.claudeCode.review = review
                s.claudeCode.permissionMode = mode
                s.claudeCode.folders = ["/Users/me/Projets/Sites"]
            }
        }
        func search(_ source: WebSearchSource, key: Bool = false, address: String = "", username: String = "")
            -> (inout AssistantSettings) -> Void
        {
            { s in
                s.webSearch.enabled = true
                s.webSearch.source = source
                s.webSearch.braveKeySaved = key
                s.webSearch.address = address
                s.webSearch.username = username
            }
        }

        let scenes: [SettingsScene] = [
            // Voice and sound
            SettingsScene(name: "RgVoix", page: .voice),
            SettingsScene(name: "RgVoixCasque", page: .voice, settings: { s in
                s.audioMode = .headphones
                s.listening = .pushToTalk
            }),
            SettingsScene(name: "RgVoix-ok-mae", page: .voice, settings: { $0.listening = .wakeWord }),
            // The shortcut to talk: one of the user's own, being recorded, refused, refused by macOS at launch.
            SettingsScene(name: "RgVoix-raccourci-perso", page: .voice, model: ownShortcut),
            SettingsScene(name: "RgVoix-raccourci-enregistrement", page: .voice, model: { model in
                ownShortcut(model)
                model.isRecordingTalkShortcut = true
            }),
            SettingsScene(name: "RgVoix-raccourci-refuse", page: .voice, model: { model in
                model.isRecordingTalkShortcut = true
                model.talkShortcutRefusal = .usedByApps
            }),
            SettingsScene(name: "RgVoix-raccourci-indisponible", page: .voice, model: { model in
                model.hasTalkShortcut = false
                model.talkShortcutRefusal = .refusedByMacOS
            }),
            // Actions
            SettingsScene(name: "RgActions", page: .actions, events: [actions(.granted)], settings: { s in
                s.actionsEnabled = true
                s.shortcutsToConfirm = ["Mode concentration"]
            }),
            SettingsScene(name: "RgActionsRefuse", page: .actions, events: [actions(.denied, shortcuts: [])],
                          settings: { $0.actionsEnabled = true }),
            SettingsScene(name: "RgActionsOff", page: .actions),
            SettingsScene(name: "RgActions-pas-encore-demande", page: .actions, events: [actions(.notAsked)],
                          settings: { s in
                              s.actionsEnabled = true
                              s.shortcutsToConfirm = shortcuts
                          }),
            // Agents
            SettingsScene(name: "RgAgents", page: .agents, events: [actions(.granted), claudeCodeReady],
                          settings: claudeCode(review: true, mode: .acceptEdits)),
            SettingsScene(name: "RgAgentsAbsent", page: .agents, events: [actions(.granted), .claudeCode(.notInstalled)],
                          settings: { $0.actionsEnabled = true }),
            SettingsScene(name: "RgAgents-a-connecter", page: .agents,
                          events: [actions(.granted), .claudeCode(.notLoggedIn)],
                          settings: claudeCode(review: true, mode: .acceptEdits)),
            // Claude Code does without the actions: on, it is ready with them off.
            SettingsScene(name: "RgAgents-actions-eteintes", page: .agents, events: [claudeCodeReady],
                          settings: { $0.claudeCode.enabled = true }),
            SettingsScene(name: "RgAgentFiche", page: .agents, events: [actions(.granted), claudeCodeReady],
                          settings: claudeCode(review: true, mode: .acceptEdits),
                          prepare: { navigation, _, _ in navigation.showsAgent = true }),
            SettingsScene(name: "RgAgentFicheSeul", page: .agents, events: [actions(.granted), claudeCodeReady],
                          settings: claudeCode(review: false, mode: .auto),
                          prepare: { navigation, _, _ in navigation.showsAgent = true }),
            // Internet search
            SettingsScene(name: "RgWeb", page: .webSearch, events: [.webSearchTested(.works(results: 5, seconds: 0.62))],
                          settings: search(.brave, key: true)),
            SettingsScene(name: "RgWebSansCle", page: .webSearch, settings: search(.brave)),
            SettingsScene(name: "RgWebRefuse", page: .webSearch, events: [.webSearchTested(.failed(.unauthorized))],
                          settings: search(.brave, key: true)),
            SettingsScene(name: "RgWebSearx", page: .webSearch,
                          events: [.webSearchTested(.works(results: 5, seconds: 0.62))],
                          settings: search(.searxng, address: "https://searx.maison.lan")),
            SettingsScene(name: "RgWebSearxRefuse", page: .webSearch, events: [.webSearchTested(.failed(.unauthorized))],
                          settings: search(.searxng, address: "https://searx.maison.lan", username: "maé")),
            SettingsScene(name: "RgWeb-eteinte", page: .webSearch),
            // The weather, rates and travel times, on the same page (not in the design)
            SettingsScene(name: "RgWeb-meteo-cours-trajets", page: .webSearch,
                          events: [.webSearchTested(.works(results: 5, seconds: 0.62))], settings: { s in
                              search(.brave, key: true)(&s)
                              s.builtInSources = true
                          }),
            SettingsScene(name: "RgWeb-meteo-seule", page: .webSearch, settings: { $0.builtInSources = true }),
            SettingsScene(name: "RgWeb-retirer-cle", page: .webSearch, settings: search(.brave, key: true),
                          prepare: { navigation, _, _ in navigation.sheet = .removeBraveKey }),
            // Memory (not in the design): what Maé remembers, ten at a time
            SettingsScene(name: "RgMemoire", page: .memory, events: [memory(remembered)], settings: memoryOn),
            SettingsScene(name: "RgMemoire-page-3", page: .memory, events: [memory(remembered)], settings: memoryOn,
                          listPage: 2),
            SettingsScene(name: "RgMemoire-quelques-notes", page: .memory,
                          events: [memory(Array(remembered.prefix(4)))], settings: memoryOn),
            SettingsScene(name: "RgMemoire-vide", page: .memory, events: [memory([])], settings: memoryOn),
            SettingsScene(name: "RgMemoire-eteinte", page: .memory, events: [memory(remembered)]),
            SettingsScene(name: "RgMemoire-tout-effacer", page: .memory, events: [memory(remembered)],
                          settings: memoryOn, prepare: { navigation, _, _ in navigation.sheet = .eraseMemory }),
            // The past conversations kept (the journal): on the comfort tier; then on the standard one, which does not
            // offer them, the switch saved on all the same
            SettingsScene(name: "RgMemoire-conversations", page: .memory,
                          events: [memory(Array(remembered.prefix(4)), exchanges: 1_248)], settings: journalOn),
            SettingsScene(name: "RgMemoire-conversations-vides", page: .memory,
                          events: [memory(Array(remembered.prefix(4)))], settings: journalOn),
            SettingsScene(name: "RgMemoire-conversations-autre-palier", page: .memory,
                          events: [.ready(standardInfo), memory(Array(remembered.prefix(4)), exchanges: 1_248)],
                          settings: journalOn),
            SettingsScene(name: "RgMemoire-effacer-conversations", page: .memory,
                          events: [memory(Array(remembered.prefix(4)), exchanges: 1_248)], settings: journalOn,
                          prepare: { navigation, _, _ in navigation.sheet = .clearMemoryJournal }),
            // Connected tools
            SettingsScene(name: "RgMcp", page: .tools, tools: tools),
            SettingsScene(name: "RgMcpVide", page: .tools),
            SettingsScene(name: "RgMcpOutil", page: .tools, tools: [homeTool],
                          prepare: { navigation, _, _ in navigation.tool = homeTool.id }),
            SettingsScene(name: "RgMcpOutilErreur", page: .tools, tools: [homeToolDown],
                          prepare: { navigation, _, _ in navigation.tool = homeToolDown.id }),
            SettingsScene(name: "RgMcpAjout", page: .tools, tools: tools,
                          prepare: { navigation, _, _ in navigation.sheet = .addTool }),
            SettingsScene(name: "RgMcpAjoutAdresse", page: .tools, tools: tools,
                          sheet: AnyView(AddToolSheet(tools: emptyTools, navigation: navigationForSheets, step: .form,
                                                      draft: service, trial: .connected(actions: 14))),
                          sheetTop: 40),
            SettingsScene(name: "RgMcpAjoutProgramme", page: .tools, tools: tools,
                          sheet: AnyView(AddToolSheet(tools: emptyTools, navigation: navigationForSheets, step: .form,
                                                      draft: program)),
                          sheetTop: 60),
            SettingsScene(name: "RgMcpAjoutEchec", page: .tools, tools: tools,
                          sheet: AnyView(AddToolSheet(tools: emptyTools, navigation: navigationForSheets, step: .form,
                                                      draft: service,
                                                      trial: .failed("Home Assistant ne répond pas. Vérifie l’adresse et que ce Mac est sur le même réseau."))),
                          sheetTop: 40),
            // Relay (not in the design)
            SettingsScene(name: "RgRelais", page: .relay, phone: devices, inbound: online),
            SettingsScene(name: "RgRelais-ton-relais", page: .relay, phone: ownLink, inbound: ownOnline),
            SettingsScene(name: "RgRelais-eteint", page: .relay, phone: homeOnly, inbound: offline),
            SettingsScene(name: "RgRelais-connexion", page: .relay, phone: relayConnecting, inbound: checking),
            SettingsScene(name: "RgRelais-injoignable", page: .relay, phone: relayDown, inbound: onlineDown),
            SettingsScene(name: "RgRelais-certificat", page: .relay, phone: devices, inbound: gettingCertificate),
            SettingsScene(name: "RgRelais-certificat-echec", page: .relay, phone: devices, inbound: certificateFailing),
            SettingsScene(name: "RgRelais-pas-de-domaine", page: .relay, phone: ownLink, inbound: noDomain),
            SettingsScene(name: "RgRelais-inutilise", page: .relay, inbound: unused),
            SettingsScene(name: "RgRelais-maison", page: .relay, phone: devices, inbound: internet),
            SettingsScene(name: "RgRelais-maison-injoignable", page: .relay, phone: devices, inbound: relayUnreachable),
            SettingsScene(name: "RgRelais-maison-pas-en-mode-maison", page: .relay, phone: devices,
                          inbound: notHomeMode),
            SettingsScene(name: "RgRelais-maison-adresse", page: .relay, phone: devices, inbound: online,
                          prepare: { navigation, _, _ in navigation.sheet = .homeRelay }),
            SettingsScene(name: "RgRelais-maison-adresse-refusee", page: .relay, phone: devices, inbound: online,
                          sheet: AnyView(RelayAddressSheet(kind: .home, relays: relaysForSheets,
                                                           navigation: navigationForSheets, text: "192.168.1.10 8080",
                                                           isRefused: true)),
                          sheetTop: 120),
            SettingsScene(name: "RgRelais-ton-relais-adresse", page: .relay, phone: devices, inbound: online,
                          prepare: { navigation, _, _ in navigation.sheet = .ownRelay }),
            // iPhone and iPad
            SettingsScene(name: "RgAppareils", page: .devices, phone: devices),
            SettingsScene(name: "RgAppareilsVide", page: .devices, phone: noDevice),
            SettingsScene(name: "RgAppareilsMaison", page: .devices, phone: homeOnly),
            SettingsScene(name: "RgAppareilsRelaisHS", page: .devices, phone: relayDown),
            SettingsScene(name: "RgAppareilsQr", page: .devices, phone: pairing),
            SettingsScene(name: "RgAppareils-code-expire", page: .devices, phone: expired),
            SettingsScene(name: "RgAppareils-ajoute", page: .devices, phone: paired),
            SettingsScene(name: "RgAppareils-retirer", page: .devices, phone: devices,
                          prepare: { _, phone, _ in phone.removing = iPhone.id }),
            // Received information
            SettingsScene(name: "RgInfos", page: .inbound, inbound: connected),
            SettingsScene(name: "RgInfosVide", page: .inbound),
            SettingsScene(name: "RgInfosSource", page: .inbound, inbound: connected,
                          prepare: { _, _, inbound in inbound.page = .source(homeAssistant.id) }),
            SettingsScene(name: "RgInfos-relais-injoignable", page: .inbound, inbound: relayUnreachable),
            SettingsScene(name: "RgInfos-internet", page: .inbound, inbound: internet),
            SettingsScene(name: "RgInfos-internet-certificat", page: .inbound, inbound: certificate),
            SettingsScene(name: "RgInfos-internet-pas-propose", page: .inbound, inbound: notOffered),
            SettingsScene(name: "RgInfos-internet-injoignable", page: .inbound, inbound: internetDown),
            SettingsScene(name: "RgInfos-source-internet", page: .inbound, inbound: internet,
                          prepare: { _, _, inbound in inbound.page = .source(webhook.id) }),
            SettingsScene(name: "RgInfos-ajouter-source", page: .inbound, inbound: internet,
                          prepare: { _, _, inbound in inbound.sheet = .addSource }),
            SettingsScene(name: "RgInfos-relais-internet", page: .inbound, phone: devices, inbound: online),
            SettingsScene(name: "RgInfosSource-relais-internet", page: .inbound, phone: devices, inbound: online,
                          prepare: { _, _, inbound in inbound.page = .source(homeAssistantOnline.id) }),
            SettingsScene(name: "RgInfos-ajouter-source-un-relais", page: .inbound, phone: devices, inbound: online,
                          prepare: { _, _, inbound in inbound.sheet = .addSource }),
            SettingsScene(name: "RgInfos-sans-relais", page: .inbound, phone: homeOnly, inbound: noRelay),
            SettingsScene(name: "RgInfosSource-sans-relais", page: .inbound, phone: homeOnly, inbound: noRelay,
                          prepare: { _, _, inbound in inbound.page = .source(webhook.id) }),
            SettingsScene(name: "RgInfos-ajouter-source-sans-relais", page: .inbound, phone: homeOnly, inbound: noRelay,
                          prepare: { _, _, inbound in inbound.sheet = .addSource }),
            SettingsScene(name: "RgInfos-changer-relais", page: .inbound, inbound: internet,
                          prepare: { _, _, inbound in
                              inbound.page = .source(homeAssistant.id)
                              inbound.sheet = .changeRelay(homeAssistant.id, .internet)
                          }),
            SettingsScene(name: "RgInfos-changer-adresse", page: .inbound, inbound: connected,
                          prepare: { _, _, inbound in
                              inbound.page = .source(homeAssistant.id)
                              inbound.sheet = .changeAddress(homeAssistant.id)
                          }),
            SettingsScene(name: "RgInfos-retirer-source", page: .inbound, inbound: connected,
                          prepare: { _, _, inbound in
                              inbound.page = .source(garage.id)
                              inbound.sheet = .remove(garage.id)
                          }),
            SettingsScene(name: "RgInfos-heures-calmes", page: .inbound, inbound: quiet),
            SettingsScene(name: "RgInfos-annonces-coupees", page: .inbound, inbound: silent),
            SettingsScene(name: "RgInfosSource-garder", page: .inbound, inbound: keeping,
                          prepare: { _, _, inbound in inbound.page = .source(gladys.id) }),
            SettingsScene(name: "RgInfosSource-37", page: .inbound, inbound: month,
                          prepare: { _, _, inbound in inbound.page = .source(station.id) }),
            SettingsScene(name: "RgInfosSource-37-page-2", page: .inbound, inbound: month,
                          prepare: { _, _, inbound in inbound.page = .source(station.id) }, listPage: 1),
            SettingsScene(name: "RgInfosSource-37-page-4", page: .inbound, inbound: month,
                          prepare: { _, _, inbound in inbound.page = .source(station.id) }, listPage: 3),
            // Advanced
            SettingsScene(name: "RgAvance", page: .advanced, events: [bigStorage], settings: wakeWordLog),
            SettingsScene(name: "RgAvanceTelechargement", page: .advanced, events: setup, settings: wakeWordLog,
                          startsReady: false),
            SettingsScene(name: "RgAvancePalierGros", page: .advanced, events: [bigStorage], settings: { s in
                wakeWordLog(&s)
                s.tierOverride = .max
            }),
            SettingsScene(name: "RgAvanceSupprimer", page: .advanced, events: [bigStorage], settings: wakeWordLog,
                          prepare: { navigation, _, _ in navigation.sheet = .deleteModels }),
            SettingsScene(name: "RgAvance-supprimer-un-modele", page: .advanced, events: [bigStorage],
                          prepare: { navigation, _, _ in navigation.sheet = .deleteModel(standardModel.id) }),
            SettingsScene(name: "RgAvance-un-modele-supprime", page: .advanced, events: [.storage(oneDeleted)]),
            // Its model is here: nothing to download. Then a tier whose model is not.
            SettingsScene(name: "RgAvance-changer-palier", page: .advanced, events: [bigStorage],
                          prepare: { navigation, _, _ in navigation.sheet = .changeTier(.forced(.standard)) }),
            SettingsScene(name: "RgAvance-changer-palier-telecharger", page: .advanced, events: [.storage(oneDeleted)],
                          prepare: { navigation, _, _ in navigation.sheet = .changeTier(.forced(.standard)) }),
        ]

        // Each scene at the window's first width, then at its narrowest (…-etroit).
        let widths: [(width: CGFloat, suffix: String)] = [(960, ""), (SettingsWindowView.minimumWidth, "-etroit")]
        for (scene, size) in scenes.flatMap({ scene in widths.map { (scene, $0) } })
        where wants(scene.name + size.suffix) {
            let events = scene.startsReady ? ready + scene.events : scene.events
            let model = AssistantModel(connection: ScriptedConnection(events))
            model.talkShortcut = .standard  // not the one this Mac's user may have recorded
            model.hasTalkShortcut = true
            scene.model(model)
            let saved = model.settings
            // Before the events arrive: a change of the search's settings forgets the last test.
            var settings = AssistantSettings()
            scene.settings(&settings)
            model.settings = settings
            try? await Task.sleep(for: .milliseconds(150))
            let navigation = SettingsNavigation()
            navigation.show(scene.page)
            let phone = PhoneAccess(link: nil, status: scene.phone)
            let inbound = InboundAccess(host: nil, status: scene.inbound)
            let relays = RelayAccess(phone: phone, inbound: inbound, passesInternetRelay: false)
            let tools = ConnectedToolsAccess(tools: scene.tools)
            scene.prepare(navigation, phone, inbound)
            let view = SettingsWindowView(model: model, navigation: navigation, tools: tools)
                .overlay {
                    if let sheet = scene.sheet {
                        SheetBackdrop(top: scene.sheetTop) { sheet }
                    }
                }
                .environment(phone)
                .environment(inbound)
                .environment(relays)
                .environment(navigation)
                .environment(\.unscrolledPages, true)
                .environment(\.firstListPage, scene.listPage)
                .environment(\.stillFrame, 1.7)
                .preferredColorScheme(.light)
            let height = max(scene.minHeight, NSHostingView(rootView: view.frame(width: size.width)).fittingSize.height)
            await save(view, size: CGSize(width: size.width, height: height.rounded(.up)),
                       to: folder.appending(path: scene.name + size.suffix + ".png"))
            model.settings = saved  // the scripted model saves the settings like the real one: put them back
        }

        // The quick panel, in the conversation and on the first-launch screen.
        for (name, events, settings) in [
            ("RgRapides", ready + [actions(.granted), claudeCodeReady], claudeCode(review: true, mode: .acceptEdits)),
            ("RgRapides-premier-lancement", [AssistantEvent.setupNeeded(Demo.setup)],
             { (_: inout AssistantSettings) in }),
        ] as [(String, [AssistantEvent], (inout AssistantSettings) -> Void)] where wants(name) {
            let model = AssistantModel(connection: ScriptedConnection(events))
            model.talkShortcut = .standard
            model.hasTalkShortcut = true
            let saved = model.settings
            var fresh = AssistantSettings()
            settings(&fresh)
            if name == "RgRapides" { fresh.webSearch.enabled = true }
            model.settings = fresh
            try? await Task.sleep(for: .milliseconds(150))
            let window = WindowState()
            let view = ContentView(model: model, window: window)
                .environment(SettingsNavigation())
                .environment(\.stillFrame, 1.7)
                .preferredColorScheme(.light)
            await save(view, size: CGSize(width: 820, height: 700), to: folder.appending(path: name + ".png")) {
                window.panel = .settings
            }
            model.settings = saved
        }
    }
}
#endif
