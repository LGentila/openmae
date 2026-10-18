#if DEBUG
import Foundation
import OpenMaeLink
import VoiceCore

/// `-inbound-test <home relay>`: received information tried end to end without the settings. The app sets that home
/// relay, adds a source named "Essai" if there is none, and writes the source's address in the log (VOICE_DEBUG=1), for
/// `curl` to post to. With `-demo-idle` no model is loaded. Everything it keeps is thrown away: its sources and the keys
/// its inbound name comes from live in a temporary folder, its secrets in memory, never in the user's settings or keychain.
///
/// `-inbound-test-public <relay> [-inbound-test-acme <directory> -inbound-test-acme-root <PEM>]`: the same through the
/// internet path, with a source named "Essai Internet": that relay instead of the iPhones' one, and the certificate from
/// that ACME server (Pebble, with its root), else Let's Encrypt's staging server. Its keys stay in memory too.
enum InboundTestHook {
    nonisolated static var isOn: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-inbound-test") || arguments.contains("-inbound-test-public")
    }

    nonisolated private static func argument(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    nonisolated static var publicRelay: URL? { argument("-inbound-test-public").flatMap(InboundHost.homeRelayURL(from:)) }

    /// The ACME server of the test: the one given, or Let's Encrypt's staging server; nil without a public relay.
    nonisolated static var acme: ACMEServer? {
        guard publicRelay != nil else { return nil }
        guard let directory = argument("-inbound-test-acme").flatMap(URL.init(string:)) else { return .letsEncryptStaging }
        let roots = argument("-inbound-test-acme-root")
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }.map(PEM.certificates(in:)) ?? []
        return ACMEServer(directory: directory, trustedRoots: roots)
    }

    nonisolated static let folder = FileManager.default.temporaryDirectory.appending(path: "openmae-inbound-test")
    nonisolated static var storeURL: URL { folder.appending(path: "received-information.json") }
    nonisolated static var identityStore: FileIdentityStore { FileIdentityStore(url: folder.appending(path: "keys")) }

    @MainActor private static let relay: URL? = argument("-inbound-test").flatMap(InboundHost.homeRelayURL(from:))
    @MainActor private static var adding = false
    @MainActor private static var addingInternet = false
    @MainActor private static var logged: URL?
    @MainActor private static var loggedInternet: URL?
    @MainActor private static var loggedPath: InboundStatus.InternetPath?

    @MainActor
    static func follow(_ status: InboundStatus, host: InboundHost) {
        followPublic(status, host: host)
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

    @MainActor
    private static func followPublic(_ status: InboundStatus, host: InboundHost) {
        guard let relay = publicRelay else { return }
        guard status.publicRelayAddress == relay else {
            Task { await host.setPublicRelay(relay) }
            return
        }
        guard let source = status.sources.first(where: { $0.name == "Essai Internet" }) else {
            if !addingInternet {
                addingInternet = true
                Task { await host.addSource(name: "Essai Internet", origin: .internet) }
            }
            return
        }
        if let address = status.addresses[source.id], address != loggedInternet {
            loggedInternet = address
            DebugLog.log("inbound test: internet address \(address.absoluteString)")
        }
        if status.internetPath != loggedPath {
            loggedPath = status.internetPath
            DebugLog.log("inbound test: internet path \(status.internetPath)"
                + (status.certificateProblem.map { " (\($0))" } ?? ""))
        }
    }
}
#endif
