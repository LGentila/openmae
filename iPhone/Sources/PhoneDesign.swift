import SwiftUI
import UIKit
import VoiceCore

// The iPhone's own pieces of the design system: sizes made for the thumb (44-point round buttons, 64-point main
// pill), and the text styles of the iPhone screens. Colours, radii and timings are the shared tokens'.

extension TextStyle {
    static let phoneHeadline = TextStyle(.display, 30, weight: 600, lineHeight: 30 * 1.15, letterSpacing: -0.015)
    static let phoneDoneHeadline = TextStyle(.display, 28, weight: 600, lineHeight: 28 * 1.15, letterSpacing: -0.015)
    static let phoneParagraph = TextStyle(.sans, 17, weight: 400, lineHeight: 24)
    static let phoneNote = TextStyle(.sans, 15, weight: 400, lineHeight: 21)
    static let phoneSmall = TextStyle(.sans, 14, weight: 400, lineHeight: 20)
    static let phoneChip = TextStyle(.sans, 14, weight: 600, lineHeight: 18)
    static let phoneTranscript = TextStyle(.display, 20, weight: 500, lineHeight: 26, letterSpacing: -0.01)
    static let phoneLost = TextStyle(.display, 22, weight: 600, lineHeight: 26, letterSpacing: -0.01)
    static let phoneTitle = TextStyle(.display, 20, weight: 600, lineHeight: 26, letterSpacing: -0.01)
    static let phoneRowTitle = TextStyle(.sans, 17, weight: 600, lineHeight: 22)
    static let phoneRowDetail = TextStyle(.sans, 14, weight: 400, lineHeight: 19)
    static let phoneSection = TextStyle(.sans, 14, weight: 600, lineHeight: 18)
    static let phoneValue = TextStyle(.sans, 17, weight: 500, lineHeight: 22)
    static let phoneSegment = TextStyle(.sans, 16, weight: 600, lineHeight: 20)
    static let phoneVersion = TextStyle(.sans, 13, weight: 400, lineHeight: 18)
    static let phoneButton = TextStyle(.sans, 17, weight: 600, lineHeight: 22)
    static let phoneBigButton = TextStyle(.sans, 18, weight: 600, lineHeight: 22)

    // The iPad's: the transcript for close reading, and the station's words, read from across the room.
    static let padTranscript = TextStyle(.display, 26, weight: 500, lineHeight: 34, letterSpacing: -0.01)
    static let stationWord = TextStyle(.display, 52, weight: 600, lineHeight: 58, letterSpacing: -0.02)
    static let stationMac = TextStyle(.sans, 20, weight: 600, lineHeight: 24)
}

extension PillMetrics {
    /// The conversation's main button.
    static let phone = PillMetrics(height: 64, disc: 44, leading: 10, trailing: 28, spacing: 14, minWidth: 221)
    /// The full-width buttons of the pairing and alert screens.
    static let phoneWide = PillMetrics(height: 64, disc: 44, leading: 10, trailing: 34, spacing: 14)
}

extension TranscriptLayout {
    static let phone = TranscriptLayout(horizontalPadding: 26, previousLineWidth: 340, wordsWidth: 340,
                                        words: .phoneTranscript, invitationTop: 30)

    /// An iPad's, `width` wide at most.
    static func pad(width: CGFloat) -> TranscriptLayout {
        TranscriptLayout(horizontalPadding: 26, previousLineWidth: width, wordsWidth: width, words: .padTranscript,
                         invitationTop: 30)
    }
}

/// Where the white discs behind the orb (or the disc that stands in for it) go: centred on the view marked with
/// `haloAnchor()`, at the orb's proportions (380 and 600 points around an orb of 342), whatever the window's size.
struct HaloAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// The halos are centred on this view.
    func haloAnchor() -> some View {
        anchorPreference(key: HaloAnchorKey.self, value: .bounds) { $0 }
    }

    /// Draws the halos behind this content, around its `haloAnchor()`.
    func halosBehindAnchor() -> some View {
        backgroundPreferenceValue(HaloAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor {
                    let bounds = proxy[anchor]
                    PhoneHalos(inner: bounds.width * 380 / 342, outer: bounds.width * 600 / 342)
                        .position(x: bounds.midX, y: bounds.midY)
                }
            }
        }
    }
}

/// The screens' background: the state's surface, with the two flat white discs behind the orb (or the disc that
/// stands in for it), centred `haloY` points from the top of the screen of an iPhone (the design's, whose status bar
/// is 59 points high); on an iPad, whose status bar is lower, they move up with the content. (The conversation and
/// the station centre them on the orb instead: `halosBehindAnchor`.)
struct PhoneBackground: View {
    let surface: RGBA
    var haloY: CGFloat = 286
    var halos = true

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                surface.color
                    .animation(Easing.animation(Easing.ease, Timing.surface), value: surface)
                if halos {
                    PhoneHalos()
                        .position(x: proxy.size.width / 2, y: haloY + Self.padShift)
                }
            }
        }
        .ignoresSafeArea()
    }

    @MainActor
    private static var padShift: CGFloat {
        guard UIDevice.current.userInterfaceIdiom == .pad,
              let window = (UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)?
                  .windows.first
        else { return 0 }
        return window.safeAreaInsets.top - 59
    }
}

/// White at 55 % and 30 %, breathing slowly.
struct PhoneHalos: View {
    var inner: CGFloat = 380
    var outer: CGFloat = 600
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(Palette.white.opacity(0.3)).frame(width: outer, height: outer)
            Circle().fill(Palette.white.opacity(0.55)).frame(width: inner, height: inner)
        }
        .scaleEffect(grown ? 1.035 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .repeatsWhileVisible($grown, .easeInOut(duration: 3.5), enabled: !reduceMotion)
    }
}

/// The wordmark at the top of the screens without a conversation, with an optional button on the right.
struct PhoneBrandBar<Trailing: View>: View {
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ZStack {
            Logo()
            HStack {
                Spacer()
                trailing
            }
            .padding(.trailing, 12)
        }
        .frame(height: 56)
    }
}

extension PhoneBrandBar where Trailing == EmptyView {
    init() {
        self.init { EmptyView() }
    }
}

/// A big disc with an icon, floating gently: the alert and "code expired" screens.
struct FloatingDisc: View {
    let icon: Icon
    let color: RGBA
    @State private var down = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 132, height: 132)
            .overlay { IconView(icon: icon, size: 64, strokeWidth: 1.8).foregroundStyle(Palette.ink) }
            .offset(y: down ? 6 : -4)
            .repeatsWhileVisible($down, .easeInOut(duration: 3), enabled: !reduceMotion)
            .accessibilityHidden(true)
    }
}

/// A white pill with a hairline: the link's state, the Mac's name, a status. `leading`: 11 points before an icon, 14
/// before words alone.
struct PhoneChip<Content: View>: View {
    var background = Palette.white
    var outlined = true
    var leading: CGFloat = 11
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .textStyle(.phoneChip)
            .foregroundStyle(Palette.ink)
            .padding(.leading, leading)
            .padding(.trailing, 14)
            .frame(height: 36)
            .background(background, in: Capsule())
            .overlay { if outlined { Capsule().strokeBorder(Palette.line) } }
    }
}

/// A disc of colour with an icon: a row of the settings (the Mac, the relay), a connected tool on its action's card.
struct RowDisc: View {
    let icon: Icon
    let color: RGBA
    var size: CGFloat = 40
    var iconSize: CGFloat = 22
    var iconColor = Palette.ink

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay { IconView(icon: icon, size: iconSize).foregroundStyle(iconColor) }
            .accessibilityHidden(true)
    }
}

/// The blinking dot of a status chip.
struct BlinkingDot: View {
    let color: RGBA
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(dimmed ? 0.35 : 1)
            .repeatsWhileVisible($dimmed, .easeInOut(duration: 0.7))
    }
}

/// An icon that turns, for "reconnecting".
struct TurningIcon: View {
    let icon: Icon
    var size: CGFloat = 20
    @State private var turned = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        IconView(icon: icon, size: size)
            .rotationEffect(.degrees(turned ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { turned = true }
            }
    }
}

/// The wide main button of the screens without a conversation ("Talk to Maé", "Try again").
struct WideButton: View {
    let title: LocalizedStringKey
    let icon: Icon
    var iconStroke: CGFloat? = 2
    let glow: RGBA
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(title) }
            .buttonStyle(PrimaryButtonStyle(icon: icon, iconStroke: iconStroke, disc: glow, metrics: .phoneWide))
            .frame(maxWidth: 353)
    }
}
