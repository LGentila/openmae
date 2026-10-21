import SwiftUI
import VoiceCore

/// Settings › Memory: the switch; then the journal's switch and how long it keeps exchanges, what Maé remembers (each
/// entry can be deleted), and erasing the history or everything. Everything stays on this Mac, in the memory's folder.
struct MemoryPage: View {
    @Bindable var model: AssistantModel
    let navigation: SettingsNavigation

    private var memory: MemorySettings { model.settings.memory }

    var body: some View {
        SettingsPageScroll {
            PageHead(Text("Memory"))
            PageIntro("Maé remembers what you ask her to (“remember that…”), and uses it when it helps, in every new conversation. With the history on, she can also find what you told her before (“what did I tell you about…”). Everything stays on your Mac, in a folder of its own, and never goes to the internet.")
            PageSection("Setting")
            SettingsCard {
                SwitchRow("On", isOn: $model.settings.memory.enabled)
                    .accessibilityLabel(Text("Memory"))
                if !memory.enabled {
                    Caption("Turn the memory on to see what Maé remembers.")
                }
            }
            if memory.enabled {
                PageSection("History of exchanges")
                SettingsCard {
                    SwitchRow("Keep the history", isOn: $model.settings.memory.journal)
                    Caption("Your words and Maé’s answers, to find them again when you ask. Off, nothing is written.")
                    if memory.journal {
                        Hairline()
                        SettingRow("Keep for") { retentionMenu }
                        if let count = model.memory?.exchanges {
                            Caption(Text("\(count) exchanges kept."))
                        }
                    }
                }
                PageSection("What Maé remembers")
                SettingsCard { entries }
                PageSection("Erase")
                SettingsCard {
                    ActionRow(top: 14, bottom: 14) {
                        Button("Clear history…") { navigation.sheet = .clearMemoryJournal }
                            .buttonStyle(WindowButtonStyle(kind: .danger))
                        Button("Erase everything…") { navigation.sheet = .eraseMemory }
                            .buttonStyle(WindowButtonStyle(kind: .danger))
                    }
                    Caption("The models are not touched, and deleting the models never erases the memory.")
                }
            }
        }
        .onAppear { model.refreshMemory() }
    }

    private var retentionMenu: some View {
        PopUpMenu(title: Self.name(memory.retention), label: Text("Keep the history for")) {
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

    /// The sheet, one row per entry, each with its delete button.
    @ViewBuilder private var entries: some View {
        let entries = model.memory?.entries ?? []
        if entries.isEmpty {
            Caption("Nothing yet. Say “remember that…” and Maé keeps it here.")
                .padding(.top, 20)
        } else {
            ForEach(entries, id: \.self) { entry in
                HStack(spacing: 14) {
                    Text(verbatim: entry)
                        .textStyle(.setting)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        model.forgetMemoryEntry(entry)
                    } label: {
                        IconView(icon: .cancel, size: 16)
                    }
                    .buttonStyle(SmallRoundButtonStyle())
                    .accessibilityLabel(Text("Forget “\(entry)”"))
                }
                .frame(minHeight: 58)
                Hairline()
            }
            if let memory = model.memory {
                Caption(Text("\(memory.characters) of \(memory.capacity) characters used."))
                    .padding(.top, 14)
            }
        }
    }

    static func badge(_ model: AssistantModel) -> SidebarBadge {
        model.settings.memory.enabled ? .dot(.on, Text("On")) : .dot(.off, Text("Off"))
    }
}

/// "Clear the history?": the journal of past exchanges is erased; what Maé remembers stays.
struct ClearMemoryJournalSheet: View {
    @Bindable var model: AssistantModel
    let navigation: SettingsNavigation

    var body: some View {
        SheetCard(width: 460, title: Text("Clear the history?"),
                  text: Text("Every exchange kept is erased from this Mac. What Maé remembers stays."))
        {
            EmptyView()
        } footer: {
            Button("Cancel") { navigation.sheet = nil }
                .buttonStyle(WindowButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Clear") {
                navigation.sheet = nil
                model.clearMemoryJournal()
            }
            .buttonStyle(WindowButtonStyle(kind: .solidDanger))
        }
    }
}

/// "Erase everything?": what Maé remembers and the history.
struct EraseMemorySheet: View {
    @Bindable var model: AssistantModel
    let navigation: SettingsNavigation

    var body: some View {
        SheetCard(width: 460, title: Text("Erase everything?"),
                  text: Text("What Maé remembers and the history of exchanges are erased from this Mac."))
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
