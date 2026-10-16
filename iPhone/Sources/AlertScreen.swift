import SwiftUI
import UIKit
import VoiceCore

/// When the conversation cannot happen: the Mac does not answer (asleep, off), Maé is not set up on the Mac yet, or
/// the microphone is not allowed.
struct AlertScreen: View {
    enum Case {
        case unreachable
        case setup
        case problem
        case microphone
    }

    let model: PhoneModel
    let kind: Case
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            PhoneBackground(surface: surface, haloY: 262)
            VStack(spacing: 0) {
                PhoneBrandBar {
                    Button { model.showsSettings = true } label: { IconView(icon: .settings, size: 21) }
                        .buttonStyle(GlassButtonStyle(diameter: 44))
                        .accessibilityLabel(Text("Settings"))
                }
                VStack(spacing: 0) {
                    FloatingDisc(icon: icon, color: disc)
                        .padding(.top, 56)
                        .padding(.bottom, 28)
                    title
                        .textStyle(.phoneHeadline)
                        .foregroundStyle(Palette.ink)
                    text
                        .textStyle(.phoneParagraph)
                        .foregroundStyle(Palette.inkMuted)
                        .frame(maxWidth: 320)
                        .padding(.top, 12)
                    if kind == .unreachable {
                        HStack(alignment: .top, spacing: 12) {
                            IconView(icon: .info, size: 20)
                                .foregroundStyle(Palette.ink)
                                .padding(.top, 1)
                            Text("Plugged in, your Mac stays awake. With the lid closed and no external display, it sleeps anyway.")
                                .textStyle(.phoneSmall)
                                .foregroundStyle(Palette.inkMuted)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.white, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.line))
                        .padding(.top, 22)
                    }
                    Spacer(minLength: 12)
                    if kind == .microphone {
                        WideButton(title: "Open Settings", icon: .settings, iconStroke: nil, glow: glow) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    } else {
                        WideButton(title: "Try again", icon: .refresh, iconStroke: 2, glow: glow, action: model.retry)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.bottom, 48)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var title: Text {
        switch kind {
        case .unreachable: Text("Your Mac does not answer.")
        case .setup: Text("Finish the setup on your Mac.")
        case .problem: Text("Maé has a problem on your Mac.")
        case .microphone: Text("Allow the microphone.")
        }
    }

    private var text: Text {
        switch kind {
        case .unreachable: Text("It may be asleep or off. I’ll try again on my own as soon as it is back.")
        case .setup: Text("Maé is not ready there yet. Open OpenMaé on your Mac to finish getting started.")
        case .problem: Text("Have a look at OpenMaé’s window on your Mac: it says what is wrong.")
        case .microphone: Text("To talk to Maé, OpenMaé needs the microphone. You can allow it in the Settings app.")
        }
    }

    private var icon: Icon {
        switch kind {
        case .unreachable: .moon
        case .setup: .download
        case .problem: .info
        case .microphone: .microphone
        }
    }

    /// One colour per case: sun for the sleeping Mac, azure for the setup to finish.
    private var surface: RGBA {
        kind == .setup ? StatePalette(.userSpeaking).surface : StatePalette(.thinking).surface
    }

    private var disc: RGBA {
        kind == .setup ? Palette.turquoiseSoft : Palette.coralSoft
    }

    private var glow: RGBA {
        kind == .setup ? Palette.azure : Palette.sun
    }
}
