import Foundation
import Observation
import OpenMaeLink
import VoiceCore

/// Received information, as the Mac's settings show it: the home relay and its state, the sources with their secret
/// addresses and their logs. Built from OpenMaeLink.InboundHost's status.
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

    /// What the user typed for the home relay; false when it cannot be an address.
    @discardableResult
    func setHomeRelay(_ text: String) -> Bool {
        guard let url = InboundHost.homeRelayURL(from: text) else { return false }
        Task { await host?.setHomeRelay(url) }
        return true
    }

    func removeHomeRelay() {
        Task { await host?.setHomeRelay(nil) }
    }

    /// A new home source; its id once added.
    func addSource(name: String) async -> InboundSource.ID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let host else { return nil }
        return await host.addSource(name: name, origin: .home, mode: .sayNow)
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

    // MARK: - What Settings › Received information shows (InboundPanel.swift)

    /// Its page: the home relay and the sources, a source, or how to send from Home Assistant.
    var page = Page.list
    /// "Add a source" was clicked: its name is being typed.
    var addingSource = false
    /// On a source's page: the change of its address, or its removal, waiting for a yes.
    var confirming: Confirmation?
}
