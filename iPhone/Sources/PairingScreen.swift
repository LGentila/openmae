import OpenMaeLink
import SwiftUI
import UIKit
import VoiceCore

/// Pairing, once: scan the code shown on the Mac, then "Done: you can talk to Maé from your iPhone" — or "this code
/// is no longer valid".
struct PairingScreen: View {
    let model: PhoneModel

    var body: some View {
        ZStack {
            PhoneBackground(surface: surface, haloY: 273, halos: isDone)
            VStack(spacing: 0) {
                PhoneBrandBar()
                switch model.pairing {
                case .scanning, .contacting: ScanView(model: model)
                case .done(let macName): DoneView(model: model, macName: macName)
                case .expired: ExpiredView(model: model, unreachable: false)
                case .unreachable: ExpiredView(model: model, unreachable: true)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .animation(.easeOut(duration: 0.4), value: model.pairing)
    }

    private var isDone: Bool {
        if case .done = model.pairing { return true }
        return false
    }

    private var surface: RGBA {
        switch model.pairing {
        case .scanning, .contacting: StatePalette(.userSpeaking).surface
        case .done: StatePalette(.speaking).surface
        case .expired, .unreachable: StatePalette(.thinking).surface
        }
    }
}

private struct ScanView: View {
    let model: PhoneModel
    @State private var cameraAllowed: Bool?
    @State private var line = false
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Text("Scan the code shown on your Mac.")
                .textStyle(.phoneHeadline)
                .foregroundStyle(Palette.ink)
                .padding(.top, 8)
            Group {
                if model.forgotten {
                    Text("Your Mac no longer knows this device. To add it again, open Settings › iPhone and iPad on your Mac, then “Add a device”.")
                } else {
                    Text("On your Mac, open Settings › iPhone and iPad, then “Add a device”.")
                }
            }
            .textStyle(.phoneParagraph)
            .foregroundStyle(Palette.inkMuted)
            .padding(.top, 12)
            viewfinder
                .padding(.top, 26)
            PhoneChip {
                BlinkingDot(color: Palette.azure)
                if model.pairing == .contacting {
                    Text("Contacting your Mac…")
                } else {
                    Text("Looking for the code…")
                }
            }
            .padding(.top, 18)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            VStack(spacing: 8) {
                IconView(icon: .lock, size: 20)
                Text("What you say goes encrypted to your Mac, and nowhere else.")
            }
            .textStyle(.phoneSmall)
            .foregroundStyle(Palette.inkMuted)
            .frame(maxWidth: 300)
            .accessibilityElement(children: .combine)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .padding(.bottom, 48)
        .task { cameraAllowed = await CameraAccess.request() }
    }

    private var viewfinder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.ink)
            if cameraAllowed == true {
                QRScanner(isActive: model.pairing == .scanning) { model.scanned($0) }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .accessibilityHidden(true)
            } else if cameraAllowed == false {
                VStack(spacing: 14) {
                    Text("Allow the camera to scan the code.")
                        .textStyle(.phoneNote)
                        .foregroundStyle(Palette.onInk)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(PillButtonStyle())
                }
                .padding(24)
            }
            target
        }
        .frame(width: 337, height: 337)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Camera viewfinder: put your Mac’s QR code inside the frame"))
    }

    /// Four corners and a line going up and down.
    private var target: some View {
        ZStack(alignment: .top) {
            ForEach(0..<4, id: \.self) { corner in
                CornerShape()
                    .stroke(Palette.azureSoft, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 46, height: 46)
                    .rotationEffect(.degrees(Double(corner) * 90))
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: [Alignment.topLeading, .topTrailing, .bottomTrailing, .bottomLeading][corner])
            }
            if cameraAllowed != false {
                Capsule()
                    .fill(Palette.turquoise)
                    .frame(height: 4)
                    .padding(.horizontal, 12)
                    .offset(y: line ? 212 : 14)
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { line = true }
                    }
            }
        }
        .frame(width: 232, height: 232)
        .allowsHitTesting(false)
    }
}

/// The top-left corner of the viewfinder's target, turned for the others.
private struct CornerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 2.5, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + 2.5, y: rect.minY + 16))
        path.addQuadCurve(to: CGPoint(x: rect.minX + 16, y: rect.minY + 2.5),
                          control: CGPoint(x: rect.minX + 2.5, y: rect.minY + 2.5))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 2.5))
        return path
    }
}

private struct DoneView: View {
    let model: PhoneModel
    let macName: String

    var body: some View {
        VStack(spacing: 0) {
            Orb(look: OrbLook(.speaking))
                .scaleEffect(300 / 380)
                .frame(width: 300, height: 300)
                .padding(.top, 4)
            Group {
                if model.isPad {
                    Text("Done: you can talk to Maé from your iPad.")
                } else {
                    Text("Done: you can talk to Maé from your iPhone.")
                }
            }
            .textStyle(.phoneDoneHeadline)
            .foregroundStyle(Palette.ink)
            .padding(.top, 4)
            HStack(spacing: 8) {
                IconView(icon: .laptop, size: 20)
                Text(verbatim: macName)
                Circle()
                    .fill(Palette.mint)
                    .frame(width: 22, height: 22)
                    .overlay { IconView(icon: .check, size: 14, strokeWidth: 3) }
            }
            .textStyle(.phoneChip)
            .foregroundStyle(Palette.ink)
            .padding(.leading, 13)
            .padding(.trailing, 8)
            .frame(height: 36)
            .background(Palette.white, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.line))
            .padding(.top, 18)
            .accessibilityElement(children: .combine)
            Group {
                if model.mac?.relay == nil {
                    Text("At home, on the same Wi-Fi as your Mac, the link happens on its own.")
                } else {
                    Text("At home and away, the link happens on its own.")
                }
            }
            .textStyle(.phoneNote)
            .foregroundStyle(Palette.inkMuted)
            .frame(maxWidth: 290)
            .padding(.top, 14)
            Spacer(minLength: 12)
            WideButton(title: "Talk to Maé", icon: .microphone, glow: StatePalette(.speaking).glow,
                       action: model.finishPairing)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .padding(.bottom, 48)
    }
}

/// "This code is no longer valid", or the Mac did not answer the pairing.
private struct ExpiredView: View {
    let model: PhoneModel
    let unreachable: Bool

    var body: some View {
        VStack(spacing: 0) {
            FloatingDisc(icon: unreachable ? .moon : .history, color: unreachable ? Palette.coralSoft : Palette.sun)
                .padding(.top, 64)
                .padding(.bottom, 28)
            Group {
                if unreachable {
                    Text("Your Mac does not answer.")
                } else {
                    Text("This code is no longer valid.")
                }
            }
            .textStyle(.phoneHeadline)
            .foregroundStyle(Palette.ink)
            Group {
                if unreachable {
                    Text("Check that it is on, with the code still showing, then scan it again.")
                } else {
                    Text("A code is valid for 5 minutes and serves only once. Show a new one on your Mac: Settings › iPhone and iPad, then “Add a device”.")
                }
            }
            .textStyle(.phoneParagraph)
            .foregroundStyle(Palette.inkMuted)
            .frame(maxWidth: 320)
            .padding(.top, 12)
            Spacer(minLength: 12)
            WideButton(title: "Scan a new code", icon: .camera, iconStroke: nil, glow: Palette.sun,
                       action: model.scanAgain)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .padding(.bottom, 48)
    }
}
