import CoreImage
import CoreImage.CIFilterBuiltins
import OpenMaeLink
import SwiftUI
import VoiceCore

/// Settings › iPhone and iPad: the paired devices (or an empty page that offers the first one), how reachable this Mac
/// is, the internet relay in one line (set in Settings › Relay) and the sleep setting. Adding a device (its QR code,
/// its expiry, "iPhone added") and removing one go through sheets.
struct DevicesPage: View {
    let phone: PhoneAccess
    @Environment(RelayAccess.self) private var relays: RelayAccess?

    var body: some View {
        SettingsPageScroll {
            PageHead(Text("iPhone and iPad")) {
                StatusPill(text: Self.reachText(phone.reach), style: .dot(Self.tone(phone.reach)))
            }
            PageIntro("Your iPhone or iPad lends its microphone, its speaker and its screen. Maé always works on your Mac.")
            if phone.status.devices.isEmpty {
                EmptyPageHero(disc: FamilyDisc(icon: .phone, color: Palette.turquoiseSoft, size: 64),
                              title: Text("Talk to Maé from your iPhone or iPad"),
                              text: Text("Scan a code with the OpenMaé app: the conversation goes through your device, your Mac does the work."))
                {
                    EmptyView()
                } action: {
                    Button(action: phone.startPairing) { IconLabel("Add a device", icon: .plus) }
                        .buttonStyle(WindowButtonStyle(kind: .main))
                }
                .padding(.top, 22)
            } else {
                PageSection("Devices")
                SettingsCard { devices }
            }
            if let relays {
                PageSection("Relay")
                SettingsCard {
                    RelayLine(title: Text("Internet relay"),
                              state: relays.isInternetRelayOn ? RelayWords.internet(relays.internetState) : nil,
                              offText: Text("Off: your iPhone and iPad reach this Mac at home only."))
                }
            }
            PageSection("Sleep")
            SettingsCard {
                SwitchRow("Keep this Mac awake when plugged in",
                          isOn: Binding(get: { phone.status.keepAwake }, set: { phone.setKeepAwake($0) }))
                Caption("Your iPhone or iPad cannot wake a sleeping Mac. With the lid closed and no external display, the Mac sleeps anyway.")
            }
        }
    }

    @ViewBuilder private var devices: some View {
        ForEach(phone.status.devices) { device in
            ListItem(disc: FamilyDisc(icon: device.kind.icon, color: Palette.azureSoft), name: {
                HStack(spacing: 8) {
                    Text(verbatim: device.displayName)
                    if phone.status.stations.contains(device.id) {
                        StatusPill(text: Text("Station"), style: .dot(.on))
                            .accessibilityLabel(Text("Home station, connected"))
                    }
                }
            }, sub: Self.added(device), trailing: {
                Button("Remove…") { phone.removing = device.id }
                    .buttonStyle(WindowButtonStyle(kind: .danger))
            })
            Hairline()
        }
        ActionRow(top: 12, bottom: 12) {
            Button(action: phone.startPairing) { IconLabel("Add a device", icon: .plus) }
                .buttonStyle(WindowButtonStyle(kind: .link, big: true))
        }
    }

    private static func added(_ device: PairedDevice) -> Text {
        let added = device.added.formatted(date: .abbreviated, time: .omitted)
        switch device.kind {
        case .iPhone: return Text("iPhone · added on \(added)")
        case .iPad: return Text("iPad · added on \(added)")
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

    static func tone(_ reach: PhoneAccess.Reach) -> StatusTone {
        switch reach {
        case .noPhone: .off
        case .everywhere: .on
        case .homeOnly, .connecting: .info
        case .relayUnreachable: .warn
        }
    }

    static func badge(_ phone: PhoneAccess) -> SidebarBadge {
        .dot(tone(phone.reach), reachText(phone.reach))
    }
}

// MARK: - Sheets

/// "Add a device": the QR code and its countdown, the code expired, then "iPhone added" (or "iPad added").
struct PairingSheet: View {
    let phone: PhoneAccess

    var body: some View {
        switch phone.status.pairing {
        case .waiting(let link, let expires):
            SheetCard(title: Text("Add a device"),
                      text: Text("The code works only once and stays between this Mac and your device: the relay cannot read it."))
            {
                VStack(spacing: 0) {
                    PairingQRCode(link: link)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Countdown(remaining: max(0, expires.timeIntervalSince(context.date)))
                    }
                    .padding(.top, 14)
                    NumberedSteps(steps: [Text("Open OpenMaé on your iPhone or iPad."),
                                          Text("Aim its camera at this code.")])
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 20)
                }
                .padding(.top, 18)
            } footer: {
                Button("Cancel", action: phone.cancelPairing)
                    .buttonStyle(WindowButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        case .expired:
            SheetCard(title: Text("Add a device"), text: Text("A code is valid for 5 minutes and serves only once.")) {
                VStack(spacing: 14) {
                    PairingQRCode(link: nil)
                    Text("This code expired")
                        .textStyle(.heroTitle)
                        .foregroundStyle(Palette.ink)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
            } footer: {
                Button("Cancel", action: phone.cancelPairing)
                    .buttonStyle(WindowButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(action: phone.startPairing) { IconLabel("Show a new code", icon: .refresh) }
                    .buttonStyle(WindowButtonStyle(kind: .main))
                    .keyboardShortcut(.defaultAction)
            }
        case .added(let device):
            SheetCard(title: device.kind == .iPhone ? Text("iPhone added") : Text("iPad added")) {
                VStack(spacing: 14) {
                    DoneCheck()
                    StatusPill(text: Text(verbatim: device.displayName), style: .dot(.on))
                    addedText(device)
                        .textStyle(.sheetText)
                        .foregroundStyle(Palette.inkMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
            } footer: {
                Button("Done", action: phone.cancelPairing)
                    .buttonStyle(WindowButtonStyle(kind: .main))
                    .keyboardShortcut(.defaultAction)
            }
        case .idle:
            EmptyView()
        }
    }

    private func addedText(_ device: PairedDevice) -> Text {
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
}

/// "Remove iPhone 16?".
struct RemoveDeviceSheet: View {
    let phone: PhoneAccess
    let device: PairedDevice.ID

    var body: some View {
        if let paired = phone.status.devices.first(where: { $0.id == device }) {
            SheetCard(width: 460, title: Text("Remove \(paired.displayName)?"),
                      text: Text("It will no longer be able to talk to Maé, and its conversation in progress closes. To add it again, you will have to scan a new code."))
            {
                EmptyView()
            } footer: {
                Button("Cancel") { phone.removing = nil }
                    .buttonStyle(WindowButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Remove") {
                    phone.removing = nil
                    phone.remove(paired)
                }
                .buttonStyle(WindowButtonStyle(kind: .solidDanger))
            }
        }
    }
}

// MARK: - The QR code

/// The code on its white card, the mark in its middle; faded under a clock once expired.
private struct PairingQRCode: View {
    /// nil once the code expired.
    let link: PairingLink?

    var body: some View {
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
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .strokeBorder(Palette.ink.opacity(0.08), lineWidth: 1))
        .outerShadow(RoundedRectangle(cornerRadius: Radius.card, style: .continuous),
                     ShadowLayer(opacity: 0.1, radius: 12, y: 10))
    }
}

/// "Valid for another 4 min 32 s", with its bar.
private struct Countdown: View {
    let remaining: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Valid for another")
                    .textStyle(.rowSub)
                    .foregroundStyle(Palette.inkMuted)
                Spacer()
                let seconds = Int(remaining.rounded(.up))
                Text("\(seconds / 60) min \(seconds % 60) s")
                    .textStyle(.value)
                    .foregroundStyle(Palette.ink)
            }
            ProgressTrack(fraction: remaining / PairingCode.lifetime)
        }
        .frame(width: 232)
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

/// The big check that draws itself once a device is added.
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
            .onAppear {
                guard !reduceMotion, stillFrame == nil else {
                    drawn = true
                    return
                }
                withAnimation(Easing.animation(CubicBezier(0.2, 1.4, 0.4, 1), 0.7)) { drawn = true }
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
