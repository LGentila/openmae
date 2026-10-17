#if DEBUG
import Foundation
import OpenMaeLink
import VoiceCore

/// `-inbound-test <home relay>`: received information tried end to end without the settings. The app sets that home
/// relay, adds a source named "Essai" if there is none, and writes the source's address in the log (VOICE_DEBUG=1), for
/// `curl` to post to. With `-demo-idle` no model is loaded. Everything it keeps is thrown away: its sources and the keys
/// its inbound name comes from live in a temporary folder, its secrets in memory, never in the user's settings or keychain.
enum InboundTestHook {
    nonisolated static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-inbound-test") }

    nonisolated static let folder = FileManager.default.temporaryDirectory.appending(path: "openmae-inbound-test")
    nonisolated static var storeURL: URL { folder.appending(path: "received-information.json") }
    nonisolated static var identityStore: FileIdentityStore { FileIdentityStore(url: folder.appending(path: "keys")) }

    @MainActor private static let relay: URL? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-inbound-test"), i + 1 < arguments.count else { return nil }
        return InboundHost.homeRelayURL(from: arguments[i + 1])
    }()
    @MainActor private static var adding = false
    @MainActor private static var logged: URL?

    @MainActor
    static func follow(_ status: InboundStatus, host: InboundHost) {
        guard let relay else { return }
        guard status.homeRelayAddress == relay else {
            Task { await host.setHomeRelay(relay) }
            return
        }
        guard let source = status.sources.first(where: { $0.name == "Essai" }) else {
            if !adding {
                adding = true
                Task { await host.addSource(name: "Essai") }
            }
            return
        }
        if let address = status.addresses[source.id], address != logged {
            logged = address
            DebugLog.log("inbound test: address \(address.absoluteString)")
        }
        DebugLog.log("inbound test: home relay \(status.homeRelay)")
    }
}
#endif
