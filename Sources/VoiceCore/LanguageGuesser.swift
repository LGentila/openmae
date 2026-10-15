import Foundation
import NaturalLanguage

/// Decides whether the user spoke French or English, from the transcript.
///
/// Uses Apple's on-device NaturalLanguage framework (no network, no model download). French is the
/// default: short or ambiguous phrases ("OK", "merci", "super") keep the previous language.
public enum LanguageGuesser {
    public static func guess(_ text: String, previous: SpeechLanguage = .french) -> SpeechLanguage {
        let words = text.split(whereSeparator: { !$0.isLetter }).count
        guard words >= 3 else { return previous }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.french, .english]
        recognizer.languageHints = [.french: 0.6, .english: 0.4]
        recognizer.processString(text)
        let scores = recognizer.languageHypotheses(withMaximum: 2)
        let fr = scores[.french] ?? 0
        let en = scores[.english] ?? 0
        if en > 0.7 { return .english }
        if fr > 0.7 { return .french }
        return previous
    }
}
