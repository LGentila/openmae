import SwiftUI
import VoiceCore
import VoiceEngineApple

/// Settings › Conversation › Search the internet: the switch, what leaves the Mac, the source (Brave Search, offered
/// first, or the user's own SearXNG) with the fields of the chosen one only, and a "Test" button. Brave's key and the
/// SearXNG's password are kept in the keychain. Built from the settings' usual pieces until the design draws it.
struct WebSearchRows: View {
    @Bindable var model: AssistantModel
    @State private var key = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var hasPassword = WebSearchKeychain.hasSecret(for: .searxng)
    @FocusState private var focus: Field?
    @Environment(\.openURL) private var openURL

    private enum Field { case key, address, username, password }

    /// Where Brave Search's API keys are made.
    static let braveKeys = URL(string: "https://brave.com/search/api/")!

    private var search: WebSearchSettings { model.settings.webSearch }

    var body: some View {
        Toggle(isOn: $model.settings.webSearch.enabled) {
            Text("Search the internet")
                .textStyle(.setting)
        }
        .toggleStyle(SwitchStyle())
        .frame(minHeight: 46)
        .onAppear {
            address = search.address
            username = search.username
        }
        .onChange(of: focus) { left, _ in
            if left == .address || left == .username { saveFields() }
        }
        HelpText("Maé looks up what she can’t know: the news, a score, opening hours, a price.")
            .padding(.bottom, 4)
        HelpText(Self.whatLeaves(search.source))
            .padding(.bottom, 6)
        if search.enabled {
            sourceRow
            switch search.source {
            case .brave: braveRows
            case .searxng: searxngRows
            }
            testRows
        }
    }

    // MARK: - The source

    /// A pop-up menu, like the tier's: the sources in the order they are offered.
    private var sourceRow: some View {
        HStack(spacing: 12) {
            Text("Source")
                .textStyle(.setting)
            Spacer(minLength: 0)
            Menu {
                Picker(selection: $model.settings.webSearch.source) {
                    ForEach(WebSearchSource.allCases, id: \.self) { source in
                        Self.name(source).tag(source)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                MenuFieldLabel(title: Self.name(search.source))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .frame(minHeight: 46)
    }

    static func name(_ source: WebSearchSource) -> Text {
        switch source {
        case .brave: Text(verbatim: "Brave Search")
        case .searxng: Text("Your SearXNG")
        }
    }

    static func whatLeaves(_ source: WebSearchSource) -> LocalizedStringKey {
        switch source {
        case .brave: "What you search for goes to Brave Search. The rest of the conversation stays on your Mac."
        case .searxng: "What you search for goes out on the internet: to your SearXNG, then to the search engines. The rest of the conversation stays on your Mac."
        }
    }

    // MARK: - Brave Search

    /// The key, pasted once: it goes to the keychain, and the settings only say that there is one.
    @ViewBuilder private var braveRows: some View {
        HStack(spacing: 8) {
            SecureField(text: $key, prompt: search.braveKeySaved ? Text("Key saved in the keychain") : Text("API key")) {
                Text("Brave Search API key")
            }
            .webSearchField()
            .focused($focus, equals: .key)
            .onSubmit(saveKey)
            Button("Save", action: saveKey)
                .buttonStyle(PillButtonStyle(kind: .link))
                .disabled(typedKey.isEmpty)
        }
        HelpText("Create a key on Brave’s website, then paste it here. It is kept in your Mac’s keychain.")
            .padding(.top, 6)
        HStack(spacing: 8) {
            Button("Create a key") { openURL(Self.braveKeys) }
                .buttonStyle(PillButtonStyle(kind: .link))
            if search.braveKeySaved {
                Button("Remove the key", action: removeKey)
                    .buttonStyle(PillButtonStyle(kind: .neutral))
            }
        }
        .padding(.top, 8)
    }

    private var typedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func saveKey() {
        guard !typedKey.isEmpty else { return }
        let saved = WebSearchKeychain.setSecret(typedKey, for: .brave)
        key = ""
        if search.braveKeySaved != saved {
            model.settings.webSearch.braveKeySaved = saved  // the engine reads the keychain again
        } else {
            model.webSearchSecretChanged()
        }
    }

    private func removeKey() {
        WebSearchKeychain.setSecret(nil, for: .brave)
        model.settings.webSearch.braveKeySaved = false
    }

    // MARK: - SearXNG

    /// Its address, and a user name and a password when a protection in front of it asks for them.
    @ViewBuilder private var searxngRows: some View {
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
                WebSearchKeychain.setSecret(nil, for: .searxng)
                hasPassword = false
                model.webSearchSecretChanged()
            }
            .buttonStyle(PillButtonStyle(kind: .neutral))
            .padding(.top, 8)
        }
    }

    private func saveFields() {
        address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if search.address != address { model.settings.webSearch.address = address }
        if search.username != username { model.settings.webSearch.username = username }
    }

    private func savePassword() {
        guard !password.isEmpty else { return }
        hasPassword = WebSearchKeychain.setSecret(password, for: .searxng)
        password = ""
        model.webSearchSecretChanged()
    }

    // MARK: - The test

    @ViewBuilder private var testRows: some View {
        HStack(spacing: 12) {
            Button("Test") {
                switch search.source {
                case .brave: saveKey()
                case .searxng: saveFields()
                }
                model.testWebSearch()
            }
            .buttonStyle(PillButtonStyle())
            .disabled(!canTest || model.isTestingWebSearch)
            if model.isTestingWebSearch {
                Text("Testing…")
                    .textStyle(.help)
                    .foregroundStyle(Palette.inkMuted)
            }
        }
        .padding(.top, 9)
        .padding(.bottom, 4)
        if let test = model.webSearchTest {
            HelpText(Self.describe(test, source: search.source, hasPassword: hasPassword),
                     color: Self.works(test) ? Palette.success : Palette.danger)
                .padding(.bottom, 6)
        }
    }

    /// The source is set up, or about to be (a key typed, not saved yet: the test saves it).
    private var canTest: Bool {
        switch search.source {
        case .brave: search.braveKeySaved || !typedKey.isEmpty
        case .searxng: SearXNGProvider.address(address) != nil
        }
    }

    private static func works(_ test: WebSearchTest) -> Bool {
        if case .works = test { return true }
        return false
    }

    /// What the test found, as the settings say it.
    static func describe(_ test: WebSearchTest, source: WebSearchSource, hasPassword: Bool) -> Text {
        switch (test, source) {
        case (.works(let results, let seconds), _):
            let time = Units.seconds(fromMilliseconds: seconds * 1000)
            return results == 1 ? Text("It works: one result in \(time).") : Text("It works: \(results) results in \(time).")
        case (.notSetUp, .brave):
            return Text("Paste your Brave key first.")
        case (.failed(.unauthorized), .brave), (.failed(.forbidden), .brave):
            return Text("Brave refuses your key.")
        case (.failed(.tooManyRequests), .brave):
            return Text("Your Brave key has reached its limit.")
        case (.failed(.unreachable), .brave):
            return Text("I can’t reach Brave.")
        case (.failed(.unexpected(let status)), .brave):
            return status == 200 ? Text("I can’t make sense of Brave’s answer.")
                : Text("Brave answered with an error (code \(status)).")
        case (.notSetUp, .searxng):
            return Text("Type the address of your SearXNG first.")
        case (.failed(.unauthorized), .searxng):
            return hasPassword ? Text("Your SearXNG refuses the password.")
                : Text("Your SearXNG asks for a user name and a password.")
        case (.failed(.forbidden), .searxng):
            return Text("Your SearXNG doesn’t accept programs: turn on its JSON format.")
        case (.failed(.tooManyRequests), .searxng):
            return Text("Your SearXNG takes OpenMaé for a robot: protect it with a password and turn off its bot protection.")
        case (.failed(.unreachable), .searxng):
            return Text("I can’t reach your SearXNG.")
        case (.failed(.unexpected(let status)), .searxng):
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
