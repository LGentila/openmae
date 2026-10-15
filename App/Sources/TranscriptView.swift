import SwiftUI
import VoiceCore

/// The live transcript: what the user said (right) and what the assistant answers (left).
struct TranscriptView: View {
    let entries: [TranscriptEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(entries) { entry in
                        EntryRow(entry: entry).id(entry.id)
                    }
                }
                .padding()
            }
            .onChange(of: entries.last?.text) { scrollToEnd(proxy) }
            .onChange(of: entries.count) { scrollToEnd(proxy) }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("The conversation will appear here", systemImage: "text.bubble",
                                       description: Text("Say hello to get started."))
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = entries.last else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
    }
}

private struct EntryRow: View {
    let entry: TranscriptEntry

    var body: some View {
        let isUser = entry.speaker == .user
        HStack {
            if isUser { Spacer(minLength: 48) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                if entry.pending {
                    Text(verbatim: "…")
                        .font(.body.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(bubble(isUser))
                } else {
                    Text(entry.text + (entry.interrupted ? " —" : ""))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(bubble(isUser))
                        .foregroundStyle(isUser ? Color.white : Color.primary)
                }
                caption
            }
            if !isUser { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder private var caption: some View {
        if entry.interrupted {
            Text("interrupted").font(.caption2).foregroundStyle(.secondary)
        } else if entry.language == .english {
            Text("English").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func bubble(_ isUser: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isUser ? Color.accentColor : Color.secondary.opacity(0.14))
    }
}
