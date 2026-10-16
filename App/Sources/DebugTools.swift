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
/// window's top-left corner), clicks there. The shortcuts, the capsule and the menu bar icon have their own
/// (DesktopPresence.swift).
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
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                      let frame = window.contentView?.superview
                else { return }
                Snapshots.write(frame, to: URL(fileURLWithPath: path))
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: click, object: nil, queue: .main) { note in
            let numbers = (note.object as? String)?.split(separator: ",").compactMap { Double($0) } ?? []
            guard numbers.count == 2 else { return }
            MainActor.assumeIsolated {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
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
            model.settings.pushToTalk = scenario.pushToTalk  // the scenario's, not the user's own setting
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
        // The settings with the actions on: access not asked yet, then refused.
        let shortcuts = ["Allumer le salon", "Mode concentration"]
        for (name, access) in [("main-9-settings-actions", ActionsStatus.Access.notAsked),
                               ("main-10-settings-actions-denied", .denied)]
        {
            let model = await scriptedModel(ready + [.actions(ActionsStatus(calendar: access, reminders: access,
                                                                            shortcuts: shortcuts))])
            let saved = model.settings
            model.settings.actionsEnabled = true
            model.settings.shortcutsToConfirm = ["Mode concentration"]
            let window = WindowState()
            let view = ContentView(model: model, window: window)
                .environment(\.stillFrame, 1.7)
                .preferredColorScheme(.light)
            await save(view, size: CGSize(width: 960, height: 700), to: folder.appending(path: name + ".png")) {
                window.panel = .settings
            }
            model.settings = saved
        }
        await renderTasks(to: folder, conversation: conversation, shortcuts: shortcuts)
        await renderWebSearch(to: folder, ready: ready)
        await renderPresence(to: folder)
        await renderPhone(to: folder)
    }

    /// Claude Code: its settings (a tall window, to see the whole panel), and the history with three tasks: one
    /// done, one in progress, one waiting for the user's "oui" (its instruction shown).
    @MainActor
    private static func renderTasks(to folder: URL, conversation: [AssistantEvent], shortcuts: [String]) async {
        let now = Date()
        func task(_ number: Int, _ title: String, _ instruction: String, _ status: AgentTask.Status,
                  minutesAgo: Double) -> AgentTask
        {
            var task = AgentTask(number: number, agentID: ClaudeCode.agentID, agentName: ClaudeCode.displayName,
                                 title: title, instruction: instruction, status: status,
                                 createdAt: now.addingTimeInterval(-minutesAgo * 60))
            if status != .awaitingConfirmation {
                task.startedAt = task.createdAt
                task.folder = "/Users/me/OpenMae/2026-10-16-tache-\(number)"
            }
            return task
        }
        var done = task(1, "site de la boulangerie", "Crée un site vitrine pour la boulangerie de la sœur de "
                        + "l’utilisateur : présentation, horaires et page de contact.", .finished, minutesAgo: 95)
        done.endedAt = now.addingTimeInterval(-50 * 60)
        done.resultText = "J’ai créé le site de la boulangerie : une page d’accueil, les horaires et une page de "
            + "contact. Ouvre **index.html** dans ton navigateur pour le voir."
        done.permissionDenials = ["npm install"]
        var running = task(2, "tri des factures", "Trie les factures du dossier par fournisseur et par année.",
                           .running, minutesAgo: 12)
        running.lastStep = .edits("factures.csv")
        let draft = task(3, "site du club de randonnée", "Crée un site pour le club de randonnée de Lucie, avec le "
                         + "calendrier des sorties et une page de contact.", .awaitingConfirmation, minutesAgo: 0)

        let history = await scriptedModel(conversation + [.tasks([done, running, draft])])
        let window = WindowState()
        await save(ContentView(model: history, window: window).environment(\.stillFrame, 1.7).preferredColorScheme(.light),
                   size: CGSize(width: 960, height: 1100), to: folder.appending(path: "main-11-history-tasks.png")) {
            window.panel = .history
        }

        let ready: [AssistantEvent] = [.ready(Demo.info), .storage(Demo.storage)]
        let model = await scriptedModel(ready + [.actions(ActionsStatus(calendar: .granted, reminders: .granted,
                                                                        shortcuts: shortcuts,
                                                                        claudeCode: .ready(version: "2.1.206")))])
        let saved = model.settings
        model.settings.actionsEnabled = true
        model.settings.claudeCode.enabled = true
        model.settings.claudeCode.folders = ["/Users/me/Projets/Sites"]
        let settingsWindow = WindowState()
        await save(ContentView(model: model, window: settingsWindow).environment(\.stillFrame, 1.7)
                       .preferredColorScheme(.light),
                   size: CGSize(width: 960, height: 1700), to: folder.appending(path: "main-12-settings-claude-code.png")) {
            settingsWindow.panel = .settings
        }
        model.settings = saved
    }

    /// The web search's settings, switched on: with Brave Search before its key is pasted, after a test that worked and
    /// after a refused key; with a SearXNG after a test that worked and one that was refused.
    @MainActor
    private static func renderWebSearch(to folder: URL, ready: [AssistantEvent]) async {
        let tests: [(name: String, source: WebSearchSource, key: Bool, test: WebSearchTest?)] = [
            ("main-13-settings-web-search-brave-new", .brave, false, nil),
            ("main-14-settings-web-search-brave", .brave, true, .works(results: 5, seconds: 0.62)),
            ("main-15-settings-web-search-brave-refused", .brave, true, .failed(.unauthorized)),
            ("main-16-settings-web-search-searxng", .searxng, false, .works(results: 25, seconds: 1.24)),
            ("main-17-settings-web-search-searxng-refused", .searxng, false, .failed(.forbidden)),
        ]
        for (name, source, key, test) in tests {
            let events: [AssistantEvent] = ready + (test.map { [AssistantEvent.webSearchTested($0)] } ?? [])
            let model = AssistantModel(connection: ScriptedConnection(events))
            model.hasTalkShortcut = true
            // Before the events arrive: a change of these settings forgets the last test.
            let saved = model.settings
            model.settings.webSearch.enabled = true
            model.settings.webSearch.source = source
            model.settings.webSearch.braveKeySaved = key
            model.settings.webSearch.address = source == .searxng ? "https://search.example.org" : ""
            try? await Task.sleep(for: .milliseconds(150))
            let window = WindowState()
            await save(ContentView(model: model, window: window).environment(\.stillFrame, 1.7)
                           .preferredColorScheme(.light),
                       size: CGSize(width: 960, height: 1100), to: folder.appending(path: name + ".png")) {
                window.panel = .settings
            }
            model.settings = saved
        }
    }

    /// The capsule over a pretend desktop, as in the design's Overlay screen (at rest: no capsule, the icon's
    /// outline), and the menu bar icon in its four states on a dark and a light bar.
    @MainActor
    private static func renderPresence(to folder: URL) async {
        let ready: [AssistantEvent] = [.ready(Demo.info), .storage(Demo.storage)]
        let heard: [AssistantEvent] = ready + [.state(.userSpeaking), .levels(input: 0.75, output: 0)]
        let thinking: [AssistantEvent] = heard + [.userTranscript(Demo.question, .french), .state(.thinking)]
        let speaking: [AssistantEvent] = thinking
            + Demo.answer.map { .assistantPiece($0) } + [.state(.speaking), .levels(input: 0, output: 0.8)]
        let scenes: [(name: String, events: [AssistantEvent], state: PipelineState?)] = [
            ("overlay-0-rest", ready, nil),
            ("overlay-1-listening", heard, .userSpeaking),
            ("overlay-2-thinking", thinking, .thinking),
            ("overlay-3-speaking", speaking, .speaking),
        ]
        for scene in scenes {
            let model = await scriptedModel(scene.events)
            let capsule = CapsuleState()
            if let state = scene.state {
                capsule.state = state
                capsule.isShown = true
                capsule.isPresented = true
            }
            let view = PretendDesktop(model: model, capsule: capsule)
                .environment(\.stillFrame, 1.7)
                .preferredColorScheme(.light)
            await save(view, size: CGSize(width: 1280, height: 720), to: folder.appending(path: scene.name + ".png"))
        }
        await save(MenuBarIconSheet().preferredColorScheme(.light), size: CGSize(width: 640, height: 300),
                   to: folder.appending(path: "menubar-icons.png"))
    }

    @MainActor
    static func scriptedModel(_ events: [AssistantEvent]) async -> AssistantModel {
        let model = AssistantModel(connection: ScriptedConnection(events))
        model.hasTalkShortcut = true  // as on a Mac that accepts ⌥ Space (snapshots register no shortcut)
        try? await Task.sleep(for: .milliseconds(150))  // the model applies the events asynchronously
        return model
    }

    @MainActor
    static func save(_ view: some View, size: CGSize, to url: URL, then prepare: () -> Void = {}) async {
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

    /// A window as the screen shows it, blur included, with what lies under it (macOS leaves the other apps out
    /// without the Screen Recording permission). CGWindowListCreateImage is obsolete in the macOS 15 SDK, whose
    /// replacement (ScreenCaptureKit) asks for that permission, but it still answers for the app's own windows:
    /// good enough for a test picture. Falls back to drawing the window's content.
    /// `alone`: the window by itself, without what lies under it.
    @MainActor
    static func writeOnScreen(_ window: NSWindow, alone: Bool = false, to url: URL) {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = window.frame
        let rect = CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
        // Options: 1 = everything on screen in `rect`; 8 = this window only (with "ignore framing", 1).
        let (options, windowID, imageOptions): (UInt32, UInt32?, UInt32) = alone
            ? (8, UInt32(exactly: window.windowNumber), 1) : (1, 0, 0)
        DebugLog.log("picture of window \(window.windowNumber) \(window.frame)")
        guard let windowID, let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"),
              let image = unsafeBitCast(symbol, to: CreateImage.self)(alone ? .null : rect, options, windowID,
                                                                       imageOptions)?.takeRetainedValue()
        else {
            if let view = window.contentView { write(view, to: url) }
            return
        }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The menu bar icon as it is now, four times its size, on a dark bar and on a light one (the outline at rest
    /// has the colour macOS gives it for the real bar). The bars are drawn still.
    @MainActor
    static func writeMenuBarButton(_ button: NSView, to url: URL) {
        let scale: CGFloat = 4
        let width = Int(button.bounds.width * scale), height = Int(button.bounds.height * scale)
        guard let layer = button.layer, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 2 * width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        for (i, bar) in [RGBA(0x1B363F), RGBA(0xE4E0D6)].enumerated() {
            context.saveGState()
            context.translateBy(x: CGFloat(i * width), y: 0)
            context.setFillColor(bar.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            layer.render(in: context)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// A pretend desktop, as in the design's Overlay screen: wallpaper, a window, the menu bar with OpenMaé's icon,
/// and the capsule when it is presented. Its colours only serve to see the glass; they are not the design's.
private struct PretendDesktop: View {
    let model: AssistantModel
    let capsule: CapsuleState

    var body: some View {
        ZStack(alignment: .topLeading) {
            RGBA(0x1B363F).color
            Circle().fill(RGBA(0x244B56)).frame(width: 820, height: 820).offset(x: -260, y: 360)
            Circle().fill(RGBA(0x2A5663)).frame(width: 760, height: 760).offset(x: 880, y: -300)
            VStack(alignment: .leading, spacing: 14) {
                RoundedRectangle(cornerRadius: 10).fill(RGBA(0xDAD5CA)).frame(width: 260, height: 20)
                ForEach([1, 0.92, 0.96], id: \.self) { width in
                    RoundedRectangle(cornerRadius: 6).fill(RGBA(0xE6E2D9)).frame(width: 708 * width, height: 12)
                }
                RoundedRectangle(cornerRadius: 12).fill(RGBA(0xEAE5DB)).frame(width: 708, height: 120)
            }
            .padding(EdgeInsets(top: 62, leading: 56, bottom: 0, trailing: 56))
            .frame(width: 820, height: 470, alignment: .topLeading)
            .background(RGBA(0xF7F4EE), in: RoundedRectangle(cornerRadius: 16))
            .offset(x: 230, y: 92)
            HStack {
                Spacer()
                menuBarIcon
                    .padding(.trailing, 200)
            }
            .frame(width: 1280, height: 32)
            .background(RGBA(red: 14 / 255, green: 26 / 255, blue: 30 / 255, alpha: 0.5).color)
            if capsule.isPresented {
                CapsuleView(model: model, capsule: capsule)
                    .position(x: 640, y: 574)
            }
        }
        .frame(width: 1280, height: 720)
        .clipped()
    }

    @ViewBuilder private var menuBarIcon: some View {
        if capsule.isPresented {
            Image(nsImage: ActiveMenuBarIcon.picture(color: StatePalette(capsule.state).glow, side: MenuBarIcon.side,
                                                     time: 1.7))
        } else {
            Image(nsImage: MenuBarIcon.restImage)
                .renderingMode(.template)
                .foregroundStyle(Palette.white.opacity(0.92))
        }
    }
}

/// The menu bar icon's four states at 48 points, on a dark and on a light bar, as in the design's MenuBarIcon
/// screen.
private struct MenuBarIconSheet: View {
    private let states: [PipelineState?] = [nil, .userSpeaking, .thinking, .speaking]

    var body: some View {
        VStack(spacing: 12) {
            row(dark: true)
            row(dark: false)
            HStack(spacing: 0) {
                ForEach(states, id: \.self) { state in
                    StateText.accessibilityName(state ?? .listening)
                        .textStyle(.chip)
                        .frame(maxWidth: .infinity)
                }
            }
            .foregroundStyle(Palette.inkMuted)
        }
        .padding(28)
        .frame(width: 640, height: 300)
        .background(RGBA(0xF4F1EA).color)
    }

    private func row(dark: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(states, id: \.self) { state in
                icon(state, dark: dark)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 96)
        .background(dark ? RGBA(0x1B363F) : RGBA(0xE4E0D6), in: RoundedRectangle(cornerRadius: Radius.section))
    }

    @ViewBuilder private func icon(_ state: PipelineState?, dark: Bool) -> some View {
        if let state {
            Image(nsImage: ActiveMenuBarIcon.picture(color: StatePalette(state).glow, side: 48, time: 1.7))
        } else {
            Image(nsImage: MenuBarIcon.restImage)
                .renderingMode(.template)
                .resizable()
                .foregroundStyle(dark ? Palette.white.opacity(0.92) : Palette.ink.opacity(0.9))
                .frame(width: 48, height: 48)
        }
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

/// `-actions-test-calendar`: every event and reminder Maé creates goes into a calendar and a list named
/// "OpenMaé (tests)" (created on first use), so trying the actions leaves the user's own calendars unchanged (Maé
/// still reads them all). Deleting that calendar and that list cleans everything up. The tasks handed to Claude
/// Code go to ~/OpenMae-tests, folders and history alike: deleting that folder cleans them up.
enum ActionsTestCollection {
    static var name: String? {
        ProcessInfo.processInfo.arguments.contains("-actions-test-calendar") ? "OpenMaé (tests)" : nil
    }

    static var agentsFolder: URL? {
        guard name != nil else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "OpenMae-tests", directoryHint: .isDirectory)
    }
}

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
        DebugLog.log("demo engine: \(command)")
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
        case .talkKey(let pressed):
            play(pressed ? talkScript : answerScript)
        default:
            break
        }
    }

    /// The talk key is down (the global shortcut, or push-to-talk): the user speaks until it goes up.
    private var talkScript: @Sendable (AsyncStream<AssistantEvent>.Continuation) async -> Void {
        { sink in
            sink.yield(.state(.userSpeaking))
            _ = await Self.voice(sink, seconds: 120, input: true)
        }
    }

    /// The talk key went up: Maé thinks, answers, then the conversation goes on as before.
    private var answerScript: @Sendable (AsyncStream<AssistantEvent>.Continuation) async -> Void {
        { [conversationScript] sink in
            sink.yield(.levels(input: 0, output: 0))
            sink.yield(.userTranscript(Demo.question, .french))
            sink.yield(.state(.thinking))
            guard await Self.wait(2) else { return }
            Demo.answer.forEach { sink.yield(.assistantPiece($0)) }
            sink.yield(.state(.speaking))
            guard await Self.voice(sink, seconds: 8.8, input: false) else { return }
            sink.yield(.state(.listening))
            await conversationScript(sink)
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
