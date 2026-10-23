import AppKit
import SwiftUI
import VoiceCore

/// First launch (and after another tier was chosen, or the models deleted). On the left, the orb wakes up
/// while the models download, with what is going on and the button; on the right, the Mac, its tier (chosen
/// here), and the three models with their progress.
struct SetupView: View {
    let model: AssistantModel
    let setup: ModelSetup

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 36) {
                welcome
                    .frame(width: 330)
                VStack(spacing: 14) {
                    MacCard(setup: setup, tierOverride: model.settings.tierOverride, isLocked: model.isDownloading,
                            onThisMac: model.storage?.tiersOnThisMac ?? [])
                    {
                        // No "Change tier?" here: nothing runs yet. The engine starts again on that tier and says
                        // what it needs (`setupNeeded`): the models card follows.
                        model.settings.tierOverride = $0
                    }
                    ModelsCard(setup: setup, progress: model.download, isDownloading: model.isDownloading)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(EdgeInsets(top: 50, leading: 32, bottom: 30, trailing: 32))
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Orb(look: .setup(downloading: model.isDownloading), style: .setup) {
                SetupCore(fraction: model.isDownloading ? model.download?.fraction : nil)
            }
            .anchorPreference(key: OrbPlacement.self, value: .bounds) {
                OrbPlacement.Orb(anchor: $0, halo: (420, 660))
            }
            Text(title)
                .textStyle(.screenTitle)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 14)
            subtitle
                .padding(.top, 12)
                .frame(minHeight: 94, alignment: .top)
            action
                .padding(.top, 24)
            Text("The models are saved in \(folder). You can quit the app during the download: it will resume where it stopped.")
                .textStyle(.note)
                .foregroundStyle(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
        }
        .multilineTextAlignment(.center)
    }

    private var title: LocalizedStringKey {
        model.download == nil && model.downloadFailure == nil ? "Set up \(AppIdentity.name)" : "Downloading"
    }

    /// What is going on, in one or two sentences.
    @ViewBuilder private var subtitle: some View {
        Group {
            if let failure = model.downloadFailure {
                FailureMessage(failure: failure)
            } else if !setup.hasEnoughSpace, model.download == nil {
                Text("\(Units.bytes(setup.neededBytes - (setup.availableBytes ?? 0))) more free space is needed. Free up space on this Mac, then try again.")
                    .foregroundStyle(Palette.danger)
            } else if let progress = model.download {
                if !model.isDownloading {
                    Text("Paused. What has been downloaded is kept.")
                } else if progress.waitingForNetwork {
                    Text("Connection lost. The download will resume by itself as soon as the Internet is back.")
                } else {
                    Text("One download, then everything works without a connection.")
                }
            } else {
                Text("The assistant runs entirely on this Mac, without the Internet. It first needs its models: one download, and the connection is not used any more.")
            }
        }
        .textStyle(.body)
        .foregroundStyle(Palette.inkMuted)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Download → progress bar → (once done the assistant loads by itself).
    @ViewBuilder private var action: some View {
        if model.isDownloading, let progress = model.download {
            VStack(spacing: 12) {
                DownloadPill(fraction: progress.fraction)
                Button("Pause", action: model.pauseDownload)
                    .buttonStyle(PillButtonStyle())
            }
        } else if !setup.hasEnoughSpace, model.download == nil {
            Button(action: model.start) { Text("Try again") }
                .buttonStyle(PrimaryButtonStyle(icon: .download, disc: Palette.coral, metrics: .setup))
        } else {
            Button(action: model.downloadModels) { Text(buttonTitle) }
                .buttonStyle(PrimaryButtonStyle(icon: .download, disc: Palette.coral, metrics: .setup))
                .keyboardShortcut(.defaultAction)
        }
    }

    private var buttonTitle: LocalizedStringKey {
        if model.downloadFailure != nil { return "Try again" }
        if model.download != nil { return "Resume" }
        return "Download (\(Units.bytes(setup.bytesToDownload)))"
    }

    /// The models folder, in the monospaced style of a path.
    private var folder: AttributedString {
        var path = AttributedString((setup.folder as NSString).abbreviatingWithTildeInPath)
        path.font = TextStyle.path.font
        path.foregroundColor = Palette.ink.color
        path.backgroundColor = Palette.line.color
        return path
    }
}

/// What the white core of the first-launch orb shows: an arrow that bounces, then the download's progress.
private struct SetupCore: View {
    /// nil before the download.
    let fraction: Double?

    var body: some View {
        ZStack {
            if let fraction {
                Circle()
                    .stroke(Palette.track, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Palette.ink, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: fraction)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(verbatim: "\(Int((fraction * 100).rounded(.down)))")
                        .textStyle(.percentage)
                    Text(verbatim: "%")
                        .textStyle(.percentSign)
                }
                .foregroundStyle(Palette.ink)
            } else {
                BouncingArrow(size: 44)
                    .foregroundStyle(Palette.ink)
            }
        }
        .frame(width: 82, height: 82)
    }
}

/// The download icon whose arrow goes down and up again.
struct BouncingArrow: View {
    var size: CGFloat
    @State private var down = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            IconView(icon: .downloadArrow, size: size)
                .offset(y: (down ? 3 : -2.5) * size / 24)
            IconView(icon: .downloadBase, size: size)
        }
        .repeatsWhileVisible($down, .easeInOut(duration: 0.9), enabled: !reduceMotion)
    }
}

/// The main pill, become a progress bar while the models download.
private struct DownloadPill: View {
    let fraction: Double

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Palette.sun)
                .frame(width: 40, height: 40)
                .overlay { BouncingArrow(size: 22).foregroundStyle(Palette.ink) }
            Text("Downloading… \(Units.percent(fraction))")
                .textStyle(.button)
                .foregroundStyle(Palette.onInk)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .background {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Palette.ink.color
                    Palette.progress.color
                        .frame(width: proxy.size.width * fraction)
                        .animation(.linear(duration: 0.3), value: fraction)
                }
            }
        }
        .clipShape(Capsule())
        .buttonShadow()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Model download"))
        .accessibilityValue(Text(verbatim: Units.percent(fraction)))
    }
}

/// Why the download stopped, in plain words.
private struct FailureMessage: View {
    let failure: DownloadFailure

    var body: some View {
        VStack(spacing: 6) {
            switch failure {
            case .notEnoughSpace(let needed, let available):
                Text("Not enough free space: \(Units.bytes(needed)) is needed and \(Units.bytes(available)) is left. Free up space, then try again.")
            case .unavailable(let file, let status):
                Text("The model server (Hugging Face) refuses a file (error \(String(status))). The app probably needs an update.")
                detail(file)
            case .corrupted(let file):
                Text("A file arrived damaged twice in a row. Check your connection, then try again.")
                detail(file)
            case .disk(let detail):
                Text("The models could not be saved on the disk.")
                self.detail(detail)
            }
        }
        .foregroundStyle(Palette.danger)
    }

    private func detail(_ text: String) -> some View {
        Text(verbatim: text)
            .textStyle(.path)
            .foregroundStyle(Palette.inkMuted)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

// MARK: - Cards

/// The Mac and its tier, with the same menu as in Settings › Advanced.
private struct MacCard: View {
    let setup: ModelSetup
    /// The tier the user forced; nil for "Automatic".
    let tierOverride: HardwareTier?
    /// The tier cannot change during the download.
    let isLocked: Bool
    /// The tiers whose models are all on this Mac already.
    let onThisMac: Set<HardwareTier>
    /// Another tier was picked (nil: "Automatic").
    let chooseTier: (HardwareTier?) -> Void

    var body: some View {
        // As much room under the last row as above the first one.
        Card(padding: EdgeInsets(top: 4, leading: 18, bottom: 4, trailing: 18)) {
            InfoRow("This Mac") {
                Text(verbatim: "\(setup.chip) · \(Units.memory(setup.memoryGiB))")
                    .textStyle(.value)
            }
            Hairline()
            InfoRow("Tier") {
                // Without the badge when the window is too narrow for it: the menu's items still say which tiers are
                // untested.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        menu
                        TierBadge(isTested: setup.tier.isTested)
                    }
                    menu
                }
            }
            if setup.tier != setup.recommendedTier {
                HelpText(Text("Recommended tier for this Mac: \(Text(StateText.tier(setup.recommendedTier)))."))
                    .padding(.bottom, 8)
            }
            if setup.tier > setup.recommendedTier {
                HelpText("This tier needs more memory than this Mac has: the assistant may be very slow.",
                         color: Palette.danger)
                    .padding(.bottom, 8)
            }
        }
    }

    private var menu: some View {
        TierMenu(override: tierOverride, recommended: setup.recommendedTier, onThisMac: onThisMac) { chooseTier($0.tier) }
            .disabled(isLocked)
    }
}

/// The three models, what they weigh, how far their download is; then the total and the free space.
private struct ModelsCard: View {
    let setup: ModelSetup
    let progress: DownloadProgress?
    let isDownloading: Bool

    /// Speech recognition, voice, language model: always in this order.
    private var items: [ModelSetup.Item] {
        let order: [ModelRole] = [.speechRecognition, .voice, .languageModel]
        return setup.items.sorted { order.firstIndex(of: $0.role) ?? 0 < order.firstIndex(of: $1.role) ?? 0 }
    }

    var body: some View {
        Card(padding: EdgeInsets(top: 6, leading: 18, bottom: 8, trailing: 18)) {
            ForEach(items, id: \.role) { item in
                if item.role != items.first?.role { Hairline() }
                ModelRow(item: item, missing: missing(item), started: progress != nil,
                         isActive: isDownloading && progress?.currentModel == item.displayName)
            }
            Hairline(color: Palette.lineStrong)
            if progress != nil {
                SegmentedProgress(parts: items.map {
                    (weight: Double($0.totalBytes), fraction: fraction($0), color: RowColors($0.role).fill)
                })
                    .padding(.top, 14)
                    .padding(.bottom, 2)
            }
            HStack {
                Text(progress == nil ? "To download" : "Downloaded")
                    .textStyle(.rowTitle)
                Spacer()
                Group {
                    if let progress {
                        Text("\(Units.bytes(progress.doneBytes)) of \(Units.bytes(progress.totalBytes))")
                    } else {
                        Text(verbatim: Units.bytes(setup.bytesToDownload))
                    }
                }
                .textStyle(.total)
            }
            .foregroundStyle(Palette.ink)
            .frame(minHeight: 42)
            .padding(.top, 4)
            HStack {
                Text("Free space on this Mac")
                    .textStyle(.label)
                Spacer()
                Text(verbatim: Units.bytes(freeBytes))
                    .textStyle(.value)
            }
            .foregroundStyle(setup.hasEnoughSpace ? Palette.inkMuted : Palette.danger)
            .frame(minHeight: 34)
        }
    }

    /// Bytes still to download for a model.
    private func missing(_ item: ModelSetup.Item) -> Int64 {
        progress?.missingBytes[item.role] ?? item.missingBytes
    }

    private func fraction(_ item: ModelSetup.Item) -> Double {
        guard item.totalBytes > 0 else { return 1 }
        return min(1, max(0, 1 - Double(missing(item)) / Double(item.totalBytes)))
    }

    /// The free space measured before the download, minus what has been downloaded since.
    private var freeBytes: Int64? {
        guard let available = setup.availableBytes else { return nil }
        guard let progress else { return available }
        let left = progress.missingBytes.values.reduce(0, +)
        return max(0, available - max(0, setup.bytesToDownload - left))
    }
}

/// The colours of a model: a pastel disc, and the full colour for its progress.
private struct RowColors {
    let disc: RGBA
    let fill: RGBA
    let icon: Icon

    init(_ role: ModelRole) {
        switch role {
        case .speechRecognition: (disc, fill, icon) = (Palette.azureSoft, Palette.azure, .microphone)
        case .voice: (disc, fill, icon) = (Palette.coralSoft, Palette.coral, .speaker)
        case .languageModel: (disc, fill, icon) = (Palette.sunSoft, Palette.sun, .sparkles)
        }
    }
}

/// One model: before the download, waiting, downloading (its disc pulses), done (a check).
private struct ModelRow: View {
    let item: ModelSetup.Item
    let missing: Int64
    /// The download has started (or was paused).
    let started: Bool
    let isActive: Bool

    private var fraction: Double {
        item.totalBytes > 0 ? min(1, max(0, 1 - Double(missing) / Double(item.totalBytes))) : 1
    }

    private var isDone: Bool { missing == 0 }
    private var isRunning: Bool { started && !isDone && (isActive || fraction > 0) }

    var body: some View {
        let colors = RowColors(item.role)
        HStack(spacing: 14) {
            Circle()
                .fill(colors.disc)
                .frame(width: 40, height: 40)
                .overlay { IconView(icon: isDone ? .check : colors.icon, size: 20).foregroundStyle(Palette.ink) }
                .phaseAnimator([false, true]) { disc, up in
                    disc.scaleEffect(isRunning && isActive && up ? 1.08 : 1)
                } animation: { _ in .easeInOut(duration: 0.7) }
            VStack(alignment: .leading, spacing: 0) {
                Text(StateText.role(item.role))
                    .textStyle(.rowTitle)
                    .foregroundStyle(Palette.ink)
                Text(verbatim: "\(item.displayName) · \(item.license)")
                    .textStyle(.rowDetail)
                    .foregroundStyle(Palette.inkMuted)
                if started {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Palette.track)
                            RoundedRectangle(cornerRadius: 3).fill(colors.fill)
                                .frame(width: proxy.size.width * fraction)
                                .animation(.linear(duration: 0.3), value: fraction)
                        }
                    }
                    .frame(height: 5)
                    .padding(.top, 7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var trailing: some View {
        if isRunning {
            Text(verbatim: Units.percent(fraction))
                .textStyle(.strongValue)
                .foregroundStyle(Palette.ink)
        } else if isDone, !started, item.missingBytes == 0 {
            Text("already here")
                .textStyle(.value)
                .foregroundStyle(Palette.success)
        } else {
            Text(verbatim: Units.bytes(item.totalBytes))
                .textStyle(started && !isDone ? TextStyle.waitingValue : .value)
                .foregroundStyle(started && !isDone ? Palette.inkMuted : Palette.ink)
        }
    }
}

/// The global progress: one segment per model, as wide as the model is large.
private struct SegmentedProgress: View {
    let parts: [(weight: Double, fraction: Double, color: RGBA)]

    var body: some View {
        GeometryReader { proxy in
            let total = max(1, parts.reduce(0) { $0 + $1.weight })
            let available = proxy.size.width - CGFloat(parts.count - 1) * 3
            HStack(spacing: 3) {
                ForEach(parts.indices, id: \.self) { i in
                    let width = available * parts[i].weight / total
                    ZStack(alignment: .leading) {
                        Palette.track.color
                        parts[i].color.color
                            .frame(width: width * parts[i].fraction)
                            .animation(.linear(duration: 0.3), value: parts[i].fraction)
                    }
                    .frame(width: width)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// A label on the left, a value on the right.
private struct InfoRow<Value: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let value: Value

    init(_ label: LocalizedStringKey, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .textStyle(.label)
                .foregroundStyle(Palette.inkMuted)
            Spacer(minLength: 0)
            value
                .foregroundStyle(Palette.ink)
        }
        .frame(minHeight: 46)
    }
}
