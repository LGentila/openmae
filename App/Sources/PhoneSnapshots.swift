#if DEBUG
import Foundation
import OpenMaeLink
import SwiftUI
import VoiceCore

/// Still pictures of the window while an iPhone or an iPad has the conversation (see `Snapshots`; the settings' page
/// iPhone and iPad is in SettingsSnapshots.swift).
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

        var everywhere = LinkStatus()
        everywhere.devices = [device]
        everywhere.relay = .registered
        everywhere.local = true
        var onPhone = everywhere
        onPhone.hand = LinkStatus.Hand(device: device, path: .relay)
        var onPhoneHome = everywhere
        onPhoneHome.hand = LinkStatus.Hand(device: device, path: .direct)
        var onIPad = everywhere
        onIPad.devices = [device, iPad]
        onIPad.stations = [iPad.id]
        onIPad.hand = LinkStatus.Hand(device: iPad, path: .direct)

        let scenarios: [(name: String, status: LinkStatus, events: [AssistantEvent])] = [
            ("phone-10-on-iphone", onPhone, ready),
            ("phone-11-on-iphone-speaking", onPhoneHome, speaking),
            ("phone-13-on-ipad", onIPad, speaking),
        ]
        for scenario in scenarios {
            let model = await scriptedModel(scenario.events)
            let saved = model.settings
            model.settings.listening = .handsFree
            let phone = PhoneAccess(link: nil, status: scenario.status)
            let window = WindowState()
            let view = ContentView(model: model, window: window)
                .environment(phone)
                .environment(\.stillFrame, 1.7)
                .preferredColorScheme(.light)
            await save(view, size: CGSize(width: 960, height: 700), to: folder.appending(path: scenario.name + ".png"))
            model.settings = saved
        }
    }
}
#endif
