import SwiftUI
import VoiceCore

/// The quick panel, under the top bar's round button: only what changes often (the output, how to talk, the actions
/// and the search), a line to the agents (and, greyed until it exists, to the connected tools), "New conversation", and
/// "All settings…", which opens the settings window.
struct QuickPanel: View {
    @Bindable var model: AssistantModel
    let close: () -> Void
    /// Opens the settings window, on a page.
    let openSettings: (SettingsNavigation.Page?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Audio", isFirst: true)
            QuickCard {
                row("Output") { OutputChoice(model: model) }
                Hairline()
                row("How to talk") { ListeningMenu(model: model) }
            }
            SectionTitle("What Maé can do")
            QuickCard {
                switchRow("Actions", isOn: $model.settings.actionsEnabled)
                Hairline()
                switchRow("Search the internet", isOn: $model.settings.webSearch.enabled)
                Hairline()
                switchRow("Weather, rates and travel times", isOn: $model.settings.builtInSources)
                Hairline()
                NavigationLine(title: Text("Agents"), value: AgentsPage.summary(model)) { openSettings(.agents) }
                Hairline()
                NavigationLine(title: Text("Connected tools"), value: Text("Soon"),
                               isEnabled: ConnectedToolsAccess.isAvailable) { openSettings(.tools) }
            }
            QuickCard {
                Button {
                    model.newConversation()
                    close()
                } label: {
                    HStack(spacing: 10) {
                        IconView(icon: .chat, size: 18)
                        Text("New conversation")
                            .textStyle(.navRow)
                        Spacer(minLength: 0)
                        Text(verbatim: "⌘ N")
                            .textStyle(.capsuleKey)
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                            .background(Palette.white, in: RoundedRectangle(cornerRadius: Radius.key, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Radius.key, style: .continuous)
                                .strokeBorder(Palette.ink.opacity(0.14), lineWidth: 1))
                    }
                    .foregroundStyle(model.isReady ? Palette.ink : Palette.inkDisabled)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.isReady)
            }
            .padding(.top, 12)
            Button { openSettings(nil) } label: {
                HStack {
                    Text("All settings…")
                        .textStyle(.mainButton)
                    Spacer(minLength: 0)
                    Text(verbatim: "⌘ ,")
                        .textStyle(.capsuleKey)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Palette.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .foregroundStyle(Palette.onInk)
                .padding(.leading, 22)
                .padding(.trailing, 9)
                .frame(height: 46)
                .background(Palette.ink, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
    }

    private func row<Control: View>(_ title: LocalizedStringKey, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .textStyle(.setting)
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
            control()
        }
        .frame(minHeight: 48)
    }

    private func switchRow(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .textStyle(.setting)
                .foregroundStyle(Palette.ink)
        }
        .toggleStyle(WindowSwitchStyle())
        .frame(minHeight: 48)
    }
}

/// A block of the quick panel: white at 92 %, rounded, its rows 48 points high.
private struct QuickCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        PanelBlock(padding: EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)) { content }
    }
}
