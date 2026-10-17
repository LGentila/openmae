// voice-cli inbound --relay <home relay> [--name Essai] [--seconds 600] — received information without the app: registers
// with a relay in home mode as a Mac does (with keys of its own, in a temporary folder), adds a source, prints its
// address, then prints each delivery and what Maé would do with it. No model and no voice: for trying a home relay, its
// answers and its limits with curl.

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
    guard let relay = value("--relay").flatMap(InboundHost.homeRelayURL(from:)) else {
        throw CLIError("--relay <home relay address> is required, e.g. --relay 127.0.0.1:8080")
    }
    let seconds = value("--seconds").flatMap(Double.init) ?? 600
    let folder = FileManager.default.temporaryDirectory.appending(path: "voice-cli-inbound")
    let host = InboundHost(announcer: PrintingAnnouncer(), identityStore: FileIdentityStore(url: folder.appending(path: "keys")),
                           secrets: MemoryInboundSecrets(), storeURL: nil)
    await host.setHomeRelay(relay)
    let source = await host.addSource(name: value("--name") ?? "Essai")
    print("listening for \(Int(seconds)) s through the home relay \(relay.absoluteString)")

    await withTaskGroup(of: Void.self) { tasks in
        tasks.addTask {
            var relayState: InboundStatus.HomeRelay?
            var address: URL?
            var results: [UUID: InboundLogEntry.Result] = [:]
            for await status in host.status {
                if status.homeRelay != relayState {
                    relayState = status.homeRelay
                    print("home relay: \(status.homeRelay)")
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
}
