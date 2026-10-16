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

    private var settings = AssistantSettings()
    private let store = ModelStore()
    private var download: Task<Void, Never>?
    private var pipeline: VoicePipeline?
    private var model: MLXChatModel?
    private var audio: SystemAudio?
    private var route: SystemAudio.Route?
    private var pipelineState = PipelineState.listening
    private var playbackSampleRate = 24_000.0
    private var tasks: [Task<Void, Never>] = []
    private var activity: NSObjectProtocol?
    private var restartingAudio = false

    // Actions: reminders and calendar, timers, shortcuts. Kept for the app's whole life (a timer keeps running
    // across a change of tier); handed to the pipeline only while the setting is on.
    private let calendarTools: CalendarTools
    private let timerTools = TimerTools()
    private let shortcutTools = ShortcutTools()
    private var actionsStatus: ActionsStatus?

    /// `actionsTestCollection`: put every event and reminder in a calendar and a list of this name (created on
    /// first use) instead of the user's own, and read only those (for trying the feature).
    public init(actionsTestCollection: String? = nil) {
        calendarTools = CalendarTools(testCollection: actionsTestCollection)
        (events, emit) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        let (commandStream, commands) = AsyncStream<AssistantCommand>.makeStream(bufferingPolicy: .unbounded)
        self.commands = commands
        // One command at a time, in order (a push-to-talk release must never overtake its press).
        Task { [weak self] in
            for await command in commandStream { await self?.handle(command) }
        }
        Task { await self.observeTimers() }
    }

    private func observeTimers() async {
        await timerTools.observe(
            onFinish: { [weak self] finished in
                Task { await self?.timerFinished(finished) }
            },
            onFirstTimer: { await Notifier.requestPermission() })
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
        case .deleteUnusedModels:
            deleteUnusedModels()
        case .refreshActions:
            await refreshActions()
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

        // Sound first: a microphone or speaker problem shows up at once, not after a minute of loading.
        let audio = SystemAudio()
        do {
            route = try audio.start(mode: settings.audioMode, playbackSampleRate: playbackSampleRate)
        } catch {
            fail(.audioDevice("\(error)"))
            return
        }
        audio.onConfigurationChange = { [weak self] in
            Task { await self?.audioConfigurationChanged() }
        }
        self.audio = audio
        pipelineState = .listening
        muteMicrophoneIfUnused()

        let model: MLXChatModel
        let pipeline: VoicePipeline
        do {
            emit.yield(.loading(.speechRecognition))
            let detector = try SileroSpeechDetector(modelURL: vadURL)
            let transcriber = try await ParakeetTranscriber.load(
                directory: store.folder(ModelCatalog.speechRecognition))
            emit.yield(.loading(.languageModel))
            MLXChatModel.releaseCachedMemory()  // what a previous tier's model may have left
            model = try await MLXChatModel.load(directory: store.folder(languageModel))
            emit.yield(.loading(.voice))
            let synthesizer = PocketSpeechSynthesizer(store: store)
            try await synthesizer.preload([.french, .english])
            if synthesizer.outputSampleRate != playbackSampleRate {
                playbackSampleRate = synthesizer.outputSampleRate
                route = try audio.start(mode: settings.audioMode, playbackSampleRate: playbackSampleRate)
            }

            var config = PipelineConfig()
            config.pushToTalk = settings.pushToTalk
            pipeline = VoicePipeline(detector: detector, transcriber: transcriber, model: model,
                                     synthesizer: synthesizer, output: audio, tools: await toolRunner(), config: config)
            try await pipeline.start()
        } catch {
            audio.stop()
            self.audio = nil
            fail(.engine("\(error)"))
            return
        }

        self.model = model
        self.pipeline = pipeline
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
        // Keep macOS from slowing the app down when its window is in the background (App Nap).
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Conversation vocale")
        emit.yield(.ready(EngineInfo(
            chip: hardware.chipName, memoryGiB: hardware.memoryGiB, tier: tier, recommendedTier: recommended,
            languageModel: languageModel.displayName,
            speechRecognition: ModelCatalog.speechRecognition.displayName,
            voice: "Pocket TTS · " + PocketSpeechSynthesizer.voices.values.sorted().joined(separator: ", "))))
        await reportDiagnostics()
        reportStorage()
        reportActions()
        if restartWhenLoaded {
            restartWhenLoaded = false
            await restart()
        }
    }

    private func fail(_ problem: AssistantProblem) {
        stage = .idle
        restartWhenLoaded = false  // the next start reads the settings anyway
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
        let running = tasks
        tasks = []
        running.forEach { $0.cancel() }
        await pipeline?.stop()
        // The tasks hold the pipeline, hence the models: wait until they are over, so that dropping the
        // references below really frees the models.
        for task in running { await task.value }
        pipeline = nil
        model = nil
        audio?.stop()
        audio = nil
        route = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
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

    private func deleteUnusedModels() {
        for pack in store.unusedPacks(keeping: ModelCatalog.packs(for: tier)) {
            do { try store.delete(pack) } catch { emit.yield(.warning("\(error.localizedDescription)")) }
        }
        reportStorage()
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
        let unused = store.unusedPacks(keeping: ModelCatalog.packs(for: tier))
        emit.yield(.storage(ModelStorage(
            usedBytes: store.usedBytes(), unusedBytes: unused.reduce(0) { $0 + store.usedBytes($1) },
            folder: store.root.path)))
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
        guard let pipeline else { return }
        if new.pushToTalk != old.pushToTalk {
            await pipeline.setPushToTalk(new.pushToTalk)
            muteMicrophoneIfUnused()
        }
        if new.audioMode != old.audioMode { await restartAudio() }
        if new.actionsEnabled != old.actionsEnabled {
            DebugLog.log("actions: \(new.actionsEnabled ? "on" : "off")")
            do { try await pipeline.setTools(await toolRunner()) } catch { emit.yield(.warning("\(error)")) }
            reportActions()
        }
    }

    // MARK: - Actions

    /// The tools for a new pipeline or conversation; nil when actions are off.
    private func toolRunner() async -> ToolRunner? {
        guard settings.actionsEnabled else { return nil }
        await shortcutTools.refresh()
        await shortcutTools.setNeedingConfirmation(Set(settings.shortcutsToConfirm))
        return ToolRunner(providers: [calendarTools, timerTools, shortcutTools])
    }

    /// The app is in front again: a shortcut may have been added to the folder, an access granted.
    private func refreshActions() async {
        guard settings.actionsEnabled, stage == .running else { return }
        if await shortcutTools.refresh() {
            do { try await pipeline?.toolsChanged() } catch { emit.yield(.warning("\(error)")) }
        }
        reportActions()
    }

    private func reportActions() {
        guard settings.actionsEnabled else { return }
        Task {
            let status = ActionsStatus(calendar: Self.access(CalendarTools.access(to: .event)),
                                       reminders: Self.access(CalendarTools.access(to: .reminder)),
                                       shortcuts: await shortcutTools.names)
            await self.send(status)
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
        guard let pipeline, let audio else { return }
        await pipeline.interrupt()
        do {
            route = try audio.start(mode: settings.audioMode, playbackSampleRate: playbackSampleRate)
        } catch {
            emit.yield(.problem(.audioDevice("\(error)")))
            return
        }
        await pipeline.resetAudioInput()
        await reportDiagnostics()
    }

    /// At rest in push-to-talk nothing the microphone hears is used: muted, so that the voices it hears do
    /// not turn the other apps down (see `SystemAudio.setMicrophoneMuted`).
    private func muteMicrophoneIfUnused() {
        audio?.setMicrophoneMuted(settings.pushToTalk && pipelineState == .listening)
    }

    /// A device was plugged or unplugged: the system stopped the audio engine.
    private func audioConfigurationChanged() async {
        guard !restartingAudio else { return }
        restartingAudio = true
        defer { restartingAudio = false }
        try? await Task.sleep(for: .milliseconds(300))  // changes often come in bursts
        await restartAudio()
    }

    // MARK: - Events

    private func forward(_ event: PipelineEvent) async {
        switch event {
        case .state(let state):
            pipelineState = state
            muteMicrophoneIfUnused()
            emit.yield(.state(state))
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
