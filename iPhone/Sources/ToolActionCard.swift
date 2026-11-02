import SwiftUI
import VoiceCore

/// Under Maé's sentence, as in the Mac's window: what a connected tool does for the request under way
/// (`PhoneModel.toolActions`). While its action waits for the user's "oui": the tool's disc, its name and what it will do
/// (« Allumer · Salon »), with "Non" and "Oui" under them, sized for the thumb (beside them on a wide iPad, as on the
/// Mac); they answer as saying it does. Then what came of it: « Salon allumé », « Home Assistant · à l’instant », and
/// "Fait", "Refusé" or "Échec". The actions of one request share a line.
struct ToolActionCard: View {
    let model: PhoneModel
    /// The buttons beside the words rather than under them.
    var wide = false

    var body: some View {
        let waiting = model.toolActions.waiting
        let finished = model.toolActions.finished
        VStack(spacing: 12) {
            if !waiting.isEmpty { WaitingPart(model: model, actions: waiting, wide: wide) }
            if !waiting.isEmpty, !finished.isEmpty { Hairline() }
            if !finished.isEmpty { FinishedLine(actions: finished) }
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 14))
        .background(Palette.white, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .cardShadow()
    }

    /// Its height, for the conversation's layout.
    static func height(_ cards: ToolActionCards, wide: Bool) -> CGFloat {
        guard !cards.isEmpty else { return 0 }
        let waiting = cards.waits ? (wide ? Self.line : Self.line + 12 + Self.button) : 0
        let finished = cards.finished.isEmpty ? 0 : Self.line
        return 24 + waiting + finished + (waiting > 0 && finished > 0 ? 25 : 0)
    }

    /// A line: the disc's height.
    static let line: CGFloat = 48
    /// The buttons' height.
    static let button: CGFloat = 48
}

/// The tool's disc, its name and what it will do; "Non" and "Oui".
private struct WaitingPart: View {
    let model: PhoneModel
    let actions: [ConnectedToolAction]
    let wide: Bool

    var body: some View {
        Group {
            if wide {
                HStack(spacing: 14) {
                    words
                    buttons.fixedSize()
                }
            } else {
                VStack(spacing: 12) {
                    words
                    buttons
                }
            }
        }
        .disabled(model.toolActions.isAnswering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Maé asks you to confirm"))
    }

    private var words: some View {
        let disc = (actions[0].disc ?? ConnectedToolDisc(of: actions[0], among: [])).look
        return HStack(spacing: 14) {
            RowDisc(icon: disc.icon, color: disc.color, size: ToolActionCard.line, iconSize: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: Self.names(actions))
                    .textStyle(.phoneRowTitle)
                    .foregroundStyle(Palette.ink)
                Text(verbatim: actions.map(Self.doing).joined(separator: ", "))
                    .textStyle(.phoneRowDetail)
                    .foregroundStyle(Palette.inkMuted)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button { model.answerToolAction(false) } label: { Text("No") }
                .buttonStyle(CardButtonStyle(kind: .glass, wide: wide))
            Button { model.answerToolAction(true) } label: { Text("Yes") }
                .buttonStyle(CardButtonStyle(kind: .main, wide: wide))
        }
    }

    /// « Home Assistant », or the names of the tools of a request that asks several.
    static func names(_ actions: [ConnectedToolAction]) -> String {
        var names: [String] = []
        for action in actions where !names.contains(action.toolName) { names.append(action.toolName) }
        return names.joined(separator: ", ")
    }

    /// « Allumer · Salon ».
    static func doing(_ action: ConnectedToolAction) -> String {
        [action.words.verb, action.words.target].compactMap { $0 }.joined(separator: " · ")
    }
}

/// What came of the actions: « Salon allumé », « Home Assistant · à l’instant », and "Fait", "Refusé" or "Échec".
private struct FinishedLine: View {
    let actions: [ConnectedToolAction]

    private enum Outcome { case done, refused, failed }

    var body: some View {
        let outcome = outcome
        HStack(spacing: 14) {
            switch outcome {
            case .done: RowDisc(icon: .check, color: Palette.mint, size: ToolActionCard.line, iconSize: 24)
            case .refused:
                RowDisc(icon: .cancel, color: Palette.fieldDisabled, size: ToolActionCard.line, iconSize: 24,
                        iconColor: Palette.inkMuted)
            case .failed:
                RowDisc(icon: .warning, color: Palette.dangerSoft, size: ToolActionCard.line, iconSize: 24,
                        iconColor: Palette.danger)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: actions.map { $0.status == .done ? $0.words.result ?? $0.title : $0.title }
                    .joined(separator: ", "))
                    .textStyle(.phoneRowTitle)
                    .foregroundStyle(Palette.ink)
                TimelineView(.periodic(from: .now, by: 15)) { timeline in
                    (Text(verbatim: WaitingPart.names(actions) + " · ") + Self.when(actions.map(\.date).max() ?? .now,
                                                                                    now: timeline.date))
                        .textStyle(.phoneRowDetail)
                        .foregroundStyle(Palette.inkMuted)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            switch outcome {
            case .done: StatusChip(text: Text("Completed"), background: Palette.successSoft, color: Palette.success)
            case .refused: StatusChip(text: Text("Declined"), background: Palette.fieldDisabled, color: Palette.inkMuted)
            case .failed: StatusChip(text: Text("Failure"), background: Palette.dangerSoft, color: Palette.danger)
            }
        }
        .frame(minHeight: ToolActionCard.line)
        .accessibilityElement(children: .combine)
    }

    /// One failure is enough for "Échec"; "Refusé" when all were refused.
    private var outcome: Outcome {
        if actions.contains(where: { if case .failed = $0.status { true } else { false } }) { return .failed }
        return actions.allSatisfy { $0.status == .refusedByUser } ? .refused : .done
    }

    /// « à l’instant » for the first minute, then « il y a 3 minutes ».
    static func when(_ date: Date, now: Date) -> Text {
        now.timeIntervalSince(date) < 60 ? Text("just now")
            : Text(date, format: .relative(presentation: .named))
    }
}

/// "Fait", "Refusé", "Échec": a word on its tint, as the Mac's status pills.
private struct StatusChip: View {
    let text: Text
    let background: RGBA
    let color: RGBA

    var body: some View {
        PhoneChip(background: background, outlined: false, leading: 14) {
            text.foregroundStyle(color).lineLimit(1)
        }
        .fixedSize()
    }
}

/// The card's buttons, sized for the thumb: "Non" white with a hairline, "Oui" ink, as the Mac's card has them; side by
/// side across the card, or (`wide`) as wide as their word. Greyed while an answer is under way.
private struct CardButtonStyle: ButtonStyle {
    enum Kind { case glass, main }

    let kind: Kind
    var wide = false

    func makeBody(configuration: Configuration) -> some View {
        CardButton(kind: kind, wide: wide, isPressed: configuration.isPressed) { configuration.label }
    }

    private struct CardButton<Label: View>: View {
        let kind: Kind
        let wide: Bool
        let isPressed: Bool
        @ViewBuilder let label: Label
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            label
                .textStyle(.phoneButton)
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, 24)
                .frame(maxWidth: wide ? nil : .infinity)
                .frame(height: ToolActionCard.button)
                .background(background, in: Capsule())
                .overlay {
                    if kind == .glass, isEnabled { Capsule().strokeBorder(Palette.ink.opacity(0.14), lineWidth: 1) }
                }
                .contentShape(Capsule())
                .scaleEffect(isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: Timing.press), value: isPressed)
        }

        private var foreground: RGBA {
            guard isEnabled else { return Palette.inkDisabled }
            return kind == .main ? Palette.onInk : Palette.ink
        }

        private var background: RGBA {
            guard isEnabled else { return Palette.fieldDisabled }
            return kind == .main ? Palette.ink : Palette.white
        }
    }
}
