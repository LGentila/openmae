import AppKit
import SwiftUI
import VoiceCore

/// What stops the assistant, in plain words, with a way out.
struct ProblemView: View {
    let problem: AssistantProblem
    let retry: () -> Void
    let deleteModels: () -> Void
    @State private var confirmDeletion = false

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
                Text("You need a Mac with Apple silicon (M1 or later) and at least 8 GB of memory. This Mac: \(chip), \(Units.memory(memoryGiB)).")
            }

        case .modelMissing(let name):
            ContentUnavailableView {
                Label("Missing file", systemImage: "shippingbox")
            } description: {
                Text("The model “\(name)”, which ships with the app, cannot be found: the app is probably damaged. Reinstall it from its disk image.")
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
                Text("If the problem comes back, a model may be damaged: deleting the models lets you download them again.")
                Text(verbatim: detail).font(.caption)
            } actions: {
                Button("Try again", action: retry)
                Button("Delete the models…", role: .destructive) { confirmDeletion = true }
            }
            .modifier(DeleteModelsConfirmation(isPresented: $confirmDeletion, delete: deleteModels))
        }
    }
}
