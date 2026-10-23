import SwiftUI
import VoiceCore
import VoiceEngineApple

/// Settings › Internet search: two capabilities, each in its own section and starting with its own switch. The web
/// search: its switch, the engine (Brave Search, offered first, or the user's own SearXNG) with the fields of the chosen
/// one only, and a test, all in one card. Then the weather, the rates and the travel times, which come from dedicated
/// services. Brave's key and the SearXNG's password are kept in the keychain.
struct WebSearchPage: View {
    @Bindable var model: AssistantModel
    let navigation: SettingsNavigation
    @State private var key = ""
    @State private var replacingKey = false
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var hasPassword = WebSearchKeychain.hasSecret(for: .searxng)
    /// "Protected by a password" switched on before anything was typed.
    @State private var protectionOn = false
    @FocusState private var focus: Field?
    @Environment(\.openURL) private var openURL

    private enum Field { case key, address, username, password }

    /// Where Brave Search's API keys are made.
    static let braveKeys = URL(string: "https://brave.com/search/api/")!

    private var search: WebSearchSettings { model.settings.webSearch }

    var body: some View {
        SettingsPageScroll {
            PageHead(Text("Search the internet"))
            PageIntro("Maé looks up what she can’t know by herself, on the web or from dedicated services. What you ask goes only to the engine or the service that answers it; the rest of the conversation stays on your Mac.")
            PageSection("Web search")
            SettingsCard {
                SwitchRow("On", isOn: $model.settings.webSearch.enabled)
                    .accessibilityLabel(Text("Web search"))
                Caption("Maé searches the web with the engine you choose: the news, a score, opening hours, a price.")
                if search.enabled {
                    Hairline()
                    SettingRow("Engine") { engineMenu }
                    Hairline()
                    switch search.source {
                    case .brave: braveRows
                    case .searxng: searxngRows
                    }
                    if canTest || model.webSearchTest != nil {
                        Hairline()
                        testRows
                    }
                }
            }
            sourcesSection
        }
        .onAppear {
            address = search.address
            username = search.username
        }
        .onChange(of: focus) { left, _ in
            switch left {
            case .address, .username: saveFields()
            case .password: savePassword()
            default: break
            }
        }
        .onChange(of: search.braveKeySaved) { replacingKey = false }
    }

    // MARK: - The built-in sources

    /// One switch for the weather, the rates and the travel times, which come from dedicated services on the internet
    /// rather than from the search's engine, with the services' credits.
    @ViewBuilder private var sourcesSection: some View {
        PageSection("Weather, rates and travel times")
        SettingsCard {
            SwitchRow("On", isOn: $model.settings.builtInSources)
                .accessibilityLabel(Text("Weather, rates and travel times"))
            Caption("Maé gives you the weather, the rate of a currency or a crypto, and travel times, through dedicated services.")
            if model.settings.builtInSources {
                if let tier = model.tier, !BuiltInSources.offered(on: tier) {
                    Caption("Not on this level yet: Maé’s model on it hasn’t been checked with these sources.", tone: .warn)
                } else {
                    Caption("For “here”, Maé uses your Mac’s location: macOS asks you the first time.")
                }
            }
            Caption("Weather data by Open-Meteo.com (CC BY 4.0). Rates of the European Central Bank, through Frankfurter. Crypto prices by CoinGecko. Travel times by Apple Maps.")
        }
    }

    // MARK: - The engine

    private var engineMenu: some View {
        PopUpMenu(title: Self.name(search.source), label: Text("Search engine")) {
            Picker(selection: $model.settings.webSearch.source) {
                ForEach(WebSearchSource.allCases, id: \.self) { source in
                    Self.name(source).tag(source)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    static func name(_ source: WebSearchSource) -> Text {
        switch source {
        case .brave: Text(verbatim: "Brave Search")
        case .searxng: Text(verbatim: "SearXNG")
        }
    }

    // MARK: - Brave Search

    /// The key, pasted once: it goes to the keychain, and the page only says that there is one.
    @ViewBuilder private var braveRows: some View {
        if search.braveKeySaved, !replacingKey {
            LabeledField(label: Text("API key")) {
                Text(verbatim: String(repeating: "•", count: 20))
                    .windowField(mono: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text("Brave API key, kept in the keychain"))
            }
            .padding(.top, 14)
            Caption("Kept in your Mac’s keychain. Create a key on Brave’s website if you want to change it.")
            ActionRow {
                Button("Replace the key…") {
                    replacingKey = true
                    focus = .key
                }
                .buttonStyle(WindowButtonStyle())
                Button("Remove the key…") { navigation.sheet = .removeBraveKey }
                    .buttonStyle(WindowButtonStyle(kind: .danger))
            }
        } else {
            LabeledField(label: Text("API key")) {
                HStack(spacing: 10) {
                    SecureField(text: $key, prompt: placeholder(Text("Paste your key here"))) { Text("Brave API key") }
                        .windowField(mono: true)
                        .focused($focus, equals: .key)
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey)
                        .buttonStyle(WindowButtonStyle())
                        .disabled(typedKey.isEmpty)
                }
            }
            .padding(.top, 14)
            if search.braveKeySaved {
                Caption("The new key replaces the old one in your Mac’s keychain.")
            } else {
                Caption("Without a key, Maé can’t search. Create a key on Brave’s website, then paste it here: it is kept in your Mac’s keychain.",
                        tone: .warn)
            }
            ActionRow {
                Button("Create a key") { openURL(Self.braveKeys) }
                    .buttonStyle(WindowButtonStyle(kind: .link))
                if replacingKey {
                    Button("Cancel") {
                        replacingKey = false
                        key = ""
                    }
                    .buttonStyle(WindowButtonStyle())
                }
            }
        }
    }

    private var typedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func saveKey() {
        guard !typedKey.isEmpty else { return }
        let saved = WebSearchKeychain.setSecret(typedKey, for: .brave)
        key = ""
        replacingKey = false
        if search.braveKeySaved != saved {
            model.settings.webSearch.braveKeySaved = saved  // the engine reads the keychain again
        } else {
            model.webSearchSecretChanged()
        }
    }

    // MARK: - SearXNG

    /// Its address, and a user name and a password when a protection in front of it asks for them.
    @ViewBuilder private var searxngRows: some View {
        LabeledField(label: Text("Address of your SearXNG")) {
            TextField(text: $address, prompt: placeholder(Text(verbatim: "https://search.example.org"))) {
                Text("Address of your SearXNG")
            }
            .windowField(mono: true)
            .focused($focus, equals: .address)
            .onSubmit(saveFields)
        }
        .padding(.top, 14)
        Hairline()
        SwitchRow("Protected by a password", isOn: Binding(get: { isProtected }, set: setProtected))
            .accessibilityLabel(Text("SearXNG protected by a password"))
        if isProtected {
            Hairline()
            HStack(alignment: .top, spacing: 12) {
                LabeledField(label: Text("User name")) {
                    TextField(text: $username, prompt: placeholder(Text(verbatim: ""))) { Text("User name") }
                        .windowField()
                        .focused($focus, equals: .username)
                        .onSubmit(saveFields)
                }
                LabeledField(label: Text("Password")) {
                    SecureField(text: $password, prompt: placeholder(hasPassword ? Text(verbatim: "••••••••") : Text(verbatim: "")))
                    {
                        Text("Password")
                    }
                    .windowField(isRefused: credentialsRefused)
                    .focused($focus, equals: .password)
                    .onSubmit(savePassword)
                }
            }
            .padding(.top, 14)
        }
    }

    private var isProtected: Bool { protectionOn || !search.username.isEmpty || hasPassword }

    /// Off: no user name and no password any more.
    private func setProtected(_ on: Bool) {
        protectionOn = on
        guard !on else { return }
        username = ""
        password = ""
        saveFields()
        if hasPassword {
            WebSearchKeychain.setSecret(nil, for: .searxng)
            hasPassword = false
            model.webSearchSecretChanged()
        }
    }

    private var credentialsRefused: Bool {
        model.webSearchTest == .failed(.unauthorized) && search.source == .searxng && hasPassword
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
        SettingRow("Test the search") {
            HStack(spacing: 10) {
                if model.isTestingWebSearch {
                    StatusPill(text: Text("Testing…"), style: .neutral)
                } else if let test = model.webSearchTest {
                    StatusPill(text: Self.result(test), style: Self.works(test) ? .success : .refused)
                }
                Button("Test") {
                    switch search.source {
                    case .brave: saveKey()
                    case .searxng:
                        saveFields()
                        savePassword()
                    }
                    model.testWebSearch()
                }
                .buttonStyle(WindowButtonStyle())
                .disabled(!canTest || model.isTestingWebSearch)
            }
        }
        if let test = model.webSearchTest, !Self.works(test), !model.isTestingWebSearch {
            Caption(Self.describe(test, source: search.source, hasPassword: hasPassword), tone: .error)
        }
    }

    /// The engine is set up, or about to be (a key typed, not saved yet: the test saves it).
    private var canTest: Bool {
        switch search.source {
        case .brave: search.braveKeySaved || !typedKey.isEmpty
        case .searxng: SearXNGProvider.address(address) != nil
        }
    }

    static func works(_ test: WebSearchTest) -> Bool {
        if case .works = test { return true }
        return false
    }

    /// The test's result, in a few words.
    static func result(_ test: WebSearchTest) -> Text {
        switch test {
        case .works(let results, let seconds):
            let time = Units.seconds(fromMilliseconds: seconds * 1000)
            return results == 1 ? Text("It works: one result in \(time)") : Text("It works: \(results) results in \(time)")
        case .notSetUp: return Text("Not set up")
        case .failed(.unauthorized), .failed(.forbidden): return Text("Access refused")
        case .failed(.tooManyRequests): return Text("Limit reached")
        case .failed(.unreachable): return Text("Unreachable")
        case .failed(.unexpected): return Text("Unexpected answer")
        }
    }

    /// Why the test failed, and what to do.
    static func describe(_ test: WebSearchTest, source: WebSearchSource, hasPassword: Bool) -> Text {
        switch (test, source) {
        case (.works, _):
            return Text(verbatim: "")
        case (.notSetUp, .brave):
            return Text("Paste your Brave key first.")
        case (.failed(.unauthorized), .brave), (.failed(.forbidden), .brave):
            return Text("Brave refused the key. Check it on Brave’s website.")
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
            return hasPassword ? Text("The server refused the user name or the password. Check them, then try again.")
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

    // MARK: - In the sidebar

    static func badge(_ model: AssistantModel) -> SidebarBadge {
        let search = model.settings.webSearch
        guard search.enabled else { return .dot(.off, Text("Off")) }
        guard search.isReady else { return .dot(.warn, Text("To set up")) }
        if let test = model.webSearchTest, !works(test) { return .dot(.warn, Text("To look at")) }
        return .dot(.on, Text("On"))
    }
}

/// "Remove the key?": Brave's key leaves the keychain.
struct RemoveBraveKeySheet: View {
    @Bindable var model: AssistantModel
    let navigation: SettingsNavigation

    var body: some View {
        SheetCard(width: 460, title: Text("Remove the key?"),
                  text: Text("Maé will no longer be able to search with Brave until you paste a key again."))
        {
            EmptyView()
        } footer: {
            Button("Cancel") { navigation.sheet = nil }
                .buttonStyle(WindowButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Remove") {
                WebSearchKeychain.setSecret(nil, for: .brave)
                model.settings.webSearch.braveKeySaved = false
                navigation.sheet = nil
            }
            .buttonStyle(WindowButtonStyle(kind: .solidDanger))
        }
    }
}
