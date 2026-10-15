import SwiftUI
import VoiceCore

// The design system's values: colours, radii, shadows, timings. The screens take every colour, radius and
// duration from here and never invent their own. There is no dark theme yet: the window stays light.

/// A colour as sRGB components, so that two colours can be blended during a change of state.
struct RGBA: Equatable, Sendable {
    var red, green, blue, alpha: Double

    /// `0xRRGGBB`.
    init(_ rgb: UInt32) {
        self.init(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255, alpha: 1)
    }

    /// `0xRRGGBBAA`.
    init(rgba: UInt32) {
        self.init(red: Double(rgba >> 24 & 0xFF) / 255, green: Double(rgba >> 16 & 0xFF) / 255,
                  blue: Double(rgba >> 8 & 0xFF) / 255, alpha: Double(rgba & 0xFF) / 255)
    }

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    func opacity(_ value: Double) -> RGBA {
        RGBA(red: red, green: green, blue: blue, alpha: alpha * value)
    }

    /// Straight blend of the components, as a CSS colour transition does.
    func mixed(with other: RGBA, _ t: Double) -> RGBA {
        RGBA(red: red + (other.red - red) * t, green: green + (other.green - green) * t,
             blue: blue + (other.blue - blue) * t, alpha: alpha + (other.alpha - alpha) * t)
    }
}

extension RGBA: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color { color }
}

/// Colour tokens that are the same in every state of the conversation.
enum Palette {
    static let card = RGBA(rgba: 0xFFFF_FFDB)  // information cards (white at 86 %)
    static let cardStrong = RGBA(rgba: 0xFFFF_FFEB)  // blocks inside the settings panel
    static let glassButton = RGBA(rgba: 0xFFFF_FFB3)  // round secondary buttons, white when hovered
    static let halo = RGBA(rgba: 0xFFFF_FF8C)  // flat discs behind the orb
    static let haloOuter = RGBA(rgba: 0xFFFF_FF4D)
    static let white = RGBA(0xFFFFFF)

    static let ink = RGBA(0x1F1B16)  // text, main button
    static let inkHover = RGBA(0x34302A)
    static let inkMuted = RGBA(0x6B655C)  // secondary text
    static let inkDisabled = RGBA(0xA19B90)
    static let onInk = RGBA(0xFFFFFF)

    static let line = RGBA(rgba: 0x1F1B_1614)  // hairlines inside a card, outline of round buttons
    static let lineStrong = RGBA(rgba: 0x1F1B_1624)
    static let lineKey = RGBA(rgba: 0x1F1B_161F)  // outline of a keyboard key
    static let track = RGBA(0xECE7DD)  // rail of the progress bars
    static let trackSoft = RGBA(0xEAE5DB)  // segmented control
    static let field = RGBA(0xF1EDE4)  // pop-up menu
    static let fieldDisabled = RGBA(0xEFEBE2)
    static let switchOff = RGBA(0xD9D4CA)

    static let coral = RGBA(0xFF6A4D)  // Maé's voice
    static let sun = RGBA(0xFFC83D)  // thinking, language model
    static let turquoise = RGBA(0x14BFAE)  // done, healthy, switch on
    static let azure = RGBA(0x2E93F5)  // the user's voice, speech recognition
    static let coralSoft = RGBA(0xFF9C86)
    static let sunSoft = RGBA(0xFFD561)
    static let turquoiseSoft = RGBA(0x6FDAC8)
    static let azureSoft = RGBA(0x86BEFF)
    static let mint = RGBA(0x8FE3B8)  // listening only
    static let sky = RGBA(0x7EC4FF)
    static let pink = RGBA(0xFF8FA3)  // speaking only
    static let orange = RGBA(0xFF9A3D)

    static let link = RGBA(0x0B5FA8)
    static let linkSoft = RGBA(rgba: 0x2E93_F51F)
    static let success = RGBA(0x0B6B49)
    static let successSoft = RGBA(0xD6F5E7)
    static let danger = RGBA(0xA8300F)
    static let dangerSoft = RGBA(0xFFE3DC)
    static let progress = RGBA(0xC8452A)  // fill of the download pill

    /// Background of the settings panel, a translucent cream (88 %) over a blur.
    static let panel = RGBA(red: 255 / 255, green: 251 / 255, blue: 244 / 255, alpha: 0.88)
    /// Hover of a pop-up menu.
    static let fieldHover = RGBA(0xE9E4D9)
}

/// The colours that follow the conversation: cream at rest, pale blue while the user speaks, sand while Maé
/// thinks, peach while Maé speaks. Warm is Maé, cold is the user.
struct StatePalette: Equatable {
    /// Window background.
    var surface: RGBA
    /// The orb's four blobs (arms at 0°, 90°, 180°, 270°).
    var blobs: [RGBA]
    /// Accent of the state: floor shadow, ripples, dot of the speaker chip, disc of the main button.
    var glow: RGBA
    /// Tinted text: the most recent words of the transcript.
    var deep: RGBA
    /// Voice bars inside the white core.
    var bar: RGBA
    /// Background of the capsule, over a blur (it is never shown at rest: that value is only a fallback).
    var glass: RGBA
    /// Status and most recent words on the capsule: darker than `deep`, the glass being more translucent.
    var deepOnGlass: RGBA

    init(_ state: PipelineState) {
        switch state {
        case .listening:
            surface = RGBA(0xFBF6EC)
            blobs = [Palette.coralSoft, Palette.sunSoft, Palette.turquoiseSoft, Palette.azureSoft]
            glow = Palette.coralSoft
            deep = Palette.inkMuted
            bar = Palette.ink
            glass = RGBA(rgba: 0xFBF6_ECE6)
            deepOnGlass = Palette.inkMuted
        case .userSpeaking:
            surface = RGBA(0xE4F1FB)
            blobs = [Palette.azure, Palette.turquoise, Palette.mint, Palette.sky]
            glow = Palette.azure
            deep = Palette.link
            bar = RGBA(0x1D86F0)
            glass = RGBA(rgba: 0xE8F4_FCE6)
            deepOnGlass = RGBA(0x0A4F8E)
        case .thinking:
            surface = RGBA(0xFBF3E0)
            blobs = [Palette.coral, Palette.sun, Palette.turquoise, Palette.azure]
            glow = Palette.sun
            deep = Palette.inkMuted
            bar = Palette.ink
            glass = RGBA(rgba: 0xFFF6_E2EB)
            deepOnGlass = RGBA(0x7A5200)
        case .speaking:
            surface = RGBA(0xFFEBDD)
            blobs = [Palette.coral, Palette.sun, Palette.pink, Palette.orange]
            glow = Palette.coral
            deep = RGBA(0xB8381A)
            bar = RGBA(0xFF5A36)
            glass = RGBA(rgba: 0xFFEC_E0EB)
            deepOnGlass = RGBA(0xA8300F)
        }
    }
}

enum Radius {
    static let window: CGFloat = 26  // settings panel
    static let card: CGFloat = 20
    static let section: CGFloat = 16
    static let field: CGFloat = 10
    static let segment: CGFloat = 8
    static let key: CGFloat = 7
    static let code: CGFloat = 5
}

/// Durations, in seconds.
enum Timing {
    static let press = 0.15
    static let ui = 0.2
    static let switchThumb = 0.25
    static let color = 0.35  // longer, blue ↔ coral would pass through a purplish grey
    static let word = 0.4
    static let rise = 0.5
    static let capsule = 0.55  // the capsule comes up
    static let pop = 0.8
    static let surface = 1.0
}

/// The design's timing curves.
enum Easing {
    static let smooth = CubicBezier(0.42, 0, 0.58, 1)  // CSS ease-in-out: continuous loops
    static let ease = CubicBezier(0.25, 0.1, 0.25, 1)  // CSS ease: colour changes
    static let pop = CubicBezier(0.3, 0.1, 0.3, 1)  // the orb's bounce at each change of state
    static let spring = CubicBezier(0.3, 1.35, 0.5, 1)  // orbit radius, slight overshoot
    static let rise = CubicBezier(0.2, 0.8, 0.3, 1)  // transcript words
    static let capsule = CubicBezier(0.2, 1.3, 0.4, 1)  // the capsule comes up, with a marked bounce
    static let ripple = CubicBezier(0.25, 0.6, 0.35, 1)

    static func animation(_ curve: CubicBezier, _ duration: Double) -> Animation {
        .timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: duration)
    }
}

/// A CSS `cubic-bezier()` timing function, evaluated like the browsers do.
struct CubicBezier: Sendable {
    let x1, y1, x2, y2: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    func callAsFunction(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        return sample(y1, y2, solve(x))
    }

    private func sample(_ a: Double, _ b: Double, _ t: Double) -> Double {
        // Bézier from (0,0) to (1,1) with control points a and b, one coordinate at a time.
        ((1 - 3 * b + 3 * a) * t + (3 * b - 6 * a)) * t * t + 3 * a * t
    }

    /// The curve parameter whose x is `x` (Newton, then bisection when the slope is too flat).
    private func solve(_ x: Double) -> Double {
        var t = x
        for _ in 0..<8 {
            let error = sample(x1, x2, t) - x
            if abs(error) < 1e-6 { return t }
            let slope = (3 * (1 - 3 * x2 + 3 * x1) * t + 2 * (3 * x2 - 6 * x1)) * t + 3 * x1
            if abs(slope) < 1e-6 { break }
            t -= error / slope
        }
        var low = 0.0, high = 1.0
        t = x
        while high - low > 1e-6 {
            if sample(x1, x2, t) < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return t
    }
}

// MARK: - Shadows and outlines

extension View {
    /// `shadow-card`: a 1-point outline and a soft shadow below.
    func cardShadow(cornerRadius: CGFloat = Radius.card) -> some View {
        overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Palette.ink.opacity(0.07), lineWidth: 1))
            .shadow(color: Palette.ink.opacity(0.05).color, radius: 10, y: 6)
    }

    /// `shadow-button`: under the main button.
    func buttonShadow() -> some View {
        shadow(color: Palette.ink.opacity(0.22).color, radius: 12, y: 10)
    }

    /// `shadow-hairline`: inner outline of the round buttons.
    func hairline<S: InsettableShape>(_ shape: S, width: CGFloat = 1, color: RGBA = Palette.line) -> some View {
        overlay(shape.strokeBorder(color, lineWidth: width))
    }
}

/// An information card: white at 86 %, rounded, with its outline and shadow.
struct Card<Content: View>: View {
    var padding = EdgeInsets(top: 4, leading: 18, bottom: 12, trailing: 18)
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .cardShadow()
    }
}

/// A hairline between two rows of a card.
struct Hairline: View {
    var color = Palette.line

    var body: some View {
        Rectangle().fill(color).frame(height: 1)
    }
}
