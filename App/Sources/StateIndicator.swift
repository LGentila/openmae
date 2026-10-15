import SwiftUI
import VoiceCore

/// The big round indicator: its colour and movement say what the assistant is doing.
///
/// - listening: blue, breathing slowly
/// - user speaking: green, follows the microphone level
/// - thinking: orange, a ring turns
/// - speaking: purple, follows the voice level
struct StateIndicator: View {
    let state: PipelineState
    let inputLevel: Float
    let outputLevel: Float
    var talkKeyDown = false

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let breathing = state == .listening ? 0.03 * sin(time * 1.6) : 0
            ZStack {
                Circle()
                    .fill(color.opacity(0.16))
                    .scaleEffect(1.0 + 0.32 * level + breathing)
                Circle()
                    .fill(color.opacity(0.28))
                    .scaleEffect(0.86 + 0.18 * level + breathing)
                Circle()
                    .fill(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom))
                    .scaleEffect(0.7 + 0.06 * level)
                    .shadow(color: color.opacity(0.35), radius: 12, y: 4)
                if state == .thinking {
                    Circle()
                        .trim(from: 0, to: 0.22)
                        .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .scaleEffect(0.86)
                        .rotationEffect(.radians(time * 4))
                }
                Image(systemName: symbol)
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: 190, height: 190)
        .animation(.easeOut(duration: 0.1), value: level)
        .animation(.easeInOut(duration: 0.3), value: state)
        .accessibilityElement()
        .accessibilityLabel(Text(StateText.title(state, pushToTalk: false)))
    }

    private var level: Double {
        switch state {
        case .userSpeaking: Double(inputLevel)
        case .speaking: Double(outputLevel)
        case .listening, .thinking: 0
        }
    }

    private var color: Color {
        switch state {
        case .listening: .blue
        case .userSpeaking: .green
        case .thinking: .orange
        case .speaking: .purple
        }
    }

    private var symbol: String {
        switch state {
        case .listening: talkKeyDown ? "mic.fill" : "ear"
        case .userSpeaking: "waveform"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        }
    }
}
