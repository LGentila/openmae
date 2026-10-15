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
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            explanation
                .frame(maxWidth: 470)
            Spacer(minLength: 24)
            Color.clear.frame(height: 60)  // the block sits a little above the middle
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(DeleteModelsConfirmation(isPresented: $confirmDeletion, delete: deleteModels))
    }

    private var explanation: some View {
        VStack(spacing: 0) {
            title
                .textStyle(.screenTitle)
                .foregroundStyle(Palette.ink)
            message
                .textStyle(.body)
                .foregroundStyle(Palette.inkMuted)
                .padding(.top, 12)
            if let detail {
                Text(verbatim: detail)
                    .textStyle(.path)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Palette.line, in: RoundedRectangle(cornerRadius: Radius.code, style: .continuous))
                    .padding(.top, 12)
            }
            actions
                .padding(.top, 28)
        }
    }

    private var title: Text {
        switch problem {
        case .microphoneDenied: Text("The microphone is blocked")
        case .unsupportedMac: Text("This Mac is not supported")
        case .modelMissing: Text("Missing file")
        case .audioDevice: Text("Sound does not start")
        case .engine: Text("The engine did not start")
        }
    }

    private var message: Text {
        switch problem {
        case .microphoneDenied:
            Text("To hear you, the assistant needs the microphone. Allow it in System Settings › Privacy & Security › Microphone, then come back here. Sound never leaves this Mac.")
        case .unsupportedMac(let chip, let memoryGiB):
            Text("You need a Mac with Apple silicon (M1 or later) and at least 8 GB of memory. This Mac: \(chip), \(Units.memory(memoryGiB)).")
        case .modelMissing(let name):
            Text("The model “\(name)”, which ships with the app, cannot be found: the app is probably damaged. Reinstall it from its disk image.")
        case .audioDevice:
            Text("The microphone or the speakers could not be opened. Check that they are connected, then try again.")
        case .engine:
            Text("If the problem comes back, a model may be damaged: deleting the models lets you download them again.")
        }
    }

    private var detail: String? {
        switch problem {
        case .audioDevice(let detail), .engine(let detail): detail
        case .microphoneDenied, .unsupportedMac, .modelMissing: nil
        }
    }

    @ViewBuilder private var actions: some View {
        switch problem {
        case .microphoneDenied:
            VStack(spacing: 14) {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("Open System Settings")
                }
                .buttonStyle(PrimaryButtonStyle(icon: .settings))
                .keyboardShortcut(.defaultAction)
                Button("Try again", action: retry)
                    .buttonStyle(PillButtonStyle())
            }
        case .audioDevice:
            Button(action: retry) { Text("Try again") }
                .buttonStyle(PrimaryButtonStyle(icon: nil))
                .keyboardShortcut(.defaultAction)
        case .engine:
            VStack(spacing: 14) {
                Button(action: retry) { Text("Try again") }
                    .buttonStyle(PrimaryButtonStyle(icon: nil))
                    .keyboardShortcut(.defaultAction)
                Button("Delete the models…") { confirmDeletion = true }
                    .buttonStyle(PillButtonStyle(kind: .destructive))
            }
        case .unsupportedMac, .modelMissing:
            EmptyView()
        }
    }
}
