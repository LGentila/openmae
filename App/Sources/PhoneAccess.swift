import Foundation
import Observation
import OpenMaeLink
import VoiceCore

/// The iPhone access, as the Mac's screens show it: paired iPhones, the pairing in progress, how reachable this Mac
/// is, and whether an iPhone has the conversation. Built from the link's status (OpenMaeLink.LinkHost).
@MainActor
@Observable
final class PhoneAccess {
    private(set) var status = LinkStatus()
    /// The iPhone whose removal is being confirmed in Settings › iPhone and iPad.
    var removing: PairedDevice.ID?
    /// Told the relay's address at first, then on every change (the internet path of received information follows it).
    @ObservationIgnored var relayChanged: ((URL?) -> Void)?
    @ObservationIgnored private var toldRelay: URL??
    @ObservationIgnored private let link: LinkHost?

    /// `link`: nil in still pictures of the screens, which set `status` themselves.
    init(link: LinkHost?, status: LinkStatus = LinkStatus()) {
        self.link = link
        self.status = status
        guard let link else { return }
        Task { [weak self] in
            for await status in link.status {
                #if DEBUG
                if case .waiting(let pairing, _) = status.pairing, self?.status.pairing != status.pairing {
                    DebugLog.log("pairing link: \(pairing.url)")
                }
                #endif
                self?.status = status
                self?.tellRelay(status.relayChoice.url)
            }
        }
        #if DEBUG
        // A test script can start a pairing (the link appears in the log with VOICE_DEBUG=1), as `voice-cli
        // link-client --pair` needs: DistributedNotificationCenter, "OpenMaeDebugPairing".
        DistributedNotificationCenter.default().addObserver(forName: .init("OpenMaeDebugPairing"), object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startPairing() }
        }
        #endif
    }

    private func tellRelay(_ relay: URL?) {
        guard toldRelay != .some(relay) else { return }
        toldRelay = .some(relay)
        relayChanged?(relay)
    }

    /// The iPhone that has the conversation.
    var hand: LinkStatus.Hand? { status.hand }

    /// The sheet over Settings › iPhone and iPad: the pairing (its code, its expiry, the device added), or a removal
    /// waiting for a yes.
    enum Sheet: Hashable {
        case pairing
        case remove(PairedDevice.ID)
    }

    var sheet: Sheet? {
        if status.pairing != .idle { return .pairing }
        if let removing, status.devices.contains(where: { $0.id == removing }) { return .remove(removing) }
        return nil
    }

    /// The badge of the iPhone settings, and the value of their row in the settings.
    enum Reach: Equatable {
        case noPhone
        case everywhere
        case homeOnly
        case relayUnreachable
        case connecting
    }

    var reach: Reach {
        guard !status.devices.isEmpty else { return .noPhone }
        switch status.relay {
        case .off: return .homeOnly
        case .registered: return .everywhere
        case .unreachable: return .relayUnreachable
        case .connecting: return .connecting
        }
    }

    func startPairing() {
        Task { await link?.startPairing() }
    }

    func cancelPairing() {
        Task { await link?.cancelPairing() }
    }

    func remove(_ device: PairedDevice) {
        Task { await link?.remove(device.id) }
    }

    func setRelay(_ choice: RelayChoice) {
        Task { await link?.setRelay(choice) }
    }

    func setKeepAwake(_ on: Bool) {
        Task { await link?.setKeepAwake(on) }
    }

    /// "Take over here": the Mac has the conversation again.
    func takeBack() {
        Task { await link?.takeBack() }
    }
}
