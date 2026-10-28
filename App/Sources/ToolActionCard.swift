import SwiftUI
import VoiceCore

/// Under Maé's sentence, what a connected tool does for the request under way (`AssistantModel.toolActions`). While its
/// action waits for the user's "oui": the tool's disc, its name and what it will do (« Allumer · Salon »), with "Non" and
/// "Oui", which answer as saying it does. Then what came of it: « Salon allumé », « Home Assistant · à l’instant », and
/// "Fait", "Refusé" or "Échec". The actions of one request share a line (rarely, one that waits and one done at once:
/// two lines).
struct ToolActionCard: View {
    let model: AssistantModel

    /// As wide as the sentence's column, with room on either side.
    static let width: CGFloat = 580

    var body: some View {
        let waiting = model.toolActions.filter { $0.status == .waiting }
        let finished = model.toolActions.filter { $0.status != .waiting }
        VStack(spacing: 12) {
            if !waiting.isEmpty { WaitingLine(model: model, actions: waiting) }
            if !waiting.isEmpty, !finished.isEmpty { Hairline() }
            if !finished.isEmpty { FinishedLine(actions: finished) }
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 14))
        .frame(maxWidth: Self.width)
        .background(Palette.white, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .cardShadow()
    }
}

/// The tool's disc, its name and what it will do; "Non" and "Oui".
private struct WaitingLine: View {
    let model: AssistantModel
    let actions: [ConnectedToolAction]

    var body: some View {
        let disc = Self.disc(actions[0], settings: model.settings.connectedTools)
        HStack(spacing: 14) {
            FamilyDisc(icon: disc.icon, color: disc.color, size: 48)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: Self.names(actions))
                    .textStyle(.rowTitle)
                    .foregroundStyle(Palette.ink)
                Text(verbatim: actions.map(Self.doing).joined(separator: ", "))
                    .textStyle(.cardDetail)
                    .foregroundStyle(Palette.inkMuted)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button { model.answerToolAction(false) } label: { Text("No") }
                .buttonStyle(WindowButtonStyle(kind: .glass))
            Button { model.answerToolAction(true) } label: { Text("Yes") }
                .buttonStyle(WindowButtonStyle(kind: .main))
        }
        .disabled(model.isAnsweringToolAction)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Maé asks you to confirm"))
    }

    /// The tool's disc as its settings show it; Home Assistant's if it was removed meanwhile.
    static func disc(_ action: ConnectedToolAction, settings: [ConnectedToolSettings]) -> (icon: Icon, color: RGBA) {
        let index = settings.firstIndex { $0.id == action.toolID }
        let tool = index.map { settings[$0] }
            ?? ConnectedToolSettings(id: action.toolID, name: action.toolName, address: "", access: .none)
        return ConnectedToolsAccess.disc(tool, index: index ?? 0)
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
            case .done: FamilyDisc(icon: .check, color: Palette.mint, size: 48)
            case .refused: FamilyDisc(icon: .cancel, color: Palette.fieldDisabled, size: 48, iconColor: Palette.inkMuted)
            case .failed: FamilyDisc(icon: .warning, color: Palette.dangerSoft, size: 48, iconColor: Palette.danger)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: actions.map { $0.status == .done ? $0.words.result ?? $0.title : $0.title }
                    .joined(separator: ", "))
                    .textStyle(.rowTitle)
                    .foregroundStyle(Palette.ink)
                TimelineView(.periodic(from: .now, by: 15)) { timeline in
                    (Text(verbatim: WaitingLine.names(actions) + " · ") + Self.when(actions.map(\.date).max() ?? .now,
                                                                                    now: timeline.date))
                        .textStyle(.cardDetail)
                        .foregroundStyle(Palette.inkMuted)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            switch outcome {
            case .done: StatusPill(text: Text("Completed"), style: .success)
            case .refused: StatusPill(text: Text("Declined"), style: .neutral)
            case .failed: StatusPill(text: Text("Failure"), style: .refused)
            }
        }
        .frame(minHeight: 48)
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

extension TextStyle {
    /// The card's second line.
    static let cardDetail = TextStyle(.sans, 13.5, weight: 400, lineHeight: 18)
}
