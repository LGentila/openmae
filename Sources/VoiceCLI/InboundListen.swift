// voice-cli inbound --relay <home relay> [--name Essai] [--seconds 600] — received information without the app: registers
// with a relay in home mode as a Mac does (with keys of its own, in a temporary folder), adds a source, prints its
// address, then prints each delivery and what Maé would do with it. No model and no voice: for trying a home relay, its
// answers and its limits with curl.
//
// voice-cli inbound --public-relay <relay> [--acme <directory URL> [--acme-root <PEM file>]] — the same through the
// internet path: an internet source, the relay's inbound domain, a certificate (Let's Encrypt's staging server by
// default, or the given ACME server, such as Pebble with its root), and the deliveries passed through.

import Foundation
import OpenMaeLink
import VoiceCore

/// Prints what the engine would say or show.
private actor PrintingAnnouncer: Announcing {
    private let start = ContinuousClock.now

    private func stamp() -> String {
        let d = ContinuousClock.now - start
        return String(format: "[%8.1f ms]", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    }

    func canAnnounce() -> Bool { true }

    func announce(_ text: String, note: String, language: SpeechLanguage, chime: Bool, urgent: Bool, id: UUID) -> Bool {
        print("\(stamp()) Maé would say\(urgent ? " (urgent)" : "") [\(language.rawValue)]: \(text)")
        print("\(stamp())   note for the model: \(note)")
        return true
    }

    func withdrawAnnouncement(_ id: UUID) -> Bool { false }
    func announcementWaits(_ id: UUID) -> Bool { false }

    func notify(title: String, body: String) {
        print("\(stamp()) notification: \(title) — \(body)")
    }

    func requestNotificationPermission() {}
}

func runInbound(_ arguments: [String]) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)  // one line at a time, even into a file
    func value(_ flag: String) -> String? {
        arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }
    let homeRelay = value("--relay").flatMap(InboundHost.homeRelayURL(from:))
    let publicRelay = value("--public-relay").flatMap(InboundHost.homeRelayURL(from:))
    guard let relay = homeRelay ?? publicRelay else {
        throw CLIError("--relay <home relay address> or --public-relay <relay address> is required, e.g. --relay 127.0.0.1:8080")
    }
    var acme = ACMEServer.letsEncryptStaging
    if let directory = value("--acme").flatMap(URL.init(string:)) {
        let roots = try value("--acme-root").map { PEM.certificates(in: try String(contentsOfFile: $0, encoding: .utf8)) } ?? []
        acme = ACMEServer(directory: directory, trustedRoots: roots)
    }
    let seconds = value("--seconds").flatMap(Double.init) ?? 600
    let folder = FileManager.default.temporaryDirectory.appending(path: "voice-cli-inbound")
    let host = InboundHost(announcer: PrintingAnnouncer(), identityStore: FileIdentityStore(url: folder.appending(path: "keys")),
                           secrets: MemoryInboundSecrets(), storeURL: nil, keys: MemoryInboundKeys(), acme: acme)
    if let homeRelay { await host.setHomeRelay(homeRelay) }
    if let publicRelay { await host.setPublicRelay(publicRelay) }
    let source = await host.addSource(name: value("--name") ?? "Essai", origin: publicRelay != nil ? .internet : .home)
    print("listening for \(Int(seconds)) s through the \(publicRelay != nil ? "public" : "home") relay \(relay.absoluteString)")

    await withTaskGroup(of: Void.self) { tasks in
        tasks.addTask {
            var relayState: InboundStatus.HomeRelay?
            var internetState: InboundStatus.InternetPath?
            var problem: String?
            var address: URL?
            var results: [UUID: InboundLogEntry.Result] = [:]
            for await status in host.status {
                if homeRelay != nil, status.homeRelay != relayState {
                    relayState = status.homeRelay
                    print("home relay: \(status.homeRelay)")
                }
                if publicRelay != nil, status.internetPath != internetState {
                    internetState = status.internetPath
                    print("internet path: \(status.internetPath)"
                        + (status.certificateExpiry.map { ", certificate valid until \($0)" } ?? ""))
                }
                if let found = status.certificateProblem, found != problem {
                    problem = found
                    print("certificate problem: \(found)")
                }
                if let found = status.addresses[source], found != address {
                    address = found
                    print("address: \(found.absoluteString)")
                }
                for entry in (status.logs[source] ?? []).reversed() where results[entry.id] != entry.result {
                    results[entry.id] = entry.result
                    print("log: \(entry.result.rawValue) via \(entry.path?.rawValue ?? "test") from \(entry.caller ?? "?")"
                        + (entry.form.map { ", \($0.rawValue)" } ?? "") + (entry.text.map { ": \($0)" } ?? "")
                        + (entry.detail.map { " (\($0))" } ?? ""))
                }
            }
        }
        tasks.addTask { try? await Task.sleep(for: .seconds(seconds)) }
        await tasks.next()
        tasks.cancelAll()
    }
    await host.setHomeRelay(nil)
    await host.setPublicRelay(nil)
}
