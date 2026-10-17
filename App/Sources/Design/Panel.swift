import SwiftUI

/// A panel opened from a round button of the top bar (settings, conversation): 430 points wide, translucent
/// cream over a blur, with a small point towards its button. It scrolls when the window is too short.
struct PanelChrome<Content: View>: View {
    /// Horizontal position of the point, from the panel's leading edge.
    var pointerX: CGFloat
    var maxHeight: CGFloat
    /// Opens scrolled to the end (the conversation: the latest exchange).
    var startsAtBottom = false
    /// The page it shows: when another one replaces it, the panel goes back to its top. Nil: left where it is.
    var page: AnyHashable?
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    static var width: CGFloat { 430 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.window, style: .continuous)
        ScrollViewReader { scroll in
            ScrollView {
                content
                    .padding(14)
                    .background(alignment: .top) { Color.clear.frame(height: 1).id(PanelTop.id) }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .onChange(of: page) { _, page in
                if page != nil { scroll.scrollTo(PanelTop.id, anchor: .top) }
            }
        }
        .defaultScrollAnchor(startsAtBottom ? .bottom : .top)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: Self.width, height: max(1, min(contentHeight, maxHeight)))
        .background(Palette.panel, in: shape)
        .background(.ultraThinMaterial, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.white.opacity(0.7), lineWidth: 1))
        .overlay(shape.stroke(RGBA(0x000000).opacity(0.18), lineWidth: 0.5))
        .overlay(alignment: .topLeading) {
            UnevenRoundedRectangle(topLeadingRadius: 4, style: .continuous)
                .fill(RGBA(red: 255 / 255, green: 251 / 255, blue: 244 / 255, alpha: 0.96))
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(45))
                .offset(x: pointerX - 8, y: -7)
                .accessibilityHidden(true)
        }
        .shadow(color: Palette.ink.opacity(0.28).color, radius: 35, y: 30)
        .shadow(color: Palette.ink.opacity(0.12).color, radius: 10, y: 8)
    }
}

/// The top of a panel's content, which it scrolls back to on a new page.
private enum PanelTop {
    static let id = "panel-top"
}

/// Title of a section of a panel: "Sound", "Conversation", "Advanced".
struct SectionTitle: View {
    let title: LocalizedStringKey
    var isFirst = false

    init(_ title: LocalizedStringKey, isFirst: Bool = false) {
        self.title = title
        self.isFirst = isFirst
    }

    var body: some View {
        Text(title)
            .textStyle(.section)
            .foregroundStyle(Palette.inkMuted)
            .padding(EdgeInsets(top: isFirst ? 4 : 8, leading: 6, bottom: 2, trailing: 6))
            .accessibilityAddTraits(.isHeader)
    }
}

/// The white block of a section.
struct PanelBlock<Content: View>: View {
    var padding = EdgeInsets(top: 2, leading: 16, bottom: 8, trailing: 16)
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.cardStrong, in: RoundedRectangle(cornerRadius: Radius.section, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.section, style: .continuous)
                .strokeBorder(Palette.line, lineWidth: 1))
    }
}

/// A line of help under a setting.
struct HelpText: View {
    let text: Text
    var color = Palette.inkMuted

    init(_ key: LocalizedStringKey, color: RGBA = Palette.inkMuted) {
        text = Text(key)
        self.color = color
    }

    init(_ text: Text, color: RGBA = Palette.inkMuted) {
        self.text = text
        self.color = color
    }

    var body: some View {
        text
            .textStyle(.help)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
