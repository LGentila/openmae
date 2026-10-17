import AppKit
import OpenMaeLink
import SwiftUI
import VoiceCore

/// Settings › Received information: short texts that other systems at home (Home Assistant, a script…) send Maé to
/// say. Its first page shows the home relay, which passes their deliveries on to this Mac, and the sources; a source's
/// page shows its secret address, what Maé does with what it sends and its last deliveries; a third page shows how to
/// send from Home Assistant. Built from the settings' usual pieces until the design draws it. Home sources only for now:
/// the public relay and OpenMaé's internal door come in later steps.
struct InboundPanel: View {
    let inbound: InboundAccess
    /// Back to the settings.
    let back: () -> Void

    var body: some View {
        Group {
            switch inbound.page {
            case .list:
                InboundList(inbound: inbound, back: back)
            case .source(let id):
                if let source = inbound.source(id) {
                    InboundSourcePage(inbound: inbound, source: source)
                } else {
                    // Just removed, or not shown by the host yet.
                    InboundList(inbound: inbound, back: back)
                }
            case .help(let id):
                InboundHelpPage(inbound: inbound, source: id.flatMap { inbound.source($0) })
            }
        }
        .animation(.easeOut(duration: Timing.ui), value: inbound.page)
        .animation(.easeOut(duration: Timing.ui), value: inbound.addingSource)
        .animation(.easeOut(duration: Timing.ui), value: inbound.confirming)
    }

    /// The width of a block's content: the panel's, less its margins and the block's.
    static var blockWidth: CGFloat { PanelChrome<EmptyView>.width - 2 * 14 - 2 * 16 }
}

extension InboundAccess {
    /// The pages of Settings › Received information. `help`: with the source whose page it was opened from, whose
    /// address it shows.
    enum Page: Hashable {
        case list
        case source(InboundSource.ID)
        case help(InboundSource.ID?)
    }

    /// What waits for a yes on a source's page.
    enum Confirmation: Hashable {
        case changeAddress
        case remove
    }

    /// Opens a page of the panel, leaving what was being typed or confirmed.
    func show(_ page: Page) {
        self.page = page
        addingSource = false
        confirming = nil
    }
}

/// The "Received information" row of the settings, with a word on where it stands; opens its panel.
struct InboundRow: View {
    let inbound: InboundAccess
    let open: () -> Void

    var body: some View {
        NavigationRow(title: Text("Received information"), value: InboundPanel.summary(inbound.status), open: open)
    }
}

// MARK: - The home relay and the sources

private struct InboundList: View {
    let inbound: InboundAccess
    let back: () -> Void

    private var status: InboundStatus { inbound.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeader(title: "Received information", badge: InboundPanel.badge(status.homeRelay), back: back)
            Text("Other systems at home, like Home Assistant or a script, can send Maé a sentence to say. It only informs her: it never triggers an action.")
                .textStyle(.panelSmall)
                .foregroundStyle(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 0, leading: 6, bottom: 4, trailing: 6))
            if let banner = InboundPanel.banner(status.homeRelay) { banner }
            SectionTitle("Home path")
            PanelBlock(padding: EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16)) {
                HomeRelayRows(inbound: inbound)
            }
            SectionTitle("Sources")
            PanelBlock(padding: EdgeInsets(top: 2, leading: 16, bottom: 12, trailing: 16)) {
                sources
            }
            PanelBlock(padding: EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)) {
                NavigationRow(title: Text("Send from Home Assistant")) { inbound.show(.help(nil)) }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder private var sources: some View {
        if status.sources.isEmpty, !inbound.addingSource {
            VStack(alignment: .leading, spacing: 2) {
                Text("No source yet")
                    .textStyle(.setting)
                    .foregroundStyle(Palette.ink)
                HelpText("Add one, then paste its address in the other system.")
            }
            .padding(.top, 10)
            .padding(.bottom, 2)
        }
        ForEach(status.sources) { source in
            SourceRow(source: source, last: status.logs[source.id]?.first?.date) { inbound.show(.source(source.id)) }
            Hairline()
        }
        if status.homeRelayAddress == nil {
            HelpText("A source gets its address once the home relay is set.")
                .padding(.top, 8)
        }
        if inbound.addingSource {
            AddSourceForm(inbound: inbound)
        } else {
            Button { inbound.addingSource = true } label: {
                Label { Text("Add a source") } icon: { IconView(icon: .plus, size: 18) }
            }
            .buttonStyle(LinkPillStyle())
            .padding(.top, 9)
        }
    }
}

/// "Home relay": its address, or a field to type it, and what it is for.
private struct HomeRelayRows: View {
    let inbound: InboundAccess
    @State private var text = ""
    @State private var isEditing = false
    /// What was typed is not an address.
    @State private var isRefused = false

    private var address: URL? { inbound.status.homeRelayAddress }

    var body: some View {
        HStack(spacing: 12) {
            Text("Home relay")
                .textStyle(.setting)
            Spacer(minLength: 0)
            if let address {
                Menu {
                    Button {
                        text = InboundPanel.shortAddress(address)
                        isRefused = false
                        isEditing = true
                    } label: {
                        Text("Change the address…")
                    }
                    Divider()
                    Button {
                        isEditing = false
                        inbound.removeHomeRelay()
                    } label: {
                        Text("None")
                    }
                } label: {
                    MenuFieldLabel(title: Text(verbatim: InboundPanel.shortAddress(address)))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Text("None")
                    .textStyle(.value)
                    .foregroundStyle(Palette.inkMuted)
            }
        }
        .frame(minHeight: 48)
        if address == nil || isEditing {
            HStack(spacing: 8) {
                TextField(text: $text, prompt: Text(verbatim: "192.168.1.10:8080")) { Text("Address of the home relay") }
                    .settingsField()
                    .onSubmit(save)
                Button("Save", action: save)
                    .buttonStyle(PillButtonStyle(kind: .link))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if address != nil {
                    Button("Cancel") {
                        isEditing = false
                        isRefused = false
                    }
                    .buttonStyle(PillButtonStyle())
                }
            }
            .padding(.bottom, 8)
            if isRefused {
                HelpText("This is not an address. Type it like 192.168.1.10:8080.", color: Palette.danger)
                    .padding(.bottom, 6)
            }
        }
        Group {
            if address == nil {
                HelpText("The OpenMaé relay, run in home mode on a machine at home (a NAS, a Raspberry Pi…). It passes on what your systems send: this Mac opens no port.")
            } else {
                HelpText("What your systems send goes through it to this Mac, which opens no port. Never make it reachable from the internet.")
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private func save() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard inbound.setHomeRelay(text) else {
            isRefused = true
            return
        }
        text = ""
        isRefused = false
        isEditing = false
    }
}

/// A source in the list: its name, where it sends from and what Maé does with it, and when it last sent something.
private struct SourceRow: View {
    let source: InboundSource
    let last: Date?
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Circle()
                    .fill(source.paused ? Palette.field : Palette.turquoiseSoft)
                    .frame(width: 44, height: 44)
                    .overlay {
                        IconView(icon: icon, size: 22)
                            .foregroundStyle(source.paused ? Palette.inkMuted : Palette.ink)
                    }
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: source.name)
                        .textStyle(.rowTitle)
                        .underline(isHovered, color: Palette.ink.opacity(0.25).color)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(verbatim: detail)
                        .textStyle(.rowDetail)
                        .foregroundStyle(Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                TimelineView(.everyMinute) { _ in
                    Text(verbatim: InboundPanel.lastDelivery(last))
                        .textStyle(.navValue)
                        .foregroundStyle(Palette.inkMuted)
                        .lineLimit(1)
                        .accessibilityLabel(Text("Last delivery: \(InboundPanel.lastDelivery(last))"))
                }
                IconView(icon: .forward, size: 16)
                    .foregroundStyle(Palette.inkMuted)
            }
            .frame(minHeight: 68)
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

    /// "Home · Say right away", or "Home · Paused".
    private var detail: String {
        let state = source.paused ? String(localized: "Paused") : InboundPanel.mode(source.mode)
        return "\(InboundPanel.origin(source.origin)) · \(state)"
    }
}

/// "Add a source": its name, then its page opens. Home sources only for now.
private struct AddSourceForm: View {
    let inbound: InboundAccess
    @State private var name = ""
    @State private var isAdding = false
    @FocusState private var isFocused: Bool

    private var typed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Name of the new source")
                .textStyle(.setting)
                .foregroundStyle(Palette.ink)
            HStack(spacing: 8) {
                TextField(text: $name, prompt: Text(verbatim: "Home Assistant")) { Text("Name of the new source") }
                    .settingsField()
                    .focused($isFocused)
                    .onSubmit(add)
                Button("Add", action: add)
                    .buttonStyle(PillButtonStyle(kind: .link))
                    .disabled(typed.isEmpty || isAdding)
                Button("Cancel") { inbound.addingSource = false }
                    .buttonStyle(PillButtonStyle())
            }
            HelpText("A name to recognize it. Its page then gives its address.")
        }
        .padding(.top, 12)
        .onAppear { isFocused = true }
    }

    private func add() {
        guard !typed.isEmpty, !isAdding else { return }
        isAdding = true
        let name = typed
        Task {
            if let id = await inbound.addSource(name: name) {
                inbound.show(.source(id))
            }
            isAdding = false
        }
    }
}

// MARK: - A source

private struct InboundSourcePage: View {
    let inbound: InboundAccess
    let source: InboundSource

    private var status: InboundStatus { inbound.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeader(title: Text(verbatim: source.name),
                        badge: source.paused ? PanelBadge(text: Text("Paused"), tone: .idle) : nil,
                        truncatesTitle: true) { inbound.show(.list) }
            if let banner = InboundPanel.banner(status.homeRelay) { banner }
            SectionTitle("Address", isFirst: true)
            PanelBlock(padding: EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 16)) { address }
            SectionTitle("What Maé does")
            PanelBlock(padding: EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16)) { behaviour }
            SectionTitle("Last deliveries")
            PanelBlock(padding: EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16)) {
                InboundLog(entries: status.logs[source.id] ?? [])
            }
            removal
        }
    }

    // MARK: Address

    @ViewBuilder private var address: some View {
        if let url = status.addresses[source.id] {
            Text(verbatim: url.absoluteString)
                .textStyle(.path)
                .foregroundStyle(Palette.ink)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
                .background(Palette.line, in: RoundedRectangle(cornerRadius: Radius.code, style: .continuous))
                .accessibilityLabel(Text("Address"))
                .accessibilityValue(Text(verbatim: url.absoluteString))
            if inbound.confirming == .changeAddress {
                ConfirmationBox(title: Text("Change the address?"),
                                message: Text("The old address stops working at once: you will have to paste the new one in the other system."),
                                confirm: Text("Change"),
                                action: {
                                    inbound.confirming = nil
                                    inbound.changeAddress(source.id)
                                },
                                cancel: { inbound.confirming = nil })
                    .padding(.horizontal, -8)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
            } else {
                HStack(spacing: 8) {
                    CopyButton(text: url.absoluteString)
                    Button("Change the address…") { inbound.confirming = .changeAddress }
                        .buttonStyle(PillButtonStyle())
                }
                .padding(.top, 10)
                HelpText("Paste it in the other system. Anyone who knows it can send Maé information: keep it to yourself.")
                    .padding(.top, 8)
                    .padding(.bottom, 8)
            }
        } else if status.homeRelayAddress == nil {
            HelpText("The address appears once the home relay is set.")
            Button("Set the home relay") { inbound.show(.list) }
                .buttonStyle(PillButtonStyle(kind: .link))
                .padding(.top, 8)
                .padding(.bottom, 12)
        } else {
            HelpText("The address is not ready yet.")
                .padding(.bottom, 12)
        }
        Hairline()
        NavigationRow(title: Text("Send from Home Assistant")) { inbound.show(.help(source.id)) }
    }

    // MARK: What Maé does

    @ViewBuilder private var behaviour: some View {
        Segmented(selection: Binding<InboundSource.Mode>(get: { source.mode == .notifyOnly ? .notifyOnly : .sayNow },
                                                         set: { mode in change { $0.mode = mode } }),
                  options: [(value: .sayNow, title: "Say right away"), (value: .notifyOnly, title: "Notification only")],
                  width: InboundPanel.blockWidth)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("What Maé does"))
        Group {
            if source.mode == .notifyOnly {
                HelpText("A notification on this Mac, with the name of the source. Maé says nothing.")
            } else {
                HelpText("After a chime, Maé says it as soon as nobody is speaking. Not said within a minute, it becomes a notification.")
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        Hairline()
        Toggle(isOn: binding(\.mayBeUrgent)) {
            Text("May ask for an urgent announcement")
                .textStyle(.setting)
        }
        .toggleStyle(SwitchStyle())
        .frame(minHeight: 48)
        HelpText("When it marks something urgent, Maé says it at once, whatever the mode: she may cut her own sentence, never yours.")
            .padding(.bottom, 8)
        Hairline()
        Toggle(isOn: binding(\.paused)) {
            Text("Pause this source")
                .textStyle(.setting)
        }
        .toggleStyle(SwitchStyle())
        .frame(minHeight: 48)
        HelpText("While it is paused, its address answers as if it did not exist.")
            .padding(.bottom, 8)
        Hairline()
        Button("Send a test") { inbound.sendTest(source.id) }
            .buttonStyle(PillButtonStyle())
            .padding(.top, 9)
        HelpText(Text("Maé says “\(InboundPhrases.test(source: source.name))”"))
            .padding(.top, 8)
            .padding(.bottom, 4)
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

    // MARK: Removal

    @ViewBuilder private var removal: some View {
        if inbound.confirming == .remove {
            ConfirmationBox(title: Text("Remove \(source.name)?"),
                            message: Text("Its address stops working at once, and its last deliveries are erased."),
                            confirm: Text("Remove"),
                            action: {
                                let id = source.id
                                inbound.show(.list)
                                inbound.remove(id)
                            },
                            cancel: { inbound.confirming = nil })
                .padding(.top, 8)
        } else {
            Button("Remove this source…") { inbound.confirming = .remove }
                .buttonStyle(PillButtonStyle(kind: .destructive))
                .padding(EdgeInsets(top: 10, leading: 6, bottom: 2, trailing: 6))
        }
    }
}

/// A source's last deliveries, newest first.
private struct InboundLog: View {
    let entries: [InboundLogEntry]

    var body: some View {
        if entries.isEmpty {
            HelpText("Nothing received yet.")
                .padding(.vertical, 12)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: "\(InboundPanel.time(entry.date)) · \(InboundPanel.path(entry.path))")
                    .textStyle(.chip)
                    .foregroundStyle(Palette.inkMuted)
                Spacer(minLength: 0)
                InboundPanel.result(entry.result)
                    .textStyle(.chip)
                    .foregroundStyle(InboundPanel.color(entry.result))
            }
            if let text = entry.text, !InboundPanel.isRefusal(entry.result) {
                Text(verbatim: text)
                    .textStyle(.label)
                    .foregroundStyle(entry.result == .duplicate ? Palette.inkMuted : Palette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reason = InboundPanel.reason(entry.result) {
                HelpText(reason)
            }
            if let detail = entry.detail {
                Text(verbatim: detail)
                    .textStyle(.path)
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

// MARK: - Sending from Home Assistant

/// A REST command in Home Assistant's configuration, the source's address in its secrets, and a test from its
/// developer tools. The examples follow the interface's language.
private struct InboundHelpPage: View {
    let inbound: InboundAccess
    /// Opened from a source's page: its address goes in the secrets.
    let source: InboundSource?

    private var address: URL? { source.flatMap { inbound.status.addresses[$0.id] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeader(title: "Send from Home Assistant", badge: nil) {
                inbound.show(source.map { .source($0.id) } ?? .list)
            }
            Text("Home Assistant sends Maé a sentence with a REST command. Add it to its configuration, then restart Home Assistant.")
                .textStyle(.panelSmall)
                .foregroundStyle(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 0, leading: 6, bottom: 4, trailing: 6))
            SectionTitle("In configuration.yaml")
            PanelBlock(padding: EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)) {
                CodeBlock(code: HomeAssistantExample.configuration)
            }
            SectionTitle("In secrets.yaml")
            PanelBlock(padding: EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)) {
                CodeBlock(code: HomeAssistantExample.secrets(address))
                Group {
                    if address == nil {
                        HelpText("Copy the address from the source’s page.")
                    } else {
                        HelpText("The address of the source is secret: it stays in secrets.yaml.")
                    }
                }
                .padding(.top, 8)
            }
            SectionTitle("Try it")
            PanelBlock(padding: EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)) {
                Text("In Developer tools › Actions, switch to YAML mode and run:")
                    .textStyle(.label)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
                CodeBlock(code: HomeAssistantExample.test)
                HelpText("Maé says it right away. Then call the same action from any automation.")
                    .padding(.top, 8)
            }
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
                payload: "{{ {'text': message} | to_json }}"
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

/// A few lines to paste elsewhere, in a fixed-width font: selectable, with "Copy".
private struct CodeBlock: View {
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: code)
                .textStyle(.path)
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                .background(Palette.line, in: RoundedRectangle(cornerRadius: Radius.code, style: .continuous))
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
            copied ? Text("Copied") : Text("Copy")
        }
        .buttonStyle(PillButtonStyle(kind: .link))
    }
}

// MARK: - Words

extension InboundPanel {
    /// The value of its row in the settings.
    static func summary(_ status: InboundStatus) -> Text {
        let sources = status.sources
        guard !sources.isEmpty else { return Text("No source") }
        switch status.homeRelay {
        case .none: return Text("No home relay")
        case .connecting: return Text("Connecting…")
        case .unreachable: return Text("Relay unreachable")
        case .notHomeMode: return Text("Relay not in home mode")
        case .connected:
            if sources.allSatisfy(\.paused) { return Text("Paused") }
            return sources.count == 1 ? Text("1 source") : Text("\(sources.count) sources")
        }
    }

    /// The home relay's state, in the panel's head.
    static func badge(_ relay: InboundStatus.HomeRelay) -> PanelBadge {
        switch relay {
        case .none: PanelBadge(text: Text("No home relay"), tone: .idle, short: Text("No relay"))
        case .connecting: PanelBadge(text: Text("Connecting…"), tone: .wait)
        case .connected: PanelBadge(text: Text("Connected"), tone: .ok)
        case .unreachable: PanelBadge(text: Text("Relay unreachable"), tone: .warn, short: Text("Unreachable"))
        case .notHomeMode: PanelBadge(text: Text("Not in home mode"), tone: .warn, short: Text("Wrong mode"))
        }
    }

    /// Why nothing arrives, when the home relay does not pass deliveries on. It is tried again meanwhile.
    static func banner(_ relay: InboundStatus.HomeRelay) -> Banner? {
        switch relay {
        case .unreachable:
            Banner(text: Text("The home relay does not answer: what your systems send cannot reach Maé. I keep trying."),
                   warning: true)
        case .notHomeMode:
            Banner(text: Text("This relay is not in home mode, so it passes nothing on to Maé. Start it with RELAY_HOME_INBOUND=true."),
                   warning: true)
        case .none, .connecting, .connected:
            nil
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
        case .internalDoor: String(localized: "Internal door")
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
        case .expired: Text("Too late: notified")
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
        case .queued: return Palette.link
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
