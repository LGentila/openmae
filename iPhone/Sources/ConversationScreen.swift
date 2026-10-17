import AVKit
import OpenMaeLink
import SwiftUI
import VoiceCore

/// The conversation, as on the Mac: the link with the Mac at the top, the orb, the live transcript, and the buttons in
/// the thumb's reach — the microphone, the main button, the sound output (hands-free and tap to talk), or one big
/// button held while talking. It follows the window's size: an iPhone, an iPad in portrait or landscape, Split View.
struct ConversationScreen: View {
    let model: PhoneModel

    var body: some View {
        let state = model.displayedState
        ZStack {
            PhoneBackground(surface: StatePalette(state).surface, halos: false)
            GeometryReader { proxy in
                let layout = ConversationLayout(size: proxy.size, isPad: model.isPad)
                Group {
                    if layout.sideBySide {
                        // An iPad on its side: the orb on the left, the words and the buttons on the right.
                        VStack(spacing: 0) {
                            TopBar(model: model).zIndex(1)
                            HStack(spacing: 0) {
                                orb(state, size: layout.orb)
                                    .frame(width: layout.orbColumn)
                                VStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    transcript(state, layout: layout)
                                    controls(state, layout: layout)
                                        .frame(height: layout.controlsHeight)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .frame(maxHeight: .infinity)
                        }
                    } else {
                        VStack(spacing: 0) {
                            TopBar(model: model).zIndex(1)
                            if layout.isPad { Spacer(minLength: 0) }
                            orb(state, size: layout.orb)
                            transcript(state, layout: layout)
                            controls(state, layout: layout)
                                .frame(maxHeight: layout.isPad ? layout.controlsHeight : .infinity)
                            if layout.isPad { Spacer(minLength: 0) }
                        }
                    }
                }
                .halosBehindAnchor()
            }
        }
        .animation(.easeOut(duration: 0.4), value: isReconnecting)
    }

    private func orb(_ state: PipelineState, size: CGFloat) -> some View {
        Orb(look: OrbLook(state), level: level(state))
            .scaleEffect(size / 380)
            .frame(width: size, height: size)
            .haloAnchor()
            .contentShape(Circle().inset(by: size * 54 / 342))
            .onTapGesture { model.tapOrb() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(StateText.accessibilityName(state))
            .accessibilityAddTraits(model.talkMode == .tap ? [.updatesFrequently, .isButton] : .updatesFrequently)
            .opacity(isReconnecting ? 0.4 : 1)
    }

    private func transcript(_ state: PipelineState, layout: ConversationLayout) -> some View {
        ZStack {
            if isReconnecting {
                VStack(spacing: 10) {
                    Text("Link interrupted")
                        .textStyle(.phoneLost)
                        .foregroundStyle(Palette.ink)
                    Text("I am taking another way. Your conversation is kept.")
                        .textStyle(.prompt)
                        .foregroundStyle(Palette.inkMuted)
                        .frame(maxWidth: 290)
                }
                .multilineTextAlignment(.center)
                .padding(.top, 14)
                .transition(.opacity)
            } else {
                let exchange = model.currentExchange
                LiveTranscript(state: state, user: exchange.user, answer: exchange.answer,
                               invitation: invitation, layout: layout.transcript)
            }
        }
        .frame(height: layout.transcriptHeight)
    }

    private func controls(_ state: PipelineState, layout: ConversationLayout) -> some View {
        Controls(model: model, state: state, holdWidth: layout.holdWidth)
            .opacity(isReconnecting ? 0.4 : 1)
            .disabled(isReconnecting)
    }

    private var isReconnecting: Bool {
        model.link == .reconnecting || model.link == .connecting
    }

    private func level(_ state: PipelineState) -> Float {
        switch state {
        case .userSpeaking: model.inputLevel
        case .speaking: model.outputLevel
        case .listening, .thinking: 0
        }
    }

    private var invitation: LiveTranscript.Invitation {
        if case .loading(let step) = model.phase { return .loading(step) }
        if !model.isConversationOpen {
            switch model.pause {
            case .macTookOver: return .message(Text("Maé is back on your Mac. Tap “Talk” to take her back."))
            case .silence: return .message(Text("The conversation paused after a silence. Tap “Talk” to go on."))
            case nil: return .message(Text(" "))
            }
        }
        switch model.talkMode {
        case .hold: return .message(Text("Keep your finger down while you talk."))
        case .tap: return .message(Text("Tap the orb to talk, and again when you are done."))
        case .handsFree: return .message(Text("Speak whenever you like, I’m listening."))
        }
    }
}

/// The conversation's sizes, from the window's: the iPhone's as designed (an orb of 342 points); on an iPad the orb
/// grows with the window, which matters most from afar, and the transcript widens, for close reading. Wider than tall
/// on an iPad: side by side.
struct ConversationLayout {
    let isPad: Bool
    let sideBySide: Bool
    let orb: CGFloat
    /// The orb's column, side by side.
    let orbColumn: CGFloat
    let transcript: TranscriptLayout
    let transcriptHeight: CGFloat
    let controlsHeight: CGFloat
    let holdWidth: CGFloat

    init(size: CGSize, isPad: Bool) {
        // A narrow window (an iPhone, an iPad in Split View) is laid out as the iPhone.
        self.isPad = isPad && size.width >= 500
        let bar: CGFloat = 56
        if !self.isPad {
            sideBySide = false
            orb = min(342, size.width - 40, max(200, size.height - bar - 176 - 110))
            orbColumn = size.width
            transcript = .phone
            transcriptHeight = 176
            controlsHeight = 110
            holdWidth = 353
        } else if size.width > size.height * 1.15 {
            sideBySide = true
            orbColumn = size.width * 0.5
            orb = min(orbColumn - 64, size.height - bar - 48, 620)
            let words = min(size.width - orbColumn - 64, 480)
            transcript = .pad(width: words)
            transcriptHeight = min(260, size.height * 0.4)
            controlsHeight = 120
            holdWidth = min(words, 440)
        } else {
            sideBySide = false
            transcriptHeight = 230
            controlsHeight = 130
            orb = min(size.width * 0.66, size.height - bar - transcriptHeight - controlsHeight - 40, 620)
            orbColumn = size.width
            let words = min(size.width - 120, 600)
            transcript = .pad(width: words)
            holdWidth = min(words, 440)
        }
    }
}

private struct TopBar: View {
    let model: PhoneModel

    var body: some View {
        HStack {
            LinkChip(status: model.link)
            Spacer()
            HStack(spacing: 8) {
                Button(action: model.newConversation) { IconView(icon: .compose, size: 21) }
                    .buttonStyle(GlassButtonStyle(diameter: 44))
                    .accessibilityLabel(Text("New conversation"))
                Button { model.showsSettings = true } label: { IconView(icon: .settings, size: 21) }
                    .buttonStyle(GlassButtonStyle(diameter: 44))
                    .accessibilityLabel(Text("Settings"))
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(height: 56)
    }
}

/// "At home", "Away", "Reconnecting…": how the iPhone reaches its Mac.
struct LinkChip: View {
    let status: PhoneLink.Status?

    var body: some View {
        let reconnecting = status != .connected(.direct) && status != .connected(.relay)
        PhoneChip(background: reconnecting ? Palette.sunSoft : Palette.white, outlined: !reconnecting) {
            switch status {
            case .connected(.direct)?:
                IconView(icon: .home, size: 20)
                Text("At home")
            case .connected(.relay)?:
                IconView(icon: .globe, size: 20)
                Text("Away")
            default:
                TurningIcon(icon: .refresh)
                Text("Reconnecting…")
            }
        }
        .animation(.easeOut(duration: 0.4), value: status)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
    }

    private var accessibility: Text {
        switch status {
        case .connected(.direct)?: Text("Link with your Mac: at home")
        case .connected(.relay)?: Text("Link with your Mac: away, through the relay")
        default: Text("Link with your Mac: reconnecting")
        }
    }
}

/// The buttons at the bottom. Hands-free: microphone, main button, sound output. Hold to talk: one big button.
private struct Controls: View {
    let model: PhoneModel
    let state: PipelineState
    var holdWidth: CGFloat = 353

    var body: some View {
        let glow = StatePalette(state).glow
        Group {
            if model.talkMode == .hold {
                HoldButton(model: model, state: state, glow: glow, width: holdWidth)
            } else {
                HStack(spacing: 14) {
                    Button { model.microphoneMuted.toggle() } label: { IconView(icon: .microphone, size: 23) }
                        .buttonStyle(GlassButtonStyle(diameter: 52, isOn: model.microphoneMuted))
                        .accessibilityLabel(model.microphoneMuted ? Text("Turn the microphone back on")
                            : Text("Mute the microphone"))
                        .overlay(alignment: .topTrailing) {
                            if model.microphoneMuted {
                                Circle().fill(Palette.coral).frame(width: 10, height: 10).offset(x: -4, y: 4)
                                    .accessibilityHidden(true)
                            }
                        }
                    mainButton(glow: glow)
                    OutputPicker()
                        .frame(width: 52, height: 52)
                        .accessibilityLabel(Text("Sound output"))
                }
            }
        }
        .padding(.bottom, 12)
        .animation(.easeOut(duration: 0.25), value: model.talkMode)
    }

    private func mainButton(glow: RGBA) -> some View {
        let (title, icon, stroke): (LocalizedStringKey, Icon, CGFloat?) = switch state {
        case .listening: ("Talk", .microphone, 2)
        case .userSpeaking: model.talkKeyDown ? ("Finish", .stop, nil) : ("Talk", .microphone, 2)
        case .thinking: ("Cancel", .cancel, nil)
        case .speaking: ("Interrupt", .pause, nil)
        }
        return Button(action: model.mainButton) { Text(title) }
            .buttonStyle(PrimaryButtonStyle(icon: icon, iconStroke: stroke, disc: glow, metrics: .phone))
            // While the Mac hears a sentence on its own, pressing would start a new one and lose it.
            .disabled(!model.isConnected || model.phase != .ready || (state == .userSpeaking && !model.talkKeyDown))
            .sensoryFeedback(.impact(weight: .light), trigger: model.talkKeyDown)
    }
}

/// Hold to talk: the whole width, held down while speaking.
private struct HoldButton: View {
    let model: PhoneModel
    let state: PipelineState
    let glow: RGBA
    var width: CGFloat = 353
    @State private var isPressed = false

    var body: some View {
        let talking = model.talkKeyDown
        let (title, icon, stroke): (LocalizedStringKey, Icon, CGFloat?) = switch state {
        case .thinking: ("Cancel", .cancel, nil)
        case .speaking: ("Interrupt", .pause, nil)
        case .listening, .userSpeaking: talking ? ("Release to send", .microphone, 2) : ("Hold to talk", .microphone, 2)
        }
        PrimaryPill(icon: icon, iconStroke: stroke, disc: glow,
                    metrics: PillMetrics(height: 72, disc: 52, leading: 10, trailing: 30, spacing: 14),
                    isPressed: isPressed || talking) {
            Text(title)
        }
        .frame(maxWidth: width)
        .scaleEffect(talking ? 0.98 : 1)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed else { return }
                isPressed = true
                model.hold(true)
            }
            .onEnded { _ in
                isPressed = false
                model.hold(false)
            })
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Hold while you talk"))
    }
}

/// The system's choice of sound output (speaker, AirPods, a car…), drawn as the design's round button.
private struct OutputPicker: View {
    var body: some View {
        ZStack {
            Circle().fill(Palette.glassButton)
            Circle().strokeBorder(Palette.line)
            IconView(icon: .speaker, size: 23).foregroundStyle(Palette.ink)
            RoutePicker()
                .opacity(0.02)  // the system's button, invisible, takes the taps
        }
    }

    private struct RoutePicker: UIViewRepresentable {
        func makeUIView(context: Context) -> AVRoutePickerView {
            let view = AVRoutePickerView()
            view.prioritizesVideoDevices = false
            return view
        }

        func updateUIView(_ view: AVRoutePickerView, context: Context) {}
    }
}
