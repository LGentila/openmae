import SwiftUI

// The settings window's building blocks, as the design draws them: a page's head and introduction, its section
// titles, the white cards and their rows and captions, status dots and pills, notes, list items, the empty page,
// fields, buttons and the modal sheet. The values are the design's; those that are not tokens yet are in Tokens.swift.

extension TextStyle {
    static let pageTitle = TextStyle(.display, 30, weight: 600, lineHeight: 36, letterSpacing: -0.02)
    static let pageIntro = TextStyle(.sans, 15, weight: 400, lineHeight: 22)
    static let pageSection = TextStyle(.sans, 13, weight: 700, lineHeight: 16, letterSpacing: 0.02)
    static let sidebarItem = TextStyle(.sans, 15, weight: 500, lineHeight: 20)
    static let sidebarItemOn = TextStyle(.sans, 15, weight: 600, lineHeight: 20)
    static let sidebarCount = TextStyle(.sans, 13, weight: 600, lineHeight: 16, tabular: true)
    static let rowSub = TextStyle(.sans, 13, weight: 400, lineHeight: 18)
    static let caption = TextStyle(.sans, 13, weight: 400, lineHeight: 13 * 1.45)
    static let itemEnd = TextStyle(.sans, 13.5, weight: 500, lineHeight: 18)
    static let itemState = TextStyle(.sans, 13.5, weight: 600, lineHeight: 18)
    static let pill = TextStyle(.sans, 13, weight: 600, lineHeight: 16)
    static let mainButton = TextStyle(.sans, 15.5, weight: 600, lineHeight: 20)
    static let field = TextStyle(.sans, 14.5, weight: 500, lineHeight: 20)
    static let fieldMono = TextStyle(.mono, 13, weight: 400, lineHeight: 18)
    static let fieldLabel = TextStyle(.sans, 13, weight: 600, lineHeight: 16)
    static let address = TextStyle(.mono, 12.5, weight: 400, lineHeight: 12.5 * 1.5)
    static let toolID = TextStyle(.mono, 12, weight: 400, lineHeight: 16)
    static let subSection = TextStyle(.sans, 12.5, weight: 700, lineHeight: 16, letterSpacing: 0.02)
    static let sheetTitle = TextStyle(.display, 24, weight: 600, lineHeight: 30, letterSpacing: -0.015)
    static let sheetText = TextStyle(.sans, 14.5, weight: 400, lineHeight: 14.5 * 1.5)
    static let heroTitle = TextStyle(.display, 22, weight: 600, lineHeight: 22 * 1.2, letterSpacing: -0.01)
    static let heroText = TextStyle(.sans, 14.5, weight: 400, lineHeight: 14.5 * 1.5)
    static let noteText = TextStyle(.sans, 13, weight: 400, lineHeight: 13 * 1.45)
    static let logLine = TextStyle(.sans, 13, weight: 400, lineHeight: 18)
    static let logEvent = TextStyle(.sans, 13.5, weight: 500, lineHeight: 18)
    static let logResult = TextStyle(.sans, 13, weight: 700, lineHeight: 18)
    static let logText = TextStyle(.sans, 14.5, weight: 400, lineHeight: 20)
    static let step = TextStyle(.sans, 14, weight: 400, lineHeight: 20)
    static let stepNumber = TextStyle(.sans, 12.5, weight: 700, lineHeight: 16)
    static let navRow = TextStyle(.sans, 15, weight: 500, lineHeight: 20)
    static let version = TextStyle(.sans, 12.5, weight: 400, lineHeight: 16)
}

// MARK: - States

/// The colour of a state, always said with a word too: on (turquoise), to look at (orange), error (red), off (grey),
/// information (blue).
enum StatusTone: Equatable {
    case on, warn, error, off, info

    var color: RGBA {
        switch self {
        case .on: Palette.turquoise
        case .warn: Palette.orange
        case .error: Palette.danger
        case .off: Palette.inkDisabled
        case .info: Palette.azure
        }
    }
}

struct StatusDot: View {
    let tone: StatusTone

    var body: some View {
        Circle().fill(tone.color).frame(width: 8, height: 8)
    }
}

/// A pill of 28 points: a dot and a word on white (a page's state), or a tinted word (a test's result).
struct StatusPill: View {
    enum Style: Equatable {
        case dot(StatusTone)
        case success, refused, neutral, attention
    }

    let text: Text
    let style: Style

    var body: some View {
        HStack(spacing: 7) {
            if case .dot(let tone) = style { StatusDot(tone: tone) }
            text
                .textStyle(.pill)
                .foregroundStyle(foreground)
                .lineLimit(1)
        }
        .padding(.leading, isDot ? 10 : 12)
        .padding(.trailing, 12)
        .frame(height: 28)
        .background(background, in: Capsule())
        .overlay { if isDot { Capsule().strokeBorder(Palette.ink.opacity(0.1), lineWidth: 1) } }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var isDot: Bool {
        if case .dot = style { return true }
        return false
    }

    private var foreground: RGBA {
        switch style {
        case .dot: Palette.ink
        case .success: Palette.success
        case .refused: Palette.danger
        case .neutral: Palette.inkMuted
        case .attention: Palette.warnInk
        }
    }

    private var background: RGBA {
        switch style {
        case .dot: Palette.white
        case .success: Palette.successSoft
        case .refused: Palette.dangerSoft
        case .neutral: Palette.fieldDisabled
        case .attention: Palette.warnSoft
        }
    }
}

// MARK: - A page

extension View {
    /// A text style whose single lines are as tall as its line height, as in the design (CSS line boxes): half the
    /// extra space above, half below.
    func textBox(_ style: TextStyle) -> some View {
        textStyle(style).padding(.vertical, style.lineSpacing / 2)
    }
}

extension EnvironmentValues {
    /// Still pictures of the settings show each page whole, at its own height, instead of scrolling it.
    @Entry var unscrolledPages = false
}

/// A page of the window: it scrolls when it is taller than the window.
struct SettingsPageScroll<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.unscrolledPages) private var unscrolled

    var body: some View {
        if unscrolled {
            page.frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView { page }
                .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// As wide as the window leaves it, never wider: what does not fit wraps or goes under (`SettingRow`, `ActionRow`).
    private var page: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(EdgeInsets(top: 28, leading: 36, bottom: 40, trailing: 36))
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

/// The page's title, with a round "back" button before it on a detail page, and its state or main action on the right.
struct PageHead<Trailing: View>: View {
    let title: Text
    var back: (() -> Void)?
    var backLabel = Text("Back")
    @ViewBuilder var trailing: Trailing

    init(_ title: Text, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    /// A detail page's head: `back` goes back to its list, `backLabel` names it for VoiceOver.
    init(_ title: Text, back: @escaping () -> Void, backLabel: Text,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() })
    {
        self.title = title
        self.back = back
        self.backLabel = backLabel
        self.trailing = trailing()
    }

    /// The state or the action on the right of the title; under it when the window is too narrow for both.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                start
                Spacer(minLength: 10)
                trailing
            }
            .frame(minHeight: 44)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) { start }
                    .frame(minHeight: 44)
                trailing
            }
        }
    }

    @ViewBuilder private var start: some View {
        if let back {
            Button(action: back) { IconView(icon: .back, size: 18) }
                .buttonStyle(RoundButtonStyle())
                .accessibilityLabel(backLabel)
        }
        title
            .textStyle(.pageTitle)
            .foregroundStyle(Palette.ink)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityAddTraits(.isHeader)
    }
}

/// What the page is for, under its title: 580 points at most.
struct PageIntro: View {
    let text: Text

    init(_ key: LocalizedStringKey) { text = Text(key) }
    init(_ text: Text) { self.text = text }

    var body: some View {
        text
            .textBox(.pageIntro)
            .foregroundStyle(Palette.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 580, alignment: .leading)
            .padding(.top, 8)
    }
}

/// A detail page's line under its title: "On this Mac · Anthropic's online models".
struct PageSubtitle: View {
    let icon: Icon
    let text: Text

    var body: some View {
        HStack(spacing: 8) {
            IconView(icon: icon, size: 16)
            text.textBox(.pageIntro)
        }
        .foregroundStyle(Palette.inkMuted)
        .padding(.top, 8)
    }
}

/// Title of a section of a page.
struct PageSection<Trailing: View>: View {
    let title: Text
    @ViewBuilder var trailing: Trailing

    init(_ key: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        title = Text(key)
        self.trailing = trailing()
    }

    init(_ title: Text, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            title
                .textBox(.pageSection)
                .foregroundStyle(Palette.inkMuted)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing
        }
        .padding(EdgeInsets(top: 24, leading: 4, bottom: 8, trailing: 4))
    }
}

/// A white card of a page: its items are separated by hairlines (`Hairline`).
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.white, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.cardOutline, lineWidth: 1))
    }
}

/// A setting: its label (and a line under it), its control on the right. 58 points at least. In a narrow window, the
/// control goes under the label (`SettingRowLayout`).
struct SettingRow<Control: View>: View {
    let label: Text
    var sub: Text?
    @ViewBuilder var control: Control

    init(_ label: Text, sub: Text? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.sub = sub
        self.control = control()
    }

    init(_ key: LocalizedStringKey, sub: Text? = nil, @ViewBuilder control: () -> Control) {
        self.init(Text(key), sub: sub, control: control)
    }

    var body: some View {
        SettingRowLayout {
            VStack(alignment: .leading, spacing: 0) {
                label
                    .textBox(.setting)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let sub {
                    sub
                        .textBox(.rowSub)
                        .foregroundStyle(Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // One view, whatever the control is made of (several views, or none).
            HStack(spacing: 16) { control }
        }
    }
}

/// A setting's label and its control: side by side, the control on the right, both centred on a row of 58 points at
/// least; or, when the width would leave the label less than `minLabelWidth` (or its own width, if shorter) next to the
/// control, the control under the label, at its start, and no wider than the row.
struct SettingRowLayout: Layout {
    var spacing: CGFloat = 16
    var minHeight: CGFloat = 58
    var minLabelWidth: CGFloat = 140

    struct Cache {
        var label: CGSize
        var control: CGSize
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(label: subviews.first?.sizeThatFits(.unspecified) ?? .zero,
              control: subviews.dropFirst().first?.sizeThatFits(.unspecified) ?? .zero)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    private func sideBySide(_ width: CGFloat, _ cache: Cache) -> Bool {
        cache.control.width + spacing + min(cache.label.width, minLabelWidth) <= width
    }

    /// Under the label: room above, between and below.
    private static let stacked = (top: CGFloat(14), gap: CGFloat(10), bottom: CGFloat(14))
    private var stacked: (top: CGFloat, gap: CGFloat, bottom: CGFloat) { Self.stacked }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        guard let width = proposal.width, width.isFinite else {
            return CGSize(width: cache.label.width + spacing + cache.control.width,
                          height: max(minHeight, cache.label.height, cache.control.height))
        }
        if sideBySide(width, cache) {
            let label = subviews[0].sizeThatFits(ProposedViewSize(width: width - spacing - cache.control.width,
                                                                  height: nil))
            return CGSize(width: width, height: max(minHeight, label.height, cache.control.height))
        }
        let label = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let control = subviews[1].sizeThatFits(ProposedViewSize(width: min(cache.control.width, width), height: nil))
        return CGSize(width: width, height: stacked.top + label.height + stacked.gap + control.height + stacked.bottom)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard subviews.count == 2 else { return }
        if sideBySide(bounds.width, cache) {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: bounds.width - spacing - cache.control.width,
                                                         height: nil))
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                              proposal: ProposedViewSize(cache.control))
        } else {
            let label = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + stacked.top), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + stacked.top + label.height + stacked.gap),
                              anchor: .topLeading,
                              proposal: ProposedViewSize(width: min(cache.control.width, bounds.width), height: nil))
        }
    }
}

/// A switch on its own row.
struct SwitchRow: View {
    let label: Text
    @Binding var isOn: Bool

    init(_ key: LocalizedStringKey, isOn: Binding<Bool>) {
        label = Text(key)
        _isOn = isOn
    }

    init(_ label: Text, isOn: Binding<Bool>) {
        self.label = label
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            label
                .textStyle(.setting)
                .foregroundStyle(Palette.ink)
        }
        .toggleStyle(WindowSwitchStyle())
        .frame(minHeight: 58)
    }
}

/// Under a setting: two lines at most. Brown to warn, red for an error.
struct Caption: View {
    enum Tone { case normal, warn, error, success }

    let text: Text
    var tone = Tone.normal

    init(_ key: LocalizedStringKey, tone: Tone = .normal) {
        text = Text(key)
        self.tone = tone
    }

    init(_ text: Text, tone: Tone = .normal) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        text
            .textBox(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, -6)
            .padding(.bottom, 14)
    }

    private var color: RGBA {
        switch tone {
        case .normal: Palette.inkMuted
        case .warn: Palette.warnText
        case .error: Palette.danger
        case .success: Palette.success
        }
    }
}

/// Buttons in a row, under a setting; on more lines when the window is too narrow for them.
struct ActionRow<Content: View>: View {
    var top: CGFloat = -2
    var bottom: CGFloat = 14
    @ViewBuilder let content: Content

    var body: some View {
        FlowLayout(spacing: 10, lineSpacing: 10) { content }
            .padding(.top, top)
            .padding(.bottom, bottom)
    }
}

/// Its views in a row, left to right, going on to the next line when the next one would not fit; each centred on its
/// line. As wide as its views when they fit on one line, as the width given otherwise; a view wider than that alone is
/// offered that width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 10

    private struct Line {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(within: proposal.width, subviews)
        return CGSize(width: lines.map(\.width).max() ?? 0,
                      height: lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, lines.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(within: bounds.width, subviews) {
            var x = bounds.minX
            for item in line.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y + line.height / 2), anchor: .leading,
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private func lines(within width: CGFloat?, _ subviews: Subviews) -> [Line] {
        let available = width.map { max(0, $0) } ?? .infinity
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > available {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: available, height: nil))
            }
            if !line.items.isEmpty, line.width + spacing + size.width > available {
                lines.append(line)
                line = Line()
            }
            line.width += (line.items.isEmpty ? 0 : spacing) + size.width
            line.height = max(line.height, size.height)
            line.items.append((index: index, size: size))
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }
}

/// A box that says what is happening, then what can be done: information, warning, error or success.
struct Note: View {
    enum Tone { case info, warn, error, success }

    let text: Text
    var tone = Tone.info
    var icon: Icon?

    init(_ key: LocalizedStringKey, tone: Tone = .info, icon: Icon? = nil) {
        text = Text(key)
        self.tone = tone
        self.icon = icon
    }

    init(_ text: Text, tone: Tone = .info, icon: Icon? = nil) {
        self.text = text
        self.tone = tone
        self.icon = icon
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconView(icon: icon ?? defaultIcon, size: 18)
                .padding(.top, -1)
            text
                .textBox(.noteText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(foreground)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: Radius.note, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var defaultIcon: Icon {
        switch tone {
        case .info: .info
        case .warn, .error: .warning
        case .success: .smallCheck
        }
    }

    private var foreground: RGBA {
        switch tone {
        case .info: Palette.infoInk
        case .warn: Palette.warnInk
        case .error: Palette.errorInk
        case .success: Palette.successInk
        }
    }

    private var background: RGBA {
        switch tone {
        case .info: Palette.linkSoft
        case .warn: Palette.warnSoft
        case .error: Palette.errorSoft
        case .success: Palette.successSoft
        }
    }
}

/// A short list of promises under a page's card: an icon and a sentence each.
struct PromiseList: View {
    let items: [(icon: Icon, text: Text)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 10) {
                    IconView(icon: items[i].icon, size: 16)
                        .foregroundStyle(Palette.inkDisabled)
                        .padding(.top, 1)
                    items[i].text
                        .textBox(.noteText)
                        .foregroundStyle(Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(EdgeInsets(top: 16, leading: 4, bottom: 0, trailing: 4))
    }
}

/// A sub-title inside a card: "Read · 1", "Found in the « OpenMaé » folder · 2".
struct CardSubtitle: View {
    let text: Text

    var body: some View {
        text
            .textBox(.subSection)
            .foregroundStyle(Palette.inkMuted)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }
}

// MARK: - Lists

/// A disc of colour with an icon: the family of an agent, a tool, a device or a source.
struct FamilyDisc: View {
    let icon: Icon
    let color: RGBA
    var size: CGFloat = 44
    var iconColor = Palette.ink

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay { IconView(icon: icon, size: size * 0.5).foregroundStyle(iconColor) }
    }
}

/// An item of a list (agent, tool, device, source): its disc, name and line, and what is on its right (under its words
/// when the window is too narrow for both, `TrailingLayout`).
struct ListItem<Name: View, Trailing: View>: View {
    let disc: FamilyDisc
    @ViewBuilder var name: Name
    let sub: Text?
    @ViewBuilder var trailing: Trailing
    var isHovered = false

    var body: some View {
        TrailingLayout(spacing: 8, indent: TrailingLayout.wordsInset) {
            HStack(spacing: 14) {
                disc
                VStack(alignment: .leading, spacing: 0) {
                    name
                        .textBox(.rowTitle)
                        .foregroundStyle(Palette.ink)
                        .underline(isHovered, color: Palette.ink.opacity(0.25).color)
                        .lineLimit(1)
                    if let sub {
                        sub
                            .textBox(.rowSub)
                            .foregroundStyle(Palette.inkMuted)
                            .lineLimit(2)
                    }
                }
            }
            .frame(minHeight: 72)
            HStack(spacing: 0) { trailing }
        }
    }
}

/// An item's own part and what is on its right (a state, a switch, buttons): side by side, both centred, the item as
/// wide as the width; or, when the width would leave the item's words less than `minWords` (or their own width, if
/// shorter), what was on the right goes under them, `indent` points in.
struct TrailingLayout: Layout {
    var spacing: CGFloat
    var indent: CGFloat
    var minWords: CGFloat = 140
    var bottom: CGFloat = 14

    /// Where a list item's words start: after its 44-point disc.
    static let wordsInset: CGFloat = 44 + 14

    struct Cache {
        var leading: CGSize
        var trailing: CGSize
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(leading: subviews.first?.sizeThatFits(.unspecified) ?? .zero,
              trailing: subviews.dropFirst().first?.sizeThatFits(.unspecified) ?? .zero)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    private func gap(_ cache: Cache) -> CGFloat { cache.trailing.width > 0 ? spacing : 0 }

    private func sideBySide(_ width: CGFloat, _ cache: Cache) -> Bool {
        let words = max(0, cache.leading.width - indent)
        return cache.trailing.width == 0
            || indent + min(words, minWords) + gap(cache) + cache.trailing.width <= width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        guard let width = proposal.width, width.isFinite else {
            return CGSize(width: cache.leading.width + gap(cache) + cache.trailing.width,
                          height: max(cache.leading.height, cache.trailing.height))
        }
        if sideBySide(width, cache) {
            let leading = subviews[0].sizeThatFits(ProposedViewSize(width: width - gap(cache) - cache.trailing.width,
                                                                    height: nil))
            return CGSize(width: width, height: max(leading.height, cache.trailing.height))
        }
        let leading = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let trailing = subviews[1].sizeThatFits(ProposedViewSize(width: min(cache.trailing.width, width - indent),
                                                                 height: nil))
        return CGSize(width: width, height: leading.height + trailing.height + bottom)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard subviews.count == 2 else { return }
        if sideBySide(bounds.width, cache) {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: bounds.width - gap(cache) - cache.trailing.width,
                                                         height: nil))
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                              proposal: ProposedViewSize(cache.trailing))
        } else {
            let leading = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX + indent, y: bounds.minY + leading.height), anchor: .topLeading,
                              proposal: ProposedViewSize(width: min(cache.trailing.width, bounds.width - indent),
                                                         height: nil))
        }
    }
}

/// A list item that opens its detail page when clicked anywhere but on its own controls.
struct OpeningListItem<Name: View, Trailing: View>: View {
    let disc: FamilyDisc
    @ViewBuilder var name: Name
    let sub: Text?
    var openLabel: Text
    let open: () -> Void
    @ViewBuilder var trailing: Trailing
    @State private var isHovered = false

    var body: some View {
        TrailingLayout(spacing: 12, indent: TrailingLayout.wordsInset) {
            Button(action: open) {
                ListItem(disc: disc, name: { name }, sub: sub, trailing: { EmptyView() }, isHovered: isHovered)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .accessibilityLabel(openLabel)
            HStack(spacing: 0) { trailing }
        }
    }
}

/// "Name ›": a row that opens a page or a sheet.
struct NavigationLine: View {
    let title: Text
    var value: Text?
    var isEnabled = true
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                title
                    .textStyle(.navRow)
                    .foregroundStyle(isEnabled ? Palette.ink : Palette.inkDisabled)
                    .underline(isHovered && isEnabled, color: Palette.ink.opacity(0.25).color)
                Spacer(minLength: 0)
                if let value {
                    value
                        .textStyle(.itemEnd)
                        .foregroundStyle(isEnabled ? Palette.inkMuted : Palette.inkDisabled)
                }
                IconView(icon: .forward, size: 18)
                    .foregroundStyle(Palette.inkDisabled)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A line of a log: when and what on the left, the result on the right.
struct LogLine: View {
    let event: Text
    let result: Text
    let resultColor: RGBA

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            event
                .textStyle(.logEvent)
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
            result
                .textStyle(.logResult)
                .foregroundStyle(resultColor)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

/// An empty page: a disc, what the page will allow, and the button that adds the first one.
struct EmptyPageHero<Extra: View, Action: View>: View {
    let disc: FamilyDisc
    let title: Text
    let text: Text
    @ViewBuilder var extra: Extra
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 10) {
            disc
            title
                .textBox(.heroTitle)
                .foregroundStyle(Palette.ink)
            text
                .textBox(.heroText)
                .foregroundStyle(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
            extra
            action
                .padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(EdgeInsets(top: 30, leading: 28, bottom: 26, trailing: 28))
        .background(Palette.white, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .strokeBorder(Palette.cardOutline, lineWidth: 1))
    }
}

/// A thin progress bar: 6 points, blue.
struct ProgressTrack: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: Radius.progress, style: .continuous)
                .fill(Palette.trackSoft)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Radius.progress, style: .continuous)
                        .fill(Palette.azure)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// An address or a few lines to paste elsewhere, in a fixed-width font, selectable.
struct CodeText: View {
    let text: String
    var lineLimit: Int?

    var body: some View {
        Text(verbatim: text)
            .textStyle(.address)
            .foregroundStyle(Palette.ink)
            .lineLimit(lineLimit)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
    }
}

// MARK: - Controls

/// The switch: 46 × 28, grey when off, turquoise when on, the thumb's position telling the state too. 45 % when
/// disabled.
struct WindowSwitchStyle: ToggleStyle {
    /// The switch alone, its label left to VoiceOver (`BareSwitch`).
    var labelHidden = false

    func makeBody(configuration: Configuration) -> some View {
        WindowSwitch(configuration: configuration, labelHidden: labelHidden)
    }

    private struct WindowSwitch: View {
        let configuration: ToggleStyleConfiguration
        let labelHidden: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            HStack(spacing: 16) {
                if !labelHidden {
                    configuration.label
                    Spacer(minLength: 0)
                }
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
                    .opacity(isEnabled ? 1 : 0.45)
                    .contentShape(Capsule())
                    .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(configuration.isOn ? Text("On") : Text("Off"))
            .accessibilityAction { if isEnabled { configuration.isOn.toggle() } }
        }
    }
}

/// A switch alone, at the end of a list item: its label is for VoiceOver only.
struct BareSwitch: View {
    let label: Text
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { label }
            .toggleStyle(WindowSwitchStyle(labelHidden: true))
            .fixedSize()
            .accessibilityLabel(label)
    }
}

/// Two choices: the chosen one white and raised. Each segment as wide as its words.
struct WindowSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: LocalizedStringKey)]
    let label: Text
    /// Its track as wide as its place, the segments at its start (in a sheet, under a field's label).
    var fills = false
    /// Options not built yet: greyed, "Soon", as the sidebar shows a page not built yet.
    var soon: Set<Value> = []

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let isOn = option.value == selection
                let isSoon = soon.contains(option.value)
                Button { selection = option.value } label: {
                    (isSoon ? Text(option.title) + Text(verbatim: " · ") + Text("Soon") : Text(option.title))
                        .textStyle(isOn ? .control : .controlOff)
                        .foregroundStyle(isOn ? Palette.ink : isSoon ? Palette.inkDisabled : Palette.inkMuted)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 16)
                        .frame(height: 32)
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
                .disabled(isSoon)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(maxWidth: fills ? .infinity : nil, alignment: .leading)
        .background(Palette.trackSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .fixedSize(horizontal: !fills, vertical: true)
        .animation(.easeOut(duration: Timing.ui), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// A pop-up menu drawn like the design's: its value in bold and up and down chevrons. As wide as its value; narrower,
/// with its value cut short, when the window leaves it less.
struct PopUpMenu<Items: View>: View {
    let title: Text
    var label: Text?
    @ViewBuilder var items: Items

    var body: some View {
        Menu {
            items
        } label: {
            MenuFieldLabel(title: title)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(label.map { $0 + Text(verbatim: " : ") + title } ?? title)
    }
}

/// A keyboard shortcut, as a key: 30 points.
struct ShortcutKey: View {
    let title: Text

    var body: some View {
        title
            .textStyle(.key)
            .foregroundStyle(Palette.ink)
            .fixedSize()
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Palette.white, in: RoundedRectangle(cornerRadius: Radius.key, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.key, style: .continuous)
                .strokeBorder(Palette.ink.opacity(0.14), lineWidth: 1))
    }
}

/// A field of the window: 40 points on `field`, a fixed-width font for an address or a command, a red outline when
/// refused.
struct WindowField: ViewModifier {
    var mono = false
    var isRefused = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .textStyle(mono ? .fieldMono : .field)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
            .overlay {
                if isRefused {
                    RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                        .strokeBorder(Palette.danger, lineWidth: 2)
                }
            }
    }
}

extension View {
    func windowField(mono: Bool = false, isRefused: Bool = false) -> some View {
        modifier(WindowField(mono: mono, isRefused: isRefused))
    }
}

/// A field's placeholder, in `ink-disabled` as in the design.
func placeholder(_ text: Text) -> Text {
    text.foregroundStyle(Palette.inkDisabled)
}

/// A field with its label above it.
struct LabeledField<Field: View>: View {
    let label: Text
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            label
                .textBox(.fieldLabel)
                .foregroundStyle(Palette.inkMuted)
                .padding(.leading, 2)
            field
        }
        .padding(.bottom, 14)
    }
}

// MARK: - Buttons

/// The window's 34-point pills: white with a hairline for common actions, blue for a link, red-tinted for a removal,
/// solid red to confirm one in a sheet, and the 44-point ink one (one per window or sheet). `big`: 40 points.
struct WindowButtonStyle: ButtonStyle {
    enum Kind { case glass, link, danger, solidDanger, main }

    var kind = Kind.glass
    var big = false

    func makeBody(configuration: Configuration) -> some View {
        WindowPill(kind: kind, big: big, isPressed: configuration.isPressed) { configuration.label }
    }

    private struct WindowPill<Label: View>: View {
        let kind: Kind
        let big: Bool
        let isPressed: Bool
        @ViewBuilder let label: Label
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            label
                .textStyle(kind == .main ? .mainButton : .smallButton)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(foreground)
                .padding(.leading, leading)
                .padding(.trailing, trailing)
                .frame(height: height)
                .background(background, in: Capsule())
                .overlay {
                    if kind == .glass, isEnabled { Capsule().strokeBorder(Palette.ink.opacity(0.14), lineWidth: 1) }
                }
                .contentShape(Capsule())
                .scaleEffect(isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: Timing.press), value: isPressed)
                .animation(.easeOut(duration: Timing.ui), value: isHovered)
                .onHover { isHovered = $0 && isEnabled }
        }

        private var height: CGFloat { kind == .main ? 44 : big ? 40 : 34 }
        private var leading: CGFloat { kind == .main ? 24 : big ? 14 : 16 }
        private var trailing: CGFloat { kind == .main ? 24 : big ? 18 : 16 }

        private var foreground: RGBA {
            guard isEnabled else { return Palette.inkDisabled }
            switch kind {
            case .glass: return Palette.ink
            case .link: return Palette.link
            case .danger: return Palette.danger
            case .solidDanger, .main: return Palette.onInk
            }
        }

        private var background: RGBA {
            guard isEnabled else { return Palette.fieldDisabled }
            switch kind {
            case .glass: return isHovered ? Palette.glassHover : Palette.white
            case .link: return Palette.azure.opacity(isHovered ? 0.2 : 0.12)
            case .danger: return isHovered ? Palette.dangerHover : Palette.dangerSoft
            case .solidDanger: return isHovered ? Palette.solidDangerHover : Palette.danger
            case .main: return isHovered ? Palette.inkHover : Palette.ink
            }
        }
    }
}

/// A button's words with an icon before them.
struct IconLabel: View {
    let title: Text
    let icon: Icon

    init(_ key: LocalizedStringKey, icon: Icon) {
        title = Text(key)
        self.icon = icon
    }

    init(_ title: Text, icon: Icon) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 8) {
            IconView(icon: icon, size: 18)
            title
        }
    }
}

/// The 40-point round button: back, close.
struct RoundButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundButton(isPressed: configuration.isPressed) { configuration.label }
    }

    private struct RoundButton<Label: View>: View {
        let isPressed: Bool
        @ViewBuilder let label: Label
        @State private var isHovered = false

        var body: some View {
            label
                .foregroundStyle(Palette.ink)
                .frame(width: 40, height: 40)
                .background(isHovered ? Palette.white : Palette.white.opacity(0.8), in: Circle())
                .overlay(Circle().strokeBorder(Palette.ink.opacity(0.1), lineWidth: 1))
                .contentShape(Circle())
                .scaleEffect(isPressed ? 0.95 : 1)
                .animation(.easeOut(duration: Timing.press), value: isPressed)
                .animation(.easeOut(duration: Timing.ui), value: isHovered)
                .onHover { isHovered = $0 }
        }
    }
}

/// A small round button without a background, for an item's own action: remove a folder, open a detail page.
struct SmallRoundButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SmallRound { configuration.label }
    }

    private struct SmallRound<Label: View>: View {
        @ViewBuilder let label: Label
        @State private var isHovered = false

        var body: some View {
            label
                .foregroundStyle(isHovered ? Palette.ink : Palette.inkMuted)
                .frame(width: 32, height: 32)
                .background(isHovered ? Palette.ink.opacity(0.07) : RGBA(rgba: 0), in: Circle())
                .contentShape(Circle())
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Sheet

/// A modal sheet over the window: 560 points wide (460 for a confirmation), on a veil of ink at 30 %. Its title, a
/// sentence, what it needs, and its buttons at the bottom right.
struct SheetCard<Content: View, Footer: View>: View {
    var width: CGFloat = 560
    let title: Text
    var text: Text?
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title
                .textBox(.sheetTitle)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let text {
                text
                    .textBox(.sheetText)
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            content
            HStack(spacing: 10) { footer }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 20)
        }
        .padding(EdgeInsets(top: 26, leading: 28, bottom: 24, trailing: 28))
        .frame(width: width, alignment: .leading)
        .background(Palette.sheet, in: RoundedRectangle(cornerRadius: Radius.window, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.window, style: .continuous)
            .stroke(RGBA(0x000000).opacity(0.18), lineWidth: 0.5))
        .shadow(color: Palette.ink.opacity(0.3).color, radius: 35, y: 30)
        .shadow(color: Palette.ink.opacity(0.12).color, radius: 10, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// A choice in a sheet: its disc, its name and what it means; a 2-point outline when hovered.
struct SheetChoice: View {
    let disc: FamilyDisc
    let title: Text
    let detail: Text
    /// False for a choice not built yet: greyed, "Soon", as the sidebar shows a page not built yet.
    var isEnabled = true
    let choose: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 16) {
                disc
                    .opacity(isEnabled ? 1 : 0.5)
                VStack(alignment: .leading, spacing: 0) {
                    title
                        .textStyle(.rowTitle)
                        .foregroundStyle(isEnabled ? Palette.ink : Palette.inkDisabled)
                    detail
                        .textStyle(.rowSub)
                        .foregroundStyle(isEnabled ? Palette.inkMuted : Palette.inkDisabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if isEnabled {
                    IconView(icon: .forward, size: 18)
                        .foregroundStyle(Palette.inkDisabled)
                } else {
                    Text("Soon")
                        .textStyle(.sidebarCount)
                        .foregroundStyle(Palette.inkDisabled)
                }
            }
            .padding(16)
            .background(Palette.white, in: RoundedRectangle(cornerRadius: Radius.choice, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.choice, style: .continuous)
                .strokeBorder(isHovered ? Palette.ink : Palette.ink.opacity(0.1), lineWidth: isHovered ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Radius.choice, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 && isEnabled }
        .animation(.easeOut(duration: Timing.ui), value: isHovered)
    }
}

/// Numbered steps: 1, 2… in ink discs.
struct NumberedSteps: View {
    let steps: [Text]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(steps.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 12) {
                    Text(verbatim: "\(i + 1)")
                        .textStyle(.stepNumber)
                        .foregroundStyle(Palette.onInk)
                        .frame(width: 22, height: 22)
                        .background(Palette.ink, in: Circle())
                    steps[i]
                        .textBox(.step)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }
            }
        }
    }
}
