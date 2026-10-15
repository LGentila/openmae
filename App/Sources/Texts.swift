import Foundation
import SwiftUI
import VoiceCore

/// The interface's wording for the engine's states. French is the source language; translations are in
/// Resources/Localizable.xcstrings.
enum StateText {
    static func title(_ state: PipelineState, pushToTalk: Bool) -> LocalizedStringKey {
        switch state {
        case .listening: pushToTalk ? "Hold Space to talk" : "I'm listening"
        case .userSpeaking: "I hear you…"
        case .thinking: "Thinking…"
        case .speaking: "Answering"
        }
    }

    static func hint(_ state: PipelineState, pushToTalk: Bool) -> LocalizedStringKey {
        switch state {
        case .listening:
            pushToTalk ? "Or hold the button at the bottom of the window." : "Speak whenever you like."
        case .userSpeaking:
            pushToTalk ? "Release to send." : "I'll answer as soon as you're done."
        case .thinking, .speaking:
            pushToTalk
                ? "Hold Space to interrupt me, or press Escape."
                : "Interrupt me whenever you like, or press Escape."
        }
    }

    static func loading(_ step: LoadingStep?) -> LocalizedStringKey {
        switch step {
        case nil: "Starting…"
        case .microphone: "Accessing the microphone…"
        case .speechRecognition: "Loading speech recognition…"
        case .languageModel: "Loading the language model…"
        case .voice: "Loading the voice…"
        }
    }

    static func tier(_ tier: HardwareTier) -> LocalizedStringKey {
        switch tier {
        case .unsupported: "Not supported"
        case .minimum: "Minimum (8 GB)"
        case .standard: "Standard (16 to 24 GB)"
        case .comfort: "Comfort (32 to 36 GB)"
        case .max: "Maximum (48 GB and more)"
        }
    }

    static func audioMode(_ mode: AudioMode) -> LocalizedStringKey {
        switch mode {
        case .speakers: "Speakers"
        case .headphones: "Headphones"
        }
    }
}

/// Numbers with their unit, in the user's language ("1,24 s" in French, "1.24 s" in English).
enum Units {
    static func milliseconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return Measurement(value: value.rounded(), unit: UnitDuration.milliseconds)
            .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    static func seconds(fromMilliseconds value: Double?) -> String {
        guard let value else { return "—" }
        return Measurement(value: value / 1000, unit: UnitDuration.seconds)
            .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(2))))
    }

    static func gigabytes(_ value: Double?) -> String {
        guard let value, value >= 0 else { return "—" }
        return Measurement(value: value, unit: UnitInformationStorage.gigabytes)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    static func kilohertz(_ hertz: Double?) -> String {
        guard let hertz else { return "—" }
        return Measurement(value: hertz / 1000, unit: UnitFrequency.kilohertz)
            .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }
}
