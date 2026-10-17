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
/// Screens: `conversation` (Maé answers), `conversation-rest`, `station` (at rest), `station-speaking` (a timer
/// rings on it), `settings`.
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
        default:
            break
        }
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
