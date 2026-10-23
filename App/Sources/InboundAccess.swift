import Foundation
import Observation
import OpenMaeLink
import VoiceCore

/// Received information, as the Mac's settings show it: the relays it goes through and their state (set in Settings ›
/// Relay, through RelayAccess), the sources with their secret addresses and their logs. Built from
/// OpenMaeLink.InboundHost's status.
@MainActor
@Observable
final class InboundAccess {
    private(set) var status = InboundStatus()
    @ObservationIgnored private let host: InboundHost?

    /// `host`: nil in still pictures of the screens, which set `status` themselves.
    init(host: InboundHost?, status: InboundStatus = InboundStatus()) {
        self.host = host
        self.status = status
        guard let host else { return }
        Task { [weak self] in
            for await status in host.status {
                self?.status = status
                #if DEBUG
                InboundTestHook.follow(status, host: host)
                #endif
            }
        }
    }

    func source(_ id: InboundSource.ID) -> InboundSource? {
        status.sources.first { $0.id == id }
    }

    /// What the user typed for the home relay (Settings › Relay, through RelayAccess); false when it cannot be an
    /// address.
    @discardableResult
    func setHomeRelay(_ text: String) -> Bool {
        guard let url = InboundHost.homeRelayURL(from: text) else { return false }
        setHomeRelayAddress(url)
        return true
    }

    /// The home relay, or none. Shown at once, saved by the host, which then says how it stands.
    func setHomeRelayAddress(_ address: URL?) {
        guard address != status.homeRelayAddress else { return }
        status.homeRelayAddress = address
        status.homeRelay = address == nil ? .none : .connecting
        Task { await host?.setHomeRelay(address) }
    }

    /// The announcements switch and the quiet hours. Shown at once, saved by the host.
    func setPreferences(_ preferences: InboundPreferences) {
        status.preferences = preferences
        Task { await host?.setPreferences(preferences) }
    }

    /// A new source; its id once added.
    func addSource(name: String, origin: InboundSource.Origin = .home) async -> InboundSource.ID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let host else { return nil }
        return await host.addSource(name: name, origin: origin, mode: .sayNow)
    }

    /// The internet relay (Settings › Relay), which the internet path goes through; RelayAccess passes it on.
    func setPublicRelay(_ relay: URL?) {
        Task { await host?.setPublicRelay(relay) }
    }

    /// Whether that relay takes information from the internet, when the settings show it.
    func checkInternetOffer() {
        Task { await host?.checkInternetOffer() }
    }

    func update(_ source: InboundSource) {
        Task { await host?.updateSource(source) }
    }

    func remove(_ id: InboundSource.ID) {
        Task { await host?.removeSource(id) }
    }

    func changeAddress(_ id: InboundSource.ID) {
        Task { await host?.changeAddress(id) }
    }

    func sendTest(_ id: InboundSource.ID) {
        Task { await host?.sendTest(id) }
    }

    // MARK: - What Settings › Received information shows (InboundPage.swift)

    /// Its page: the relays and the sources, or a source.
    var page = Page.list
    /// The sheet over it.
    var sheet: Sheet?
}
