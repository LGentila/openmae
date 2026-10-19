import Foundation
import Observation
import OpenMaeLink
import VoiceCore

/// Received information, as the Mac's settings show it: the home path (the home relay, or OpenMaé's internal door) and
/// its state, the internet path, the sources with their secret addresses and their logs. Built from
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

    /// What the user typed for the home relay, which becomes the home path; false when it cannot be an address.
    @discardableResult
    func setHomeRelay(_ text: String) -> Bool {
        guard let url = InboundHost.homeRelayURL(from: text) else { return false }
        Task { await host?.setHomeRelay(url) }
        return true
    }

    /// No home path, or back to the home relay already set. The door opens with `openDoor`.
    func setHomePath(_ path: InboundStatus.HomePath) {
        Task { await host?.setHomePath(path) }
    }

    /// "Open the door", once its warning is read: the internal door becomes the home path, and this network becomes
    /// the home network. False when this Mac sees no network to record (then nothing changed).
    func openDoor() async -> Bool {
        guard let host else { return false }
        return await host.openDoor() == .opened
    }

    /// A desktop's "home network" safeguard; false when it could not be turned on (no network to record).
    func setDoorSafeguard(_ on: Bool) async -> Bool {
        await host?.setDoorSafeguard(on) ?? false
    }

    func setDoorPort(_ port: UInt16) {
        Task { await host?.setDoorPort(port) }
    }

    /// A new source; its id once added.
    func addSource(name: String, origin: InboundSource.Origin = .home) async -> InboundSource.ID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let host else { return nil }
        return await host.addSource(name: name, origin: origin, mode: .sayNow)
    }

    /// The relay the iPhones use (Settings › iPhone and iPad), which the internet path goes through.
    func setPublicRelay(_ relay: URL?) {
        Task { await host?.setPublicRelay(relay) }
    }

    /// Whether that relay takes information from the internet, when the panel shows it.
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

    /// Its page: the paths and the sources, or a source.
    var page = Page.list
    /// The sheet over it.
    var sheet: Sheet?
}
