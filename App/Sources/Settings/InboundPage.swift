import AppKit
import OpenMaeLink
import SwiftUI
import VoiceCore

/// Settings › Received information: short texts that other systems (Home Assistant, a script, a service on the
/// internet…) send Maé to say. The page shows, once there is a source, the relays the sources go through (set in
/// Settings › Relay: the internet relay, which cannot read them, and the home relay) and where they stand, the sources,
/// and the announcements switch and the quiet hours (what is not said goes to the news, « Quoi de neuf ? »); a source's
/// page shows the relay it goes through, its secret address, what Maé does with what it sends and its last deliveries.
/// Adding a source, changing its relay or its address and removing it go through sheets. The design draws the home
/// relay only: the internet relay and the announcements take the same form.
struct InboundPage: View {
    let inbound: InboundAccess

    private var status: InboundStatus { inbound.status }

    var body: some View {
        SettingsPageScroll {
            PageHead(Text("Received information")) {
                let badge = InboundWords.badge(status)
                StatusPill(text: badge.text, style: .dot(badge.tone))
            }
            PageIntro("Other systems, at home like Home Assistant or on the internet, can send Maé a sentence to say. It only informs her: it never triggers an action.")
            if let note = InboundWords.note(status) { note.padding(.top, 16) }
            if !status.sources.isEmpty {
                PageSection("Relays")
                SettingsCard { NeededRelays(status: status) }
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
        ActionRow(top: 12, bottom: 12) {
            Button { inbound.sheet = .addSource } label: { IconLabel("Add a source", icon: .plus) }
                .buttonStyle(WindowButtonStyle(kind: .link, big: true))
        }
    }

    // MARK: - In the sidebar

    static func badge(_ inbound: InboundAccess) -> SidebarBadge? {
        let status = inbound.status
        if InboundWords.needed(status).contains(where: { $0.tone == .warn }) { return .dot(.warn, Text("To look at")) }
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
        /// The source goes through the other relay: its address changes.
        case changeRelay(InboundSource.ID, InboundSource.Origin)
        case changeAddress(InboundSource.ID)
        case remove(InboundSource.ID)
    }

    /// Opens a page, leaving any sheet.
    func show(_ page: Page) {
        self.page = page
        sheet = nil
    }
}

// MARK: - The relays

/// The relays the sources go through, each in a line that opens Settings › Relay: where it stands, or, when it is off,
/// what that means.
private struct NeededRelays: View {
    let status: InboundStatus

    var body: some View {
        let origins = InboundWords.relayOrigins(status)
        ForEach(origins, id: \.self) { origin in
            if origin != origins.first { Hairline() }
            switch origin {
            case .internet:
                RelayLine(title: Text("Internet relay"),
                          state: RelayWords.isOn(.internet, status) ? RelayWords.need(.internet, status) : nil,
                          offText: Text("Off: your sources from the internet get no address."))
            case .home:
                RelayLine(title: Text("Home relay"),
                          state: RelayWords.isOn(.home, status) ? RelayWords.need(.home, status) : nil,
                          offText: Text("Off: your sources at home get no address."))
            }
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
            Caption("Maé says nothing on her own: everything is kept for later, and urgent announcements also show a notification. Ask her “What’s new?” to hear it.")
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

    /// "Home relay · Say right away", or "Internet relay · Paused".
    private var detail: String {
        let state = source.paused ? String(localized: "Paused") : InboundWords.mode(source.mode)
        return "\(InboundWords.origin(source.origin)) · \(state)"
    }
}

/// A source's page: the relay it goes through and its address, what Maé does with what it sends, its last deliveries,
/// and its removal.
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
            if let note = RelayWords.trouble(source.origin, status) { note.padding(.top, 16) }
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

    /// "Goes through": the internet relay or the home relay, a choice once the other one is on too. Another relay
    /// changes the address: asked first while the source has one.
    @ViewBuilder private var relay: some View {
        let other: InboundSource.Origin = source.origin == .internet ? .home : .internet
        SettingRow("Goes through") {
            if RelayWords.isOn(other, status) {
                WindowSegmented(selection: Binding(get: { source.origin }, set: goThrough), options: RelayCaption.options,
                                label: Text("Goes through"))
            } else {
                RelayName(origin: source.origin)
            }
        }
        RelayCaption(origin: source.origin)
    }

    private func goThrough(_ origin: InboundSource.Origin) {
        guard origin != source.origin else { return }
        if status.addresses[source.id] == nil {
            change { $0.origin = origin }
        } else {
            inbound.sheet = .changeRelay(source.id, origin)
        }
    }

    @ViewBuilder private var address: some View {
        relay
        Hairline()
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
        } else if !RelayWords.isOn(source.origin, status) {
            Group {
                if source.origin == .internet {
                    Caption("The address appears once the internet relay is on.")
                } else {
                    Caption("The address appears once the home relay is on.")
                }
            }
            .padding(.top, 20)
            ActionRow {
                Button("Set up the relay…") { navigation?.show(.relay) }
                    .buttonStyle(WindowButtonStyle())
            }
        } else if source.origin == .internet, status.internetPath == .notOffered {
            Caption("Your relay does not take information from the internet: this source has no address.")
                .padding(.top, 20)
        } else if source.origin == .internet {
            Caption("The address appears once the internet relay answers.")
                .padding(.top, 20)
        } else {
            Caption("The address is not ready yet.")
                .padding(.top, 20)
        }
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
            // Never said late: still waiting after a minute (or the `expires` it came with), it goes to the news.
            Caption("After a chime, Maé says it as soon as nobody is speaking. If she couldn’t say it within a minute, she keeps it and tells you when you ask “What’s new?”.")
        case .keepForLater:
            Caption("Maé keeps it without a word, and reads it when you ask “What’s new?”.")
        case .notifyOnly:
            Caption("A notification on this Mac, with the name of the source. Maé says nothing.")
        }
        Hairline()
        SwitchRow("May ask for an urgent announcement", isOn: binding(\.mayBeUrgent))
        Caption("Urgent information is said at once, whatever the mode, without cutting you off. If Maé can’t speak, a notification shows it and she keeps it for “What’s new?”.")
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

/// A source's last deliveries, newest first, ten at a time.
private struct InboundLog: View {
    let entries: [InboundLogEntry]

    var body: some View {
        if entries.isEmpty {
            Caption("Nothing received yet.")
                .padding(.top, 20)
        } else {
            PagedList(items: entries) { page in
                ForEach(page) { entry in
                    if entry.id != page.first?.id { Hairline() }
                    LogRow(entry: entry)
                }
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

/// "Add a source": its name and the relay it goes through (a choice once both relays are on), then its page opens. With
/// no relay on, it says so and opens Settings › Relay.
struct AddSourceSheet: View {
    let inbound: InboundAccess
    @State private var name = ""
    /// The relay picked, when both are on.
    @State private var origin = InboundSource.Origin.internet
    @State private var isAdding = false
    @FocusState private var isFocused: Bool
    @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?

    private var typed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The relays a new source may go through: those that are on.
    private var offered: [InboundSource.Origin] {
        [InboundSource.Origin.internet, .home].filter { RelayWords.isOn($0, inbound.status) }
    }

    /// The relay it goes through; nil while none is on.
    private var chosen: InboundSource.Origin? { offered.contains(origin) ? origin : offered.first }

    var body: some View {
        SheetCard(title: Text("Add a source"),
                  text: Text("A name to recognize it, and the relay it goes through. Its page then gives its secret address."))
        {
            VStack(alignment: .leading, spacing: 0) {
                LabeledField(label: Text("Name")) {
                    TextField(text: $name, prompt: placeholder(Text(verbatim: "Home Assistant"))) { Text("Name of the new source") }
                        .windowField()
                        .focused($isFocused)
                        .onSubmit(add)
                }
                LabeledField(label: Text("Goes through")) {
                    if offered.count > 1 {
                        WindowSegmented(selection: $origin, options: RelayCaption.options, label: Text("Goes through"),
                                        fills: true)
                    } else if let chosen {
                        RelayName(origin: chosen)
                            .frame(minHeight: 36, alignment: .leading)
                    } else {
                        Text("No relay is on: a source needs one to get its address.")
                            .textBox(.step)
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let chosen {
                    RelayCaption(origin: chosen)
                        .padding(.top, 4)
                } else {
                    ActionRow {
                        Button("Set up the relay…") {
                            inbound.sheet = nil
                            navigation?.show(.relay)
                        }
                        .buttonStyle(WindowButtonStyle())
                    }
                }
            }
            .padding(.top, 18)
        } footer: {
            Button("Cancel") { inbound.sheet = nil }
                .buttonStyle(WindowButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Add", action: add)
                .buttonStyle(WindowButtonStyle(kind: .main))
                .keyboardShortcut(.defaultAction)
                .disabled(typed.isEmpty || isAdding || chosen == nil)
        }
        .onAppear { isFocused = true }
    }

    private func add() {
        guard !typed.isEmpty, !isAdding, let origin = chosen else { return }
        isAdding = true
        let name = typed
        Task {
            if let id = await inbound.addSource(name: name, origin: origin) {
                inbound.show(.source(id))
            }
            isAdding = false
        }
    }
}

/// A relay's name with its icon, where a source has no other relay to go through.
private struct RelayName: View {
    let origin: InboundSource.Origin

    var body: some View {
        HStack(spacing: 8) {
            IconView(icon: origin == .internet ? .globe : .home, size: 18)
            Group {
                switch origin {
                case .internet: Text("Internet relay")
                case .home: Text("Home relay")
                }
            }
            .textStyle(.control)
        }
        .foregroundStyle(Palette.ink)
        .accessibilityElement(children: .combine)
    }
}

/// What going through a relay means for a source.
private struct RelayCaption: View {
    let origin: InboundSource.Origin

    /// The relays a source may go through, as a choice.
    static let options: [(value: InboundSource.Origin, title: LocalizedStringKey)] = [
        (value: .internet, title: "Internet relay"), (value: .home, title: "Home relay"),
    ]

    var body: some View {
        switch origin {
        case .internet: Caption("From the internet, through the internet relay, which cannot read what is sent.")
        case .home: Caption("From your home network, through the home relay.")
        }
    }
}

/// "Go through the home relay?": the source's address changes, the old one stops working at once.
struct ChangeRelaySheet: View {
    let inbound: InboundAccess
    let source: InboundSource.ID
    let origin: InboundSource.Origin

    var body: some View {
        SheetCard(width: 460,
                  title: origin == .home ? Text("Go through the home relay?") : Text("Go through the internet relay?"),
                  text: Text("The old address stops working at once: you will have to paste the new one in the other system."))
        {
            EmptyView()
        } footer: {
            Button("Cancel") { inbound.sheet = nil }
                .buttonStyle(WindowButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Change") {
                inbound.sheet = nil
                guard var latest = inbound.source(source) else { return }
                latest.origin = origin
                inbound.update(latest)
            }
            .buttonStyle(WindowButtonStyle(kind: .solidDanger))
        }
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
    /// The page's head: no source, else where the relays the sources go through stand (Settings › Relay says more).
    static func badge(_ status: InboundStatus) -> StatusWord {
        let needs = needed(status)
        guard let first = needs.first else { return StatusWord(Text("No source"), .off) }
        guard needs.count > 1 else { return first }
        if needs.contains(where: { $0.tone == .warn }) { return StatusWord(Text("To look at"), .warn) }
        return needs.first { $0.tone == .info } ?? needs.first { $0.tone == .off } ?? StatusWord(Text("Ready"), .on)
    }

    /// A source's head: paused, or the state of the relay it goes through.
    static func badge(of source: InboundSource, _ status: InboundStatus) -> StatusWord {
        if source.paused { return StatusWord(Text("Paused"), .off) }
        return RelayWords.need(source.origin, status)
    }

    /// The relays the sources go through: the internet relay, then the home relay.
    static func relayOrigins(_ status: InboundStatus) -> [InboundSource.Origin] {
        [InboundSource.Origin.internet, .home].filter { origin in status.sources.contains { $0.origin == origin } }
    }

    /// Where the relays the sources go through stand: an off one is to set up.
    static func needed(_ status: InboundStatus) -> [StatusWord] {
        relayOrigins(status).map { RelayWords.need($0, status) }
    }

    /// What the page's head says: why nothing arrives through a relay the sources go through, when it is in trouble.
    static func note(_ status: InboundStatus) -> Note? {
        relayOrigins(status).lazy.compactMap { RelayWords.trouble($0, status) }.first
    }

    static func origin(_ origin: InboundSource.Origin) -> String {
        switch origin {
        case .home: String(localized: "Home relay")
        case .internet: String(localized: "Internet relay")
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

    /// When a source last sent something: "2 min ago", or "Never".
    static func lastDelivery(_ date: Date?) -> String {
        guard let date else { return String(localized: "Never") }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated).locale(TaskText.locale))
    }

    /// "14:32" today, "Thursday 14:32" within the week, "12 October 14:32" before (a log keeps 30 days).
    static func time(_ date: Date) -> String {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date())) ?? Date()
        let style: Date.FormatStyle = if calendar.isDateInToday(date) {
            .dateTime.hour().minute()
        } else if date >= weekAgo {
            .dateTime.weekday(.wide).hour().minute()
        } else {
            .dateTime.day().month(.wide).hour().minute()
        }
        return date.formatted(style.locale(TaskText.locale))
    }

    /// The way a delivery came; none for "Send a test".
    static func path(_ path: InboundPath?) -> String {
        switch path {
        case .homeRelay: String(localized: "Home relay")
        case .publicRelay: String(localized: "Internet relay")
        case nil: String(localized: "Your test")
        }
    }

    /// The delivery was refused (its sender got an error): nothing was said or shown.
    static func isRefusal(_ result: InboundLogEntry.Result) -> Bool {
        switch result {
        case .paused, .wrongPath, .unreadable, .noText, .tooLarge, .rateLimited, .methodRefused, .timedOut: true
        case .queued, .said, .expired, .notified, .kept, .notifiedAndKept, .duplicate: false
        }
    }

    static func result(_ result: InboundLogEntry.Result) -> Text {
        switch result {
        case .queued: Text("Waiting")
        case .said: Text("Said")
        case .expired: Text("Too late: kept for later")
        case .notified: Text("Notified")
        case .kept: Text("Kept for later")
        case .notifiedAndKept: Text("Notified and kept for later")
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
        case .queued, .said, .expired, .notified, .kept, .notifiedAndKept, .duplicate: nil
        }
    }
}
