import AppKit
import SwiftUI
import VoiceCore

// The capsule: a glass pill at the bottom of the screen that says, without opening the window, that Maé listens,
// thinks or answers. It appears with the global shortcut (or once Maé answers while the window is behind other
// apps), never at rest, and goes away at the end of the answer. It never takes the keyboard.

/// What the capsule shows, set by `DesktopPresence`.
@MainActor
@Observable
final class CapsuleState {
    /// The state of the conversation it follows; never "at rest": on its way out it keeps the last one.
    var state = PipelineState.userSpeaking
    /// The capsule is up, or coming up; false: on its way out.
    var isShown = false
    /// Its content exists: from just before it comes up until it has faded out (nothing moves while it is away).
    var isPresented = false
}

/// The small orb on the left, the status and the end of the sentence in the middle, the action and its key on the
/// right, ripples around.
struct CapsuleView: View {
    let model: AssistantModel
    let capsule: CapsuleState

    static let size = CGSize(width: 540, height: 72)

    /// Set once the view is on screen, so that it comes up from below rather than appearing.
    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.stillFrame) private var stillFrame

    var body: some View {
        let state = capsule.state
        let shape = Capsule()
        HStack(spacing: 14) {
            CapsuleOrb(model: model, state: state)
            CapsuleText(model: model, state: state)
            CapsuleAction(state: state)
        }
        .padding(.leading, 8)
        .padding(.trailing, 22)
        .frame(width: Self.size.width, height: Self.size.height)
        // Behind the content, from front to back: the ripples (larger than the capsule), the glass, its shadow.
        .background { CapsuleRipples(state: state) }
        .background {
            ZStack {
                if stillFrame == nil { GlassBlur() }  // a still picture has no screen behind it to blur
                shape.fill(StatePalette(state).glass)
                    .animation(Easing.animation(Easing.ease, 0.5), value: state)
                shape.strokeBorder(Palette.white.opacity(0.6), lineWidth: 1)
            }
        }
        .background { CapsuleShadow() }
        .overlay(shape.inset(by: -0.25).stroke(RGBA(0x000000).opacity(0.22), lineWidth: 0.5))
        .modifier(Entrance(isShown: (arrived || stillFrame != nil) && capsule.isShown, reduceMotion: reduceMotion))
        .onAppear { arrived = true }
        .accessibilityElement(children: .combine)
    }
}

/// The capsule comes up 18 points and grows from 90 % with a marked bounce while it fades in; it leaves the same
/// way. With Reduce Motion it only fades.
private struct Entrance: ViewModifier {
    let isShown: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(isShown || reduceMotion ? 1 : 0.9)
            .offset(y: isShown || reduceMotion ? 0 : 18)
            .animation(Easing.animation(Easing.capsule, Timing.capsule), value: isShown)
            .opacity(isShown ? 1 : 0)
            .animation(Easing.animation(Easing.ease, 0.3), value: isShown)
    }
}

// MARK: - Pieces

/// The 64-point orb, breathing with the voice of whoever speaks.
private struct CapsuleOrb: View {
    let model: AssistantModel
    let state: PipelineState

    var body: some View {
        Orb(look: .capsule(state), style: .capsule, level: level)
    }

    private var level: Float {
        switch state {
        case .userSpeaking: model.inputLevel
        case .speaking: model.outputLevel
        case .listening, .thinking: 0
        }
    }
}

/// The status, over the end of the sentence in progress. The user's words only exist once their turn is over, so
/// while Maé listens the status is alone.
private struct CapsuleText: View {
    let model: AssistantModel
    let state: PipelineState

    var body: some View {
        let deep = StatePalette(state).deepOnGlass
        VStack(alignment: .leading, spacing: 2) {
            Text(status)
                .textStyle(.capsuleStatus)
                .foregroundStyle(deep)
                .animation(Easing.animation(Easing.ease, 0.4), value: state)
                .lineLimit(1)
            if let sentence {
                CapsuleWords(sentence: sentence, deep: deep)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var status: LocalizedStringKey {
        switch state {
        case .listening, .userSpeaking: "I'm listening…"
        case .thinking: "I'm thinking…"
        case .speaking: "Maé is answering"
        }
    }

    /// What the user said while Maé thinks, then Maé's answer as she speaks it.
    private var sentence: CapsuleSentence? {
        let exchange = model.currentExchange
        switch state {
        case .thinking:
            guard let user = exchange.user, !user.pending, !user.text.isEmpty else { return nil }
            return CapsuleSentence(id: user.id, words: TranscriptWords.split(user.text), tintsRecentWords: false,
                                   pace: 0.035)
        case .speaking:
            guard let answer = exchange.answer else { return nil }
            return CapsuleSentence(id: answer.id, words: TranscriptWords.split(answer.text), tintsRecentWords: true,
                                   pace: 0.26)
        case .listening, .userSpeaking:
            return nil
        }
    }
}

private struct CapsuleSentence {
    var id: UUID
    var words: [String]
    /// The two most recent words are tinted.
    var tintsRecentWords: Bool
    /// Seconds between two words. Maé's text comes ahead of her voice: it is shown at the pace of speech.
    var pace: Double
}

/// The last five words of the sentence on one line, after "…" when there are more. Each new word comes up
/// unblurring; the others jump to their new place.
private struct CapsuleWords: View {
    let sentence: CapsuleSentence
    let deep: RGBA

    @Environment(\.stillFrame) private var stillFrame
    @State private var shown = Shown()

    private struct Shown: Equatable {
        var sentence: UUID?
        var count = 0
    }

    var body: some View {
        let count = stillFrame != nil ? sentence.words.count
            : shown.sentence == sentence.id ? min(shown.count, sentence.words.count) : 0
        let first = max(0, count - 5)
        let style = TextStyle.capsuleTranscript
        HStack(spacing: 0.28 * style.size) {
            if first > 0 {
                Text(verbatim: "…").foregroundStyle(Palette.inkMuted)
            }
            ForEach(first..<count, id: \.self) { i in
                Text(verbatim: sentence.words[i])
                    .foregroundStyle(sentence.tintsRecentWords && i >= count - 2 ? deep : Palette.ink)
                    .animation(Easing.animation(Easing.ease, 0.7), value: i >= count - 2)
                    .transition(.asymmetric(
                        insertion: .modifier(active: WordArrival(amount: 1), identity: WordArrival(amount: 0))
                            .animation(Easing.animation(Easing.rise, Timing.word)),
                        removal: .identity))
            }
        }
        .textStyle(style)
        .lineLimit(1)
        .fixedSize()
        .frame(maxWidth: .infinity, minHeight: style.lineHeight, alignment: .leading)
        .padding(.vertical, 4)  // room for a word coming up, blurred
        .clipped()
        .padding(.vertical, -4)
        .task(id: [sentence.id.uuidString, String(sentence.words.count)]) { await reveal() }
    }

    private func reveal() async {
        guard stillFrame == nil else { return }
        if shown.sentence != sentence.id { shown = Shown(sentence: sentence.id) }
        while shown.count < sentence.words.count {
            shown.count += 1
            try? await Task.sleep(for: .seconds(sentence.pace))
            if Task.isCancelled { return }
        }
    }
}

/// A word comes up 5 points, from blurred to sharp.
private struct WordArrival: ViewModifier {
    let amount: Double

    func body(content: Content) -> some View {
        content
            .offset(y: 5 * amount)
            .blur(radius: 3 * amount)
            .opacity(1 - amount)
    }
}

/// What the key on the right does: finish the user's turn, cancel the answer being prepared, interrupt Maé.
private struct CapsuleAction: View {
    let state: PipelineState

    /// The action's label: a little darker than `ink-muted` on the glass, as in the design's capsule.
    private static let label = RGBA(0x5E584F)

    var body: some View {
        HStack(spacing: 9) {
            Text(title)
                .textStyle(.capsuleAction)
                .foregroundStyle(Self.label)
            KeyCap(title: key, onGlass: true)
        }
        .fixedSize()
    }

    private var title: LocalizedStringKey {
        switch state {
        case .listening, .userSpeaking: "Finish"
        case .thinking: "Cancel"
        case .speaking: "Interrupt"
        }
    }

    private var key: Text {
        switch state {
        case .listening, .userSpeaking: Text("⌥ Space")
        case .thinking, .speaking: Text(verbatim: "esc")
        }
    }
}

/// Two ripples 1.2 s apart following the capsule's outline: inwards while the user speaks, outwards while Maé
/// speaks, invisible otherwise and with Reduce Motion.
private struct CapsuleRipples: View {
    let state: PipelineState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.stillFrame) private var stillFrame

    /// How far a ripple goes beyond the capsule.
    private static let reach: CGFloat = 20

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: stillFrame != nil)) { timeline in
                let time = stillFrame ?? timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    Self.ripples(at: time, inwards: false)
                        .opacity(state == .speaking ? 1 : 0)
                    Self.ripples(at: time, inwards: true)
                        .opacity(state == .userSpeaking ? 1 : 0)
                }
            }
            .animation(Easing.animation(Easing.ease, 0.5), value: state)
            .frame(width: CapsuleView.size.width + 2 * Self.reach, height: CapsuleView.size.height + 2 * Self.reach)
            .allowsHitTesting(false)
        }
    }

    /// Each set only shows in its own state, so it keeps that state's colour: azure inwards, coral outwards.
    private static func ripples(at time: Double, inwards: Bool) -> some View {
        let color = StatePalette(inwards ? .userSpeaking : .speaking).glow
        return Canvas { context, _ in
            let capsule = CGRect(origin: CGPoint(x: reach, y: reach), size: CapsuleView.size)
            for ring in 0..<2 {
                let p = Keyframes.loop(time, period: 2.4, delay: 1.2 * Double(ring))
                let grow = Easing.ripple(p)
                let outset = reach * (inwards ? 1 - grow : grow)
                let opacity = inwards
                    ? Keyframes.value(at: p, [(0, 0), (0.4, 0.65), (1, 0)], curve: Easing.ripple)
                    : Keyframes.value(at: p, [(0, 0.6), (1, 0)], curve: Easing.ripple)
                // A 2-point line inside the ripple's outline, like a CSS border.
                let outline = capsule.insetBy(dx: 1 - outset, dy: 1 - outset)
                context.stroke(Capsule().path(in: outline), with: .color(color.opacity(opacity).color), lineWidth: 2)
            }
        }
    }
}

/// shadow-capsule's two soft black shadows, only outside the capsule as in CSS: the glass does not show its own
/// shadow through.
private struct CapsuleShadow: View {
    var body: some View {
        let black = RGBA(0x000000)
        ZStack {
            Capsule().fill(black).shadow(color: black.opacity(0.38).color, radius: 30, y: 24)
            Capsule().fill(black).shadow(color: black.opacity(0.22).color, radius: 9, y: 6)
        }
        .mask {
            Rectangle()
                .padding(-110)
                .overlay(Capsule().blendMode(.destinationOut))
                .compositingGroup()
        }
        .allowsHitTesting(false)
    }
}

/// The screen behind the capsule, blurred: an AppKit visual effect shaped like the capsule. It stays active although
/// the panel never becomes the key window.
private struct GlassBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    private static let mask: NSImage = {
        let size = CapsuleView.size
        let radius = size.height / 2
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }()
}

// MARK: - Panel

/// The panel's whole content: the capsule while it is presented, in the middle of the room left for its shadow and
/// ripples.
private struct CapsuleHost: View {
    let model: AssistantModel
    let capsule: CapsuleState

    var body: some View {
        ZStack {
            if capsule.isPresented {
                CapsuleView(model: model, capsule: capsule)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .light)  // the design has no dark theme yet
    }
}

/// Floats above every window, on every Space and over full-screen apps; lets clicks through and never becomes the
/// key window, so the app in front keeps the keyboard. It stays when OpenMaé is hidden (⌘H).
final class CapsulePanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: CGRect(origin: .zero, size: content.frame.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        contentView = content
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false  // the capsule draws its own
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        canHide = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = NSAppearance(named: .aqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Brings the capsule up at the bottom of the screen and takes it away.
@MainActor
final class CapsuleController {
    let capsule = CapsuleState()
    let panel: CapsulePanel
    private var removal: Task<Void, Never>?

    /// Room around the capsule for its shadow and its ripples.
    private static let margin: CGFloat = 100
    /// From the bottom of the screen's usable area (above the Dock) to the capsule.
    private static let bottomGap: CGFloat = 80

    init(model: AssistantModel) {
        let size = CGSize(width: CapsuleView.size.width + 2 * Self.margin,
                          height: CapsuleView.size.height + 2 * Self.margin)
        let host = NSHostingView(rootView: CapsuleHost(model: model, capsule: capsule))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        panel = CapsulePanel(content: host)
    }

    var isShown: Bool { capsule.isShown }

    func show(_ state: PipelineState) {
        removal?.cancel()
        removal = nil
        let changes = !capsule.isShown || capsule.state != state
        capsule.state = state
        if !capsule.isPresented {
            place()
            panel.orderFrontRegardless()
            capsule.isPresented = true
        }
        capsule.isShown = true
        if changes { announce(state) }
    }

    func hide() {
        guard capsule.isShown else { return }
        capsule.isShown = false
        removal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Timing.capsule))
            guard let self, !Task.isCancelled else { return }
            capsule.isPresented = false
            panel.orderOut(nil)
            removal = nil
        }
    }

    /// Bottom centre of the screen the pointer is on, clear of what the user works on in the middle.
    private func place() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: (area.midX - size.width / 2).rounded(),
                                     y: area.minY + Self.bottomGap - Self.margin))
    }

    /// VoiceOver says the new state: the capsule cannot be reached otherwise, since it never takes the focus.
    private func announce(_ state: PipelineState) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: StateText.spokenName(state),
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
