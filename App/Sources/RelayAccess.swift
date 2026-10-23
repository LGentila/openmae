import Foundation
import Observation
import OpenMaeLink
import VoiceCore

/// The relays, set once for the whole app in Settings › Relay.
///
/// - The internet relay (the OpenMaé relay by default, or one's own; or none) lets the iPhones and iPads reach this Mac
///   away from home, and brings what the sources send from the internet, passed through without being read. The link
///   keeps it (`LinkHost`, `link.json`); this passes it on to received information, whose internet path goes through
///   it.
/// - The home relay (none by default): a relay in home mode on the home network, which brings what the sources at home
///   send. Received information keeps it (`InboundHost`, `received-information.json`).
///
/// Built on PhoneAccess and InboundAccess, which follow the link's and received information's status: where each relay
/// stands comes from what both say.
@MainActor
@Observable
final class RelayAccess {
    let phone: PhoneAccess
    let inbound: InboundAccess
    /// What the switches turned off, and the last relay of one's own: given back while the app runs.
    @ObservationIgnored private var lastInternetRelay: RelayChoice?
    @ObservationIgnored private var lastOwnRelay: URL?
    @ObservationIgnored private var lastHomeRelay: URL?

    /// `passesInternetRelay`: false when received information is given a relay of its own (the inbound test) or none
    /// (still pictures of the screens).
    init(phone: PhoneAccess, inbound: InboundAccess, passesInternetRelay: Bool = true) {
        self.phone = phone
        self.inbound = inbound
        guard passesInternetRelay else { return }
        // The internet path of received information goes through the internet relay, and follows when it changes.
        phone.relayChanged = { [weak inbound] relay in inbound?.setPublicRelay(relay) }
    }

    // MARK: - The internet relay

    var internetRelay: RelayChoice { phone.status.relayChoice }

    var isInternetRelayOn: Bool { internetRelay != .none }

    func setInternetRelay(_ choice: RelayChoice) {
        if case .custom(let url) = internetRelay { lastOwnRelay = url }
        phone.setRelay(choice)
    }

    /// Its switch: off remembers the relay, on gives it back (the OpenMaé relay the first time).
    func setInternetRelayOn(_ on: Bool) {
        guard on != isInternetRelayOn else { return }
        if on {
            setInternetRelay(lastInternetRelay ?? .official)
        } else {
            lastInternetRelay = internetRelay
            setInternetRelay(.none)
        }
    }

    /// The relay of one's own to show in its sheet: the chosen one, else the last one.
    var ownRelayToEdit: URL? {
        if case .custom(let url) = internetRelay { return url }
        return lastOwnRelay
    }

    /// A relay of one's own as it is typed ("relay.example.org", "https://relay.example.org"); nil when it cannot be an
    /// address. Without a scheme, it is HTTPS.
    static func ownRelayURL(from text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    enum InternetState: Equatable {
        case off, connecting, ready, unreachable
    }

    /// Where the internet relay stands: the iPhones' registration says it while an iPhone or an iPad is paired; else
    /// what received information last read of it (the settings window has it read when it opens).
    var internetState: InternetState {
        guard isInternetRelayOn else { return .off }
        switch phone.status.relay {
        case .registered: return .ready
        case .unreachable: return .unreachable
        case .connecting: return .connecting
        case .off:
            switch inbound.status.internetPath {
            case .checking: return .connecting
            case .unreachable: return .unreachable
            case .notOffered, .available, .gettingCertificate, .ready: return .ready
            }
        }
    }

    /// Whether it takes information from the internet, and how far the internet path is, when the settings show it:
    /// read again when the relay changes, as long as nothing else asks it.
    func readInternetOffer() {
        inbound.checkInternetOffer()
    }

    // MARK: - The home relay

    var homeRelayAddress: URL? { inbound.status.homeRelayAddress }

    /// What the user typed for it; false when it cannot be an address.
    @discardableResult
    func setHomeRelay(_ text: String) -> Bool {
        inbound.setHomeRelay(text)
    }

    /// Its switch turned on: gives back the address it had while the app runs; false when there is none to give back,
    /// and the address must be typed.
    func restoreHomeRelay() -> Bool {
        guard homeRelayAddress == nil else { return true }
        guard let last = lastHomeRelay else { return false }
        inbound.setHomeRelayAddress(last)
        return true
    }

    /// Its switch turned off: the sources at home have no address any more.
    func removeHomeRelay() {
        if let address = homeRelayAddress { lastHomeRelay = address }
        inbound.setHomeRelayAddress(nil)
    }

    /// The address to show in its sheet: the current one, else the last one.
    var homeRelayToEdit: URL? { homeRelayAddress ?? lastHomeRelay }
}
