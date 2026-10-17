#if DEBUG
import Foundation
import OpenMaeLink
import SwiftUI
import VoiceCore

/// Still pictures of Settings › iPhone and iPad and of the window while an iPhone or an iPad has the conversation (see
/// `Snapshots`).
extension Snapshots {
    @MainActor
    static func renderPhone(to folder: URL) async {
        let ready: [AssistantEvent] = [.ready(Demo.info), .storage(Demo.storage)]
        let speaking: [AssistantEvent] = ready + [.state(.userSpeaking), .userTranscript(Demo.question, .french),
                                                  .state(.thinking)]
            + Demo.answer.map { .assistantPiece($0) } + [.state(.speaking)]
        let added = ISO8601DateFormatter().date(from: "2026-10-15T10:00:00Z") ?? Date()
        let device = PairedDevice(publicKey: Data(repeating: 7, count: 32), name: "iPhone", model: "iPhone17,3",
                                  added: added)
        let iPad = PairedDevice(publicKey: Data(repeating: 8, count: 32), name: "iPad", model: "iPad14,1",
                                added: added)
        let link = PairingLink(macID: String(repeating: "a", count: 26), macKey: Data(repeating: 1, count: 32),
                               relay: RelayClient.official, code: Data(repeating: 2, count: 32),
                               macName: "MacBook Pro")

        var none = LinkStatus()
        none.relay = .off
        var everywhere = LinkStatus()
        everywhere.devices = [device]
        everywhere.relay = .registered
        everywhere.local = true
        var home = everywhere
        home.relayChoice = .none
        home.relay = .off
        var unreachable = everywhere
        unreachable.relay = .unreachable
        var waiting = none
        waiting.pairing = .waiting(link, expires: Date().addingTimeInterval(272))
        var expired = none
        expired.pairing = .expired
        var paired = everywhere
        paired.pairing = .added(device)
        var onPhone = everywhere
        onPhone.hand = LinkStatus.Hand(device: device, path: .relay)
        var onPhoneHome = everywhere
        onPhoneHome.hand = LinkStatus.Hand(device: device, path: .direct)
        var withStation = everywhere
        withStation.devices = [device, iPad]
        withStation.stations = [iPad.id]
        var onIPad = withStation
        onIPad.hand = LinkStatus.Hand(device: iPad, path: .direct)
        var iPadAdded = everywhere
        iPadAdded.pairing = .added(iPad)

        let scenarios: [(name: String, status: LinkStatus, panel: WindowState.Panel?, events: [AssistantEvent],
                         removing: Bool)] = [
            ("phone-1-settings", everywhere, .settings, ready, false),
            ("phone-2-empty", none, .phone, ready, false),
            ("phone-3-code", waiting, .phone, ready, false),
            ("phone-4-code-expired", expired, .phone, ready, false),
            ("phone-5-added", paired, .phone, ready, false),
            ("phone-6-list", everywhere, .phone, ready, false),
            ("phone-7-home-only", home, .phone, ready, false),
            ("phone-8-relay-unreachable", unreachable, .phone, ready, false),
            ("phone-9-remove", everywhere, .phone, ready, true),
            ("phone-10-on-iphone", onPhone, nil, ready, false),
            ("phone-11-on-iphone-speaking", onPhoneHome, nil, speaking, false),
            ("phone-12-list-with-station", withStation, .phone, ready, false),
            ("phone-13-on-ipad", onIPad, nil, speaking, false),
            ("phone-14-ipad-added", iPadAdded, .phone, ready, false),
        ]
        for scenario in scenarios {
            let model = await scriptedModel(scenario.events)
            let saved = model.settings
            model.settings.listening = .handsFree
            let phone = PhoneAccess(link: nil, status: scenario.status)
            if scenario.removing { phone.removing = device.id }
            let window = WindowState()
            let view = ContentView(model: model, window: window)
                .environment(phone)
                .environment(\.stillFrame, 1.7)
                .preferredColorScheme(.light)
            await save(view, size: CGSize(width: 960, height: 700), to: folder.appending(path: scenario.name + ".png")) {
                window.panel = scenario.panel
            }
            model.settings = saved
        }
    }
}
#endif
