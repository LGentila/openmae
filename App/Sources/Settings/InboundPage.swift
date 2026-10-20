import AppKit
import OpenMaeLink
import SwiftUI
import VoiceCore

/// Settings › Received information: short texts that other systems (Home Assistant, a script, a service on the
/// internet…) send Maé to say. The page shows the two paths their deliveries take to this Mac (the home relay, and the
/// internet path through the iPhones' relay, which cannot read them), the sources, and, once there is one, the
/// announcements switch and the quiet hours (what is not said goes to the news, « Quoi de neuf ? »); a source's page
/// shows its secret address, what Maé does with what it sends and its last deliveries. Adding a source, changing its
/// address, removing it, the home relay's address and how to send from Home Assistant go through sheets. The design
/// draws the home path only: the internet path and the announcements take the same form.
struct InboundPage: View {
    let inbound: InboundAccess
    @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?

    private var status: InboundStatus { inbound.status }

    var body: some View {
        SettingsPageScroll {
            PageHead(Text("Received information")) {
                let badge = InboundWords.badge(status)
                StatusPill(text: badge.text, style: .dot(badge.tone))
            }
            PageIntro("Other systems, at home like Home Assistant or on the internet, can send Maé a sentence to say. It only informs her: it never triggers an action.")
            if let note = InboundWords.note(status) { note.padding(.top, 16) }
            PageSection("At home")
            SettingsCard { HomeRelayRows(inbound: inbound) }
            PageSection("Over the internet")
            SettingsCard {
                InternetPathRows(status: status) { navigation?.show(.devices) }
            }
            PageSection("Sources")
            if status.sources.isEmpty {
                EmptyPageHero(disc: FamilyDisc(icon: .inbox, color: Palette.turquoiseSoft, size: 64),
                              title: Text("No source"),
                              text: Text("A source is a secret address to give to Home Assistant or a script. Each one can tell Maé something."))
                {
                    EmptyView()
                } action: {
                    Button { inbound.sheet = .addSource } label: { IconLabel("Add a source", icon: .plus) }
                        .buttonStyle(WindowButtonStyle(kind: .main))
                }
            } else {
                SettingsCard { sources }
            }
            SettingsCard {
                NavigationLine(title: Text("Send from Home Assistant")) { inbound.sheet = .homeAssistant(nil) }
            }
            .padding(.top, 14)
            if !status.sources.isEmpty {
                PageSection("Announcements")
                SettingsCard { AnnouncementRows(inbound: inbound) }
            }
        }
        .onAppear { inbound.checkInternetOffer() }
    }

    @ViewBuilder private var sources: some View {
        ForEach(status.sources) { source in
            SourceItem(source: source, last: status.logs[source.id]?.first?.date) { inbound.show(.source(source.id)) }
            Hairline()
        }
        if status.homeRelayAddress == nil, status.sources.contains(where: { $0.origin == .home }) {
            Caption("A home source gets its address once the home relay is set.")
                .padding(.top, 18)
        }
        ActionRow(top: 12, bottom: 12) {
            Button { inbound.sheet = .addSource } label: { IconLabel("Add a source", icon: .plus) }
                .buttonStyle(WindowButtonStyle(kind: .link, big: true))
        }
    }

    // MARK: - In the sidebar

    static func badge(_ inbound: InboundAccess) -> SidebarBadge? {
        let status = inbound.status
        if InboundWords.note(status) != nil { return .dot(.warn, Text("To look at")) }
        let count = status.sources.count
        guard count > 0 else { return nil }
        return .count(count, count == 1 ? Text("1 source") : Text("\(count) sources"))
    }
}

extension InboundAccess {
    /// The pages of Settings › Received information.
    enum Page: Hashable {
        case list
        case source(InboundSource.ID)
    }

    /// What may be shown over them.
    enum Sheet: Hashable {
        case addSource
        case homeRelay
        case changeAddress(InboundSource.ID)
        case remove(InboundSource.ID)
        /// How to send from Home Assistant, with the address of the source it was opened from.
        case homeAssistant(InboundSource.ID?)
    }

    /// Opens a page, leaving any sheet.
    func show(_ page: Page) {
        self.page = page
        sheet = nil
    }
}

// MARK: - The paths

/// "Home relay": its address in a menu (change it, or none), and what it is for.
private struct HomeRelayRows: View {
    let inbound: InboundAccess

    private var address: URL? { inbound.status.homeRelayAddress }

    var body: some View {
        SettingRow("Home relay") {
            PopUpMenu(title: address.map { Text(verbatim: InboundWords.shortAddress($0)) } ?? Text("No relay"),
                      label: Text("Home relay"))
            {
                Button { inbound.sheet = .homeRelay } label: {
                    address == nil ? Text("Set the address…") : Text("Change the address…")
                }
                if address != nil {
                    Divider()
                    Button { inbound.removeHomeRelay() } label: { Text("None") }
                }
            }
        }
        if address == nil {
            Caption("The OpenMaé relay, run in home mode on a machine at home (a NAS, a Raspberry Pi…). It passes on what your systems send: this Mac opens no port.")
        } else {
            Caption("What your systems send goes through it to this Mac, which opens no port. Never make it reachable from the internet.")
        }
    }
}

/// "Through your relay": the internet path's state, and what it means.
private struct InternetPathRows: View {
    let status: InboundStatus
    let openDevices: () -> Void

    var body: some View {
        SettingRow("Through your relay") {
            let badge = InboundWords.internetBadge(status)
            StatusPill(text: badge.text, style: .dot(badge.tone))
        }
        switch status.internetPath {
        case .ready:
            if let expiry = status.certificateExpiry {
                Caption(Text("Your relay cannot read what is sent: it stays encrypted up to this Mac. The certificate renews by itself (valid until \(expiry.formatted(.dateTime.day().month(.wide).locale(TaskText.locale))))."))
            } else {
                Caption("Your relay cannot read what is sent: it stays encrypted up to this Mac.")
            }
        case .gettingCertificate:
            if let problem = status.certificateProblem {
                Caption(Text("The last try at the certificate failed, I try again later: \(problem)"), tone: .warn)
            } else {
                Caption("This Mac asks Let’s Encrypt for the certificate that keeps deliveries encrypted up to it. It takes a few seconds.")
            }
        case .notOffered:
            if status.publicRelayAddress == nil {
                Caption("No relay is chosen. Choose one in iPhone and iPad to receive from the internet.")
                ActionRow {
                    Button(action: openDevices) { IconLabel("Open iPhone and iPad", icon: .arrowRight) }
                        .buttonStyle(WindowButtonStyle())
                }
            } else {
                Caption("Your relay does not take information from the internet. Its operator can turn it on (RELAY_INBOUND_DOMAIN).")
            }
        case .unreachable:
            Caption("Your relay does not answer. I keep trying.", tone: .warn)
        case .available:
            Caption("Your relay offers it, without being able to read what is sent. Add a source with the origin Internet to use it.")
        case .checking:
            Caption("Checking what your relay offers…")
        }
    }
}

// MARK: - Announcements

/// "Announcements": whether Maé says on her own what the sources send, and the quiet hours. What she does not say is
/// kept for later, in the news.
private struct AnnouncementRows: View {
    let inbound: InboundAccess

    private var preferences: InboundPreferences { inbound.status.preferences }

    var body: some View {
        SwitchRow("On", isOn: binding(\.announcements))
        if preferences.announcements {
            Caption("Maé says what your sources send as it arrives, as each source’s mode says.")
            Hairline()
            SwitchRow("Quiet hours", isOn: binding(\.quietHours.enabled))
            if preferences.quietHours.enabled {
                SettingRow("Hours") {
                    HStack(spacing: 8) {
                        HourMenu(minutes: binding(\.quietHours.start), label: Text("Start of the quiet hours"))
                        Text("to")
                            .textStyle(.setting)
                            .foregroundStyle(Palette.inkMuted)
                        HourMenu(minutes: binding(\.quietHours.end), label: Text("End of the quiet hours"))
                    }
                }
            }
            Caption("Meanwhile, what should be said right away is kept for later. Urgent announcements are still said.")
        } else {
            Caption("Maé says nothing on her own: everything is kept for later. Ask her “What’s new?” to hear it.")
        }
    }

    private func binding<Value>(_ key: WritableKeyPath<InboundPreferences, Value>) -> Binding<Value> {
        Binding(get: { inbound.status.preferences[keyPath: key] }, set: { value in
            var preferences = inbound.status.preferences
            preferences[keyPath: key] = value
            inbound.setPreferences(preferences)
        })
    }
}

/// An hour of the day, on the hour, in a pop-up menu.
private struct HourMenu: View {
    @Binding var minutes: Int
    let label: Text

    var body: some View {
        PopUpMenu(title: Text(verbatim: InboundWords.hour(minutes)), label: label) {
            Picker(selection: $minutes) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(verbatim: InboundWords.hour(hour * 60)).tag(hour * 60)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

// MARK: - The sources

/// A source in the list: its name, where it sends from and what Maé does with it, and when it last sent something.
private struct SourceItem: View {
    let source: InboundSource
    let last: Date?
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            ListItem(disc: FamilyDisc(icon: icon, color: source.paused ? Palette.advancedDisc : Palette.turquoiseSoft),
                     name: { Text(verbatim: source.name) }, sub: Text(verbatim: detail),
                     trailing: {
                         HStack(spacing: 12) {
                             TimelineView(.everyMinute) { _ in
                                 Text(verbatim: InboundWords.lastDelivery(last))
                                     .textStyle(.itemEnd)
                                     .foregroundStyle(Palette.inkMuted)
                                     .lineLimit(1)
                                     .accessibilityLabel(Text("Last delivery: \(InboundWords.lastDelivery(last))"))
                             }
                             IconView(icon: .forward, size: 18)
                                 .foregroundStyle(Palette.inkDisabled)
                         }
                     },
                     isHovered: isHovered)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var icon: Icon {
        if source.paused { return .pause }
        return source.origin == .home ? .home : .globe
    }

    /// "Home · Say right away", or "Internet · Paused".
    private var detail: String {
        let state = source.paused ? String(localized: "Paused") : InboundWords.mode(source.mode)
        return "\(InboundWords.origin(source.origin)) · \(state)"
    }
}

/// A source's page: its address, what Maé does with what it sends, its last deliveries, and its removal.
struct InboundSourcePage: View {
    let inbound: InboundAccess
    let source: InboundSource
    @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?

    private var status: InboundStatus { inbound.status }

    var body: some View {
        SettingsPageScroll {
            PageHead(Text(verbatim: source.name), back: { inbound.show(.list) },
                     backLabel: Text("Received information"))
            {
                let badge = InboundWords.badge(of: source, status)
                StatusPill(text: badge.text, style: .dot(badge.tone))
            }
            if let note = source.origin == .home ? InboundWords.homeNote(status.homeRelay)
                : InboundWords.internetNote(status)
            {
                note.padding(.top, 16)
            }
            PageSection("Address")
            SettingsCard { address }
            PageSection("What Maé does")
            SettingsCard { behaviour }
            PageSection("Last information")
            SettingsCard { InboundLog(entries: status.logs[source.id] ?? []) }
            Button("Remove this source…") { inbound.sheet = .remove(source.id) }
                .buttonStyle(WindowButtonStyle(kind: .danger))
                .padding(.top, 22)
        }
    }

    // MARK: Address

    @ViewBuilder private var address: some View {
        if let url = status.addresses[source.id] {
            CodeText(text: url.absoluteString, lineLimit: 3)
                .accessibilityLabel(Text("Address"))
                .accessibilityValue(Text(verbatim: url.absoluteString))
                .padding(.top, 14)
            ActionRow(top: 12, bottom: 14) {
                CopyButton(text: url.absoluteString)
                Button("Change the address…") { inbound.sheet = .changeAddress(source.id) }
                    .buttonStyle(WindowButtonStyle())
            }
            Caption("Paste it in the other system. Anyone who knows it can send Maé information: keep it to yourself.")
        } else if source.origin == .internet {
            switch status.internetPath {
            case .notOffered where status.publicRelayAddress == nil:
                Caption("The address appears once a relay is chosen, in iPhone and iPad.")
                    .padding(.top, 20)
                ActionRow {
                    Button { navigation?.show(.devices) } label: { IconLabel("Open iPhone and iPad", icon: .arrowRight) }
                        .buttonStyle(WindowButtonStyle())
                }
            case .notOffered:
                Caption("Your relay does not take information from the internet: this source has no address.")
                    .padding(.top, 20)
            default:
                Caption("The address appears once your relay answers.")
                    .padding(.top, 20)
            }
        } else if status.homeRelayAddress == nil {
            Caption("The address appears once the home relay is set.")
                .padding(.top, 20)
            ActionRow {
                Button("Set the home relay") { inbound.sheet = .homeRelay }
                    .buttonStyle(WindowButtonStyle(kind: .link))
            }
        } else {
            Caption("The address is not ready yet.")
                .padding(.top, 20)
        }
        Hairline()
        NavigationLine(title: Text("Send from Home Assistant")) { inbound.sheet = .homeAssistant(source.id) }
    }

    // MARK: What Maé does

    @ViewBuilder private var behaviour: some View {
        SettingRow("When information arrives") {
            PopUpMenu(title: Text(verbatim: InboundWords.mode(source.mode)), label: Text("When information arrives")) {
                Picker(selection: Binding<InboundSource.Mode>(get: { source.mode },
                                                              set: { mode in change { $0.mode = mode } }))
                {
                    ForEach(InboundSource.Mode.allCases, id: \.self) { mode in
                        Text(verbatim: InboundWords.mode(mode)).tag(mode)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        switch source.mode {
        case .sayNow:
            Caption("After a chime, Maé says it as soon as nobody is speaking. Not said within a minute, it is kept for later.")
        case .keepForLater:
            Caption("Maé keeps it without a word, and reads it when you ask “What’s new?”.")
        case .notifyOnly:
            Caption("A notification on this Mac, with the name of the source. Maé says nothing.")
        }
        Hairline()
        SwitchRow("May ask for an urgent announcement", isOn: binding(\.mayBeUrgent))
        Caption("When it marks something urgent, Maé says it at once, whatever the mode: she may cut her own sentence, never yours.")
        Hairline()
        SwitchRow("Pause this source", isOn: binding(\.paused))
        Caption("While it is paused, its address answers as if it did not exist.")
        Hairline()
        SettingRow("Send a test") {
            Button("Send a test") { inbound.sendTest(source.id) }
                .buttonStyle(WindowButtonStyle())
        }
        Caption(Text("Maé says “\(InboundPhrases.test(source: source.name))”"))
    }

    private func binding(_ key: WritableKeyPath<InboundSource, Bool>) -> Binding<Bool> {
        Binding(get: { source[keyPath: key] }, set: { value in change { $0[keyPath: key] = value } })
    }

    /// Saves a change of this source, made to its latest state.
    private func change(_ edit: (inout InboundSource) -> Void) {
        guard var latest = inbound.source(source.id) else { return }
        edit(&latest)
        inbound.update(latest)
    }
}

/// A source's last deliveries, newest first.
private struct InboundLog: View {
    let entries: [InboundLogEntry]

    var body: some View {
        if entries.isEmpty {
            Caption("Nothing received yet.")
                .padding(.top, 20)
        } else {
            ForEach(entries) { entry in
                if entry.id != entries.first?.id { Hairline() }
                LogRow(entry: entry)
            }
        }
    }
}

/// A delivery: when, by which path, what became of it, and its text, or why it was refused (with what the sender was
/// told, when it was told more).
private struct LogRow: View {
    let entry: InboundLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(verbatim: "\(InboundWords.time(entry.date)) · \(InboundWords.path(entry.path))")
                    .textStyle(.logLine)
                    .foregroundStyle(Palette.inkMuted)
                Spacer(minLength: 0)
                InboundWords.result(entry.result)
                    .textStyle(.logResult)
                    .foregroundStyle(InboundWords.color(entry.result))
            }
            if let text = entry.text, !InboundWords.isRefusal(entry.result) {
                Text(verbatim: text)
                    .textStyle(.logText)
                    .foregroundStyle(entry.result == .duplicate ? Palette.inkMuted : Palette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reason = InboundWords.reason(entry.result) {
                Text(reason)
                    .textStyle(.logText)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = entry.detail {
                Text(verbatim: detail)
                    .textStyle(.toolID)
                    .foregroundStyle(Palette.inkMuted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
        .help(entry.caller.map { Text("Sent from \($0)") } ?? Text(verbatim: ""))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sheets

/// "Add a source": its name and where it sends from, then its page opens.
struct AddSourceSheet: View {
    let inbound: InboundAccess
    @State private var name = ""
    @State private var origin = InboundSource.Origin.home
    @State private var isAdding = false
    @FocusState private var isFocused: Bool

    private var typed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        SheetCard(title: Text("Add a source"),
                  text: Text("A name to recognize it, and where it sends from. Its page then gives its secret address."))
        {
            VStack(alignment: .leading, spacing: 0) {
                LabeledField(label: Text("Name")) {
                    TextField(text: $name, prompt: placeholder(Text(verbatim: "Home Assistant"))) { Text("Name of the new source") }
                        .windowField()
                        .focused($isFocused)
                        .onSubmit(add)
                }
                LabeledField(label: Text("Where it sends from")) {
                    WindowSegmented(selection: $origin,
                                    options: [(value: .home, title: "Home"), (value: .internet, title: "Internet")],
                                    label: Text("Where it sends from"), fills: true)
                }
                Group {
                    if origin == .home {
                        Caption("From your home network, through the home relay.")
                    } else {
                        Caption("From the internet, through your relay, which cannot read what is sent.")
                    }
                }
                .padding(.top, 4)
            }
            .padding(.top, 18)
        } footer: {
            Button("Cancel") { inbound.sheet = nil }
                .buttonStyle(WindowButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Add", action: add)
                .buttonStyle(WindowButtonStyle(kind: .main))
                .keyboardShortcut(.defaultAction)
                .disabled(typed.isEmpty || isAdding)
        }
        .onAppear { isFocused = true }
    }

    private func add() {
        guard !typed.isEmpty, !isAdding else { return }
        isAdding = true
        let name = typed
        let origin = origin
        Task {
            if let id = await inbound.addSource(name: name, origin: origin) {
                inbound.show(.source(id))
            }
            isAdding = false
        }
    }
}

/// The home relay's address.
struct HomeRelaySheet: View {
    let inbound: InboundAccess
    @State private var text = ""
    /// What was typed is not an address.
    @State private var isRefused = false
    @FocusState private var isFocused: Bool

    var body: some View {
        SheetCard(title: Text("Home relay"),
                  text: Text("The OpenMaé relay in home mode, on a machine at home. Type the address it listens on."))
        {
            LabeledField(label: Text("Address of the home relay")) {
                TextField(text: $text, prompt: placeholder(Text(verbatim: "192.168.1.10:8080"))) { Text("Address of the home relay") }
                    .windowField(mono: true, isRefused: isRefused)
                    .focused($isFocused)
                    .onSubmit(save)
            }
            .padding(.top, 18)
            if isRefused {
                Caption("This is not an address. Type it like 192.168.1.10:8080.", tone: .error)
                    .padding(.top, 4)
            }
        } footer: {
            Button("Cancel") { inbound.sheet = nil }
                .buttonStyle(WindowButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .buttonStyle(WindowButtonStyle(kind: .main))
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear {
            text = inbound.status.homeRelayAddress.map(InboundWords.shortAddress) ?? ""
            isFocused = true
        }
    }

    private func save() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard inbound.setHomeRelay(text) else {
            isRefused = true
            return
        }
        inbound.sheet = nil
    }
}

/// "Change the address?": the old one stops working at once.
struct ChangeAddressSheet: View {
    let inbound: InboundAccess
    let source: InboundSource.ID

    var body: some View {
        SheetCard(width: 460, title: Text("Change the address?"),
                  text: Text("The old address stops working at once: you will have to paste the new one in the other system."))
        {
            EmptyView()
        } footer: {
            Button("Cancel") { inbound.sheet = nil }
                .buttonStyle(WindowButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Change") {
                inbound.sheet = nil
                inbound.changeAddress(source)
            }
            .buttonStyle(WindowButtonStyle(kind: .solidDanger))
        }
    }
}

/// "Remove Home Assistant?": its address stops working, its log is erased.
struct RemoveSourceSheet: View {
    let inbound: InboundAccess
    let source: InboundSource.ID

    var body: some View {
        if let found = inbound.source(source) {
            SheetCard(width: 460, title: Text("Remove \(found.name)?"),
                      text: Text("Its address stops working at once, and its last deliveries are erased."))
            {
                EmptyView()
            } footer: {
                Button("Cancel") { inbound.sheet = nil }
                    .buttonStyle(WindowButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Remove") {
                    inbound.show(.list)
                    inbound.remove(source)
                }
                .buttonStyle(WindowButtonStyle(kind: .solidDanger))
            }
        }
    }
}

/// How to send from Home Assistant: a REST command in its configuration, the source's address in its secrets, and a
/// test from its developer tools. The examples follow the interface's language.
struct HomeAssistantSheet: View {
    let inbound: InboundAccess
    /// Opened from a source's page: its address goes in the secrets.
    let source: InboundSource.ID?

    private var address: URL? { source.flatMap { inbound.status.addresses[$0] } }

    var body: some View {
        SheetCard(title: Text("Send from Home Assistant"),
                  text: Text("Home Assistant sends Maé a sentence with a REST command. Add it to its configuration, then restart Home Assistant."))
        {
            VStack(alignment: .leading, spacing: 0) {
                PageSection("In configuration.yaml")
                CodeBlock(code: HomeAssistantExample.configuration)
                PageSection("In secrets.yaml")
                CodeBlock(code: HomeAssistantExample.secrets(address))
                Group {
                    if address == nil {
                        Caption("Copy the address from the source’s page.")
                    } else {
                        Caption("The address of the source is secret: it stays in secrets.yaml.")
                    }
                }
                .padding(.top, 16)
                PageSection("Try it")
                Text("In Developer tools › Actions, switch to YAML mode and run:")
                    .textStyle(.step)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
                CodeBlock(code: HomeAssistantExample.test)
                Caption("Maé says it right away. Then call the same action from any automation.")
                    .padding(.top, 16)
                PageSection("Welcome home")
                Text("With “news: true”, Maé says the text, then the news she kept for you. For example, when you come home:")
                    .textStyle(.step)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
                CodeBlock(code: HomeAssistantExample.welcome)
            }
            .padding(.top, -6)
        } footer: {
            Button("Done") { inbound.sheet = nil }
                .buttonStyle(WindowButtonStyle(kind: .main))
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// The Home Assistant example of the help, in the interface's language (its names included: `prevenir_mae` in French).
private enum HomeAssistantExample {
    static var configuration: String {
        String(localized: """
            rest_command:
              notify_mae:
                # the address copied from OpenMaé
                url: !secret mae_address
                method: post
                content_type: "application/json"
                payload: "{{ {'text': message, 'news': news | default(false)} | to_json }}"
            """)
    }

    /// An automation for coming home: the text, then the news.
    static var welcome: String {
        String(localized: """
            automation:
              - alias: "Back home: Maé welcomes you"
                triggers:
                  - trigger: state
                    entity_id: person.<you>
                    to: "home"
                actions:
                  - action: rest_command.notify_mae
                    data:
                      message: "Good evening, welcome back."
                      news: true
            """)
    }

    /// With the source's address, or a placeholder.
    static func secrets(_ address: URL?) -> String {
        let address = address?.absoluteString ?? String(localized: "<the source’s address>")
        return String(localized: "mae_address: \"\(address)\"")
    }

    static var test: String {
        String(localized: """
            action: rest_command.notify_mae
            data:
              message: "Test from Home Assistant"
            """)
    }
}

/// A few lines to paste elsewhere, with "Copy".
private struct CodeBlock: View {
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CodeText(text: code)
            CopyButton(text: code)
        }
    }
}

/// "Copy": puts a text on the pasteboard, and says so for a moment.
private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            IconLabel(copied ? Text("Copied") : Text("Copy"), icon: copied ? .smallCheck : .copy)
        }
        .buttonStyle(WindowButtonStyle(kind: .link))
    }
}

// MARK: - Words

/// How the page says where things stand.
@MainActor
enum InboundWords {
    struct Badge {
        let text: Text
        let tone: StatusTone
    }

    /// The page's head: the home relay's state, or the internet path's when only internet sources are there.
    static func badge(_ status: InboundStatus) -> Badge {
        if status.sources.isEmpty, status.homeRelayAddress == nil { return Badge(text: Text("No source"), tone: .off) }
        let internetOnly = !status.sources.isEmpty && status.sources.allSatisfy { $0.origin == .internet }
        guard internetOnly, status.homeRelayAddress == nil else { return homeBadge(status.homeRelay) }
        return internetBadge(status)
    }

    /// A source's head: paused, or the state of the path it sends by.
    static func badge(of source: InboundSource, _ status: InboundStatus) -> Badge {
        if source.paused { return Badge(text: Text("Paused"), tone: .off) }
        return source.origin == .home ? homeBadge(status.homeRelay) : internetBadge(status)
    }

    static func homeBadge(_ relay: InboundStatus.HomeRelay) -> Badge {
        switch relay {
        case .none: Badge(text: Text("No home relay"), tone: .off)
        case .connecting: Badge(text: Text("Connecting…"), tone: .info)
        case .connected: Badge(text: Text("Connected"), tone: .on)
        case .unreachable: Badge(text: Text("Relay unreachable"), tone: .warn)
        case .notHomeMode: Badge(text: Text("Not in home mode"), tone: .warn)
        }
    }

    static func internetBadge(_ status: InboundStatus) -> Badge {
        switch status.internetPath {
        case .ready: Badge(text: Text("Ready"), tone: .on)
        case .gettingCertificate: Badge(text: Text("Getting the certificate…"), tone: .info)
        case .checking: Badge(text: Text("Connecting…"), tone: .info)
        case .unreachable: Badge(text: Text("Relay unreachable"), tone: .warn)
        case .notOffered:
            status.publicRelayAddress == nil ? Badge(text: Text("No relay"), tone: .off)
                : Badge(text: Text("Not offered"), tone: .warn)
        case .available: Badge(text: Text("Available"), tone: .off)
        }
    }

    /// What the page's head says: the home relay's trouble, else the internet path's when an internet source waits.
    static func note(_ status: InboundStatus) -> Note? {
        if status.sources.contains(where: { $0.origin == .home }) || status.homeRelayAddress != nil,
           let note = homeNote(status.homeRelay)
        {
            return note
        }
        return internetNote(status)
    }

    /// Why nothing arrives, when the home relay does not pass deliveries on. It is tried again meanwhile.
    static func homeNote(_ relay: InboundStatus.HomeRelay) -> Note? {
        switch relay {
        case .unreachable:
            Note("The home relay does not answer: what your systems send cannot reach Maé. I keep trying.", tone: .warn)
        case .notHomeMode:
            Note("This relay is not in home mode, so it passes nothing on to Maé. Start it with RELAY_HOME_INBOUND=true.",
                 tone: .warn)
        case .none, .connecting, .connected:
            nil
        }
    }

    /// Why nothing arrives from the internet, when an internet source exists.
    static func internetNote(_ status: InboundStatus) -> Note? {
        guard status.sources.contains(where: { $0.origin == .internet }) else { return nil }
        switch status.internetPath {
        case .unreachable:
            return Note("Your relay does not answer: what is sent from the internet cannot reach Maé. I keep trying.",
                        tone: .warn)
        case .notOffered:
            return Note(status.publicRelayAddress == nil
                ? Text("No relay is chosen, so nothing can come from the internet. Choose one in iPhone and iPad.")
                : Text("Your relay does not take information from the internet, so internet sources receive nothing."),
                tone: .warn)
        case .gettingCertificate where status.certificateProblem != nil:
            return Note("This Mac could not get its certificate yet: what is sent from the internet cannot reach Maé. I try again later.",
                        tone: .warn)
        default:
            return nil
        }
    }

    static func origin(_ origin: InboundSource.Origin) -> String {
        switch origin {
        case .home: String(localized: "Home")
        case .internet: String(localized: "Internet")
        }
    }

    static func mode(_ mode: InboundSource.Mode) -> String {
        switch mode {
        case .sayNow: String(localized: "Say right away")
        case .keepForLater: String(localized: "Keep for later")
        case .notifyOnly: String(localized: "Notification only")
        }
    }

    /// "22:00": an hour of the quiet hours, `minutes` after midnight.
    static func hour(_ minutes: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minutes / 60 % 24, minute: minutes % 60, second: 0, of: Date())
            ?? Date()
        return date.formatted(.dateTime.hour().minute().locale(TaskText.locale))
    }

    /// "192.168.1.10:8080": the home relay's address as it is typed, without "http://".
    static func shortAddress(_ url: URL) -> String {
        let text = url.absoluteString
        return text.hasPrefix("http://") ? String(text.dropFirst("http://".count)) : text
    }

    /// When a source last sent something: "2 min ago", or "Never".
    static func lastDelivery(_ date: Date?) -> String {
        guard let date else { return String(localized: "Never") }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated).locale(TaskText.locale))
    }

    /// "14:32" today, "Thursday 14:32" before (a log keeps a week).
    static func time(_ date: Date) -> String {
        let style: Date.FormatStyle = Calendar.current.isDateInToday(date) ? .dateTime.hour().minute()
            : .dateTime.weekday(.wide).hour().minute()
        return date.formatted(style.locale(TaskText.locale))
    }

    /// The way a delivery came; none for "Send a test".
    static func path(_ path: InboundPath?) -> String {
        switch path {
        case .homeRelay: String(localized: "Home relay")
        case .publicRelay: String(localized: "Public relay")
        case nil: String(localized: "Your test")
        }
    }

    /// The delivery was refused (its sender got an error): nothing was said or shown.
    static func isRefusal(_ result: InboundLogEntry.Result) -> Bool {
        switch result {
        case .paused, .wrongPath, .unreadable, .noText, .tooLarge, .rateLimited, .methodRefused, .timedOut: true
        case .queued, .said, .expired, .notified, .kept, .duplicate: false
        }
    }

    static func result(_ result: InboundLogEntry.Result) -> Text {
        switch result {
        case .queued: Text("Waiting")
        case .said: Text("Said")
        case .expired: Text("Too late: kept for later")
        case .notified: Text("Notified")
        case .kept: Text("Kept for later")
        case .duplicate: Text("Duplicate: ignored")
        case .paused, .wrongPath, .unreadable, .noText, .tooLarge, .rateLimited, .methodRefused, .timedOut:
            Text("Refused")
        }
    }

    static func color(_ result: InboundLogEntry.Result) -> RGBA {
        if isRefusal(result) { return Palette.danger }
        switch result {
        case .said: return Palette.success
        case .queued, .expired: return Palette.warnText
        default: return Palette.inkMuted
        }
    }

    /// Why a delivery was refused, in plain words.
    static func reason(_ result: InboundLogEntry.Result) -> LocalizedStringKey? {
        switch result {
        case .paused: "The source was paused: its address answered as if it did not exist."
        case .wrongPath: "It came by a path this source does not accept."
        case .unreadable: "Nothing readable: an empty text, or broken JSON."
        case .noText: "A JSON object without a text field."
        case .tooLarge: "Over 64 KB."
        case .rateLimited: "Too many deliveries: at most 6 a minute and 60 an hour."
        case .methodRefused: "Wrong method: send with POST, or GET with ?text=."
        case .timedOut: "It took over 10 seconds to arrive."
        case .queued, .said, .expired, .notified, .kept, .duplicate: nil
        }
    }
}
