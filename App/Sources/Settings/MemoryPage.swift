import SwiftUI
import VoiceCore

/// Settings › Memory: the memory's switch, named after what it does. With it on: the past conversations, their switch
/// named after what it keeps, how long they are kept and how many exchanges are; what Maé remembers (newest first, ten at
/// a time, each entry can be deleted); erasing the past conversations, or everything. Everything stays on this Mac, in
/// the memory's folder. While the model that finds a past conversation asked about in other words downloads (the past
/// conversations on, the model not on this Mac yet), a note under the introduction says so, with its progress.
///
/// The past conversations (the journal) are offered with every tier's model (`MemorySettings.journalOffered(on:)`): with
/// a tier that would not offer them, their switch would be off and disabled, nothing more shown of them, and the saved
/// switch would stay as it is.
struct MemoryPage: View {
    @Bindable var model: AssistantModel
    let navigation: SettingsNavigation

    private var memory: MemorySettings { model.settings.memory }

    /// The tier's model offers the journal; not known yet (the engine has not said its tier), it does.
    private var journalOffered: Bool { model.tier.map { MemorySettings.journalOffered(on: $0) } ?? true }

    /// Off on a tier that does not offer the journal, whatever is saved.
    private var journalSwitch: Binding<Bool> {
        journalOffered ? $model.settings.memory.journal : .constant(false)
    }

    var body: some View {
        SettingsPageScroll {
            PageHead(Text("Memory"))
            PageIntro("Maé can remember what you tell her, from one conversation to the next. Everything stays on your Mac, in a folder of its own, and never goes to the internet.")
            // As Settings › Advanced shows the first download of the models: a note, then its progress bar.
            if memory.enabled, memory.journal, journalOffered, let download = model.journalSearchDownload {
                Note(Self.downloading(download))
                    .padding(.top, 16)
                ProgressTrack(fraction: download.fraction)
                    .padding(EdgeInsets(top: 10, leading: 4, bottom: 0, trailing: 4))
            }
            PageSection("Setting")
            SettingsCard {
                SwitchRow("Remember when you ask", isOn: $model.settings.memory.enabled)
                    .accessibilityLabel(Text("Memory"))
                Caption("Say “remember that…”: Maé keeps it here and uses it when it helps, in every conversation.")
            }
            if memory.enabled {
                PageSection("Past conversations")
                SettingsCard { journalRows }
                PageSection("What Maé remembers")
                SettingsCard { entries }
                PageSection("Erase")
                SettingsCard {
                    ActionRow(top: 14, bottom: 14) {
                        if journalOffered, (model.memory?.exchanges ?? 0) > 0 {
                            Button("Erase past conversations…") { navigation.sheet = .clearMemoryJournal }
                                .buttonStyle(WindowButtonStyle(kind: .danger))
                        }
                        Button("Erase everything…") { navigation.sheet = .eraseMemory }
                            .buttonStyle(WindowButtonStyle(kind: .danger))
                    }
                    Caption("The models are not touched, and deleting the models never erases the memory.")
                }
            }
        }
        .onAppear { model.refreshMemory() }
    }

    /// The journal's switch, what it keeps and why; then, on, how long and how many.
    @ViewBuilder private var journalRows: some View {
        SwitchRow("Keep past conversations", isOn: journalSwitch)
            .disabled(!journalOffered)
        Caption("Your words and Maé’s answers, so that she can find a conversation again when you ask her about it.")
        if journalOffered, memory.journal {
            Hairline()
            SettingRow("Keep for") { retentionMenu }
            if let count = model.memory?.exchanges {
                Caption(Self.kept(count))
            }
        }
    }

    private var retentionMenu: some View {
        PopUpMenu(title: Self.name(memory.retention), label: Text("Keep past conversations for")) {
            Picker(selection: $model.settings.memory.retention) {
                ForEach(MemoryRetention.allCases, id: \.self) { retention in
                    Self.name(retention).tag(retention)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    static func name(_ retention: MemoryRetention) -> Text {
        switch retention {
        case .thirtyDays: Text("30 days")
        case .oneYear: Text("1 year")
        case .unlimited: Text("Unlimited")
        }
    }

    /// The model that finds a past conversation asked about in other words, downloading (once the past conversations are
    /// on, if this Mac does not have it yet): what it is for, in plain words, and how far it got. Nothing once it is in
    /// place.
    static func downloading(_ download: DownloadProgress) -> Text {
        let progress = Text("Maé is downloading what she needs to find a conversation even when you talk about it in other words: \(Units.percent(download.fraction)) of \(Units.bytes(download.totalBytes)).")
        guard download.waitingForNetwork else { return progress }
        return progress + Text(verbatim: " ")
            + Text("Connection lost. The download will resume by itself as soon as the Internet is back.")
    }

    /// How many exchanges the journal holds so far, said as a count of what she kept: under "Keep for", "5 exchanges
    /// kept" read as a limit.
    static func kept(_ count: Int) -> Text {
        switch count {
        case 0: Text("Maé has kept nothing yet.")
        case 1: Text("So far, Maé has kept one exchange.")
        default: Text("So far, Maé has kept \(Units.count(count)) exchanges.")
        }
    }

    /// The sheet, newest first, one row per entry, each with its delete button; then how full it is.
    @ViewBuilder private var entries: some View {
        let entries = Array((model.memory?.entries ?? []).reversed())
        if entries.isEmpty {
            Caption("Nothing yet. Say “remember that…” and Maé keeps it here.")
                .padding(.top, 20)
        } else {
            PagedList(items: entries) { page in
                ForEach(page, id: \.self) { entry in
                    if entry != page.first { Hairline() }
                    EntryRow(entry: entry) { model.forgetMemoryEntry(entry) }
                }
            }
            Hairline()
            if let memory = model.memory {
                Caption(Text("\(Units.count(memory.characters)) of \(Units.count(memory.capacity)) characters used."))
                    .padding(.top, 14)
            }
        }
    }

    static func badge(_ model: AssistantModel) -> SidebarBadge {
        model.settings.memory.enabled ? .dot(.on, Text("On")) : .dot(.off, Text("Off"))
    }
}

/// An entry of the sheet, with its delete button.
private struct EntryRow: View {
    let entry: String
    let forget: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(verbatim: entry)
                .textStyle(.setting)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: forget) {
                IconView(icon: .cancel, size: 16)
            }
            .buttonStyle(SmallRoundButtonStyle())
            .accessibilityLabel(Text("Forget “\(entry)”"))
        }
        .frame(minHeight: 58)
    }
}

/// "Erase past conversations?": the journal is erased; what Maé remembers stays.
struct ClearMemoryJournalSheet: View {
    @Bindable var model: AssistantModel
    let navigation: SettingsNavigation

    var body: some View {
        SheetCard(width: 460, title: Text("Erase past conversations?"),
                  text: Text("Every exchange kept is erased from this Mac. What Maé remembers stays."))
        {
            EmptyView()
        } footer: {
            Button("Cancel") { navigation.sheet = nil }
                .buttonStyle(WindowButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Erase") {
                navigation.sheet = nil
                model.clearMemoryJournal()
            }
            .buttonStyle(WindowButtonStyle(kind: .solidDanger))
        }
    }
}

/// "Erase everything?": what Maé remembers, and the past conversations kept, on this tier or another.
struct EraseMemorySheet: View {
    @Bindable var model: AssistantModel
    let navigation: SettingsNavigation

    var body: some View {
        SheetCard(width: 460, title: Text("Erase everything?"),
                  text: Text("What Maé remembers and the past conversations she keeps are erased from this Mac."))
        {
            EmptyView()
        } footer: {
            Button("Cancel") { navigation.sheet = nil }
                .buttonStyle(WindowButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Erase") {
                navigation.sheet = nil
                model.eraseMemory()
            }
            .buttonStyle(WindowButtonStyle(kind: .solidDanger))
        }
    }
}
