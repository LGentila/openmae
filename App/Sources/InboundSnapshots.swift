#if DEBUG
import Foundation
import OpenMaeLink
import SwiftUI
import VoiceCore

/// Still pictures of Settings › Received information (see `Snapshots`): its row in the settings, the panel without a
/// home relay, with sources, with the relay connecting, unreachable or not in home mode, a source's page (with its log,
/// without a relay, while a change of address or a removal waits for a yes), "Add a source", and the help for Home
/// Assistant.
extension Snapshots {
    private struct InboundScene {
        var name: String
        var status: InboundStatus
        var panel: WindowState.Panel = .inbound
        var page: InboundAccess.Page = .list
        var addingSource = false
        var confirming: InboundAccess.Confirmation?
        var height: CGFloat = 900
    }

    @MainActor
    static func renderInbound(to folder: URL) async {
        let ready: [AssistantEvent] = [.ready(Demo.info), .storage(Demo.storage)]
        let now = Date()
        func ago(minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let relay = URL(string: "http://192.168.1.10:8080")!
        let inboundName = "q4mzfxk2v7hn3brt6wdpya5ce2"
        /// A secret as the host makes them (32 bytes in base64url), but always the same.
        func secret(_ seed: Int) -> String {
            Data((0..<32).map { UInt8(($0 * 37 + seed * 101 + 11) % 256) }).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        let homeAssistant = InboundSource(name: "Home Assistant", mayBeUrgent: true, created: ago(minutes: 9000))
        let garage = InboundSource(name: "Porte du garage", mode: .notifyOnly, created: ago(minutes: 6000))
        let backups = InboundSource(name: "Script des sauvegardes", paused: true, created: ago(minutes: 3000))
        let washer = "La machine à laver a fini."
        let homeAssistantLog = [
            InboundLogEntry(date: ago(minutes: 1), path: .homeRelay, form: .json, result: .duplicate,
                            caller: "192.168.1.20", text: washer),
            InboundLogEntry(date: ago(minutes: 2), path: .homeRelay, form: .json, result: .said, caller: "192.168.1.20",
                            text: washer),
            InboundLogEntry(date: ago(minutes: 26), path: nil, form: .text, result: .said,
                            text: InboundPhrases.test(source: homeAssistant.name)),
            InboundLogEntry(date: ago(minutes: 48), path: .homeRelay, form: .json, result: .noText,
                            caller: "192.168.1.20", detail: InboundRefusal.noText.explanation),
            InboundLogEntry(date: ago(minutes: 75), path: .homeRelay, form: .json, result: .expired,
                            caller: "192.168.1.20", text: "Quelqu’un a sonné à la porte d’entrée."),
            InboundLogEntry(date: ago(minutes: 26 * 60), path: .homeRelay, form: .json, result: .notified,
                            caller: "192.168.1.20", text: "Les volets du salon sont fermés."),
            InboundLogEntry(date: ago(minutes: 27 * 60), path: .homeRelay, result: .unreadable, caller: "192.168.1.20",
                            detail: "The body is not a valid JSON object."),
        ]
        let garageLog = [
            InboundLogEntry(date: ago(minutes: 180), path: .homeRelay, form: .text, result: .notified,
                            caller: "192.168.1.35", text: "La porte du garage est restée ouverte."),
        ]

        let empty = InboundStatus()
        var noRelay = InboundStatus()
        noRelay.sources = [homeAssistant, garage]
        noRelay.logs = [homeAssistant.id: homeAssistantLog, garage.id: garageLog]
        var connected = noRelay
        connected.homeRelayAddress = relay
        connected.homeRelay = .connected
        connected.inboundName = inboundName
        connected.sources = [homeAssistant, garage, backups]
        for (i, source) in connected.sources.enumerated() {
            connected.addresses[source.id] = relay.appending(path: inboundName).appending(path: "in")
                .appending(path: secret(i))
        }
        var connecting = connected
        connecting.homeRelay = .connecting
        var unreachable = connected
        unreachable.homeRelay = .unreachable
        var notHomeMode = connected
        notHomeMode.homeRelay = .notHomeMode

        let scenes = [
            InboundScene(name: "inbound-1-settings", status: connected, panel: .settings, height: 1300),
            InboundScene(name: "inbound-2-empty", status: empty, height: 700),
            InboundScene(name: "inbound-3-sources", status: connected),
            InboundScene(name: "inbound-4-relay-unreachable", status: unreachable),
            InboundScene(name: "inbound-5-not-home-mode", status: notHomeMode),
            InboundScene(name: "inbound-6-source-page", status: connected, page: .source(homeAssistant.id), height: 1700),
            InboundScene(name: "inbound-7-help", status: connected, page: .help(homeAssistant.id), height: 1300),
            InboundScene(name: "inbound-8-add-source", status: connected, addingSource: true, height: 1000),
            InboundScene(name: "inbound-9-source-no-relay", status: noRelay, page: .source(homeAssistant.id), height: 1400),
            InboundScene(name: "inbound-10-change-address", status: connected, page: .source(homeAssistant.id),
                         confirming: .changeAddress),
            InboundScene(name: "inbound-11-remove", status: connected, page: .source(garage.id), confirming: .remove,
                         height: 1300),
            InboundScene(name: "inbound-12-connecting", status: connecting),
        ]
        for scene in scenes {
            let model = await scriptedModel(ready)
            let saved = model.settings
            model.settings.listening = .handsFree
            let inbound = InboundAccess(host: nil, status: scene.status)
            inbound.show(scene.page)
            inbound.addingSource = scene.addingSource
            inbound.confirming = scene.confirming
            let window = WindowState()
            let view = ContentView(model: model, window: window)
                .environment(PhoneAccess(link: nil, status: LinkStatus()))
                .environment(inbound)
                .environment(\.stillFrame, 1.7)
                .preferredColorScheme(.light)
            await save(view, size: CGSize(width: 960, height: scene.height),
                       to: folder.appending(path: scene.name + ".png"))
            {
                window.panel = scene.panel
            }
            model.settings = saved
        }
    }
}
#endif
