import SwiftUI
import VoiceCore
import VoiceEngineApple

/// Settings › Conversation › Search the internet: the switch, what leaves the Mac, the user's SearXNG (its address, a
/// user name, a password kept in the keychain) and a "Test" button. Built from the settings' usual pieces until the
/// design draws it.
struct WebSearchRows: View {
    @Bindable var model: AssistantModel
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var hasPassword = WebSearchKeychain.hasPassword
    @FocusState private var focus: Field?

    private enum Field { case address, username, password }

    var body: some View {
        Toggle(isOn: $model.settings.webSearch.enabled) {
            Text("Search the internet")
                .textStyle(.setting)
        }
        .toggleStyle(SwitchStyle())
        .frame(minHeight: 46)
        .onAppear {
            address = model.settings.webSearch.address
            username = model.settings.webSearch.username
        }
        .onChange(of: focus) { left, _ in
            if left == .address || left == .username { saveFields() }
        }
        HelpText("Maé looks up what she can’t know: the news, a score, opening hours, a price. She goes through your own SearXNG.")
            .padding(.bottom, 4)
        HelpText("What you search for goes out on the internet: to your SearXNG, then to the search engines. The rest of the conversation stays on your Mac.")
            .padding(.bottom, 6)
        if model.settings.webSearch.enabled {
            TextField(text: $address, prompt: Text(verbatim: "https://search.example.org")) { Text("Address of your SearXNG") }
                .webSearchField()
                .focused($focus, equals: .address)
                .onSubmit(saveFields)
                .padding(.bottom, 8)
            TextField(text: $username, prompt: Text("User name, if it asks for one")) { Text("User name") }
                .webSearchField()
                .focused($focus, equals: .username)
                .onSubmit(saveFields)
                .padding(.bottom, 8)
            HStack(spacing: 8) {
                SecureField(text: $password,
                            prompt: hasPassword ? Text("Saved in the keychain") : Text("Password, if it asks for one"))
                {
                    Text("Password")
                }
                .webSearchField()
                .focused($focus, equals: .password)
                .onSubmit(savePassword)
                Button("Save", action: savePassword)
                    .buttonStyle(PillButtonStyle(kind: .link))
                    .disabled(password.isEmpty)
            }
            if hasPassword {
                Button("Remove the password") {
                    WebSearchKeychain.setPassword(nil)
                    hasPassword = false
                    model.refreshActions()  // the engine reads the keychain again
                }
                .buttonStyle(PillButtonStyle(kind: .neutral))
                .padding(.top, 8)
            }
            HStack(spacing: 12) {
                Button("Test") {
                    saveFields()
                    model.testWebSearch()
                }
                .buttonStyle(PillButtonStyle())
                .disabled(SearXNGProvider.address(address) == nil || model.isTestingWebSearch)
                if model.isTestingWebSearch {
                    Text("Testing…")
                        .textStyle(.help)
                        .foregroundStyle(Palette.inkMuted)
                }
            }
            .padding(.top, 9)
            .padding(.bottom, 4)
            if let test = model.webSearchTest {
                HelpText(Self.describe(test, hasPassword: hasPassword), color: Self.works(test) ? Palette.success : Palette.danger)
                    .padding(.bottom, 6)
            }
        }
    }

    private func saveFields() {
        let search = model.settings.webSearch
        address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if search.address != address { model.settings.webSearch.address = address }
        if search.username != username { model.settings.webSearch.username = username }
    }

    private func savePassword() {
        guard !password.isEmpty else { return }
        hasPassword = WebSearchKeychain.setPassword(password)
        password = ""
        model.refreshActions()  // the engine reads the keychain again
    }

    private static func works(_ test: WebSearchTest) -> Bool {
        if case .works = test { return true }
        return false
    }

    /// What the test found, as the settings say it.
    static func describe(_ test: WebSearchTest, hasPassword: Bool) -> Text {
        switch test {
        case .works(let results, let seconds):
            let time = Units.seconds(fromMilliseconds: seconds * 1000)
            return results == 1 ? Text("It works: one result in \(time).") : Text("It works: \(results) results in \(time).")
        case .noAddress:
            return Text("Type the address of your SearXNG first.")
        case .failed(.unauthorized):
            return hasPassword ? Text("Your SearXNG refuses the password.")
                : Text("Your SearXNG asks for a user name and a password.")
        case .failed(.forbidden):
            return Text("Your SearXNG doesn’t accept programs: turn on its JSON format.")
        case .failed(.tooManyRequests):
            return Text("Your SearXNG takes OpenMaé for a robot: protect it with a password and turn off its bot protection.")
        case .failed(.unreachable):
            return Text("I can’t reach your SearXNG.")
        case .failed(.unexpected(let status)):
            return status == 200 ? Text("This address doesn’t answer like a SearXNG.")
                : Text("This address doesn’t answer like a SearXNG (code \(status)).")
        }
    }
}

/// A text field of the settings, drawn like their pop-up menus: 34 points high, on `field`, rounded.
private struct WebSearchField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .textStyle(.label)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 34)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
    }
}

private extension View {
    func webSearchField() -> some View { modifier(WebSearchField()) }
}
