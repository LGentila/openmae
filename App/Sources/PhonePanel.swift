import CoreImage
import CoreImage.CIFilterBuiltins
import OpenMaeLink
import SwiftUI
import VoiceCore

/// Settings › iPhone and iPad: no device yet, the pairing QR code (and its expiry), "iPhone added" (or "iPad added"),
/// the paired devices with how reachable this Mac is (and which iPad is a home station now), and below them the relay
/// and the sleep settings.
struct PhonePanel: View {
    let phone: PhoneAccess
    /// Back to the settings.
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch phone.status.pairing {
            case .waiting(let link, let expires):
                PairingCodeView(phone: phone, link: link, expires: expires)
            case .expired:
                PairingCodeView(phone: phone, link: nil, expires: nil)
            case .added(let device):
                added(device)
            case .idle:
                if phone.status.devices.isEmpty { empty } else { devices }
                settings
            }
        }
    }

    // MARK: - No iPhone yet

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeader(title: "iPhone and iPad", badge: badge, back: back)
            VStack(spacing: 10) {
                Circle()
                    .fill(Palette.turquoiseSoft)
                    .frame(width: 60, height: 60)
                    .overlay { IconView(icon: .phone, size: 28).foregroundStyle(Palette.ink) }
                Text("Talk to Maé from your iPhone or iPad")
                    .textStyle(.panelHeading)
                    .foregroundStyle(Palette.ink)
                Text("Your iPhone or iPad is the microphone and the speaker. The work stays on this Mac, with its models. Everything is end-to-end encrypted.")
                    .textStyle(.panelText)
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: phone.startPairing) { Label { Text("Add a device") } icon: { IconView(icon: .plus, size: 18) } }
                    .buttonStyle(LinkPillStyle())
                    .padding(.top, 4)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(EdgeInsets(top: 20, leading: 22, bottom: 18, trailing: 22))
            .background(Palette.cardStrong, in: RoundedRectangle(cornerRadius: Radius.section, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.section, style: .continuous).strokeBorder(Palette.line))
        }
    }

    // MARK: - Paired iPhones

    private var devices: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeader(title: "iPhone and iPad", badge: badge, back: back)
            if let banner { banner }
            SectionTitle("Devices", isFirst: true)
            PanelBlock(padding: EdgeInsets(top: 2, leading: 16, bottom: 12, trailing: 16)) {
                ForEach(phone.status.devices) { device in
                    if phone.removing == device.id {
                        removal(device)
                    } else {
                        deviceRow(device)
                    }
                    Hairline()
                }
                Button(action: phone.startPairing) { Label { Text("Add a device") } icon: { IconView(icon: .plus, size: 18) } }
                    .buttonStyle(LinkPillStyle())
                    .padding(.top, 9)
            }
        }
        .animation(.easeOut(duration: Timing.ui), value: phone.removing)
    }

    private func deviceRow(_ device: PairedDevice) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Palette.turquoiseSoft)
                .frame(width: 44, height: 44)
                .overlay { IconView(icon: device.kind.icon, size: 22).foregroundStyle(Palette.ink) }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(verbatim: device.displayName)
                        .textStyle(.rowTitle)
                        .foregroundStyle(Palette.ink)
                    if phone.status.stations.contains(device.id) {
                        PanelBadge(text: Text("Station"), tone: .ok)
                            .accessibilityLabel(Text("Home station, connected"))
                    }
                }
                let added = device.added.formatted(date: .abbreviated, time: .omitted)
                Group {
                    switch device.kind {
                    case .iPhone: Text("iPhone · added on \(added)")
                    case .iPad: Text("iPad · added on \(added)")
                    }
                }
                .textStyle(.rowDetail)
                .foregroundStyle(Palette.inkMuted)
            }
            Spacer(minLength: 0)
            Button("Remove…") { phone.removing = device.id }
                .buttonStyle(PillButtonStyle(kind: .destructive))
        }
        .frame(minHeight: 68)
    }

    private func removal(_ device: PairedDevice) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove \(device.displayName)?")
                .textStyle(.confirmTitle)
                .foregroundStyle(Palette.ink)
            Text("It will no longer be able to talk to Maé, and its conversation in progress closes. To add it again, you will have to scan a new code.")
                .textStyle(.panelSmall)
                .foregroundStyle(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Remove") {
                    phone.removing = nil
                    phone.remove(device)
                }
                .buttonStyle(SolidDangerPillStyle())
                Button("Cancel") { phone.removing = nil }
                    .buttonStyle(PillButtonStyle())
            }
        }
        .padding(14)
        .background(Palette.dangerSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, -8)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
    }

    /// Why the iPhone reaches this Mac at home only, when it does.
    private var banner: Banner? {
        switch phone.reach {
        case .homeOnly:
            Banner(text: Text("Without a relay, your devices reach you at home only, on the same Wi-Fi as this Mac."),
                   warning: false)
        case .relayUnreachable:
            Banner(text: Text("The relay does not answer. Your devices can reach you at home only. I keep trying."),
                   warning: true)
        default:
            nil
        }
    }

    private var badge: PanelBadge {
        let text = Self.reachText(phone.reach)
        switch phone.reach {
        case .noPhone: return PanelBadge(text: text, tone: .idle)
        case .everywhere: return PanelBadge(text: text, tone: .ok)
        case .homeOnly: return PanelBadge(text: text, tone: .info)
        case .relayUnreachable: return PanelBadge(text: text, tone: .warn)
        case .connecting: return PanelBadge(text: text, tone: .wait)
        }
    }

    static func reachText(_ reach: PhoneAccess.Reach) -> Text {
        switch reach {
        case .noPhone: Text("No device")
        case .everywhere: Text("Reachable from anywhere")
        case .homeOnly: Text("Reachable at home only")
        case .relayUnreachable: Text("Relay unreachable")
        case .connecting: Text("Connecting to the relay…")
        }
    }

    // MARK: - iPhone or iPad added

    private func added(_ device: PairedDevice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeader(title: "Add a device", badge: nil, back: phone.cancelPairing)
            VStack(spacing: 12) {
                DoneCheck()
                Group {
                    switch device.kind {
                    case .iPhone: Text("iPhone added")
                    case .iPad: Text("iPad added")
                    }
                }
                .textStyle(.addedTitle)
                .foregroundStyle(Palette.ink)
                .padding(.top, 4)
                HStack(spacing: 8) {
                    IconView(icon: device.kind.icon, size: 16)
                    Text(verbatim: device.displayName)
                        .textStyle(.panelChip)
                }
                .foregroundStyle(Palette.ink)
                .padding(.leading, 11)
                .padding(.trailing, 13)
                .frame(height: 30)
                .background(Palette.field, in: Capsule())
                Group {
                    switch (device.kind, phone.status.relayChoice.url == nil) {
                    case (.iPhone, true):
                        Text("You can now talk to Maé from your iPhone, at home. Keep this Mac on and plugged in so that it stays reachable.")
                    case (.iPhone, false):
                        Text("You can now talk to Maé from your iPhone, at home and away. Keep this Mac on and plugged in so that it stays reachable.")
                    case (.iPad, true):
                        Text("You can now talk to Maé from your iPad, at home. Keep this Mac on and plugged in so that it stays reachable.")
                    case (.iPad, false):
                        Text("You can now talk to Maé from your iPad, at home and away. Keep this Mac on and plugged in so that it stays reachable.")
                    }
                }
                .textStyle(.panelText)
                .foregroundStyle(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                Button("Done", action: phone.cancelPairing)
                    .buttonStyle(LinkPillStyle())
                    .padding(.top, 4)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(EdgeInsets(top: 26, leading: 24, bottom: 22, trailing: 24))
            .background(Palette.cardStrong, in: RoundedRectangle(cornerRadius: Radius.section, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.section, style: .continuous).strokeBorder(Palette.line))
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Relay and sleep

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Relay")
            PanelBlock(padding: EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16)) {
                RelayChooser(phone: phone)
            }
            SectionTitle("Sleep")
            PanelBlock(padding: EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16)) {
                Toggle(isOn: Binding(get: { phone.status.keepAwake }, set: { phone.setKeepAwake($0) })) {
                    Text("Keep this Mac awake when plugged in")
                        .textStyle(.setting)
                }
                .toggleStyle(SwitchStyle())
                .frame(minHeight: 48)
                HelpText("Your iPhone or iPad cannot wake a sleeping Mac. With the lid closed and no external display, the Mac sleeps anyway.")
            }
        }
    }
}

/// "Go through": the OpenMaé relay, none, or one's own.
private struct RelayChooser: View {
    let phone: PhoneAccess
    @State private var custom = ""
    @State private var editingCustom = false

    var body: some View {
        HStack(spacing: 12) {
            Text("Go through")
                .textStyle(.setting)
            Spacer(minLength: 0)
            Menu {
                Button { choose(.official) } label: { Text("OpenMaé relay") }
                Button { editingCustom = true } label: { Text("Another relay…") }
                Divider()
                Button { choose(.none) } label: { Text("None") }
            } label: {
                MenuFieldLabel(title: title)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .frame(minHeight: 48)
        if editingCustom {
            HStack(spacing: 8) {
                TextField(text: $custom, prompt: Text(verbatim: "https://relay.example.org")) { Text("Address of the relay") }
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveCustom)
                Button("OK", action: saveCustom)
                    .buttonStyle(PillButtonStyle())
                    .disabled(customURL == nil)
            }
            .padding(.bottom, 8)
        }
        HelpText(help)
            .padding(.top, 2)
            .padding(.bottom, 6)
    }

    private var title: Text {
        switch phone.status.relayChoice {
        case .official: Text("OpenMaé relay")
        case .custom(let url): Text(verbatim: url.host() ?? url.absoluteString)
        case .none: Text("None")
        }
    }

    private var help: Text {
        let host = Text(verbatim: phone.status.relayChoice.url?.host() ?? "")
        switch (phone.status.relayChoice, phone.reach) {
        case (.none, _):
            return Text("Choose “OpenMaé relay” to talk to Maé from anywhere.")
        case (_, .relayUnreachable):
            return Text("\(host) does not answer for now. Next try in a few seconds.")
        case (.official, _):
            return Text("\(host). It only sees encrypted packets: neither your voice nor your texts.")
        case (.custom, _):
            return Text("\(host), your own relay. It only sees encrypted packets. It sends no notifications.")
        }
    }

    private var customURL: URL? {
        var text = custom.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), ["https", "http"].contains(url.scheme ?? ""), url.host() != nil else {
            return nil
        }
        return url
    }

    private func saveCustom() {
        guard let url = customURL else { return }
        choose(.custom(url))
    }

    private func choose(_ choice: RelayChoice) {
        editingCustom = false
        phone.setRelay(choice)
    }
}

// MARK: - The QR code

private struct PairingCodeView: View {
    let phone: PhoneAccess
    /// nil once the code expired.
    let link: PairingLink?
    let expires: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeader(title: "Add a device",
                        badge: link == nil ? PanelBadge(text: Text("Code expired"), tone: .warn)
                            : PanelBadge(text: Text("Waiting for your device…"), tone: .wait,
                                         short: Text("Waiting…")),
                        back: phone.cancelPairing)
            VStack(spacing: 14) {
                code
                if let expires {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Countdown(remaining: max(0, expires.timeIntervalSince(context.date)))
                    }
                } else {
                    VStack(spacing: 6) {
                        Text("This code expired")
                            .textStyle(.expiredTitle)
                            .foregroundStyle(Palette.ink)
                        Text("A code is valid for 5 minutes and serves only once.")
                            .textStyle(.panelText)
                            .foregroundStyle(Palette.inkMuted)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                }
                if link != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: "1")
                            .textStyle(.badge)
                            .foregroundStyle(Palette.onInk)
                            .frame(width: 22, height: 22)
                            .background(Palette.ink, in: Circle())
                        Text("Open OpenMaé on your iPhone or iPad and scan this code.")
                            .textStyle(.label)
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(EdgeInsets(top: 18, leading: 16, bottom: 16, trailing: 16))
            .background(Palette.cardStrong, in: RoundedRectangle(cornerRadius: Radius.section, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.section, style: .continuous).strokeBorder(Palette.line))
            HStack(spacing: 12) {
                Text("The code stays between this Mac and your device: the relay cannot read it.")
                    .textStyle(.rowDetail)
                    .foregroundStyle(Palette.inkMuted)
                    .frame(maxWidth: 220, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Cancel", action: phone.cancelPairing)
                    .buttonStyle(PillButtonStyle())
                if link == nil {
                    Button(action: phone.startPairing) {
                        Label { Text("Show a new code") } icon: { IconView(icon: .refresh, size: 18) }
                    }
                    .buttonStyle(LinkPillStyle())
                }
            }
            .padding(EdgeInsets(top: 4, leading: 6, bottom: 0, trailing: 0))
        }
    }

    private var code: some View {
        ZStack {
            if let link, let image = QRCode.image(link.url.absoluteString) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .accessibilityLabel(Text("Pairing QR code"))
                Circle()
                    .fill(Palette.white)
                    .frame(width: 52, height: 52)
                    .overlay { Mark(size: 34) }
            } else {
                // Expired: a faded code under a clock.
                RoundedRectangle(cornerRadius: 4).fill(Palette.ink.opacity(0.12)).frame(width: 200, height: 200)
                Rectangle().fill(Palette.white.opacity(0.55))
                Circle()
                    .fill(Palette.sunSoft)
                    .frame(width: 52, height: 52)
                    .overlay { IconView(icon: .history, size: 26).foregroundStyle(Palette.ink) }
            }
        }
        .frame(width: 232, height: 232)
        .background(Palette.white, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .cardShadow()
        .frame(maxWidth: .infinity)
    }
}

/// "Valid for another 4 min 32 s", with its bar.
private struct Countdown: View {
    let remaining: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Valid for another")
                    .textStyle(.rowDetail)
                    .foregroundStyle(Palette.inkMuted)
                Spacer()
                let seconds = Int(remaining.rounded(.up))
                Text("\(seconds / 60) min \(seconds % 60) s")
                    .textStyle(.strongValue)
                    .foregroundStyle(Palette.ink)
            }
            GeometryReader { proxy in
                Capsule().fill(Palette.trackSoft)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Palette.azure)
                            .frame(width: proxy.size.width * remaining / PairingCode.lifetime)
                    }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
        }
        .frame(width: 232)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

enum QRCode {
    /// The code as a crisp image, one pixel per module (scaled up without smoothing).
    static func image(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "Q"  // the logo in the middle hides a few modules
        guard let output = filter.outputImage else { return nil }
        // Ink on white, without the quiet zone the card already gives.
        let colored = output.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": CIColor(cgColor: Palette.ink.cgColor), "inputColor1": CIColor(cgColor: Palette.white.cgColor),
        ])
        return CIContext().createCGImage(colored, from: colored.extent)
    }
}

/// The three-disc mark alone.
struct Mark: View {
    var size: CGFloat = 28

    var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / 28
            for (x, y, r, color) in [(8.5, 11.5, 7.5, Palette.coral), (17, 8.5, 6.5, Palette.sun),
                                     (19, 14.5, 6, Palette.turquoise)]
            {
                context.fill(Path(ellipseIn: CGRect(x: (x - r) * scale, y: (y - r) * scale, width: 2 * r * scale,
                                                    height: 2 * r * scale)), with: .color(color.color))
            }
        }
        .frame(width: size, height: size * 22 / 28)
        .accessibilityHidden(true)
    }
}

/// The big check that draws itself once an iPhone is added.
private struct DoneCheck: View {
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.stillFrame) private var stillFrame

    var body: some View {
        Circle()
            .fill(Palette.mint)
            .frame(width: 96, height: 96)
            .overlay {
                IconView(icon: .check, size: 46, strokeWidth: 2.6, trim: drawn ? 1 : 0)
                    .foregroundStyle(Palette.ink)
            }
            .scaleEffect(drawn ? 1 : 0.6)
            .padding(.top, 8)
            .onAppear {
                guard !reduceMotion, stillFrame == nil else {
                    drawn = true
                    return
                }
                withAnimation(Easing.animation(CubicBezier(0.2, 1.4, 0.4, 1), 0.7)) { drawn = true }
            }
    }
}

// MARK: - Pieces of the panel

/// The "iPhone and iPad" row of the settings, with how reachable this Mac is; opens Settings › iPhone and iPad.
struct PhoneRow: View {
    let phone: PhoneAccess
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Text("iPhone and iPad")
                    .textStyle(.setting)
                    .underline(isHovered, color: Palette.ink.opacity(0.25).color)
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                PhonePanel.reachText(phone.reach)
                    .textStyle(.navValue)
                    .foregroundStyle(Palette.inkMuted)
                IconView(icon: .forward, size: 16)
                    .foregroundStyle(Palette.inkMuted)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The panel's head: back, title, and the status badge on the right.
struct PanelHeader: View {
    let title: LocalizedStringKey
    let badge: PanelBadge?
    let back: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: back) { IconView(icon: .back, size: 18) }
                .buttonStyle(GlassButtonStyle(diameter: 36))
                .accessibilityLabel(Text("Back"))
            Text(title)
                .textStyle(.panelTitle)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let badge { badge }
        }
        .padding(EdgeInsets(top: 0, leading: 2, bottom: 4, trailing: 2))
    }
}

/// A status pill: a dot of the tone's colour, then a few words.
struct PanelBadge: View {
    enum Tone { case idle, ok, info, wait, warn }

    let text: Text
    let tone: Tone
    /// What it says where there is little room.
    var short: Text?
    @State private var dimmed = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dot)
                .frame(width: 8, height: 8)
                .opacity(tone == .wait && dimmed ? 0.35 : 1)
            // A long status gives way to its short form rather than pushing the panel's title onto two lines. Only
            // the words are alternatives: while it blinks, the badge carries an identity of its own
            // (repeatsWhileVisible), and two alternatives of a ViewThatFits sharing one stop the app.
            if let short {
                ViewThatFits(in: .horizontal) {
                    words(text)
                    words(short)
                }
            } else {
                words(text)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 13)
        .frame(height: 30)
        .background(tone == .warn ? Palette.sunSoft : Palette.white, in: Capsule())
        .overlay { if tone != .warn { Capsule().strokeBorder(Palette.line) } }
        .repeatsWhileVisible($dimmed, .easeInOut(duration: 0.7), enabled: tone == .wait)
        .accessibilityElement(children: .combine)
    }

    private func words(_ text: Text) -> some View {
        text
            .textStyle(.panelBadge)
            .foregroundStyle(Palette.ink)
            .lineLimit(1)
    }

    private var dot: RGBA {
        switch tone {
        case .idle: Palette.inkDisabled
        case .ok: Palette.turquoise
        case .info, .wait: Palette.azure
        case .warn: Palette.ink
        }
    }
}

/// A line of explanation over the devices: blue to inform, sun to warn.
struct Banner: View {
    let text: Text
    let warning: Bool
    @State private var turning = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconView(icon: warning ? .refresh : .info, size: 18)
                .rotationEffect(.degrees(warning && turning ? 360 : 0))
                .repeatsWhileVisible($turning, .linear(duration: 1.3), enabled: warning)
            text
                .textStyle(.panelSmall)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(warning ? StatePalette(.thinking).deepOnGlass : StatePalette(.userSpeaking).deepOnGlass)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(warning ? Palette.sunSoft.opacity(0.4) : Palette.linkSoft,
                    in: RoundedRectangle(cornerRadius: Radius.section, style: .continuous))
    }
}

/// A 40-point link pill with an icon, as the panel's main actions ("Add an iPhone", "Done").
struct LinkPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LinkPill(isPressed: configuration.isPressed) { configuration.label }
    }

    private struct LinkPill<Content: View>: View {
        let isPressed: Bool
        @ViewBuilder let content: Content
        @State private var isHovered = false

        var body: some View {
            content
                .labelStyle(PillLabelStyle())
                .textStyle(.smallButton)
                .foregroundStyle(Palette.link)
                .padding(.leading, 14)
                .padding(.trailing, 18)
                .frame(height: 40)
                .background(Palette.azure.opacity(isHovered ? 0.22 : 0.14), in: Capsule())
                .contentShape(Capsule())
                .scaleEffect(isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: Timing.press), value: isPressed)
                .animation(.easeOut(duration: Timing.ui), value: isHovered)
                .onHover { isHovered = $0 }
        }
    }
}

/// "Remove": the only solid red button, for the confirmation.
struct SolidDangerPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textStyle(.smallButton)
            .foregroundStyle(Palette.onInk)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(Palette.danger, in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: Timing.press), value: configuration.isPressed)
    }
}

private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
            configuration.title
        }
    }
}

extension DeviceKind {
    var icon: Icon {
        switch self {
        case .iPhone: .phone
        case .iPad: .tablet
        }
    }
}

extension TextStyle {
    // The iPhone and iPad settings of the Mac.
    static let panelTitle = TextStyle(.display, 20, weight: 600, lineHeight: 26, letterSpacing: -0.01)
    static let panelHeading = TextStyle(.display, 20, weight: 600, lineHeight: 24, letterSpacing: -0.01)
    static let addedTitle = TextStyle(.display, 24, weight: 600, lineHeight: 29, letterSpacing: -0.01)
    static let expiredTitle = TextStyle(.display, 18, weight: 600, lineHeight: 22, letterSpacing: -0.01)
    static let panelText = TextStyle(.sans, 13.5, weight: 400, lineHeight: 13.5 * 1.5)
    static let panelSmall = TextStyle(.sans, 13, weight: 400, lineHeight: 13 * 1.45)
    static let panelBadge = TextStyle(.sans, 13, weight: 600, lineHeight: 16)
    static let panelChip = TextStyle(.sans, 13, weight: 600, lineHeight: 16)
    static let confirmTitle = TextStyle(.sans, 15, weight: 700, lineHeight: 20)
    static let navValue = TextStyle(.sans, 14, weight: 500, lineHeight: 20)
}
