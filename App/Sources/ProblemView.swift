import AppKit
import SwiftUI
import VoiceCore

/// What stops the assistant, in plain words, with a way out.
struct ProblemView: View {
    let problem: AssistantProblem
    let retry: () -> Void

    var body: some View {
        switch problem {
        case .microphoneDenied:
            ContentUnavailableView {
                Label("The microphone is blocked", systemImage: "mic.slash")
            } description: {
                Text("To hear you, the assistant needs the microphone. Allow it in System Settings › Privacy & Security › Microphone, then come back here. Sound never leaves this Mac.")
            } actions: {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Try again", action: retry)
            }

        case .unsupportedMac(let chip, let memoryGiB):
            ContentUnavailableView {
                Label("This Mac is not supported", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
            } description: {
                Text("You need a Mac with Apple silicon (M1 or later) and at least 8 GB of memory. This Mac: \(chip), \(Units.gigabytes(memoryGiB.rounded())).")
            }

        case .modelMissing(let name):
            ContentUnavailableView {
                Label("Model not found", systemImage: "shippingbox")
            } description: {
                Text("The model “\(name)” is not on this Mac yet. Automatic download comes in the next stage of the project.")
            } actions: {
                Button("Try again", action: retry)
            }

        case .audioDevice(let detail):
            ContentUnavailableView {
                Label("Sound does not start", systemImage: "speaker.slash")
            } description: {
                Text("The microphone or the speakers could not be opened. Check that they are connected, then try again.")
                Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
            } actions: {
                Button("Try again", action: retry)
            }

        case .engine(let detail):
            ContentUnavailableView {
                Label("The engine did not start", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: detail).font(.caption)
            } actions: {
                Button("Try again", action: retry)
            }
        }
    }
}
