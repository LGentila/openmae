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
enum DebugCommands {
    static let name = Notification.Name("OpenMaeDebugCommand")

    static func listen(_ handler: @escaping @MainActor (AssistantCommand) -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { note in
            guard let json = note.object as? String,
                  let command = try? JSONDecoder().decode(AssistantCommand.self, from: Data(json.utf8))
            else { return }
            MainActor.assumeIsolated { handler(command) }
        }
    }
}

/// Draws the screens in typical states into PNG files, with a scripted
/// engine instead of the real one, so the layout can be checked without clicking through a 17 GB download.
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
        let items = [
            ModelSetup.Item(role: .speechRecognition, displayName: "Parakeet TDT 0.6B v3", license: "CC-BY-4.0",
                            totalBytes: 482_000_000, missingBytes: 482_000_000),
            ModelSetup.Item(role: .languageModel, displayName: "Gemma 4 26B-A4B", license: "Apache-2.0",
                            totalBytes: 15_370_000_000, missingBytes: 15_370_000_000),
            ModelSetup.Item(role: .voice, displayName: "Pocket TTS", license: "CC-BY-4.0",
                            totalBytes: 1_670_000_000, missingBytes: 1_670_000_000),
        ]
        let setup = ModelSetup(
            chip: "Apple M1 Pro", memoryGiB: 32, tier: .comfort, recommendedTier: .comfort, items: items,
            bytesToDownload: 17_520_000_000, neededBytes: 18_520_000_000, availableBytes: 44_300_000_000,
            folder: NSHomeDirectory() + "/Library/Application Support/OpenMaé/Models")
        var noSpace = setup
        noSpace.availableBytes = 9_800_000_000
        var forced = setup
        forced.tier = .standard
        forced.items[1] = ModelSetup.Item(role: .languageModel, displayName: "Gemma 4 E4B", license: "Apache-2.0",
                                          totalBytes: 5_180_000_000, missingBytes: 5_180_000_000)
        forced.items[0].missingBytes = 0
        forced.items[2].missingBytes = 0
        forced.bytesToDownload = 5_180_000_000
        var progress = DownloadProgress(doneBytes: 6_240_000_000, totalBytes: 17_520_000_000)
        progress.bytesPerSecond = 45_300_000
        progress.currentModel = "Gemma 4 26B-A4B"
        var offline = progress
        offline.waitingForNetwork = true
        let info = EngineInfo(chip: "Apple M1 Pro", memoryGiB: 32, tier: .comfort, recommendedTier: .comfort,
                              languageModel: "Gemma 4 26B-A4B", speechRecognition: "Parakeet TDT 0.6B v3",
                              voice: "Pocket TTS · alba, estelle")
        let storage = ModelStorage(usedBytes: 21_100_000_000, unusedBytes: 3_580_000_000, folder: setup.folder)

        let scenarios: [(String, ModelSetup, [AssistantEvent])] = [
            ("1-setup", setup, [.setupNeeded(setup)]),
            ("2-downloading", setup, [.setupNeeded(setup), .downloadProgress(progress)]),
            ("3-offline", setup, [.setupNeeded(setup), .downloadProgress(offline)]),
            ("4-paused", setup, [.setupNeeded(setup), .downloadProgress(progress), .downloadStopped(nil)]),
            ("5-failed", setup, [.setupNeeded(setup), .downloadProgress(progress),
                                 .downloadStopped(.corrupted(file: "gemma-4-26b-a4b-it-4bit/model-00002-of-00003.safetensors"))]),
            ("6-no-space", noSpace, [.setupNeeded(noSpace)]),
            ("7-other-tier", forced, [.setupNeeded(forced)]),
        ]
        for (name, setup, events) in scenarios {
            let model = await scriptedModel(events)
            save(SetupView(model: model, setup: setup) {}, size: CGSize(width: 520, height: 820),
                 to: folder.appending(path: name + ".png"))
        }
        let ready = await scriptedModel([.ready(info), .storage(storage)])
        save(SettingsPanel(model: ready), size: CGSize(width: 380, height: 900), to: folder.appending(path: "8-settings.png"))
        save(ProblemView(problem: .engine("Error Domain=com.apple.CoreML Code=0 \"model damaged\""), retry: {},
                         deleteModels: {}),
             size: CGSize(width: 520, height: 500), to: folder.appending(path: "9-engine-problem.png"))
    }

    @MainActor
    private static func scriptedModel(_ events: [AssistantEvent]) async -> AssistantModel {
        let model = AssistantModel(connection: ScriptedConnection(events))
        try? await Task.sleep(for: .milliseconds(150))  // the model applies the events asynchronously
        return model
    }

    @MainActor
    private static func save(_ view: some View, size: CGSize, to url: URL) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// An engine that only replays a list of events.
private final class ScriptedConnection: AssistantConnection {
    let events: AsyncStream<AssistantEvent>

    init(_ list: [AssistantEvent]) {
        events = AsyncStream { continuation in
            list.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func send(_ command: AssistantCommand) {}
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
#endif
