import OpenMaeLink
import SwiftUI
import VoiceCore

/// The home station at rest, read from across the room: a big orb, what Maé is doing in a few big words, and the Mac
/// it is linked to. A tap on the orb talks (and takes the conversation from the Mac); while Maé says something on her
/// own here (a timer that rings), a tap stops her. Once it has the conversation, the station shows the conversation
/// screen, until it gives it back to the Mac.
struct StationScreen: View {
    let model: PhoneModel

    var body: some View {
        let state = model.displayedState
        ZStack {
            PhoneBackground(surface: StatePalette(state).surface, halos: false)
            GeometryReader { proxy in
                let size = proxy.size
                let sideways = size.width > size.height * 1.15
                VStack(spacing: 0) {
                    StationTopBar(model: model).zIndex(1)
                    Group {
                        if sideways {
                            HStack(spacing: 0) {
                                orb(state, size: min(size.width * 0.5 - 48, size.height - 56 - 48, 560))
                                    .frame(width: size.width * 0.5)
                                words(state, alignment: .leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.trailing, 48)
                            }
                        } else {
                            VStack(spacing: 36) {
                                orb(state, size: min(size.width * 0.74, size.height - 56 - 260, 600))
                                words(state, alignment: .center)
                                    .padding(.horizontal, 32)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .halosBehindAnchor()
            }
        }
        // Any touch brings the screen back to full brightness.
        .simultaneousGesture(TapGesture().onEnded { model.touched() })
        .animation(.easeOut(duration: 0.4), value: isReconnecting)
    }

    private func orb(_ state: PipelineState, size: CGFloat) -> some View {
        Orb(look: OrbLook(state), level: state == .speaking ? model.outputLevel : 0)
            .scaleEffect(size / 380)
            .frame(width: size, height: size)
            .haloAnchor()
            .contentShape(Circle().inset(by: size * 54 / 342))
            .onTapGesture { model.tapOrb() }
            .opacity(isReconnecting ? 0.4 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(StateText.accessibilityName(state))
            .accessibilityHint(state == .speaking || state == .thinking ? Text("Tap to stop Maé") : Text("Tap to talk"))
            .accessibilityAddTraits([.isButton, .updatesFrequently])
    }

    private func words(_ state: PipelineState, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 18) {
            stateWord(state)
                .textStyle(.stationWord)
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: Timing.ui), value: state)
                .fixedSize(horizontal: false, vertical: true)
            if let mac = model.mac {
                PhoneChip {
                    IconView(icon: .laptop, size: 22)
                    Text(verbatim: mac.name)
                        .textStyle(.stationMac)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Linked to \(mac.name)"))
            }
        }
    }

    /// The state in a few words. At rest: how to talk, or why it cannot right now.
    private func stateWord(_ state: PipelineState) -> Text {
        if isReconnecting { return Text("Reconnecting…") }
        if case .loading = model.phase { return Text("Maé is getting ready…") }
        switch state {
        case .listening:
            return model.talkMode == .tap ? Text("Tap the orb to talk") : Text("Tap the orb to start")
        case .userSpeaking: return Text("I'm listening…")
        case .thinking: return Text("Maé is thinking…")
        case .speaking: return Text("Maé is speaking")
        }
    }

    private var isReconnecting: Bool {
        model.link == .reconnecting || model.link == .connecting
    }
}

/// The station's top: how it reaches the Mac, and the settings.
private struct StationTopBar: View {
    let model: PhoneModel

    var body: some View {
        HStack {
            LinkChip(status: model.link)
            Spacer()
            Button { model.showsSettings = true } label: { IconView(icon: .settings, size: 21) }
                .buttonStyle(GlassButtonStyle(diameter: 44))
                .accessibilityLabel(Text("Settings"))
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(height: 56)
    }
}
