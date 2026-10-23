import AppKit
import SwiftUI
import VoiceCore

/// The measurements side panel: latency of each stage of the last turn, session statistics, model,
/// audio and Mac.
struct DebugPanel: View {
    let model: AssistantModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                lastTurn
                session
                languageModel
                audio
                mac
                if let warning = model.lastWarning {
                    GroupBox("Last incident") {
                        Text(verbatim: warning)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Button("Copy measurements") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.measurementsJSON(), forType: .string)
                }
                .help("Copies all measurements of this session (JSON)")
            }
            .padding()
        }
    }

    // MARK: - Sections

    @ViewBuilder private var lastTurn: some View {
        GroupBox("Last turn") {
            if let turn = model.turns.last {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: Units.seconds(fromMilliseconds: turn.latencyMs))
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .foregroundStyle(latencyColor(turn.latencyMs))
                        Text("end of speech → first sound")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    let stages: [(LocalizedStringKey, Double?)] = [
                        ("Silence wait", turn.endOfTurnMs),
                        ("Transcription", turn.transcriptionMs),
                        ("Model's first token", turn.firstTokenMs),
                        ("First sentence", turn.firstPieceMs),
                        ("First sound of the voice", turn.synthesisFirstAudioMs),
                    ]
                    let longest = max(stages.compactMap(\.1).max() ?? 1, 1)
                    ForEach(stages.indices, id: \.self) { i in
                        StageRow(label: stages[i].0, ms: stages[i].1, fraction: (stages[i].1 ?? 0) / longest)
                    }
                    if turn.speculative {
                        Text("Prepared during the silence (speculative start): stages overlap.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Talk to the assistant to see measurements.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var session: some View {
        GroupBox("Session") {
            VStack(spacing: 4) {
                LabeledContent("Turns") { Text(verbatim: "\(model.turns.count)") }
                LabeledContent("Median latency") {
                    Text(verbatim: Units.seconds(fromMilliseconds: model.medianLatencyMs))
                        .foregroundStyle(latencyColor(model.medianLatencyMs))
                }
                LabeledContent("Interruptions") { Text(verbatim: "\(model.bargeIns.count)") }
                LabeledContent("Voice cut after (median)") {
                    Text(verbatim: Units.milliseconds(model.medianBargeInMs))
                }
            }
        }
    }

    private var languageModel: some View {
        GroupBox("Language model") {
            VStack(spacing: 4) {
                if let info = model.info {
                    LabeledContent("Model") { Text(verbatim: info.languageModel) }
                }
                LabeledContent("Tokens already in memory") { Text(verbatim: count(model.diagnostics.reusedTokens)) }
                LabeledContent("Tokens computed") { Text(verbatim: count(model.diagnostics.computedTokens)) }
                LabeledContent("Compute time") { Text(verbatim: Units.milliseconds(model.diagnostics.prefillMs)) }
                LabeledContent("History size") { Text(verbatim: count(model.turns.last?.historyTokens)) }
                LabeledContent("Full recomputations") { Text(verbatim: "\(model.diagnostics.cacheRebuilds)") }
                Text("“Tokens” are the word pieces the model works with.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var audio: some View {
        GroupBox("Audio") {
            VStack(spacing: 4) {
                let d = model.diagnostics
                LabeledContent("Mode") { Text(StateText.audioMode(d.audioMode)) }
                LabeledContent("Microphone") { Text(verbatim: d.inputDevice ?? "—") }
                LabeledContent("Output") { Text(verbatim: d.outputDevice ?? "—") }
                LabeledContent("Microphone format") {
                    Text(verbatim: "\(Units.kilohertz(d.inputSampleRate)) · \(d.inputChannels ?? 0) ch")
                }
                LabeledContent("Voice dropouts") {
                    Text(verbatim: "\(d.audioUnderruns)")
                        .foregroundStyle(d.audioUnderruns > 0 ? .orange : .primary)
                }
            }
        }
    }

    private var mac: some View {
        GroupBox("Mac") {
            VStack(spacing: 4) {
                if let info = model.info {
                    LabeledContent("Chip") { Text(verbatim: info.chip) }
                    LabeledContent("Memory") { Text(verbatim: Units.memory(info.memoryGiB)) }
                    LabeledContent("Tier") {
                        Text(StateText.tier(info.tier))
                            .foregroundStyle(info.tier.isTested ? Color.primary : Color.orange)
                    }
                    if !info.tier.isTested {
                        Text("Untested tier: performance is estimated.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                LabeledContent("Memory used by the app") {
                    Text(verbatim: Units.gigabytes(model.diagnostics.memoryGB))
                }
            }
        }
    }

    // MARK: - Helpers

    private func count(_ value: Int?) -> String {
        value.map(Units.count) ?? "—"
    }

    private func latencyColor(_ ms: Double?) -> Color {
        guard let ms else { return .primary }
        return ms < 1000 ? .green : ms < 1500 ? .orange : .red
    }
}

private struct StageRow: View {
    let label: LocalizedStringKey
    let ms: Double?
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(verbatim: Units.milliseconds(ms)).font(.caption.monospacedDigit())
            }
            GeometryReader { geometry in
                Capsule()
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: max(2, geometry.size.width * min(max(fraction, 0), 1)))
            }
            .frame(height: 4)
        }
    }
}
