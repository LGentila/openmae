import AppKit
import SwiftUI
import VoiceCore

/// The conversation so far, opened from the clock button of the top bar: what the user said and what Maé
/// answered, the latest at the bottom. Below it, the tasks handed to Claude Code, with their result.
struct HistoryPanel: View {
    let entries: [TranscriptEntry]
    var tasks: [AgentTask] = []
    var stopTask: (UUID) -> Void = { _ in }

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
            if !tasks.isEmpty {
                SectionTitle("Tasks")
                PanelBlock(padding: EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)) {
                    ForEach(tasks) { task in
                        if task.id != tasks.first?.id { Hairline() }
                        TaskRow(task: task) { stopTask(task.id) }
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

/// A task: its title, its agent and where it stands; a click shows the instruction, the result and what the agent
/// was not allowed to do. A task waiting for the user's "oui" shows its instruction at once: it is what would be sent.
private struct TaskRow: View {
    let task: AgentTask
    let stop: () -> Void
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { isOpen.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: task.title.prefix(1).uppercased() + task.title.dropFirst())
                            .textStyle(.setting)
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        HelpText(Text(verbatim: subtitle))
                    }
                    Spacer(minLength: 0)
                    TaskText.status(task.status)
                        .textStyle(.chip)
                        .foregroundStyle(statusColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? Text("Hides the details") : Text("Shows the details"))
            if isOpen || task.status == .awaitingConfirmation {
                details
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            detail(Text("Instruction"), ([task.instruction] + task.followUps).joined(separator: "\n\n"))
            if task.status == .running, let step = task.lastStep {
                detail(Text("Latest step"), TaskText.step(step))
            }
            if let result = task.resultText, !result.isEmpty {
                detail(Text("Result"), result, markdown: true)
            }
            if let failure = task.failure {
                detail(Text("What went wrong"), TaskText.failure(failure))
            }
            if !task.permissionDenials.isEmpty {
                detail(Text("Not allowed without your OK"), task.permissionDenials.joined(separator: "\n"))
            }
            if task.status == .running || task.folder != nil {
                HStack(spacing: 8) {
                    if let folder = task.folder {
                        Button("Open the folder") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: folder, isDirectory: true))
                        }
                        .buttonStyle(PillButtonStyle(kind: .link))
                    }
                    if task.status == .running {
                        Button("Stop", action: stop)
                            .buttonStyle(PillButtonStyle(kind: .destructive))
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func detail(_ title: Text, _ text: String, markdown: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            title
                .textStyle(.chip)
                .foregroundStyle(Palette.inkMuted)
            Group {
                if markdown, let rich = try? AttributedString(
                    markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
                {
                    Text(rich)
                } else {
                    Text(verbatim: text)
                }
            }
            .textStyle(.label)
            .foregroundStyle(Palette.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Claude Code · 12 minutes ago".
    private var subtitle: String {
        let since = task.endedAt ?? task.startedAt ?? task.createdAt
        return "\(task.agentName) · " + since.formatted(.relative(presentation: .named).locale(TaskText.locale))
    }

    private var statusColor: RGBA {
        switch task.status {
        case .finished: Palette.success
        case .failed: Palette.danger
        case .running, .awaitingConfirmation: Palette.link
        case .cancelled, .interrupted: Palette.inkMuted
        }
    }
}

/// The wording of the tasks, in the interface's language.
enum TaskText {
    /// The language the interface shows (not necessarily the Mac's: a German Mac gets the French interface).
    static var locale: Locale { Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en") }

    private static var language: SpeechLanguage { locale.language.languageCode == .french ? .french : .english }

    static func status(_ status: AgentTask.Status) -> Text {
        switch status {
        case .awaitingConfirmation: Text("Waiting for your yes")
        case .running: Text("In progress")
        case .finished: Text("Finished")
        case .failed: Text("Failed")
        case .cancelled: Text("Stopped")
        case .interrupted: Text("Interrupted")
        }
    }

    /// "modification de index.html": as Maé says it.
    static func step(_ step: AgentStep) -> String {
        AgentPhrases.describe(step, language)
    }

    static func failure(_ failure: AgentTask.Failure) -> String {
        switch failure {
        case .notLoggedIn: String(localized: "Claude Code isn’t signed in. Open it once in Terminal to sign in.")
        case .agent(let message): message
        case .couldNotStart(let reason): String(localized: "Claude Code could not be started (\(reason)).")
        case .stoppedWithoutResult: String(localized: "Claude Code stopped without giving a result.")
        }
    }
}
