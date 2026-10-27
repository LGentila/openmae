import AppKit
import OpenMaeLink
import SwiftUI
import VoiceCore

/// Where the settings window is: its page, the detail page open in it, the sheet over it. Shared by the window, the
/// quick panel and the menu commands, which open the window on a page.
@MainActor
@Observable
final class SettingsNavigation {
    /// The pages of the sidebar, in its order.
    enum Page: Hashable, CaseIterable {
        case voice, actions, agents, webSearch, memory, tools, relay, devices, inbound, advanced
    }

    /// The sheets of the pages; those of iPhone and iPad and of Received information follow PhoneAccess and
    /// InboundAccess.
    enum Sheet: Hashable {
        case changeTier(TierChoice)
        case deleteModels
        /// One model of Settings › Advanced (`ModelStorage.Model.id`).
        case deleteModel(String)
        case eraseWakeLog
        case removeBraveKey
        case clearMemoryJournal
        case eraseMemory
        case addTool
        case removeTool(ConnectedTool.ID)
        /// Relay: the address of one's own internet relay, or of the home relay.
        case ownRelay
        case homeRelay
    }

    var page = Page.voice
    /// Agents › Claude Code.
    var showsAgent = false
    /// Connected tools › a tool.
    var tool: ConnectedTool.ID?
    var sheet: Sheet?

    static let windowID = "settings"

    /// A page from the top: no detail page, no sheet.
    func show(_ page: Page) {
        self.page = page
        showsAgent = false
        tool = nil
        sheet = nil
    }
}

/// The settings window: a sidebar of ten pages in three groups, and the page. 960 × 700 points at first.
struct SettingsWindowView: View {
    @Bindable var model: AssistantModel
    let navigation: SettingsNavigation
    let tools: ConnectedToolsAccess
    @Environment(PhoneAccess.self) private var phone: PhoneAccess?
    @Environment(InboundAccess.self) private var inbound: InboundAccess?
    @Environment(RelayAccess.self) private var relays: RelayAccess?

    /// The narrowest the window gets: half of a 1512-point screen, with room to spare. Every page fits in it.
    static let minimumWidth: CGFloat = 720

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model, navigation: navigation, tools: tools)
            // Never wider than what the sidebar leaves: a page too wide for it would push the whole window's content
            // out on both sides.
            page
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(pageIdentity)
        }
        .background(StatePalette(.listening).surface)
        .overlay { SettingsSheetLayer(model: model, navigation: navigation, tools: tools) }
        .ignoresSafeArea()
        .animation(.easeOut(duration: Timing.ui), value: navigation.sheet)
        .animation(.easeOut(duration: Timing.ui), value: inbound?.sheet)
        .animation(.easeOut(duration: Timing.ui), value: phone?.sheet)
        .onChange(of: navigation.page) { _, page in
            // Another page leaves what waited for a yes on the previous one.
            phone?.removing = nil
            if page == .inbound { inbound?.show(.list) }
        }
        // The internet relay's state in the sidebar: what it offers is read when the window opens and when it changes.
        .onAppear { relays?.readInternetOffer() }
        .onChange(of: inbound?.status.publicRelayAddress) { relays?.readInternetOffer() }
        .background(WindowReader { SettingsWindowLink.window = $0 })
    }

    @ViewBuilder private var page: some View {
        switch navigation.page {
        case .voice: VoicePage(model: model)
        case .actions: ActionsPage(model: model)
        case .agents:
            if navigation.showsAgent {
                ClaudeCodePage(model: model, navigation: navigation)
            } else {
                AgentsPage(model: model, navigation: navigation)
            }
        case .webSearch: WebSearchPage(model: model, navigation: navigation)
        case .memory: MemoryPage(model: model, navigation: navigation)
        case .tools:
            if let id = navigation.tool, let tool = tools.tool(id) {
                ToolPage(tools: tools, tool: tool, navigation: navigation)
            } else {
                ToolsPage(tools: tools, navigation: navigation)
            }
        case .relay:
            if let relays { RelayPage(relays: relays) }
        case .devices:
            if let phone { DevicesPage(phone: phone) }
        case .inbound:
            if let inbound {
                if case .source(let id) = inbound.page, let source = inbound.source(id) {
                    InboundSourcePage(inbound: inbound, source: source)
                } else {
                    InboundPage(inbound: inbound)
                }
            }
        case .advanced: AdvancedPage(model: model, navigation: navigation)
        }
    }

    /// A new page, or a detail page, starts at its top.
    private var pageIdentity: AnyHashable {
        switch navigation.page {
        case .agents: AnyHashable([AnyHashable(navigation.page), AnyHashable(navigation.showsAgent)])
        case .tools: AnyHashable([AnyHashable(navigation.page), AnyHashable(navigation.tool)])
        case .inbound: AnyHashable([AnyHashable(navigation.page), AnyHashable(inbound?.page)])
        default: AnyHashable(navigation.page)
        }
    }
}

// MARK: - The sidebar

/// The sidebar: "Voice and sound"; What Maé can do; Devices and sources; "Advanced"; the app's version at the bottom.
private struct SettingsSidebar: View {
    @Bindable var model: AssistantModel
    let navigation: SettingsNavigation
    let tools: ConnectedToolsAccess
    @Environment(PhoneAccess.self) private var phone: PhoneAccess?
    @Environment(InboundAccess.self) private var inbound: InboundAccess?
    @Environment(RelayAccess.self) private var relays: RelayAccess?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 56)  // the window's buttons
            item(.voice)
            group("What Maé can do")
            item(.actions)
            item(.agents)
            item(.webSearch)
            item(.memory)
            item(.tools)
            group("Devices and sources")
            if relays != nil { item(.relay) }
            if phone != nil { item(.devices) }
            if inbound != nil { item(.inbound) }
            Color.clear.frame(height: 14)
            item(.advanced)
            Spacer(minLength: 0)
            Text("OpenMaé \(Self.version)")
                .textStyle(.version)
                .foregroundStyle(Palette.inkMuted)
                .padding(EdgeInsets(top: 14, leading: 10, bottom: 0, trailing: 10))
        }
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 16, trailing: 12))
        .frame(width: 260)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.line).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Settings"))
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private func group(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .textStyle(.section)
            .foregroundStyle(Palette.inkMuted)
            .padding(EdgeInsets(top: 16, leading: 10, bottom: 6, trailing: 10))
            .accessibilityAddTraits(.isHeader)
    }

    private func item(_ page: SettingsNavigation.Page) -> some View {
        SidebarItem(page: page, isCurrent: navigation.page == page, badge: badge(page),
                    isEnabled: page != .tools || ConnectedToolsAccess.isAvailable)
        {
            navigation.show(page)
            if page == .inbound { inbound?.show(.list) }
        }
    }

    private func badge(_ page: SettingsNavigation.Page) -> SidebarBadge? {
        switch page {
        case .voice, .advanced: nil
        case .actions: ActionsPage.badge(model)
        case .agents: AgentsPage.badge(model)
        case .webSearch: WebSearchPage.badge(model)
        case .memory: MemoryPage.badge(model)
        case .tools: ConnectedToolsAccess.isAvailable ? ToolsPage.badge(tools) : .soon
        case .relay: relays.map(RelayPage.badge)
        case .devices: phone.map(DevicesPage.badge)
        case .inbound: inbound.flatMap(InboundPage.badge)
        }
    }
}

/// What an entry of the sidebar shows on its right: a dot and its word (for VoiceOver), how many, or "Soon".
enum SidebarBadge {
    case dot(StatusTone, Text)
    case count(Int, Text)
    case soon
}

private struct SidebarItem: View {
    let page: SettingsNavigation.Page
    let isCurrent: Bool
    let badge: SidebarBadge?
    let isEnabled: Bool
    let select: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Circle()
                    .fill(page.discColor)
                    .frame(width: 28, height: 28)
                    .overlay { IconView(icon: page.icon, size: 16).foregroundStyle(Palette.ink) }
                    .opacity(isEnabled ? 1 : 0.5)
                page.title
                    .textStyle(isCurrent ? .sidebarItemOn : .sidebarItem)
                    .foregroundStyle(isCurrent ? Palette.onInk : isEnabled ? Palette.ink : Palette.inkDisabled)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(height: 40)
            .background(background, in: RoundedRectangle(cornerRadius: Radius.sidebarItem, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.sidebarItem, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .padding(.bottom, 2)
        .onHover { isHovered = $0 && isEnabled }
        .animation(.easeOut(duration: Timing.ui), value: isCurrent)
        .animation(.easeOut(duration: Timing.ui), value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var trailing: some View {
        switch badge {
        case .dot(let tone, let word):
            StatusDot(tone: tone).accessibilityLabel(word)
        case .count(let count, let word):
            Text(verbatim: "\(count)")
                .textStyle(.sidebarCount)
                .foregroundStyle(isCurrent ? Palette.onInk.opacity(0.72) : Palette.inkMuted)
                .accessibilityLabel(word)
        case .soon:
            Text("Soon")
                .textStyle(.sidebarCount)
                .foregroundStyle(Palette.inkDisabled)
        case nil:
            EmptyView()
        }
    }

    private var background: RGBA {
        if isCurrent { return Palette.ink }
        return isHovered ? Palette.ink.opacity(0.06) : RGBA(rgba: 0)
    }
}

extension SettingsNavigation.Page {
    var title: Text {
        switch self {
        case .voice: Text("Voice and sound")
        case .actions: Text("Actions")
        case .agents: Text("Agents")
        case .webSearch: Text("Search the internet")
        case .memory: Text("Memory")
        case .tools: Text("Connected tools")
        case .relay: Text("Relay")
        case .devices: Text("iPhone and iPad")
        case .inbound: Text("Received information")
        case .advanced: Text("Advanced")
        }
    }

    var icon: Icon {
        switch self {
        case .voice: .microphone
        case .actions: .bolt
        case .agents: .robot
        case .webSearch: .search
        case .memory: .bulb
        case .tools: .plug
        case .relay: .globe
        case .devices: .phone
        case .inbound: .inbox
        case .advanced: .settings
        }
    }

    /// The family of the page: blue to talk, sun for what Maé can do, turquoise for devices and sources.
    var discColor: RGBA {
        switch self {
        case .voice: Palette.azureSoft
        case .actions, .agents, .webSearch, .memory, .tools: Palette.sunSoft
        case .relay, .devices, .inbound: Palette.turquoiseSoft
        case .advanced: Palette.advancedDisc
        }
    }
}

// MARK: - Sheets

/// The sheet over the window, with its veil: the settings' own (the relays' addresses among them), the iPhone pairing
/// and removal, and those of received information. Escape or "Cancel" closes it.
private struct SettingsSheetLayer: View {
    @Bindable var model: AssistantModel
    let navigation: SettingsNavigation
    let tools: ConnectedToolsAccess
    @Environment(PhoneAccess.self) private var phone: PhoneAccess?
    @Environment(InboundAccess.self) private var inbound: InboundAccess?
    @Environment(RelayAccess.self) private var relays: RelayAccess?

    var body: some View {
        if let sheet = activeSheet {
            SheetBackdrop(top: sheet.top) { sheet.view }
                .transition(.opacity)
        }
    }

    private struct Shown {
        let view: AnyView
        var top: CGFloat = 52
    }

    private var activeSheet: Shown? {
        if let sheet = navigation.sheet {
            switch sheet {
            case .changeTier(let choice):
                return Shown(view: AnyView(ChangeTierSheet(model: model, navigation: navigation, choice: choice)),
                             top: 120)
            case .deleteModels:
                return Shown(view: AnyView(DeleteModelsSheet(model: model, navigation: navigation)), top: 120)
            case .deleteModel(let id):
                guard let entry = model.storage?.models.first(where: { $0.id == id }) else { return nil }
                return Shown(view: AnyView(DeleteModelSheet(model: model, navigation: navigation, entry: entry)),
                             top: 120)
            case .eraseWakeLog:
                return Shown(view: AnyView(EraseWakeLogSheet(navigation: navigation)), top: 120)
            case .removeBraveKey:
                return Shown(view: AnyView(RemoveBraveKeySheet(model: model, navigation: navigation)), top: 120)
            case .clearMemoryJournal:
                return Shown(view: AnyView(ClearMemoryJournalSheet(model: model, navigation: navigation)), top: 120)
            case .eraseMemory:
                return Shown(view: AnyView(EraseMemorySheet(model: model, navigation: navigation)), top: 120)
            case .addTool:
                return Shown(view: AnyView(AddToolSheet(tools: tools, navigation: navigation)))
            case .removeTool(let id):
                guard let tool = tools.tool(id) else { return nil }
                return Shown(view: AnyView(RemoveToolSheet(tools: tools, tool: tool, navigation: navigation)),
                             top: 120)
            case .ownRelay, .homeRelay:
                guard let relays else { return nil }
                return Shown(view: AnyView(RelayAddressSheet(kind: sheet == .homeRelay ? .home : .own, relays: relays,
                                                             navigation: navigation)),
                             top: 120)
            }
        }
        if navigation.page == .devices, let phone, let sheet = phone.sheet {
            switch sheet {
            case .pairing: return Shown(view: AnyView(PairingSheet(phone: phone)), top: 24)
            case .remove(let device): return Shown(view: AnyView(RemoveDeviceSheet(phone: phone, device: device)),
                                                   top: 120)
            }
        }
        if navigation.page == .inbound, let inbound, let sheet = inbound.sheet {
            switch sheet {
            case .addSource: return Shown(view: AnyView(AddSourceSheet(inbound: inbound)))
            case .changeAddress(let source): return Shown(view: AnyView(ChangeAddressSheet(inbound: inbound,
                                                                                            source: source)),
                                                          top: 120)
            case .changeRelay(let source, let origin):
                return Shown(view: AnyView(ChangeRelaySheet(inbound: inbound, source: source, origin: origin)),
                             top: 120)
            case .remove(let source): return Shown(view: AnyView(RemoveSourceSheet(inbound: inbound, source: source)),
                                                   top: 120)
            }
        }
        return nil
    }
}

/// A veil of ink at 30 % over the window, and the sheet on it, `top` points from the top; it scrolls when the window is
/// too short.
struct SheetBackdrop<Content: View>: View {
    var top: CGFloat = 52
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            Palette.ink.opacity(0.3).color
                .contentShape(Rectangle())
                .onTapGesture {}
                .accessibilityHidden(true)
            ScrollView {
                content
                    .padding(.top, top)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// The settings window, so that the main window's keys (the space bar to talk, Escape) leave it alone.
@MainActor
enum SettingsWindowLink {
    static weak var window: NSWindow?
}

/// Reports the window a view is in, once it is in one.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(found: found) }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let found: (NSWindow) -> Void

        init(found: @escaping (NSWindow) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { found(window) }
        }
    }
}
