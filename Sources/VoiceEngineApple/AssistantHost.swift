import Foundation
import VoiceCore

/// The engine as the app sees it: it receives `AssistantCommand`s and sends `AssistantEvent`s
/// (see AssistantProtocol.swift). It owns the models, the microphone and the speakers, and runs in the
/// app's process. A future separate-process engine would wrap this same object.
///
/// Its life: microphone permission and hardware check → if models are missing, say what has to be
/// downloaded and wait for the user's go (first launch) → download → load the models → converse.
/// Choosing another tier or deleting the models goes through all of it again.
public actor AssistantHost: AssistantConnection {
    public nonisolated let events: AsyncStream<AssistantEvent>
    private nonisolated let emit: AsyncStream<AssistantEvent>.Continuation
    private nonisolated let commands: AsyncStream<AssistantCommand>.Continuation

    private enum Stage { case idle, setup, downloading, loading, running }
    private var stage = Stage.idle
    /// The tier changed while the models were loading: start again once they are loaded.
    private var restartWhenLoaded = false
    /// A pipeline was stopped (another tier chosen, the models deleted) and its conversation went with it: the next one
    /// says so once it is ready (`conversationCleared`), for the interfaces to clear what they still show of it.
    private var conversationDropped = false

    private var settings = AssistantSettings()
    private let store = ModelStore()
    /// The models the engine loads or has loaded (the tier's when it started), until it stops: never deleted on their
    /// own, even once another tier is chosen.
    private var loadedPacks: Set<String> = []
    private var download: Task<Void, Never>?
    private var pipeline: VoicePipeline?
    private var model: MLXChatModel?
    private var audio: SystemAudio?
    private var route: SystemAudio.Route?
    private var pipelineState = PipelineState.listening
    private var playbackSampleRate = 24_000.0
    private var tasks: [Task<Void, Never>] = []
    private var activity: NSObjectProtocol?
    /// While an exchange goes on (the user speaks to Maé, she thinks, she answers), the Mac does not go to sleep on its
    /// own: neither the sentence nor the answer is cut. At rest it may (see `SystemAudio.allowIdleSleep`).
    private var exchangeActivity: NSObjectProtocol?
    private var restartingAudio = false
    /// The voice's output: the Mac's speakers, or an iPhone's (see `useRemoteAudio`).
    private var router: AudioRouter?
    /// While an iPhone has the conversation: its microphone, its voice output, and what it takes to interrupt Maé there.
    private var remote: (microphone: AsyncStream<[Float]>, output: any AudioOutput, bargeIn: BargeInProfile)?
    /// Whether that iPhone hears the voice right now (see `setRemoteAudioReachable`).
    private var remoteReachable = true
    private var remoteFeed: Task<Void, Never>?
    /// Where what Maé says on her own goes, when not where the conversation is: a home station (`announceThrough`).
    private var announcements: (output: (any AudioOutput)?, reachable: Bool) = (nil, true)

    // Actions: reminders and calendar, timers, shortcuts. Kept for the app's whole life (a timer keeps running
    // across a change of tier); handed to the pipeline only while the setting is on.
    private let calendarTools: CalendarTools
    private let timerTools = TimerTools()
    private let shortcutTools = ShortcutTools()
    /// Tasks handed to Claude Code, with the actions or on its own when they are off: they go on across a change of
    /// tier, or with Claude Code or the actions switched off, until the app quits.
    private let agentTools: AgentTools
    /// Searching the internet: with the actions, or on its own when they are off.
    private let webSearchTools = WebSearchTools()
    /// The Mac stays awake, on battery too, while a timer runs (it would ring late, once the Mac wakes up) and while an
    /// agent works on a task (its run would pause). A timer that rang still holds it a few seconds: its announcement
    /// keeps the Mac awake in turn, as an exchange, once it has started.
    private let timersAwake = StayAwake(reason: "OpenMaé: a timer is running", linger: .seconds(5))
    private let tasksAwake = StayAwake(reason: "OpenMaé: an agent is working on a task")
    /// The built-in sources (weather, quotes, travel times): one switch for the three, with the actions or without.
    private let here = MacLocation()
    private let weatherTools: WeatherTools
    private let quoteTools = QuoteTools()
    private let travelTools: TravelTimeTools
    /// The news of received information (« Quoi de neuf ? »): offered while a source exists (`useNews`), with the
    /// actions or without.
    private let newsTools = NewsTools()
    /// The news came or went while the models loaded: the tools are set again once they are loaded.
    private var newsChangedWhileLoading = false
    private var actionsStatus: ActionsStatus?
    /// Counts the checks of Claude Code (`reportClaudeCode`): only the last one's answer goes to the app.
    private var claudeCodeChecks = 0
    /// What Maé remembers when asked, and the journal of past exchanges, in `AppIdentity.memoryDirectory` (opened on
    /// first use). The provider is always among the tools, last, and offers its tool only while the memory is on.
    private let memoryStore = LazyMemoryStore()
    private let memoryTools: MemoryTools
    /// Writes the exchanges into the journal while it is on.
    private var journalWriter: StoreJournal?
    /// Forgets the exchanges older than the retention, at start-up and once a day.
    private var purge: Task<Void, Never>?

    /// `actionsTestCollection`: put every event and reminder in a calendar and a list of this name (created on
    /// first use) instead of the user's own, and read only those (for trying the feature). `agentsTestFolder`: keep
    /// the tasks handed to agents, and their folders, there instead of the user's own.
    public init(actionsTestCollection: String? = nil, agentsTestFolder: URL? = nil) {
        calendarTools = CalendarTools(testCollection: actionsTestCollection)
        weatherTools = WeatherTools(here: here)
        travelTools = TravelTimeTools(here: here, estimator: MapKitTravel())
        memoryTools = MemoryTools(store: memoryStore)
        agentTools = agentsTestFolder.map {
            AgentTools(store: TaskStore(folder: $0.appending(path: "Tasks", directoryHint: .isDirectory)), workspace: $0)
        } ?? AgentTools()
        (events, emit) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        let (commandStream, commands) = AsyncStream<AssistantCommand>.makeStream(bufferingPolicy: .unbounded)
        self.commands = commands
        // One command at a time, in order (a push-to-talk release must never overtake its press).
        Task { [weak self] in
            for await command in commandStream { await self?.handle(command) }
        }
        Task { await self.observeTimers() }
        Task { await self.observeTasks() }
    }

    /// The app is quitting: the agents' runs stop with it (synchronous, from the app's last moments).
    public static func stopAgentsNow() {
        ClaudeCodeConnector.stopAll()
    }

    /// The `userInfo` key of the folder a task's notification opens when clicked.
    public static let notificationFolderKey = Notifier.folderKey

    private func observeTimers() async {
        let awake = timersAwake
        await timerTools.observe(
            onFinish: { [weak self] finished in
                Task { await self?.timerFinished(finished) }
            },
            onFirstTimer: { await Notifier.requestPermission() },
            onRunning: { awake.set($0) })
    }

    private func observeTasks() async {
        let emit = emit
        let awake = tasksAwake
        await agentTools.observe(
            onChange: { emit.yield(.tasks($0)) },
            onEnd: { task in
                // Announced by a notification only, never out loud: the user may be talking about something else.
                let notification = AgentPhrases.notification(for: task)
                Notifier.post(title: notification.title, body: notification.body, folder: task.folder)
            },
            onFirstTask: { await Notifier.requestPermission() },
            onRunning: { awake.set($0) })
    }

    public nonisolated func send(_ command: AssistantCommand) {
        commands.yield(command)
    }

    private func handle(_ command: AssistantCommand) async {
        switch command {
        case .start(let settings):
            self.settings = settings
            await start()
        case .updateSettings(let settings):
            await apply(settings)
        case .talkKey(let pressed):
            await pipeline?.setTalkKey(pressed: pressed)
        case .stopSpeaking:
            DebugLog.log("stop requested by the interface")
            await pipeline?.interrupt()
        case .newConversation:
            do { try await pipeline?.resetConversation() } catch { emit.yield(.warning("\(error)")) }
        case .downloadModels:
            startDownload()
        case .pauseDownload:
            download?.cancel()
        case .deleteModels:
            await deleteModels()
        case .deleteModel(let id):
            deleteModel(id)
        case .refreshActions:
            await refreshActions()
        case .stopTask(let id):
            // Not awaited: stopping can take a few seconds, and the next command must not wait for it.
            Task { await agentTools.stop(id) }
        case .testWebSearch:
            // Not awaited either: a search can take up to five seconds.
            Task { await testWebSearch() }
        case .refreshMemory:
            await reportMemory()
        case .forgetMemoryEntry(let entry):
            do { try await memoryStore.removeFromSheet(entry) } catch { emit.yield(.warning("\(error)")) }
            await reportMemory()
        case .clearMemoryJournal:
            do { try await memoryStore.clearJournal() } catch { emit.yield(.warning("\(error)")) }
            await reportMemory()
        case .eraseMemory:
            do { try await memoryStore.eraseAll() } catch { emit.yield(.warning("\(error)")) }
            await reportMemory()
        case .typedTurn(let text):
            await pipeline?.submit(text: text)
        case .shutdown:
            shutdown()
        }
    }

    // MARK: - Start-up

    private var tier: HardwareTier {
        settings.tierOverride ?? HardwareTier.recommended(for: .current)
    }

    private func start() async {
        guard stage == .idle || stage == .setup else { return }
        stage = .loading
        emit.yield(.loading(.microphone))
        guard await SystemAudio.requestMicrophoneAccess() else {
            fail(.microphoneDenied)
            return
        }
        let hardware = HardwareProfile.current
        let recommended = HardwareTier.recommended(for: hardware)
        guard recommended != .unsupported else {
            fail(.unsupportedMac(chip: hardware.chipName, memoryGiB: hardware.memoryGiB))
            return
        }
        let tier = self.tier
        guard let languageModel = ModelCatalog.languageModel(for: tier) else {
            fail(.unsupportedMac(chip: hardware.chipName, memoryGiB: hardware.memoryGiB))
            return
        }
        guard store.isComplete(ModelCatalog.packs(for: tier)) else {
            stage = .setup
            emit.yield(.setupNeeded(setup(tier: tier, recommended: recommended, hardware: hardware)))
            reportStorage()
            return
        }
        guard let vadURL = ModelLocator.voiceActivity() else {
            fail(.modelMissing("Silero VAD"))
            return
        }
        loadedPacks = Set(ModelCatalog.packs(for: tier).map(\.id))

        // Sound first: a microphone or speaker problem shows up at once, not after a minute of loading.
        let audio = SystemAudio()
        do {
            route = try await startReliably(audio)
        } catch {
            fail(.audioDevice("\(error)"))
            return
        }
        audio.onConfigurationChange = { [weak self] in
            Task { await self?.audioConfigurationChanged() }
        }
        self.audio = audio
        pipelineState = .listening
        audio.setOtherApps(.normal)

        let model: MLXChatModel
        let pipeline: VoicePipeline
        var started: VoicePipeline?  // stopped if the voice then fails to load: its keep-warm loop would hold the models
        do {
            emit.yield(.loading(.speechRecognition))
            let detector = try SileroSpeechDetector(modelURL: vadURL)
            let transcriber = try await ParakeetTranscriber.load(
                directory: store.folder(ModelCatalog.speechRecognition))
            emit.yield(.loading(.languageModel))
            MLXChatModel.releaseCachedMemory()  // what a previous tier's model may have left
            model = try await MLXChatModel.load(directory: store.folder(languageModel))

            // The conversations' beginning (`VoicePipeline.start`) is computed before the voice loads, on weights still
            // in memory. Loading the voice makes macOS compress most of them (Gemma 4 26B on the reference Mac: the
            // process's resident memory went from 14.4 to 3.8 GB), and a beginning computed after it waited while 10 to
            // 15 GB came back. Nothing reaches the pipeline before the voice is loaded: the microphone, the timers, an
            // iPhone or received information only once loading is over (`self.pipeline` set, `stage == .running`).
            let synthesizer = PocketSpeechSynthesizer(store: store)  // its voices load below
            var config = PipelineConfig()
            config.listening = settings.listening
            config.actionExamples = ActionCatalog.showsExamples(on: tier)
            config.cutOffPlacement = Conversation.cutOffPlacement(on: tier)
            config.actionsPerRequest = ActionCatalog.actionsPerRequest(on: tier)
            let router = AudioRouter(audio)
            self.router = router
            pipeline = VoicePipeline(detector: detector, transcriber: transcriber, model: model,
                                     synthesizer: synthesizer, output: router, tools: await toolRunner(), config: config)
            try await pipeline.start()
            started = pipeline

            emit.yield(.loading(.voice))
            try await synthesizer.preload([.french, .english])
            if synthesizer.outputSampleRate != playbackSampleRate {
                playbackSampleRate = synthesizer.outputSampleRate
                route = try await startReliably(audio)
            }
            // What loading the voice pushed out of memory comes back from now on, while Maé already listens.
            model.wakeUp()
        } catch {
            await started?.stop()
            audio.stop()
            self.audio = nil
            fail(.engine("\(error)"))
            return
        }

        self.model = model
        self.pipeline = pipeline
        await configureMemory()  // the journal, when it is on
        stage = .running
        let emit = emit
        tasks = [
            Task { for await event in pipeline.events { await self.forward(event) } },
            // The microphone has been running during the loading: what it heard meanwhile is dropped.
            Task {
                let ready = ContinuousClock.now
                for await chunk in audio.microphone where ContinuousClock.now - ready > .milliseconds(200) {
                    await pipeline.push(chunk)
                }
            },
            Task { for await level in audio.levels { emit.yield(.levels(input: level.input, output: level.output)) } },
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    await self.reportDiagnostics()
                }
            },
        ]
        // Keep macOS from slowing the app down when its window is in the background (App Nap), but let the Mac go to
        // sleep on its own as usual: `.userInitiated` would also keep it awake, on battery too, as long as the models
        // are loaded. The Mac stays awake only during an exchange, while a timer or an agent's task runs, and through a
        // `KeepAwake` (iPhone access, the wake-word mode), on mains.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Conversation vocale")
        if conversationDropped {
            // The new model starts a new conversation: the screens stop showing the exchanges of the one before it.
            // Before anything of the new pipeline (its events are forwarded once this method waits for something).
            conversationDropped = false
            DebugLog.log("new conversation: another language model is ready")
            emit.yield(.conversationCleared)
        }
        emit.yield(.ready(EngineInfo(
            chip: hardware.chipName, memoryGiB: hardware.memoryGiB, tier: tier, recommendedTier: recommended,
            languageModel: languageModel.displayName,
            speechRecognition: ModelCatalog.speechRecognition.displayName,
            voice: "Pocket TTS · " + PocketSpeechSynthesizer.voices.values.sorted().joined(separator: ", "))))
        await reportDiagnostics()
        reportStorage()
        reportActions()
        reportClaudeCode()
        if remote != nil { await attachRemote() }  // an iPhone took the conversation while the models loaded
        if announcements.output != nil {  // a home station connected while the models loaded
            await pipeline.announceThrough(announcements.output, reachable: announcements.reachable)
        }
        if restartWhenLoaded {
            restartWhenLoaded = false
            await restart()
        } else if newsChangedWhileLoading {
            newsChangedWhileLoading = false
            await newsChanged()
        }
    }

    private func fail(_ problem: AssistantProblem) {
        stage = .idle
        restartWhenLoaded = false  // the next start reads the settings anyway
        loadedPacks = []  // nothing stays loaded: start-up stops whatever it had started before it fails
        emit.yield(.problem(problem))
    }

    /// What the first-launch screen shows: the Mac, its tier, and what has to be downloaded.
    private func setup(tier: HardwareTier, recommended: HardwareTier, hardware: HardwareProfile) -> ModelSetup {
        let packs = ModelCatalog.packs(for: tier)
        let toDownload = store.bytesToDownload(packs)
        return ModelSetup(
            chip: hardware.chipName, memoryGiB: hardware.memoryGiB, tier: tier, recommendedTier: recommended,
            items: packs.map {
                ModelSetup.Item(role: $0.role, displayName: $0.displayName, license: $0.license,
                                totalBytes: $0.totalBytes, missingBytes: store.bytesToDownload([$0]))
            },
            bytesToDownload: toDownload, neededBytes: toDownload + ModelDownloader.safetyMarginBytes,
            availableBytes: store.availableBytes(), folder: store.root.path)
    }

    /// Stops everything, before another tier is loaded or the models are deleted.
    private func stopEngine() async {
        if pipeline != nil { conversationDropped = true }
        let running = tasks
        tasks = []
        running.forEach { $0.cancel() }
        await pipeline?.stop()
        // The tasks hold the pipeline, hence the models: wait until they are over, so that dropping the
        // references below really frees the models.
        for task in running { await task.value }
        pipeline = nil
        model = nil
        loadedPacks = []
        audio?.stop()
        audio = nil
        route = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        keepAwakeDuringExchange(false)
        // MLX keeps freed GPU memory for reuse: give it back to macOS (about 15 GB for the 26B model).
        MLXChatModel.releaseCachedMemory()
        stage = .idle
    }

    private func shutdown() {
        download?.cancel()
        tasks.forEach { $0.cancel() }
        tasks = []
        audio?.stop()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        keepAwakeDuringExchange(false)
    }

    // MARK: - Models: download, tier, deletion

    private enum DownloadOutcome { case finished, paused, failed(DownloadFailure) }

    private func startDownload() {
        guard stage == .setup else { return }
        stage = .downloading
        let packs = ModelCatalog.packs(for: tier)
        let downloader = ModelDownloader(store: store)
        let emit = emit
        DebugLog.log("download: \(packs.map(\.id)), \(store.bytesToDownload(packs)) bytes to go")
        download = Task {
            let outcome: DownloadOutcome
            do {
                try await downloader.download(packs) { emit.yield(.downloadProgress($0)) }
                outcome = .finished
            } catch is CancellationError {
                outcome = .paused
            } catch let failure as DownloadFailure {
                outcome = .failed(failure)
            } catch {
                outcome = .failed(.disk("\(error)"))
            }
            await self.downloadEnded(outcome)
        }
    }

    private func downloadEnded(_ outcome: DownloadOutcome) async {
        download = nil
        stage = .setup
        switch outcome {
        case .finished:
            DebugLog.log("download: complete")
            await start()
        case .paused:
            DebugLog.log("download: paused")
            emit.yield(.downloadStopped(nil))
            reportStorage()
        case .failed(let failure):
            DebugLog.log("download: failed, \(failure)")
            emit.yield(.downloadStopped(failure))
            reportStorage()
        }
    }

    /// Another tier was chosen: stop whatever is going on and go through start-up again (which shows the
    /// download screen if that tier's language model is not on disk yet).
    private func restart() async {
        switch stage {
        case .loading:
            restartWhenLoaded = true
            return
        case .downloading:
            download?.cancel()
            await download?.value
        case .running:
            await stopEngine()
        case .idle, .setup:
            break
        }
        await start()
    }

    private func deleteModels() async {
        switch stage {
        case .loading:
            return  // the interface does not offer it while loading
        case .downloading:
            download?.cancel()
            await download?.value
        case .running:
            await stopEngine()
        case .idle, .setup:
            break
        }
        do {
            try store.deleteAll()
            DebugLog.log("models deleted")
        } catch {
            emit.yield(.warning("\(error.localizedDescription)"))
        }
        deleteCompiledModelCaches()
        stage = .idle
        await start()
    }

    /// The models that cannot be deleted on their own: those the tier needs (in use, or waiting for their download) and
    /// those the engine has loaded.
    private var packsInUse: Set<String> {
        Set(ModelCatalog.packs(for: tier).map(\.id)).union(loadedPacks)
    }

    /// Settings › Advanced: one model, by the name of its folder. Only a model of the catalog, never one in use, and not
    /// while models load or download (the interface does not offer it then either).
    private func deleteModel(_ id: String) {
        defer { reportStorage() }
        guard let pack = ModelCatalog.all.first(where: { $0.id == id }) else {
            DebugLog.log("model not deleted: \(id) is not a model of the catalog")
            return
        }
        guard stage != .loading, stage != .downloading, !packsInUse.contains(id) else {
            DebugLog.log("model not deleted: \(id) is in use")
            return
        }
        do {
            try store.delete(pack)
            DebugLog.log("model deleted: \(id)")
        } catch {
            emit.yield(.warning("\(error.localizedDescription)"))
        }
        // The first-launch screen shows the free space: it grew.
        if stage == .setup {
            let hardware = HardwareProfile.current
            emit.yield(.setupNeeded(setup(tier: tier, recommended: HardwareTier.recommended(for: hardware),
                                          hardware: hardware)))
        }
    }

    /// CoreML keeps versions of the models compiled for this Mac's Neural Engine in the app's cache folder
    /// (about 2 GB); they are of no use without the models. Only called when no model is loaded.
    private func deleteCompiledModelCaches() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(
            at: caches.appending(path: identifier).appending(path: "com.apple.e5rt.e5bundlecache"))
    }

    private func reportStorage() {
        emit.yield(.storage(store.storage(inUse: packsInUse)))
    }

    // MARK: - Settings and audio devices

    private func apply(_ new: AssistantSettings) async {
        let oldTier = tier
        let old = settings
        settings = new
        if tier != oldTier {
            DebugLog.log("tier: \(oldTier.rawValue) → \(tier.rawValue)")
            await restart()
            return
        }
        if new.shortcutsToConfirm != old.shortcutsToConfirm {
            await shortcutTools.setNeedingConfirmation(Set(new.shortcutsToConfirm))
        }
        // A change the model sees (Claude Code switched on or off, a folder added; the search or the sources switched on
        // or off) means new instructions.
        var agentsChanged = false
        if new.claudeCode != old.claudeCode {
            DebugLog.log("agents: Claude Code \(new.claudeCode.enabled ? "on" : "off")")
            agentsChanged = await configureAgents()
            if new.claudeCode.enabled != old.claudeCode.enabled, stage == .running { reportClaudeCode() }
        }
        var searchChanged = false
        if new.webSearch != old.webSearch { searchChanged = await configureWebSearch() }
        var sourcesChanged = false
        if new.builtInSources != old.builtInSources { sourcesChanged = await configureSources() }
        var memoryChanged = false
        if new.memory != old.memory {
            memoryChanged = await configureMemory()
            DebugLog.log("memory: \(new.memory.enabled ? "on" : "off"), journal \(new.memory.journalOn ? "on" : "off")")
            if new.memory.retention != old.memory.retention { Task { await self.purgeJournal() } }
            await reportMemory()
        }
        if agentsChanged || searchChanged || sourcesChanged || memoryChanged, new.actionsEnabled == old.actionsEnabled {
            if searchChanged {
                DebugLog.log("web search: \(new.webSearch.isReady ? "on (\(new.webSearch.source.rawValue))" : "off")")
            }
            if sourcesChanged { DebugLog.log("built-in sources: \(new.builtInSources ? "on" : "off")") }
            // With the actions, a tool comes or goes and the conversation goes on. On their own, Claude Code, the search,
            // the sources and the memory are the only tools: when one of them comes or goes, the tools are set again and
            // a new conversation starts, as when the actions are switched on or off (the app clears its transcript on the
            // pipeline's `conversationCleared`). A folder added for Claude Code, or the memory's journal switched, only
            // changes a tool: the conversation goes on.
            let comeOrGo = searchChanged || sourcesChanged || new.claudeCode.enabled != old.claudeCode.enabled
                || new.memory.enabled != old.memory.enabled
            do {
                if new.actionsEnabled || !comeOrGo {
                    try await pipeline?.toolsChanged()
                } else {
                    try await pipeline?.setTools(await toolRunner())
                }
            } catch {
                emit.yield(.warning("\(error)"))
            }
        }
        guard let pipeline else { return }
        if new.listening != old.listening {
            DebugLog.log("listening: \(old.listening.rawValue) → \(new.listening.rawValue)")
            await pipeline.setListening(new.listening)
        }
        if new.audioMode != old.audioMode { await restartAudio() }
        if new.actionsEnabled != old.actionsEnabled {
            DebugLog.log("actions: \(new.actionsEnabled ? "on" : "off")")
            do { try await pipeline.setTools(await toolRunner()) } catch { emit.yield(.warning("\(error)")) }
            reportActions()
        }
    }

    // MARK: - Actions

    /// The tools for a new pipeline or conversation: the actions when they are on; Claude Code, the web search, the
    /// built-in sources, the news and the memory when they are, with the actions or on their own; nil when all are off.
    private func toolRunner() async -> ToolRunner? {
        await configureWebSearch()
        await configureSources()
        await configureAgents()
        let sources: [any ToolProvider] = [weatherTools, quoteTools, travelTools]
        await configureMemory()
        // Last: the sheet it adds to the prompt changes between conversations, what comes before it does not.
        let memory: [any ToolProvider] = [memoryTools]
        guard settings.actionsEnabled else {
            // In the same order as with the actions.
            let agents: [any ToolProvider] = settings.claudeCode.enabled ? [agentTools] : []
            let search: [any ToolProvider] = settings.webSearch.isReady ? [webSearchTools] : []
            let on = agents + search + (sourcesOn ? sources : []) + (await newsTools.isOn ? [newsTools] : [])
                + (settings.memory.enabled ? memory : [])
            return on.isEmpty ? nil : ToolRunner(providers: on, actions: false)
        }
        await calendarTools.offerMoves(ActionCatalog.movesItems(on: tier))
        await shortcutTools.refresh()
        await shortcutTools.setNeedingConfirmation(Set(settings.shortcutsToConfirm))
        return ToolRunner(providers: [calendarTools, timerTools, shortcutTools, agentTools, webSearchTools] + sources
            + [newsTools] + memory)
    }

    // MARK: - Memory

    /// Switches the memory and its journal as the settings say (the journal only while it is offered:
    /// `MemorySettings.journalOffered`). Returns true when what the model sees changed (its tool, or `chercher` with the
    /// journal).
    @discardableResult
    private func configureMemory() async -> Bool {
        let memory = settings.memory
        let changed = await memoryTools.configure(enabled: memory.enabled, journal: memory.journalOn)
        if memory.journalOn {
            let writer = journalWriter ?? StoreJournal(store: memoryStore)
            journalWriter = writer
            await pipeline?.setJournal(writer)
            schedulePurge()
        } else {
            await pipeline?.setJournal(nil)
            purge?.cancel()
            purge = nil
        }
        return changed
    }

    /// Forgets the exchanges older than the retention: now, then once a day; never during an exchange (it waits for
    /// the rest).
    private func schedulePurge() {
        guard purge == nil else { return }
        purge = Task { [weak self] in
            while !Task.isCancelled {
                await self?.purgeJournal()
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    private func purgeJournal() async {
        guard let days = settings.memory.retention.days, settings.memory.journalOn else { return }
        while pipelineState != .listening {
            try? await Task.sleep(for: .seconds(60))
            if Task.isCancelled { return }
        }
        do {
            let count = try await memoryStore.purgeJournal(keepingDays: days)
            if count > 0 { DebugLog.log("memory: \(count) exchanges older than \(days) days forgotten") }
        } catch {
            DebugLog.log("memory: purge failed: \(error)")
        }
    }

    /// What the memory page shows. Nothing is created on disk while the memory was never switched on.
    private func reportMemory() async {
        guard settings.memory.enabled || memoryStore.exists else {
            emit.yield(.memory(MemoryOverview(entries: [], characters: 0, capacity: MemorySheet.capacity, exchanges: 0,
                                              folder: memoryStore.folder.path)))
            return
        }
        let entries = (try? await memoryStore.loadSheet()) ?? []
        let exchanges = (try? await memoryStore.countJournal(from: nil, to: nil)) ?? 0
        emit.yield(.memory(MemoryOverview(entries: entries, characters: MemorySheet(entries: entries).characters,
                                          capacity: MemorySheet.capacity, exchanges: exchanges,
                                          folder: memoryStore.folder.path)))
    }

    /// The built-in sources are offered: switched on, on a tier whose model passed their benchmark.
    private var sourcesOn: Bool { settings.builtInSources && BuiltInSources.offered(on: tier) }

    /// Switches the three built-in sources on or off together. Returns true when what the model sees changed.
    @discardableResult
    private func configureSources() async -> Bool {
        let on = sourcesOn
        let weather = await weatherTools.configure(on)
        let quotes = await quoteTools.configure(on)
        let travel = await travelTools.configure(on)
        return weather || quotes || travel
    }

    /// Hands the source of the settings to the web search tool while the search is switched on, with the keychain's key
    /// or password. Returns true when what the model sees changed.
    @discardableResult
    private func configureWebSearch() async -> Bool {
        await webSearchTools.configure(settings.webSearch.isReady ? webSearchProvider() : nil)
    }

    /// The source of the settings, as they and the keychain describe it, switched on or not; nil when it is not set up
    /// (no key in the keychain for Brave Search, no address for SearXNG).
    private func webSearchProvider() -> (any WebSearchProvider)? {
        let search = settings.webSearch
        switch search.source {
        case .brave:
            guard let key = WebSearchKeychain.secret(for: .brave), !key.isEmpty else { return nil }
            return BraveSearchProvider(key: key)
        case .searxng:
            guard let address = SearXNGProvider.address(search.address) else { return nil }
            return SearXNGProvider(address: address, username: search.username,
                                   password: WebSearchKeychain.secret(for: .searxng) ?? "")
        }
    }

    /// The settings' "Test" button: one search, with the settings and the key or password as they are now.
    private func testWebSearch() async {
        await configureWebSearch()  // the key or the password may have just been saved
        guard let provider = webSearchProvider() else {
            emit.yield(.webSearchTested(.notSetUp))
            return
        }
        let start = ContinuousClock.now
        let test: WebSearchTest
        do {
            let found = try await provider.search("Wikipédia", language: .french)
            let d = ContinuousClock.now - start
            test = .works(results: found.found,
                          seconds: Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
        } catch let error as WebSearchError {
            test = .failed(error)
        } catch {
            test = .failed(.unreachable)
        }
        DebugLog.log("web search test: \(test)")
        emit.yield(.webSearchTested(test))
    }

    /// Hands Claude Code to the delegation tools when it is switched on, with its settings. Returns true when what
    /// the model sees changed.
    @discardableResult
    private func configureAgents() async -> Bool {
        let claudeCode = settings.claudeCode
        let agents = claudeCode.enabled
            ? [AgentTools.Agent(connector: ClaudeCodeConnector(permissionMode: claudeCode.permissionMode),
                                review: claudeCode.review)]
            : []
        let folders = claudeCode.folders.map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return await agentTools.configure(agents: agents, folders: folders)
    }

    /// The app is in front again: a shortcut may have been added to the folder, an access granted, the web search's
    /// key or password saved, Claude Code installed or signed in.
    private func refreshActions() async {
        guard stage == .running else { return }
        reportClaudeCode()
        if await configureWebSearch() {
            // The keychain decided otherwise than the settings (a key saved again after it was lost, or removed from it
            // elsewhere): the search's tool comes or goes, the conversation goes on.
            do { try await pipeline?.toolsChanged() } catch { emit.yield(.warning("\(error)")) }
        }
        guard settings.actionsEnabled else { return }
        if await shortcutTools.refresh() {
            do { try await pipeline?.toolsChanged() } catch { emit.yield(.warning("\(error)")) }
        }
        reportActions()
    }

    /// What the actions can use, while they are on.
    private func reportActions() {
        guard settings.actionsEnabled else { return }
        Task {
            let status = ActionsStatus(calendar: Self.access(CalendarTools.access(to: .event)),
                                       reminders: Self.access(CalendarTools.access(to: .reminder)),
                                       shortcuts: await shortcutTools.names)
            self.send(status)
        }
    }

    /// Tells the app whether Claude Code is installed and signed in, whatever the actions. Switched on, Claude Code
    /// itself is asked (about a second, in the background); switched off, only whether it is installed is looked at,
    /// which runs nothing (nil when it is).
    private func reportClaudeCode() {
        claudeCodeChecks += 1
        let check = claudeCodeChecks
        guard settings.claudeCode.enabled else {
            emit.yield(.claudeCode(ClaudeCodeConnector.command() == nil ? .notInstalled : nil))
            return
        }
        Task {
            let availability = await ClaudeCodeConnector().availability()
            // Switched off, or asked again, meanwhile: the later check answers instead.
            guard check == claudeCodeChecks else { return }
            emit.yield(.claudeCode(availability))
        }
    }

    private func send(_ status: ActionsStatus) {
        guard status != actionsStatus else { return }
        actionsStatus = status
        emit.yield(.actions(status))
    }

    private static func access(_ access: CalendarTools.Access) -> ActionsStatus.Access {
        switch access {
        case .notAsked: .notAsked
        case .granted: .granted
        case .denied: .denied
        }
    }

    private func timerFinished(_ finished: TimerTools.Finished) async {
        DebugLog.log("timer: \(finished.text)")
        Notifier.post(title: AppIdentity.name, body: finished.text)
        await pipeline?.announce(finished.text, note: finished.note, language: finished.language)
    }

    private func restartAudio() async {
        // While an iPhone has the conversation the Mac's microphone and speakers stay released; they restart with
        // the current settings when it lets go.
        guard remote == nil, let pipeline, let audio else { return }
        await pipeline.interrupt()
        do {
            route = try await startReliably(audio)
        } catch {
            emit.yield(.problem(.audioDevice("\(error)")))
            return
        }
        await pipeline.resetAudioInput()
        await reportDiagnostics()
    }

    private func keepAwakeDuringExchange(_ inExchange: Bool) {
        if inExchange, exchangeActivity == nil {
            exchangeActivity = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled, reason: "OpenMaé: in a conversation")
        } else if !inExchange, let exchangeActivity {
            ProcessInfo.processInfo.endActivity(exchangeActivity)
            self.exchangeActivity = nil
        }
    }

    /// Other apps are silent while the user speaks (hands-free: from voice detection; push-to-talk: while the key
    /// or button is held), lower while Maé prepares and says the answer, and left alone at rest.
    private func adjustOtherApps() {
        switch pipelineState {
        case .listening: audio?.setOtherApps(.normal)
        case .userSpeaking: audio?.setOtherApps(.silent)
        case .thinking, .speaking: audio?.setOtherApps(.lowered)
        }
    }

    /// (Re)starts the Mac's microphone and speakers, and checks that the microphone really hears: a new engine made
    /// too soon after the previous one sometimes stays deaf. It is then rebuilt, a little later each time.
    private func startReliably(_ audio: SystemAudio) async throws -> SystemAudio.Route {
        audio.stop()
        for attempt in 1...4 {
            // Gives the previous voice-processing device time to go away.
            try? await Task.sleep(for: .milliseconds(attempt == 1 ? 300 : 700 * attempt))
            let route = try audio.start(mode: settings.audioMode, playbackSampleRate: playbackSampleRate)
            if await audio.waitForMicrophone(timeout: .milliseconds(1500)) { return route }
            DebugLog.log("audio: the microphone stays deaf (attempt \(attempt)), restarting it")
            audio.stop()
        }
        // Still nothing: maybe a truly silent microphone. Keep the last engine rather than none.
        return try audio.start(mode: settings.audioMode, playbackSampleRate: playbackSampleRate)
    }

    /// A device was plugged or unplugged: the system stopped the audio engine.
    private func audioConfigurationChanged() async {
        guard !restartingAudio else { return }
        restartingAudio = true
        defer { restartingAudio = false }
        try? await Task.sleep(for: .milliseconds(300))  // changes often come in bursts
        await restartAudio()
    }

    // MARK: - An iPhone's microphone and voice

    private func attachRemote() async {
        guard stage == .running, let remote, let pipeline, let router else { return }  // applied once running
        await router.use(remote.output)  // what the speakers were playing stops; the rest goes to the iPhone
        audio?.stop()  // the Mac's microphone and speakers are free again
        await pipeline.setBargeIn(remote.bargeIn)  // its echo is not the Mac's
        await pipeline.resetAudioInput()
        await pipeline.voiceOutputChanged()  // what waited for another iPhone out of reach is not said to this one
        await pipeline.setOutputReachable(remoteReachable)  // a pipeline loaded while the iPhone was out of reach
        if remoteFeed == nil {
            remoteFeed = Task { [weak self] in
                for await chunk in remote.microphone { await self?.pushRemote(chunk) }
            }
        }
        DebugLog.log("audio: the iPhone has the microphone and the voice")
    }

    /// Through the actor rather than holding the pipeline: the feed outlives a change of tier.
    private func pushRemote(_ chunk: [Float]) async {
        await pipeline?.push(chunk)
    }

    // MARK: - Events

    private func forward(_ event: PipelineEvent) async {
        switch event {
        case .state(let state):
            pipelineState = state
            adjustOtherApps()
            keepAwakeDuringExchange(state != .listening)
            emit.yield(.state(state))
        case .partialTranscript(let text): emit.yield(.partialTranscript(text))
        case .userTranscript(let text, let language):
            DebugLog.log("user [\(language.rawValue)]: \(text)")
            emit.yield(.userTranscript(text, language))
        case .assistantPiece(let piece): emit.yield(.assistantPiece(piece))
        case .turnFinished(let metrics):
            DebugLog.log(metrics.interrupted
                ? "turn interrupted after: \(metrics.assistantText)"
                : "turn done: latency \(Int(metrics.latencyMs ?? -1)) ms — \(metrics.assistantText)")
            emit.yield(.turnFinished(metrics))
            await reportDiagnostics()
            if metrics.tool != nil { reportActions() }  // an access may just have been granted
        case .bargeIn(let stopMs, let detectionMs): emit.yield(.bargeIn(stopMs: stopMs, detectionMs: detectionMs))
        case .awake(let awake): emit.yield(.awake(awake))
        case .wakeDecision(let decision): emit.yield(.wakeDecision(decision))
        case .conversationCleared:
            DebugLog.log("new conversation")
            emit.yield(.conversationCleared)
        case .failure(let message): emit.yield(.warning(message))
        }
    }

    private func reportDiagnostics() async {
        var diagnostics = EngineDiagnostics()
        diagnostics.memoryGB = ProcessMemory.footprintGB
        if let model {
            let prefill = await model.lastPrefill
            diagnostics.reusedTokens = prefill.reused
            diagnostics.computedTokens = prefill.computed
            diagnostics.prefillMs = prefill.ms
            diagnostics.cacheRebuilds = await model.cacheRebuilds
        }
        diagnostics.audioUnderruns = audio?.underruns ?? 0
        if let route {
            diagnostics.audioMode = route.mode
            diagnostics.inputDevice = route.inputDevice
            diagnostics.outputDevice = route.outputDevice
            diagnostics.inputSampleRate = route.inputSampleRate
            diagnostics.inputChannels = route.inputChannels
        }
        emit.yield(.diagnostics(diagnostics))
    }
}

/// An iPhone can take the conversation (OpenMaeLink): the engine then hears its microphone and speaks through it,
/// and releases the Mac's microphone and speakers.
extension AssistantHost: RemoteAudioRouting {
    public func useRemoteAudio(microphone: AsyncStream<[Float]>, output: any AudioOutput, bargeIn: BargeInProfile) async {
        remoteFeed?.cancel()
        remoteFeed = nil
        remote = (microphone, output, bargeIn)
        remoteReachable = true
        await attachRemote()
    }

    public func setRemoteAudioReachable(_ reachable: Bool, reachedUntil: ContinuousClock.Instant?) async {
        guard remote != nil, reachable != remoteReachable else { return }
        remoteReachable = reachable
        guard stage == .running else { return }  // a pipeline still loading gets it from `attachRemote`
        await pipeline?.setOutputReachable(reachable, reachedUntil: reachedUntil)
    }

    public func useLocalAudio() async {
        guard remote != nil else { return }
        remote = nil
        remoteReachable = true
        remoteFeed?.cancel()
        remoteFeed = nil
        guard stage == .running, let audio, let router else { return }
        await router.use(audio)
        if remote == nil { await pipeline?.setBargeIn(.mac) }  // unless another iPhone took the conversation meanwhile
        await restartAudio()  // the Mac's microphone and speakers again, with the current settings
        // What waited for the iPhone (a timer that rang while it was out of reach) is said here, now that the speakers
        // are back; unless another iPhone took the conversation meanwhile (`attachRemote` told the pipeline then). Not
        // what it did not hear of an answer, nor the request to repeat a sentence of the user's that its drop cut.
        if remote == nil {
            await pipeline?.voiceOutputChanged()
            await pipeline?.setOutputReachable(true)
        }
        DebugLog.log("audio: the Mac has the microphone and the voice again")
    }

    public func announceThrough(_ output: (any AudioOutput)?, reachable: Bool) async {
        announcements = (output, reachable)
        guard stage == .running else { return }  // a pipeline still loading gets it once running
        await pipeline?.announceThrough(output, reachable: reachable)
    }
}

/// Information received from other systems (OpenMaeLink's received information) is said like a timer that rings, kept
/// for the news (read by lire_nouvelles), or shown in a notification. Not an `AssistantCommand`: a paired iPhone cannot
/// trigger it.
extension AssistantHost: Announcing {
    public func canAnnounce() async -> Bool {
        stage == .running && pipeline != nil
    }

    public func announce(_ text: String, note: String, language: SpeechLanguage, chime: Bool, urgent: Bool, id: UUID)
        async -> Bool
    {
        guard stage == .running, let pipeline else { return false }
        DebugLog.log("received information: announced\(urgent ? " (urgent)" : "")")
        // Urgent: Maé's own sentence (or her thinking) is cut; the user is never cut, the announcement waits for them.
        if urgent, pipelineState == .thinking || pipelineState == .speaking { await pipeline.interrupt() }
        await pipeline.announce(text, note: note, language: language, chime: chime, id: id)
        return true
    }

    public func withdrawAnnouncement(_ id: UUID) async -> Bool {
        await pipeline?.withdrawAnnouncement(id) ?? false
    }

    public func announcementState(_ id: UUID) async -> AnnouncementState {
        await pipeline?.announcementState(id) ?? .unknown
    }

    /// The tool lire_nouvelles comes or goes with the first source added, or the last one removed. With the actions,
    /// the system prompt is computed again and the conversation goes on; without them, the tools are set again and a
    /// new conversation starts, as for the web search on its own.
    public func useNews(_ news: NewsStore?) async {
        guard await newsTools.configure(news) else { return }
        DebugLog.log("news: lire_nouvelles \(news == nil ? "taken away" : "offered")")
        await newsChanged()
    }

    private func newsChanged() async {
        guard stage == .running, let pipeline else {
            if stage == .loading { newsChangedWhileLoading = true }  // its tools may have been read before
            return
        }
        do {
            if settings.actionsEnabled {
                try await pipeline.toolsChanged()
            } else {
                try await pipeline.setTools(await toolRunner())
            }
        } catch {
            emit.yield(.warning("\(error)"))
        }
    }

    public func notify(title: String, body: String) async {
        Notifier.post(title: title, body: body)
    }

    public func requestNotificationPermission() async {
        await Notifier.requestPermission()
    }
}
