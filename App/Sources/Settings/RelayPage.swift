import OpenMaeLink
import SwiftUI
import VoiceCore

/// Settings › Relay: the two relays, set once for the whole app (RelayAccess).
///
/// - The internet relay starts with its switch, on by default: the OpenMaé relay, or one's own. The iPhone and the iPad
///   reach this Mac through it away from home, and the sources that send from the internet go through it, which cannot
///   read them. Its card says where it stands, what uses it, and how far the internet path is (the inbound domain, the
///   certificate this Mac holds), in plain words.
/// - The home relay, off by default: a relay in home mode on the home network, for the sources at home.
///
/// The addresses (one's own relay, the home relay) are typed in sheets. iPhone and iPad and Received information show
/// the relays they need in a line that opens this page.
struct RelayPage: View {
    let relays: RelayAccess

    var body: some View {
        SettingsPageScroll {
            PageHead(Text("Relay")) {
                let summary = RelayWords.summary(relays)
                StatusPill(text: summary.text, style: .dot(summary.tone))
            }
            PageIntro("Relays bring this Mac what comes from elsewhere: your iPhone and iPad away from home, and the information your sources send. This Mac opens no port.")
            PageSection("Internet relay")
            SettingsCard { InternetRelayRows(relays: relays) }
            PageSection("Home relay")
            SettingsCard { HomeRelayRows(relays: relays) }
        }
        .onAppear { relays.readInternetOffer() }
    }

    // MARK: - In the sidebar

    static func badge(_ relays: RelayAccess) -> SidebarBadge {
        let summary = RelayWords.summary(relays)
        return .dot(summary.tone, summary.text)
    }
}

// MARK: - The internet relay

/// "On"; "Go through": the OpenMaé relay or one's own, and what it sees; then what uses it, and where each stands.
private struct InternetRelayRows: View {
    let relays: RelayAccess
    @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?

    private var status: InboundStatus { relays.inbound.status }

    var body: some View {
        SwitchRow("On", isOn: Binding(get: { relays.isInternetRelayOn }, set: relays.setInternetRelayOn))
            .accessibilityLabel(Text("Internet relay"))
        if relays.isInternetRelayOn {
            Hairline()
            SettingRow("Go through") {
                PopUpMenu(title: name, label: Text("Internet relay")) {
                    Button { relays.setInternetRelay(.official) } label: { Text("OpenMaé relay") }
                    Button { navigation?.sheet = .ownRelay } label: { Text("Your own relay…") }
                }
            }
            Caption(help, tone: relays.internetState == .unreachable ? .warn : .normal)
            Hairline()
            CardSubtitle(text: Text("Used by"))
            RelayStateRow(title: Text("iPhone and iPad"), state: devices) { navigation?.show(.devices) }
            Hairline()
            RelayStateRow(title: Text("Information from the internet"), state: RelayWords.internetInformation(status)) {
                navigation?.show(.inbound)
            }
            information
        } else {
            Caption("Your iPhone and iPad reach this Mac at home only, and no source can send from the internet.")
        }
    }

    private var name: Text {
        switch relays.internetRelay {
        case .official, .none: Text("OpenMaé relay")
        case .custom: Text("Your own relay")
        }
    }

    /// Where it is, and what it sees.
    private var help: Text {
        let host = Text(verbatim: relays.internetRelay.url?.host() ?? "")
        switch (relays.internetRelay, relays.internetState) {
        case (_, .unreachable): return Text("\(host) does not answer for now. Next try in a few seconds.")
        case (.custom, _): return Text("\(host). It only sees encrypted packets. It sends no notifications.")
        default: return Text("\(host). It only sees encrypted packets: neither your voice nor your texts.")
        }
    }

    /// The paired devices: how they reach this Mac through it.
    private var devices: StatusWord {
        StatusWord(DevicesPage.reachText(relays.phone.reach), DevicesPage.tone(relays.phone.reach))
    }

    /// Whether it takes information from the internet, and how far the internet path is.
    @ViewBuilder private var information: some View {
        switch status.internetPath {
        case .checking:
            EmptyView()
        case .notOffered:
            Caption("Your relay does not take information from the internet. Its operator can turn it on (RELAY_INBOUND_DOMAIN).",
                    tone: status.sources.contains { $0.origin == .internet } ? .warn : .normal)
        case .unreachable:
            // Said under "Go through" when the whole relay does not answer.
            if relays.internetState != .unreachable {
                Caption("Your relay does not answer. I keep trying.", tone: .warn)
            }
        case .available:
            Caption("It can take information from the internet without reading it. No source goes through it yet.")
        case .gettingCertificate:
            if let problem = status.certificateProblem {
                Caption("This Mac could not get its certificate yet: what is sent from the internet cannot reach Maé. I try again later.",
                        tone: .warn)
                Text(verbatim: problem)
                    .textStyle(.toolID)
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.top, -8)
                    .padding(.bottom, 14)
            } else {
                Caption("This Mac asks Let’s Encrypt for the certificate that keeps deliveries encrypted up to it. It takes a few seconds.")
            }
        case .ready:
            if let expiry = status.certificateExpiry {
                Caption(Text("Your relay cannot read what is sent: it stays encrypted up to this Mac. The certificate renews by itself (valid until \(expiry.formatted(.dateTime.day().month(.wide).locale(TaskText.locale))))."))
            } else {
                Caption("Your relay cannot read what is sent: it stays encrypted up to this Mac.")
            }
        }
    }
}

// MARK: - The home relay

/// "On"; its address, with "Change…"; then what uses it, and where it stands.
private struct HomeRelayRows: View {
    let relays: RelayAccess
    @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?

    var body: some View {
        // On while its address is being typed for the first time.
        SwitchRow("On", isOn: Binding(get: { relays.homeRelayAddress != nil || navigation?.sheet == .homeRelay },
                                      set: setOn))
            .accessibilityLabel(Text("Home relay"))
        if let address = relays.homeRelayAddress {
            Hairline()
            SettingRow("Address") {
                HStack(spacing: 12) {
                    Text(verbatim: RelayWords.typed(address, scheme: "http"))
                        .textStyle(.fieldMono)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Change…") { navigation?.sheet = .homeRelay }
                        .buttonStyle(WindowButtonStyle())
                }
            }
            Caption("What your systems send goes through it to this Mac, which opens no port. Never make it reachable from the internet.")
            Hairline()
            CardSubtitle(text: Text("Used by"))
            RelayStateRow(title: Text("Information from home"),
                          state: RelayWords.homeInformation(relays.inbound.status.homeRelay))
            {
                navigation?.show(.inbound)
            }
            switch relays.inbound.status.homeRelay {
            case .unreachable:
                Caption("The home relay does not answer: what your systems send cannot reach Maé. I keep trying.", tone: .warn)
            case .notHomeMode:
                Caption("This relay is not in home mode, so it passes nothing on to Maé. Start it with RELAY_HOME_INBOUND=true.",
                        tone: .warn)
            case .none, .connecting, .connected:
                EmptyView()
            }
        } else {
            Caption("The OpenMaé relay, run in home mode on a machine at home (a NAS, a Raspberry Pi…). It passes on what your systems send: this Mac opens no port.")
        }
    }

    /// On gives back the address it had while the app runs, else asks for it.
    private func setOn(_ on: Bool) {
        if on {
            if !relays.restoreHomeRelay() { navigation?.sheet = .homeRelay }
        } else {
            relays.removeHomeRelay()
        }
    }
}

// MARK: - Lines for the other pages

/// A state in a word and a colour.
struct StatusWord {
    let text: Text
    let tone: StatusTone

    init(_ text: Text, _ tone: StatusTone) {
        self.text = text
        self.tone = tone
    }
}

/// What uses a relay, or a relay a page needs: its name, a dot and a word, and the page it opens.
struct RelayStateRow: View {
    let title: Text
    let state: StatusWord
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                title
                    .textStyle(.navRow)
                    .foregroundStyle(Palette.ink)
                    .underline(isHovered, color: Palette.ink.opacity(0.25).color)
                    .lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    StatusDot(tone: state.tone)
                    state.text
                        .textStyle(.itemState)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .fixedSize()
                }
                IconView(icon: .forward, size: 18)
                    .foregroundStyle(Palette.inkDisabled)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A relay a page needs, in a line of that page: its state, which opens Settings › Relay; or, when it is off, what that
/// means and "Set up the relay…".
struct RelayLine: View {
    let title: Text
    /// nil: the relay is off.
    let state: StatusWord?
    let offText: Text
    @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?

    var body: some View {
        if let state {
            RelayStateRow(title: title, state: state) { navigation?.show(.relay) }
        } else {
            SettingRow(title, sub: offText) {
                Button("Set up the relay…") { navigation?.show(.relay) }
                    .buttonStyle(WindowButtonStyle())
            }
            .padding(.vertical, 6)
        }
    }
}

// MARK: - The sheet

/// The address of a relay: one's own internet relay, or the home relay. What is typed is checked when it is saved.
struct RelayAddressSheet: View {
    enum Kind { case own, home }

    let kind: Kind
    let relays: RelayAccess
    let navigation: SettingsNavigation
    @State private var text: String
    /// What was typed is not an address.
    @State private var isRefused: Bool
    /// Filled in from the relay when the sheet opens, unless a still picture gave its own text.
    private let prefills: Bool
    @FocusState private var isFocused: Bool

    init(kind: Kind, relays: RelayAccess, navigation: SettingsNavigation, text: String? = nil,
         isRefused: Bool = false)
    {
        self.kind = kind
        self.relays = relays
        self.navigation = navigation
        _text = State(initialValue: text ?? "")
        _isRefused = State(initialValue: isRefused)
        prefills = text == nil
    }

    private var typed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        SheetCard(title: kind == .own ? Text("Your own relay") : Text("Home relay"),
                  text: kind == .own ? Text("A relay you host yourself, reachable from the internet. Type its address.")
                      : Text("The OpenMaé relay in home mode, on a machine at home. Type the address it listens on."))
        {
            LabeledField(label: label) {
                TextField(text: $text, prompt: placeholder(Text(verbatim: kind == .own ? "relay.example.org"
                                                                                        : "192.168.1.10:8080")))
                {
                    label
                }
                .windowField(mono: true, isRefused: isRefused)
                .focused($isFocused)
                .onSubmit(save)
            }
            .padding(.top, 18)
            if isRefused {
                Group {
                    if kind == .own {
                        Caption("This is not an address. Type it like relay.example.org.", tone: .error)
                    } else {
                        Caption("This is not an address. Type it like 192.168.1.10:8080.", tone: .error)
                    }
                }
                .padding(.top, 4)
            }
        } footer: {
            Button("Cancel") { navigation.sheet = nil }
                .buttonStyle(WindowButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .buttonStyle(WindowButtonStyle(kind: .main))
                .keyboardShortcut(.defaultAction)
                .disabled(typed.isEmpty)
        }
        .onAppear {
            if prefills {
                switch kind {
                case .own: text = relays.ownRelayToEdit.map { RelayWords.typed($0, scheme: "https") } ?? ""
                case .home: text = relays.homeRelayToEdit.map { RelayWords.typed($0, scheme: "http") } ?? ""
                }
            }
            isFocused = true
        }
        .onChange(of: text) { isRefused = false }
    }

    private var label: Text {
        kind == .own ? Text("Address of the relay") : Text("Address of the home relay")
    }

    private func save() {
        guard !typed.isEmpty else { return }
        switch kind {
        case .own:
            guard let url = RelayAccess.ownRelayURL(from: typed) else {
                isRefused = true
                return
            }
            relays.setInternetRelay(.custom(url))
        case .home:
            guard relays.setHomeRelay(typed) else {
                isRefused = true
                return
            }
        }
        navigation.sheet = nil
    }
}

// MARK: - Words

/// How the pages say where the relays stand.
@MainActor
enum RelayWords {
    /// The page's head and the sidebar: what needs a look, else whether a relay is on.
    static func summary(_ relays: RelayAccess) -> StatusWord {
        let status = relays.inbound.status
        var states: [StatusWord] = []
        if relays.isInternetRelayOn {
            states.append(internet(relays.internetState))
            if status.sources.contains(where: { $0.origin == .internet }) { states.append(internetInformation(status)) }
        }
        if relays.homeRelayAddress != nil { states.append(homeInformation(status.homeRelay)) }
        if states.contains(where: { $0.tone == .warn }) { return StatusWord(Text("To look at"), .warn) }
        if let waiting = states.first(where: { $0.tone == .info }) { return waiting }
        if states.contains(where: { $0.tone == .on }) { return StatusWord(Text("Ready"), .on) }
        return StatusWord(Text("Off"), .off)
    }

    static func internet(_ state: RelayAccess.InternetState) -> StatusWord {
        switch state {
        case .off: StatusWord(Text("Off"), .off)
        case .connecting: StatusWord(Text("Connecting…"), .info)
        case .ready: StatusWord(Text("Ready"), .on)
        case .unreachable: StatusWord(Text("Unreachable"), .warn)
        }
    }

    /// Information from the internet, through the internet relay (which is on): whether it takes it, and how far the
    /// internet path is.
    static func internetInformation(_ status: InboundStatus) -> StatusWord {
        switch status.internetPath {
        case .checking: StatusWord(Text("Checking…"), .info)
        case .notOffered:
            StatusWord(Text("Not offered"), status.sources.contains { $0.origin == .internet } ? .warn : .off)
        case .unreachable: StatusWord(Text("Unreachable"), .warn)
        case .available: StatusWord(Text("Available"), .off)
        case .gettingCertificate:
            status.certificateProblem == nil ? StatusWord(Text("Getting ready…"), .info)
                : StatusWord(Text("To look at"), .warn)
        case .ready: StatusWord(Text("Ready"), .on)
        }
    }

    /// Information from home, through the home relay.
    static func homeInformation(_ relay: InboundStatus.HomeRelay) -> StatusWord {
        switch relay {
        case .none: StatusWord(Text("Off"), .off)
        case .connecting: StatusWord(Text("Connecting…"), .info)
        case .connected: StatusWord(Text("Connected"), .on)
        case .unreachable: StatusWord(Text("Unreachable"), .warn)
        case .notHomeMode: StatusWord(Text("Not in home mode"), .warn)
        }
    }

    /// The relay a source goes through, as received information knows it: off, or where it stands.
    static func isOn(_ origin: InboundSource.Origin, _ status: InboundStatus) -> Bool {
        switch origin {
        case .internet: status.publicRelayAddress != nil
        case .home: status.homeRelayAddress != nil
        }
    }

    static func need(_ origin: InboundSource.Origin, _ status: InboundStatus) -> StatusWord {
        guard isOn(origin, status) else { return StatusWord(Text("Relay off"), .warn) }
        switch origin {
        case .internet: return internetInformation(status)
        case .home: return homeInformation(status.homeRelay)
        }
    }

    /// Why nothing arrives through the relay a source goes through, when it is on and in trouble (an off one has its
    /// own line, with "Set up the relay…").
    static func trouble(_ origin: InboundSource.Origin, _ status: InboundStatus) -> Note? {
        guard isOn(origin, status) else { return nil }
        switch origin {
        case .home:
            switch status.homeRelay {
            case .unreachable:
                return Note("The home relay does not answer: what your systems send cannot reach Maé. I keep trying.",
                            tone: .warn)
            case .notHomeMode:
                return Note("This relay is not in home mode, so it passes nothing on to Maé. Start it with RELAY_HOME_INBOUND=true.",
                            tone: .warn)
            case .none, .connecting, .connected:
                return nil
            }
        case .internet:
            switch status.internetPath {
            case .unreachable:
                return Note("The internet relay does not answer: what is sent from the internet cannot reach Maé. I keep trying.",
                            tone: .warn)
            case .notOffered:
                return Note("Your relay does not take information from the internet, so internet sources receive nothing.",
                            tone: .warn)
            case .gettingCertificate where status.certificateProblem != nil:
                return Note("This Mac could not get its certificate yet: what is sent from the internet cannot reach Maé. I try again later.",
                            tone: .warn)
            default:
                return nil
            }
        }
    }

    /// "192.168.1.10:8080" or "relay.example.org": an address as it is typed, without its default scheme.
    static func typed(_ url: URL, scheme: String) -> String {
        let text = url.absoluteString
        let prefix = scheme + "://"
        return text.lowercased().hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }
}
