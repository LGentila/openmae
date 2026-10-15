import Foundation
import VoiceCore

/// The engine as the app sees it: it receives `AssistantCommand`s and sends `AssistantEvent`s
/// (see AssistantProtocol.swift). It owns the models, the microphone and the speakers, and runs in the
/// app's process. A future separate-process engine would wrap this same object.
public actor AssistantHost: AssistantConnection {
    public nonisolated let events: AsyncStream<AssistantEvent>
    private nonisolated let emit: AsyncStream<AssistantEvent>.Continuation
    private nonisolated let commands: AsyncStream<AssistantCommand>.Continuation

    private var settings = AssistantSettings()
    private var pipeline: VoicePipeline?
    private var model: MLXChatModel?
    private var audio: SystemAudio?
    private var route: SystemAudio.Route?
    private var playbackSampleRate = 24_000.0
    private var tasks: [Task<Void, Never>] = []
    private var activity: NSObjectProtocol?
    private var restartingAudio = false

    public init() {
        (events, emit) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        let (commandStream, commands) = AsyncStream<AssistantCommand>.makeStream(bufferingPolicy: .unbounded)
        self.commands = commands
        // One command at a time, in order (a push-to-talk release must never overtake its press).
        Task { [weak self] in
            for await command in commandStream { await self?.handle(command) }
        }
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
        case .shutdown:
            shutdown()
        }
    }

    // MARK: - Start-up

    private func start() async {
        guard pipeline == nil else { return }
        emit.yield(.loading(.microphone))
        guard await SystemAudio.requestMicrophoneAccess() else {
            emit.yield(.problem(.microphoneDenied))
            return
        }
        let hardware = HardwareProfile.current
        let tier = HardwareTier.recommended(for: hardware)
        guard let languageSpec = ModelCatalog.languageModel(for: tier) else {
            emit.yield(.problem(.unsupportedMac(chip: hardware.chipName, memoryGiB: hardware.memoryGiB)))
            return
        }
        guard let languageURL = ModelLocator.languageModel() else {
            emit.yield(.problem(.modelMissing(languageSpec.displayName)))
            return
        }
        guard let vadURL = ModelLocator.voiceActivity() else {
            emit.yield(.problem(.modelMissing(ModelCatalog.voiceActivity.displayName)))
            return
        }

        // Sound first: a microphone or speaker problem shows up at once, not after a minute of loading.
        let audio = SystemAudio()
        do {
            route = try audio.start(mode: settings.audioMode, playbackSampleRate: playbackSampleRate)
        } catch {
            emit.yield(.problem(.audioDevice("\(error)")))
            return
        }
        audio.onConfigurationChange = { [weak self] in
            Task { await self?.audioConfigurationChanged() }
        }
        self.audio = audio

        let model: MLXChatModel
        let pipeline: VoicePipeline
        do {
            emit.yield(.loading(.speechRecognition))
            let detector = try SileroSpeechDetector(modelURL: vadURL)
            let transcriber = try await ParakeetTranscriber.load()
            emit.yield(.loading(.languageModel))
            model = try await MLXChatModel.load(directory: languageURL)
            emit.yield(.loading(.voice))
            let synthesizer = PocketSpeechSynthesizer()
            try await synthesizer.preload([.french, .english])
            if synthesizer.outputSampleRate != playbackSampleRate {
                playbackSampleRate = synthesizer.outputSampleRate
                route = try audio.start(mode: settings.audioMode, playbackSampleRate: playbackSampleRate)
            }

            var config = PipelineConfig()
            config.pushToTalk = settings.pushToTalk
            pipeline = VoicePipeline(detector: detector, transcriber: transcriber, model: model,
                                     synthesizer: synthesizer, output: audio, config: config)
            try await pipeline.start()
        } catch {
            audio.stop()
            self.audio = nil
            emit.yield(.problem(.engine("\(error)")))
            return
        }

        self.model = model
        self.pipeline = pipeline
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
            chip: hardware.chipName, memoryGiB: hardware.memoryGiB, tier: tier,
            languageModel: languageSpec.displayName,
            speechRecognition: ModelCatalog.speechRecognition.displayName,
            voice: "Pocket TTS · " + PocketSpeechSynthesizer.voices.values.sorted().joined(separator: ", "))))
        await reportDiagnostics()
    }

    private func shutdown() {
        tasks.forEach { $0.cancel() }
        tasks = []
        audio?.stop()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    // MARK: - Settings and audio devices

    private func apply(_ new: AssistantSettings) async {
        let old = settings
        settings = new
        guard let pipeline else { return }
        if new.pushToTalk != old.pushToTalk { await pipeline.setPushToTalk(new.pushToTalk) }
        if new.audioMode != old.audioMode { await restartAudio() }
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
        case .state(let state): emit.yield(.state(state))
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
