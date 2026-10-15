import AppKit
import SwiftUI
import VoiceCore

/// First launch (and after another tier was chosen, or the models deleted): the Mac, its tier, what will be
/// downloaded and how much space it takes, then the download itself.
struct SetupView: View {
    let model: AssistantModel
    let setup: ModelSetup
    /// Opens the settings (to choose another tier).
    let showSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(.tint)
                    Text("Set up \(AppIdentity.name)")
                        .font(.title.weight(.semibold))
                    Text("The assistant runs entirely on this Mac, without the Internet. It first needs its models: one download, and the connection is not used any more.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                MacSummary(setup: setup, showSettings: showSettings)
                ModelList(setup: setup)

                if model.download != nil || model.downloadFailure != nil {
                    DownloadStatus(model: model)
                }
                actions

                Text("The models are saved in \((setup.folder as NSString).abbreviatingWithTildeInPath). You can quit the app during the download: it will resume where it stopped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var actions: some View {
        if model.isDownloading {
            Button("Pause", action: model.pauseDownload)
                .controlSize(.large)
        } else if !setup.hasEnoughSpace, model.download == nil {
            Label("\(Units.bytes(setup.neededBytes - (setup.availableBytes ?? 0))) more free space is needed. Free up space on this Mac, then try again.",
                  systemImage: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again", action: model.start)
                .controlSize(.large)
        } else {
            Button(action: model.downloadModels) {
                Text(buttonTitle)
                    .frame(minWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var buttonTitle: LocalizedStringKey {
        if model.downloadFailure != nil { return "Try again" }
        if model.download != nil { return "Resume" }
        return "Download (\(Units.bytes(setup.bytesToDownload)))"
    }
}

/// The Mac and its tier.
private struct MacSummary: View {
    let setup: ModelSetup
    let showSettings: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Row("This Mac") {
                    Text(verbatim: "\(setup.chip) · \(Units.memory(setup.memoryGiB))")
                }
                Row("Tier") {
                    HStack(spacing: 6) {
                        Text(StateText.tier(setup.tier))
                        TierBadge(tier: setup.tier)
                    }
                }
                if setup.tier != setup.recommendedTier {
                    Text("Chosen in the settings (Advanced). Recommended tier for this Mac: \(Text(StateText.tier(setup.recommendedTier))).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if setup.tier > setup.recommendedTier {
                    Text("This tier needs more memory than this Mac has: the assistant may be very slow.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button("Choose another tier…", action: showSettings)
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(4)
        }
    }
}

/// "tested" in green, or "untested / estimated" in orange: untested tiers must say so.
struct TierBadge: View {
    let tier: HardwareTier

    var body: some View {
        Text(tier.isTested ? "tested" : "untested / estimated")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill((tier.isTested ? Color.green : Color.orange).opacity(0.18)))
            .foregroundStyle(tier.isTested ? Color.green : Color.orange)
    }
}

/// What will be downloaded, model by model, and the total against the free space.
private struct ModelList: View {
    let setup: ModelSetup

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(setup.items, id: \.displayName) { item in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(StateText.role(item.role))
                            Text(verbatim: "\(item.displayName) · \(item.license)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if item.missingBytes == 0 {
                            Label("already here", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Text(verbatim: Units.bytes(item.totalBytes))
                                .monospacedDigit()
                        }
                    }
                }
                Divider()
                Row("To download") {
                    Text(verbatim: Units.bytes(setup.bytesToDownload))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                Row("Free space on this Mac") {
                    Text(verbatim: Units.bytes(setup.availableBytes))
                        .monospacedDigit()
                        .foregroundStyle(setup.hasEnoughSpace ? Color.primary : Color.red)
                }
            }
            .padding(4)
        }
    }
}

/// Progress bar and what is going on: speed, time left, waiting for the network, paused, failure.
private struct DownloadStatus: View {
    let model: AssistantModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = model.download {
                ProgressView(value: progress.fraction)
                HStack {
                    Text(verbatim: "\(Units.bytes(progress.doneBytes)) / \(Units.bytes(progress.totalBytes))")
                        .monospacedDigit()
                    Spacer()
                    if model.isDownloading, !progress.waitingForNetwork {
                        Text(verbatim: [Units.speed(progress.bytesPerSecond), Units.remaining(progress.secondsRemaining)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .monospacedDigit()
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if progress.waitingForNetwork, model.isDownloading {
                    Label("Connection lost. The download will resume by itself as soon as the Internet is back.",
                          systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                } else if model.isDownloading, let current = progress.currentModel {
                    Text("Downloading: \(current)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if !model.isDownloading, model.downloadFailure == nil {
                    Text("Paused. What has been downloaded is kept.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if let failure = model.downloadFailure {
                FailureMessage(failure: failure)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Why the download stopped, in plain words.
private struct FailureMessage: View {
    let failure: DownloadFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch failure {
            case .notEnoughSpace(let needed, let available):
                Label("Not enough free space: \(Units.bytes(needed)) is needed and \(Units.bytes(available)) is left. Free up space, then try again.",
                      systemImage: "externaldrive.badge.exclamationmark")
            case .unavailable(let file, let status):
                Label("The model server (Hugging Face) refuses a file (error \(String(status))). The app probably needs an update.",
                      systemImage: "xmark.icloud")
                Text(verbatim: file).font(.caption.monospaced()).foregroundStyle(.secondary)
            case .corrupted(let file):
                Label("A file arrived damaged twice in a row. Check your connection, then try again.",
                      systemImage: "exclamationmark.triangle")
                Text(verbatim: file).font(.caption.monospaced()).foregroundStyle(.secondary)
            case .disk(let detail):
                Label("The models could not be saved on the disk.", systemImage: "externaldrive.badge.xmark")
                Text(verbatim: detail).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.red)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
    }
}

/// A label on the left, a value on the right.
private struct Row<Content: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            content
        }
    }
}
