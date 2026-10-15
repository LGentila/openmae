import SwiftUI
import VoiceCore

/// The conversation so far, opened from the clock button of the top bar: what the user said and what Maé
/// answered, the latest at the bottom.
struct HistoryPanel: View {
    let entries: [TranscriptEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("This conversation", isFirst: true)
            PanelBlock(padding: EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)) {
                if entries.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("The conversation will appear here")
                            .textStyle(.setting)
                            .foregroundStyle(Palette.ink)
                        HelpText("Say hello to get started.")
                    }
                    .padding(.vertical, 12)
                } else {
                    ForEach(entries) { entry in
                        if entry.id != entries.first?.id { Hairline() }
                        EntryRow(entry: entry)
                    }
                }
            }
        }
    }
}

private struct EntryRow: View {
    let entry: TranscriptEntry

    var body: some View {
        let isUser = entry.speaker == .user
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isUser ? Palette.azure : Palette.coral)
                    .frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                (isUser ? Text("You") : Text(verbatim: "Maé"))
                    .textStyle(.chip)
                    .foregroundStyle(Palette.inkMuted)
            }
            .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.pending ? "…" : entry.text)
                    .textStyle(.label)
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if entry.interrupted {
                    HelpText("interrupted")
                } else if entry.language == .english {
                    HelpText("English")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
