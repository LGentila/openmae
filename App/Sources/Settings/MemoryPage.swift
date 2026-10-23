import SwiftUI
import VoiceCore

/// Settings › Memory: the switch, named after what it does; then what Maé remembers (newest first, ten at a time, each
/// entry can be deleted), and erasing everything. Everything stays on this Mac, in the memory's folder. The journal of
/// past exchanges is not offered in this version (`MemorySettings.journalOffered`): the page says nothing of it, and
/// "Erase everything" still erases one that is on disk.
struct MemoryPage: View {
    @Bindable var model: AssistantModel
    let navigation: SettingsNavigation

    private var memory: MemorySettings { model.settings.memory }

    var body: some View {
        SettingsPageScroll {
            PageHead(Text("Memory"))
            PageIntro("Maé can remember what you tell her, from one conversation to the next. Everything stays on your Mac, in a folder of its own, and never goes to the internet.")
            PageSection("Setting")
            SettingsCard {
                SwitchRow("Remember when you ask", isOn: $model.settings.memory.enabled)
                    .accessibilityLabel(Text("Memory"))
                Caption("Say “remember that…”: Maé keeps it here and uses it when it helps, in every conversation.")
            }
            if memory.enabled {
                PageSection("What Maé remembers")
                SettingsCard { entries }
                PageSection("Erase")
                SettingsCard {
                    ActionRow(top: 14, bottom: 14) {
                        Button("Erase everything…") { navigation.sheet = .eraseMemory }
                            .buttonStyle(WindowButtonStyle(kind: .danger))
                    }
                    Caption("The models are not touched, and deleting the models never erases the memory.")
                }
            }
        }
        .onAppear { model.refreshMemory() }
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
                // In the app's language, whatever the Mac's region: « 1 200 », "1,200".
                let number = { (count: Int) in count.formatted(.number.locale(TaskText.locale)) }
                Caption(Text("\(number(memory.characters)) of \(number(memory.capacity)) characters used."))
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

/// "Erase everything?": what Maé remembers, and the journal of past exchanges if one is on disk.
struct EraseMemorySheet: View {
    @Bindable var model: AssistantModel
    let navigation: SettingsNavigation

    var body: some View {
        SheetCard(width: 460, title: Text("Erase everything?"),
                  text: Text("Everything Maé remembers is erased from this Mac, with the history of past exchanges if there is one."))
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
