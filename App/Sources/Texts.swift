import Foundation
import SwiftUI
import VoiceCore

/// The interface's wording for the engine's states. The source text is English; the French translation is
/// in Resources/Localizable.xcstrings.
enum StateText {
    /// What VoiceOver says of the orb.
    static func accessibilityName(_ state: PipelineState) -> Text {
        Text(spokenName(state))
    }

    /// The same, as VoiceOver announces it when the capsule changes.
    static func spokenName(_ state: PipelineState) -> String {
        switch state {
        case .listening: String(localized: "Idle")
        case .userSpeaking: String(localized: "Listening")
        case .thinking: String(localized: "Thinking")
        case .speaking: String(localized: "Maé is speaking")
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

    static func role(_ role: ModelRole) -> LocalizedStringKey {
        switch role {
        case .speechRecognition: "Speech recognition"
        case .languageModel: "Language model"
        case .voice: "Voice"
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

    /// Memory of the Mac: "32 Go".
    static func memory(_ gibibytes: Double) -> String {
        Measurement(value: gibibytes.rounded(), unit: UnitInformationStorage.gigabytes)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    /// "17,5 Go" (decimal units, like the Finder).
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return value.formatted(.byteCount(style: .file))
    }

    /// "46 %": a share, rounded down (100 % only when it is complete).
    static func percent(_ fraction: Double) -> String {
        ((fraction * 100).rounded(.down) / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    static func kilohertz(_ hertz: Double?) -> String {
        guard let hertz else { return "—" }
        return Measurement(value: hertz / 1000, unit: UnitFrequency.kilohertz)
            .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }
}
