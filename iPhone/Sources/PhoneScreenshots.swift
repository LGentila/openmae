#if DEBUG
import OpenMaeLink
import SwiftUI
import UIKit
import VoiceCore

/// Still pictures of the screens in the simulator, without a Mac: `-screenshot <screen>` shows that screen with sample
/// content, for `xcrun simctl io booted screenshot`. `-landscape`: laid out at the landscape size and turned a quarter
/// (`ScreenshotFrame`), for a picture to turn back: an app that follows any window size cannot turn the iPad's window
/// itself, and this Xcode has no Simulator window to turn.
///
/// Screens: `conversation` (Maé answers), `conversation-listening` (the user's words as they speak),
/// `conversation-rest`, `station` (at rest), `station-speaking` (a timer rings on it), `settings`; a connected tool's
/// card (Home Assistant, « Allume le salon »): `tool-asks` (while Maé asks), `tool-asks-rest` (waiting for the « oui »
/// at rest), `tool-done`, `tool-declined`, `tool-failed`.
enum PhoneScreenshots {
    static var requested: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-screenshot"), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    static var landscape: Bool { ProcessInfo.processInfo.arguments.contains("-landscape") }

    @MainActor
    static func prepare(_ model: PhoneModel, _ screen: String) {
        let mac = PairedMac(id: String(repeating: "a", count: 26), publicKey: Data(repeating: 1, count: 32),
                            name: "MacBook Pro", relay: RelayClient.official)
        let question = TranscriptEntry(speaker: .user, text: "Mets un minuteur de dix minutes pour les pâtes.")
        let answer = TranscriptEntry(speaker: .assistant,
                                     text: "C’est parti\u{00A0}: dix minutes pour les pâtes. Je te préviens quand c’est prêt.")
        switch screen {
        case "conversation":
            model.talkMode = .tap
            model.showForScreenshot(mac: mac, link: .connected(.direct), state: .speaking, open: true,
                                    transcript: [question, answer])
        case "conversation-listening":
            model.talkMode = .tap
            let soFar = TranscriptEntry(speaker: .user, text: "Mets un minuteur de dix", pending: true)
            model.showForScreenshot(mac: mac, link: .connected(.direct), state: .userSpeaking, open: true,
                                    transcript: [soFar])
        case "conversation-rest":
            model.talkMode = .tap
            model.showForScreenshot(mac: mac, link: .connected(.direct), state: .listening, open: true,
                                    transcript: [])
        case "station":
            model.stationMode = true
            model.showForScreenshot(mac: mac, link: .connected(.direct), state: .listening, open: false,
                                    transcript: [])
        case "station-speaking":
            model.stationMode = true
            let timer = TranscriptEntry(speaker: .assistant, text: "Ton minuteur de dix minutes est terminé.")
            model.showForScreenshot(mac: mac, link: .connected(.direct), state: .speaking, open: false,
                                    transcript: [timer], voicePlaying: true)
        case "settings":
            model.stationMode = true
            model.showForScreenshot(mac: mac, link: .connected(.direct), state: .listening, open: false,
                                    transcript: [])
        case _ where screen.hasPrefix("tool-"):
            showToolCard(model, mac: mac, screen)
        default:
            break
        }
    }

    /// A connected tool's card under Maé's sentence: in French whatever the interface's language, as Maé says these
    /// sentences in French.
    @MainActor
    private static func showToolCard(_ model: PhoneModel, mac: PairedMac, _ screen: String) {
        let turnOn = MCPTool(name: "intent__HassTurnOn", description: "")
        let waiting = ConnectedToolAction(toolID: UUID(), toolName: "Home Assistant",
                                          words: ConnectedToolPhrases.card(turnOn, ["area": "salon"]),
                                          title: "Allumer le salon", status: .waiting, date: Date(),
                                          disc: ConnectedToolDisc(kind: .homeAssistant, index: 0))
        func outcome(_ status: ConnectedToolAction.Status) -> ConnectedToolAction {
            var action = waiting
            action.status = status
            return action
        }
        func exchange(_ user: String, _ answer: String) -> [TranscriptEntry] {
            [TranscriptEntry(speaker: .user, text: user), TranscriptEntry(speaker: .assistant, text: answer)]
        }
        let asks = exchange("Allume le salon.", ConnectedToolPhrases.confirm(turnOn, ["area": "salon"],
                                                                            toolName: "Home Assistant"))
        let scene: (state: PipelineState, transcript: [TranscriptEntry], card: ConnectedToolAction)? = switch screen {
        case "tool-asks": (.speaking, asks, waiting)
        case "tool-asks-rest": (.listening, asks, waiting)
        case "tool-done": (.speaking, exchange("Oui.", ConnectedToolPhrases.done), outcome(.done))
        case "tool-declined": (.speaking, exchange("Non.", ActionPhrases.declined(.french)), outcome(.refusedByUser))
        case "tool-failed":
            (.speaking, exchange("Oui.", "Je n’arrive pas à joindre Home Assistant."), outcome(.failed(.unreachable)))
        default: nil
        }
        guard let scene else { return }
        model.talkMode = .handsFree
        model.showForScreenshot(mac: mac, link: .connected(.direct), state: scene.state, open: true,
                                transcript: scene.transcript, toolActions: [scene.card])
    }
}

/// The screen as it is, or, for `-landscape`, laid out at the iPad's landscape size (its status bar and home indicator
/// kept as room at the top and bottom) and turned a quarter to fill the portrait screen.
struct ScreenshotFrame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if PhoneScreenshots.landscape {
            GeometryReader { proxy in
                content
                    .safeAreaPadding(.top, 24)
                    .safeAreaPadding(.bottom, 20)
                    .frame(width: proxy.size.height, height: proxy.size.width)
                    .rotationEffect(.degrees(-90))
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .ignoresSafeArea()
            .statusBarHidden()
        } else {
            content
        }
    }
}
#endif
