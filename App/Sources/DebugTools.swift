#if DEBUG
import AppKit
import SwiftUI
import VoiceCore

// Development aids, compiled into debug builds only (CONFIGURATION=Debug zsh scripts/build-app.sh).

/// Lets a test script click the buttons: it posts an `AssistantCommand`, as JSON, in a distributed
/// notification, and the app handles it like a click. With VOICE_DEBUG=1 the app writes the engine's
/// events on its standard error output. Example, from Swift:
///
///   DistributedNotificationCenter.default().postNotificationName(
///       .init("OpenMaeDebugCommand"), object: #"{"downloadModels":{}}"#, deliverImmediately: true)
///
/// A second notification, "OpenMaeDebugCapture", whose object is a file path, saves a picture of the window
/// there (PNG), title bar included. A third, "OpenMaeDebugClick", whose object is "x,y" (points from the
/// window's top-left corner), clicks there.
enum DebugCommands {
    static let name = Notification.Name("OpenMaeDebugCommand")
    static let capture = Notification.Name("OpenMaeDebugCapture")
    static let click = Notification.Name("OpenMaeDebugClick")

    static func listen(_ handler: @escaping @MainActor (AssistantCommand) -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { note in
            guard let json = note.object as? String,
                  let command = try? JSONDecoder().decode(AssistantCommand.self, from: Data(json.utf8))
            else { return }
            MainActor.assumeIsolated { handler(command) }
        }
        DistributedNotificationCenter.default().addObserver(forName: capture, object: nil, queue: .main) { note in
            guard let path = note.object as? String else { return }
            MainActor.assumeIsolated {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                      let frame = window.contentView?.superview
                else { return }
                Snapshots.write(frame, to: URL(fileURLWithPath: path))
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: click, object: nil, queue: .main) { note in
            let numbers = (note.object as? String)?.split(separator: ",").compactMap { Double($0) } ?? []
            guard numbers.count == 2 else { return }
            MainActor.assumeIsolated {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
                let point = NSPoint(x: numbers[0], y: window.frame.height - numbers[1])
                let target = window.contentView?.superview?.hitTest(point)
                FileHandle.standardError.write(Data("click \(point) → \(target.map { String(describing: type(of: $0)) } ?? "nothing")\n".utf8))
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                      clickCount: 1, pressure: 1)
                    {
                        window.sendEvent(event)
                    }
                }
            }
        }
    }
}

// MARK: - Still pictures of the screens

/// Draws the screens in typical states into PNG files, with a scripted engine instead of the real one, so
/// the layout can be checked without clicking through a 17 GB download.
///
///   OpenMae.app/Contents/MacOS/OpenMae -snapshots <folder> [-AppleLanguages '(en)']
enum Snapshots {
    static var folder: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-snapshots"), i + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[i + 1])
    }

    @MainActor
    static func render(to folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ready: [AssistantEvent] = [.ready(Demo.info), .storage(Demo.storage)]
        let heard: [AssistantEvent] = ready + [.state(.userSpeaking), .levels(input: 0.75, output: 0)]
        let thinking: [AssistantEvent] = heard + [.userTranscript(Demo.question, .french), .state(.thinking)]
        let speaking: [AssistantEvent] = thinking
            + Demo.answer.map { .assistantPiece($0) } + [.state(.speaking), .levels(input: 0, output: 0.8)]
        let conversation: [AssistantEvent] = speaking + [.state(.listening), .levels(input: 0, output: 0)]
            + [.state(.userSpeaking), .userTranscript("Et quel temps fera-t-il ?", .french), .state(.thinking),
               .assistantPiece("Je n’ai pas accès à Internet, donc je ne connais pas la météo de demain."),
               .state(.speaking), .state(.listening)]

        var progress = DownloadProgress(doneBytes: 8_060_000_000, totalBytes: Demo.setup.bytesToDownload)
        progress.currentModel = "Gemma 4 26B-A4B"
        progress.missingBytes = [.speechRecognition: 0, .voice: 0, .languageModel: 9_460_000_000]
        var offline = progress
        offline.waitingForNetwork = true
        var noSpace = Demo.setup
        noSpace.availableBytes = 9_800_000_000
        var forced = Demo.setup
        forced.tier = .standard
        forced.items[2] = ModelSetup.Item(role: .languageModel, displayName: "Gemma 4 E4B", license: "Apache-2.0",
                                          totalBytes: 5_180_000_000, missingBytes: 5_180_000_000)
        forced.items[0].missingBytes = 0
        forced.items[1].missingBytes = 0
        forced.bytesToDownload = 5_180_000_000
        let setup: [AssistantEvent] = [.setupNeeded(Demo.setup), .storage(ModelStorage(usedBytes: 0, unusedBytes: 0,
                                                                                       folder: Demo.setup.folder))]

        let scenarios: [(name: String, events: [AssistantEvent], panel: WindowState.Panel?, pushToTalk: Bool)] = [
            ("main-1-rest", ready, nil, false),
            ("main-2-listening", heard, nil, false),
            ("main-3-thinking", thinking, nil, false),
            ("main-4-speaking", speaking, nil, false),
            ("main-5-push-to-talk", ready, nil, true),
            ("main-6-history", conversation, .history, false),
            ("main-7-settings", ready, .settings, false),
            ("main-8-loading", [.loading(.languageModel)], nil, false),
            ("setup-1-welcome", setup, nil, false),
            ("setup-2-downloading", setup + [.downloadProgress(progress)], nil, false),
            ("setup-3-offline", setup + [.downloadProgress(offline)], nil, false),
            ("setup-4-paused", setup + [.downloadProgress(progress), .downloadStopped(nil)], nil, false),
            ("setup-5-failed", setup + [.downloadProgress(progress),
                                        .downloadStopped(.corrupted(file: "gemma-4-26b-a4b-it-4bit/model-00002-of-00003.safetensors"))],
             nil, false),
            ("setup-6-no-space", [.setupNeeded(noSpace)], nil, false),
            ("setup-7-other-tier", [.setupNeeded(forced)], nil, false),
            ("setup-8-settings", setup, .settings, false),
            ("problem-1-engine", [.problem(.engine("Error Domain=com.apple.CoreML Code=0 \"model damaged\""))], nil,
             false),
            ("problem-2-microphone", [.problem(.microphoneDenied)], nil, false),
        ]
        for scenario in scenarios {
            let model = await scriptedModel(scenario.events)
            let saved = model.settings
            if scenario.pushToTalk { model.settings.pushToTalk = true }
            let window = WindowState()
            let view = ContentView(model: model, window: window)
                .environment(\.stillFrame, 1.7)
                .preferredColorScheme(.light)
            await save(view, size: CGSize(width: 960, height: 700), to: folder.appending(path: scenario.name + ".png")) {
                // Once the window has started the (scripted) engine, which closes any panel.
                window.panel = scenario.panel
                window.pointsAtTier = scenario.name.hasPrefix("setup")
            }
            model.settings = saved  // the scripted model saves the settings like the real one: put them back
        }
    }

    @MainActor
    private static func scriptedModel(_ events: [AssistantEvent]) async -> AssistantModel {
        let model = AssistantModel(connection: ScriptedConnection(events))
        try? await Task.sleep(for: .milliseconds(150))  // the model applies the events asynchronously
        return model
    }

    @MainActor
    private static func save(_ view: some View, size: CGSize, to url: URL, then prepare: () -> Void = {}) async {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        prepare()
        try? await Task.sleep(for: .milliseconds(600))  // panels and words appear with a short animation
        write(host, to: url)
    }

    @MainActor
    static func write(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// An engine that only replays a list of events, at once and again when asked to start (as the window does
/// when it appears).
private final class ScriptedConnection: AssistantConnection {
    let events: AsyncStream<AssistantEvent>
    private let list: [AssistantEvent]
    private let sink: AsyncStream<AssistantEvent>.Continuation

    init(_ list: [AssistantEvent]) {
        self.list = list
        (events, sink) = AsyncStream.makeStream()
        list.forEach { sink.yield($0) }
    }

    func send(_ command: AssistantCommand) {
        if case .start = command { list.forEach { sink.yield($0) } }
    }
}

/// Window content in snapshot mode: renders, then quits.
struct SnapshotRunner: View {
    let folder: URL

    var body: some View {
        Text(verbatim: "Snapshots → \(folder.path)")
            .padding()
            .task {
                await Snapshots.render(to: folder)
                exit(0)
            }
    }
}

// MARK: - Demonstration

/// A pretend engine that plays a conversation in a loop, to look at the screens moving without talking:
///
///   OpenMae.app/Contents/MacOS/OpenMae -demo            the conversation
///   OpenMae.app/Contents/MacOS/OpenMae -demo-setup      the first launch first (Download does download nothing)
enum Demo {
    static var isOn: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return startsWithSetup || arguments.contains("-demo") || arguments.contains("-demo-idle")
    }
    static var startsWithSetup: Bool { ProcessInfo.processInfo.arguments.contains("-demo-setup") }

    static let question = "Maé, rappelle-moi d’appeler Camille demain matin à dix heures, pour parler du voyage."
    static let answer = ["C’est noté ! Demain à 10 h, je te rappelle d’appeler Camille.",
                         "Tu veux que je note aussi les idées du voyage ?"]

    static let info = EngineInfo(chip: "Apple M1 Pro", memoryGiB: 32, tier: .comfort, recommendedTier: .comfort,
                                 languageModel: "Gemma 4 26B-A4B", speechRecognition: "Parakeet TDT 0.6B v3",
                                 voice: "Pocket TTS · estelle")
    static let storage = ModelStorage(usedBytes: 17_520_000_000, unusedBytes: 0,
                                      folder: NSHomeDirectory() + "/Library/Application Support/OpenMaé/Models")
    static let setup = ModelSetup(
        chip: "Apple M1 Pro", memoryGiB: 32, tier: .comfort, recommendedTier: .comfort,
        items: [
            ModelSetup.Item(role: .speechRecognition, displayName: "Parakeet TDT 0.6B v3", license: "CC-BY-4.0",
                            totalBytes: 483_100_000, missingBytes: 483_100_000),
            ModelSetup.Item(role: .voice, displayName: "Pocket TTS", license: "CC-BY-4.0",
                            totalBytes: 1_670_000_000, missingBytes: 1_670_000_000),
            ModelSetup.Item(role: .languageModel, displayName: "Gemma 4 26B-A4B", license: "Apache-2.0",
                            totalBytes: 15_370_000_000, missingBytes: 15_370_000_000),
        ],
        bytesToDownload: 17_523_100_000, neededBytes: 18_523_100_000, availableBytes: 73_190_000_000,
        folder: NSHomeDirectory() + "/Library/Application Support/OpenMaé/Models")
}

final class DemoConnection: AssistantConnection, @unchecked Sendable {
    let events: AsyncStream<AssistantEvent>
    private let sink: AsyncStream<AssistantEvent>.Continuation
    private let lock = NSLock()
    private var script: Task<Void, Never>?

    init() {
        (events, sink) = AsyncStream.makeStream()
    }

    func send(_ command: AssistantCommand) {
        switch command {
        case .start:
            play(Demo.startsWithSetup ? setupScript : conversationScript)
        case .downloadModels:
            play(downloadScript)
        case .pauseDownload:
            play { sink in sink.yield(.downloadStopped(nil)) }
        case .stopSpeaking:
            play { [conversationScript] sink in
                sink.yield(.levels(input: 0, output: 0))
                sink.yield(.state(.listening))
                await conversationScript(sink)
            }
        default:
            break
        }
    }

    private func play(_ steps: @escaping @Sendable (AsyncStream<AssistantEvent>.Continuation) async -> Void) {
        lock.withLock {
            script?.cancel()
            script = Task { [sink] in await steps(sink) }
        }
    }

    private var setupScript: @Sendable (AsyncStream<AssistantEvent>.Continuation) async -> Void {
        { sink in
            sink.yield(.setupNeeded(Demo.setup))
            sink.yield(.storage(ModelStorage(usedBytes: 0, unusedBytes: 0, folder: Demo.setup.folder)))
        }
    }

    /// About twenty seconds of download, model after model, then loading.
    private var downloadScript: @Sendable (AsyncStream<AssistantEvent>.Continuation) async -> Void {
        { [conversationScript] sink in
            let items = Demo.setup.items
            let total = Demo.setup.bytesToDownload
            for step in 0...190 {
                var done = Int64(Double(total) * Double(step) / 190)
                var progress = DownloadProgress(doneBytes: done, totalBytes: total)
                for item in items {
                    let got = min(done, item.totalBytes)
                    progress.missingBytes[item.role] = item.totalBytes - got
                    if got < item.totalBytes, progress.currentModel == nil { progress.currentModel = item.displayName }
                    done -= got
                }
                sink.yield(.downloadProgress(progress))
                guard await Self.wait(0.1) else { return }
            }
            for step in [LoadingStep.speechRecognition, .languageModel, .voice] {
                sink.yield(.loading(step))
                guard await Self.wait(1) else { return }
            }
            await conversationScript(sink)
        }
    }

    /// At rest, the user speaks, Maé thinks, then answers; again and again (with -demo-idle: at rest only).
    private var conversationScript: @Sendable (AsyncStream<AssistantEvent>.Continuation) async -> Void {
        { sink in
            sink.yield(.ready(Demo.info))
            sink.yield(.storage(Demo.storage))
            guard !ProcessInfo.processInfo.arguments.contains("-demo-idle") else { return }
            while !Task.isCancelled {
                sink.yield(.state(.listening))
                guard await Self.wait(2.2) else { return }
                sink.yield(.state(.userSpeaking))
                guard await Self.voice(sink, seconds: 5.8, input: true) else { return }
                sink.yield(.userTranscript(Demo.question, .french))
                sink.yield(.state(.thinking))
                guard await Self.wait(2) else { return }
                Demo.answer.forEach { sink.yield(.assistantPiece($0)) }
                sink.yield(.state(.speaking))
                guard await Self.voice(sink, seconds: 8.8, input: false) else { return }
                sink.yield(.levels(input: 0, output: 0))
            }
        }
    }

    /// A voice-like level, twenty times per second.
    private static func voice(_ sink: AsyncStream<AssistantEvent>.Continuation, seconds: Double, input: Bool) async
        -> Bool
    {
        let steps = Int(seconds * 20)
        for i in 0..<steps {
            let t = Double(i) / 20
            let level = Float(max(0, 0.55 + 0.25 * sin(t * 9) * sin(t * 2.3) + 0.1 * sin(t * 23)))
            sink.yield(.levels(input: input ? level : 0, output: input ? 0 : level))
            guard await wait(0.05) else { return false }
        }
        sink.yield(.levels(input: 0, output: 0))
        return true
    }

    /// False when the script was cancelled meanwhile.
    private static func wait(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }
}
#endif
