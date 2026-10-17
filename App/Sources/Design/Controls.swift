import SwiftUI

// Buttons and controls of the design: one dark main pill per window, round white "glass" buttons, small
// tinted pills for the actions of the settings, and the controls of the settings panel.

// MARK: - Main button

/// Size of the main pill: 60 points high in the conversation, 58 on the first-launch screen.
struct PillMetrics {
    var height: CGFloat
    var disc: CGFloat
    var leading: CGFloat
    var trailing: CGFloat
    var spacing: CGFloat
    var minWidth: CGFloat?

    static let conversation = PillMetrics(height: 60, disc: 42, leading: 10, trailing: 30, spacing: 14, minWidth: 200)
    static let setup = PillMetrics(height: 58, disc: 40, leading: 9, trailing: 22, spacing: 12)
}

/// The main pill's look: ink, with a coloured disc and its icon on the left (no disc without an icon).
struct PrimaryPill<Label: View>: View {
    let icon: Icon?
    var iconStroke: CGFloat?
    /// Colour of the disc: the accent of the conversation's state.
    let disc: RGBA
    var metrics = PillMetrics.conversation
    var isPressed = false
    @ViewBuilder let label: Label
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: metrics.spacing) {
            if let icon {
                Circle()
                    .fill(disc)
                    .frame(width: metrics.disc, height: metrics.disc)
                    .overlay { IconView(icon: icon, size: 22, strokeWidth: iconStroke).foregroundStyle(Palette.ink) }
                    .animation(.easeOut(duration: 0.4), value: disc)
            }
            label
                .textStyle(.button)
                .foregroundStyle(Palette.onInk)
                .lineLimit(1)
        }
        .padding(.leading, icon == nil ? metrics.trailing : metrics.leading)
        .padding(.trailing, metrics.trailing)
        .frame(minWidth: metrics.minWidth, maxWidth: metrics.minWidth == nil ? .infinity : nil)
        .frame(height: metrics.height)
        .background(isHovered ? Palette.inkHover : Palette.ink, in: Capsule())
        .buttonShadow()
        .contentShape(Capsule())
        .scaleEffect(isPressed ? 0.97 : 1)
        .animation(.easeOut(duration: Timing.press), value: isPressed)
        .animation(.easeOut(duration: Timing.ui), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    let icon: Icon?
    var iconStroke: CGFloat?
    var disc = Palette.coralSoft
    var metrics = PillMetrics.conversation

    func makeBody(configuration: Configuration) -> some View {
        PrimaryPill(icon: icon, iconStroke: iconStroke, disc: disc, metrics: metrics,
                    isPressed: configuration.isPressed) { configuration.label }
    }
}

// MARK: - Round glass buttons

/// Round secondary button: white at 70 % with a hairline, white when hovered. `isOn`: its panel is open.
struct GlassButtonStyle: ButtonStyle {
    var diameter: CGFloat = 52
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        GlassCircle(diameter: diameter, isOn: isOn, isPressed: configuration.isPressed) { configuration.label }
    }
}

private struct GlassCircle<Label: View>: View {
    let diameter: CGFloat
    let isOn: Bool
    let isPressed: Bool
    @ViewBuilder let label: Label
    @State private var isHovered = false

    var body: some View {
        label
            .foregroundStyle(Palette.ink)
            .frame(width: diameter, height: diameter)
            .background(isHovered || isOn ? Palette.white : Palette.glassButton, in: Circle())
            .hairline(Circle(), width: isOn ? 1.5 : 1, color: isOn ? Palette.ink : Palette.line)
            .contentShape(Circle())
            .scaleEffect(isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: Timing.press), value: isPressed)
            .animation(.easeOut(duration: Timing.ui), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

// MARK: - Small pills

/// The 34-point pills of the settings and the first-launch screen.
struct PillButtonStyle: ButtonStyle {
    enum Kind {
        /// "Choose another tier…": blue text on a blue tint.
        case link
        /// "Delete the models…".
        case destructive
        /// Any other secondary action.
        case neutral
    }

    var kind = Kind.neutral

    func makeBody(configuration: Configuration) -> some View {
        SmallPill(kind: kind, isPressed: configuration.isPressed) { configuration.label }
    }
}

private struct SmallPill<Label: View>: View {
    let kind: PillButtonStyle.Kind
    let isPressed: Bool
    @ViewBuilder let label: Label
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        label
            .textStyle(.smallButton)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.leading, kind == .link ? 12 : 16)
            .padding(.trailing, kind == .link ? 14 : 16)
            .frame(height: 34)
            .background(background, in: Capsule())
            .overlay {
                if kind == .neutral, isEnabled { Capsule().strokeBorder(Palette.line, lineWidth: 1) }
            }
            .opacity(kind == .link && !isEnabled ? 0.45 : 1)
            .contentShape(Capsule())
            .scaleEffect(isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: Timing.press), value: isPressed)
            .animation(.easeOut(duration: Timing.ui), value: isHovered)
            .onHover { isHovered = $0 && isEnabled }
    }

    private var foreground: RGBA {
        switch kind {
        case .link: isEnabled ? Palette.link : Palette.inkMuted
        case .destructive: isEnabled ? Palette.danger : Palette.inkDisabled
        case .neutral: isEnabled ? Palette.ink : Palette.inkDisabled
        }
    }

    private var background: RGBA {
        switch kind {
        case .link: isEnabled ? Palette.azure.opacity(isHovered ? 0.2 : 0.12) : Palette.ink.opacity(0.06)
        case .destructive: isEnabled ? Palette.dangerSoft : Palette.fieldDisabled
        case .neutral: isEnabled ? (isHovered ? Palette.white : Palette.glassButton) : Palette.fieldDisabled
        }
    }
}

// MARK: - Settings controls

/// Switch: 46 × 28, grey when off, turquoise when on; the thumb's position tells the state too.
struct SwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 0)
            Capsule()
                .fill(configuration.isOn ? Palette.turquoise : Palette.switchOff)
                .frame(width: 46, height: 28)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Palette.white)
                        .frame(width: 24, height: 24)
                        .shadow(color: Palette.ink.opacity(0.3).color, radius: 1.5, y: 1)
                        .padding(2)
                }
                .animation(Easing.animation(CubicBezier(0.3, 1.3, 0.5, 1), Timing.switchThumb),
                           value: configuration.isOn)
                .contentShape(Capsule())
                .onTapGesture { configuration.isOn.toggle() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? Text("On") : Text("Off"))
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

/// Two-choice segmented control: the chosen segment is white and raised.
struct Segmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: LocalizedStringKey)]
    var width: CGFloat = 236

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let isOn = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .textStyle(isOn ? .control : .controlOff)
                        .foregroundStyle(isOn ? Palette.ink : Palette.inkMuted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: Radius.segment, style: .continuous)
                                    .fill(Palette.white)
                                    .overlay(RoundedRectangle(cornerRadius: Radius.segment, style: .continuous)
                                        .strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
                                    .shadow(color: Palette.ink.opacity(0.18).color, radius: 1.5, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(width: width)
        .background(Palette.trackSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .animation(.easeOut(duration: Timing.ui), value: selection)
    }
}

/// Look of a pop-up menu: its value in bold, up and down chevrons.
struct MenuFieldLabel: View {
    let title: Text
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            title
                .textStyle(.control)
                .lineLimit(1)
            IconView(icon: .chevrons, size: 16)
        }
        .foregroundStyle(Palette.ink)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 34)
        .background(isHovered ? Palette.fieldHover : Palette.field,
                    in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovered = $0 && isEnabled }
    }
}

/// A text field of the settings, drawn like their pop-up menus: 34 points high, on `field`, rounded.
struct SettingsField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .textStyle(.label)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 34)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
    }
}

extension View {
    func settingsField() -> some View { modifier(SettingsField()) }
}

// MARK: - Small pieces

/// A keyboard key, as in "Hold [Space] to talk".
struct KeyCap: View {
    let title: Text
    /// On the capsule's glass: 13 points, on white at 90 %.
    var onGlass = false

    var body: some View {
        title
            .textStyle(onGlass ? .capsuleKey : .key)
            .foregroundStyle(Palette.ink)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Palette.white.opacity(onGlass ? 0.9 : 1),
                        in: RoundedRectangle(cornerRadius: Radius.key, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.key, style: .continuous)
                .strokeBorder(Palette.lineKey, lineWidth: 1))
            .shadow(color: Palette.ink.opacity(onGlass ? 0.1 : 0.08).color, radius: 0, y: 1)
    }
}

/// "✓ tested" in green; an untested tier says so in grey.
struct TierBadge: View {
    let isTested: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isTested { IconView(icon: .smallCheck, size: 12) }
            Text(isTested ? "tested" : "untested / estimated")
                .textStyle(.badge)
        }
        .foregroundStyle(isTested ? Palette.success : Palette.inkMuted)
        .padding(.leading, isTested ? 7 : 9)
        .padding(.trailing, 9)
        .frame(height: 22)
        .background(isTested ? Palette.successSoft : Palette.field, in: Capsule())
    }
}

/// The three-disc mark and the wordmark "Open**Maé**", side by side.
struct Logo: View {
    var body: some View {
        HStack(spacing: 10) {
            Canvas { context, _ in
                for (x, y, r, color) in [(8.5, 11.5, 7.5, Palette.coral), (17, 8.5, 6.5, Palette.sun),
                                         (19, 14.5, 6, Palette.turquoise)]
                {
                    context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                                 with: .color(color.color))
                }
            }
            .frame(width: 28, height: 22)
            (Text(verbatim: "Open").styled(.wordmark).foregroundStyle(Palette.inkMuted)
                + Text(verbatim: "Maé").styled(.wordmarkStrong).foregroundStyle(Palette.ink))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "OpenMaé"))
    }
}
