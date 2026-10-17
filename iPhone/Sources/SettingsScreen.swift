import OpenMaeLink
import SwiftUI
import VoiceCore

/// The iPhone's (and iPad's) settings: its Mac, how to talk, when a conversation ends on its own, station mode on an
/// iPad, and the relay (chosen on the Mac).
struct SettingsScreen: View {
    @Bindable var model: PhoneModel
    @State private var confirmForget = false

    var body: some View {
        ZStack {
            PhoneBackground(surface: StatePalette(.listening).surface, halos: false)
            VStack(spacing: 0) {
                ZStack {
                    Text("Settings")
                        .textStyle(.phoneTitle)
                        .foregroundStyle(Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    HStack {
                        Button { model.showsSettings = false } label: { IconView(icon: .back, size: 22) }
                            .buttonStyle(GlassButtonStyle(diameter: 44))
                            .accessibilityLabel(Text("Back"))
                        Spacer()
                    }
                    .padding(.leading, 12)
                }
                .frame(height: 56)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let mac = model.mac { macSection(mac) }
                        conversationSection
                        if model.isPad { stationSection }
                        if let mac = model.mac { relaySection(mac) }
                        Text("OpenMaé \(Self.version)")
                            .textStyle(.phoneVersion)
                            .foregroundStyle(Palette.inkMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 12)
                    }
                    // On an iPad, a column of the iPhone's width or a bit more, in the middle.
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding(EdgeInsets(top: 8, leading: 20, bottom: 46, trailing: 20))
                }
            }
        }
        .alert("Forget this Mac?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive, action: model.forgetMac)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To talk to Maé again, you will have to scan a new code shown on your Mac.")
        }
    }

    private func macSection(_ mac: PairedMac) -> some View {
        SettingsSection(title: "My Mac") {
            HStack(spacing: 14) {
                RowDisc(icon: .laptop, color: Palette.turquoiseSoft)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: mac.name)
                        .textStyle(.phoneRowTitle)
                        .foregroundStyle(Palette.ink)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.isConnected ? Palette.turquoise : Palette.inkDisabled)
                            .frame(width: 8, height: 8)
                        reach
                    }
                    .textStyle(.phoneRowDetail)
                    .foregroundStyle(Palette.inkMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 72)
            .accessibilityElement(children: .combine)
            Hairline()
            Button { confirmForget = true } label: {
                Text("Forget this Mac…")
                    .textStyle(.phoneRowTitle)
                    .foregroundStyle(StatePalette(.speaking).deep)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var reach: Text {
        switch model.link {
        case .connected(.direct)?: Text("Reachable, at home")
        case .connected(.relay)?: Text("Reachable, away")
        case .unreachable?: Text("Does not answer right now")
        default: Text("Connecting…")
        }
    }

    private var conversationSection: some View {
        SettingsSection(title: "Conversation") {
            VStack(alignment: .leading, spacing: 10) {
                TalkModePicker(selection: $model.talkMode)
                talkModeHelp
                    .textStyle(.phoneRowDetail)
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            Hairline()
            Menu {
                Picker(selection: $model.autoEndMinutes) {
                    ForEach(PhoneModel.autoEndChoices, id: \.self) { minutes in
                        autoEndText(minutes).tag(minutes)
                    }
                } label: {
                    EmptyView()
                }
            } label: {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Automatic end")
                            .textStyle(.phoneRowTitle)
                            .foregroundStyle(Palette.ink)
                        Text("After a silence, to save the battery")
                            .textStyle(.phoneRowDetail)
                            .foregroundStyle(Palette.inkMuted)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        autoEndText(model.autoEndMinutes)
                        IconView(icon: .chevrons, size: 18)
                    }
                    .textStyle(.phoneValue)
                    .foregroundStyle(Palette.inkMuted)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 64)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func autoEndText(_ minutes: Int) -> Text {
        minutes == 0 ? Text("Never") : Text("\(minutes) min")
    }

    private var talkModeHelp: Text {
        switch model.talkMode {
        case .handsFree:
            model.stationMode ? Text("At the station, Maé hears everything in the room: she also answers the TV.")
                : Text("Maé hears you whenever you speak.")
        case .hold: Text("Keep your finger on the button while you talk.")
        case .tap: Text("Tap the orb to talk, and again when you are done.")
        }
    }

    /// iPad: a home station while plugged in.
    private var stationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Station") {
                Toggle(isOn: $model.stationMode) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Station mode")
                            .textStyle(.phoneRowTitle)
                            .foregroundStyle(Palette.ink)
                        Text("When plugged in, this iPad stays on and linked to your Mac")
                            .textStyle(.phoneRowDetail)
                            .foregroundStyle(Palette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(SwitchStyle())
                .padding(.horizontal, 16)
                .frame(minHeight: 72)
            }
            Text("Maé’s announcements, like a timer that rings, are spoken here while it is connected. A minute after you talk, your Mac hears you again.")
                .textStyle(.phoneSmall)
                .foregroundStyle(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 8, leading: 6, bottom: 0, trailing: 6))
        }
    }

    private func relaySection(_ mac: PairedMac) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Relay") {
                HStack(spacing: 14) {
                    RowDisc(icon: .globe, color: Palette.azureSoft)
                    VStack(alignment: .leading, spacing: 0) {
                        Group {
                            switch mac.relay {
                            case nil: Text("No relay")
                            case RelayClient.official?: Text("OpenMaé relay")
                            default: Text("Your own relay")
                            }
                        }
                        .textStyle(.phoneRowTitle)
                        .foregroundStyle(Palette.ink)
                        Group {
                            if let host = mac.relay?.host() {
                                Text(verbatim: host)
                            } else {
                                Text("Your Mac is reachable at home only")
                            }
                        }
                        .textStyle(.phoneRowDetail)
                        .foregroundStyle(Palette.inkMuted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 64)
                .accessibilityElement(children: .combine)
            }
            Text("Chosen on your Mac. It only sees encrypted packets.")
                .textStyle(.phoneSmall)
                .foregroundStyle(Palette.inkMuted)
                .padding(EdgeInsets(top: 8, leading: 6, bottom: 0, trailing: 6))
        }
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

/// A titled white card of the settings.
private struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .textStyle(.phoneSection)
                .foregroundStyle(Palette.inkMuted)
                .padding(.leading, 6)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content }
                .background(Palette.white, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.line))
        }
    }
}

private struct RowDisc: View {
    let icon: Icon
    let color: RGBA

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 40, height: 40)
            .overlay { IconView(icon: icon, size: 22).foregroundStyle(Palette.ink) }
            .accessibilityHidden(true)
    }
}

/// "Hands-free", "Hold" or "Tap": three big segments, the chosen one ink on cream.
private struct TalkModePicker: View {
    @Binding var selection: PhoneModel.TalkMode

    var body: some View {
        HStack(spacing: 4) {
            segment(.handsFree, Text("Hands-free"))
            segment(.hold, Text("Hold down"))
            segment(.tap, Text("Tap"))
        }
        .padding(4)
        .background(StatePalette(.listening).surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Way of talking"))
    }

    private func segment(_ mode: PhoneModel.TalkMode, _ title: Text) -> some View {
        let isOn = selection == mode
        return Button { selection = mode } label: {
            title
                .textStyle(.phoneSegment)
                .foregroundStyle(isOn ? Palette.onInk : Palette.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(isOn ? Palette.ink : RGBA(rgba: 0), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .animation(.easeOut(duration: Timing.ui), value: selection)
    }
}
