import Foundation

/// Decides, in the wake-word listening mode, whether what was said is meant for Maé.
///
/// The pipeline asks `request(in:)` about the transcript of each sentence heard while Maé waits for the phrase (or
/// thinks, or speaks): only a sentence that starts with the phrase wakes her, and the phrase is not part of the request.
/// A detector that listens to the sound itself (a small model trained on the phrase, which hears it even while the TV
/// talks) goes in front of the transcript through `hears(_:)`: the sentence being said is then meant for Maé as soon as
/// the phrase is heard, whatever its transcript says.
public protocol WakeWordDetector: Sendable {
    /// Microphone audio (16 kHz mono), chunk after chunk, while Maé waits for the phrase. True: the phrase was just
    /// heard. The pipeline acts on it once its voice detector has heard someone speak.
    func hears(_ chunk: [Float]) async -> Bool
    /// What follows the wake phrase at the very start of a transcript ("" when the sentence is only the phrase), or
    /// nil when it does not start with it.
    func request(in transcript: String) -> String?
    /// The transcript does not start with the phrase, but its start may be the phrase misheard ("Okay my?" for « OK
    /// Maé »): the sentence is checked again whole, with what follows.
    func mayStartWithPhrase(_ transcript: String) -> Bool
}

extension WakeWordDetector {
    /// A detector that only reads transcripts hears nothing in the sound.
    public func hears(_ chunk: [Float]) async -> Bool { false }
    public func mayStartWithPhrase(_ transcript: String) -> Bool { false }
}

/// « OK Maé », read in what speech recognition writes. It rarely writes the name right: the spellings accepted here are
/// those it wrote for « OK Maé » said by real and synthetic voices, near and far ("Ok Mae", "Ok, Mae.", "Okay, my",
/// "Ok Mah", "Okemae", "Au quai Mahé", "Coqué Mae", "Coquet Mai", "Ok Maï", "Ok May", "Ok, ma est"), and the ways it
/// writes the name after other words ("Mahé", "Maë", "Maye", "Maille", "Meille", "Nae"). Only the very start of the
/// sentence counts: "Elle habite à Mahé" or "René m'a écrit" never wake Maé, and "OK mais…", "Okay, maybe…", "Okay, may
/// I…" or "OK Marie" keep their meaning. Some spellings count only in one case: "Okay, maybe." when nothing follows
/// (« OK Maé » alone), "OK mais, stop" and "Okay, Maestop." for « OK Maé, stop » (at worst they silence Maé).
public struct OKMaeWakeWord: WakeWordDetector {
    public init() {}

    /// "Ok", "Okay", "Oké" (and "O.K." or "Au quai", read as two words); "Coqué" and "Coquet" when the voice gives it a
    /// hard start.
    static let leads: Set<String> = ["ok", "okay", "oke", "okey", "coque", "coquet"]
    /// The name, without accents; "my" as in "Okay, my", how a real voice's « OK Maé » is often written.
    static let names: Set<String> = ["mae", "mahe", "maee", "may", "mai", "maye", "maille", "meille", "nae", "my", "mah"]
    /// What may come before the phrase.
    static let fillers: Set<String> = ["euh", "heu", "hum", "hmm", "mm", "bon"]

    public func request(in transcript: String) -> String? {
        let words = Self.words(transcript)
        var i = Self.afterFillers(words)
        func word(_ k: Int) -> String? { k < words.count ? words[k].folded : nil }

        guard let lead = word(i) else { return nil }
        if Self.isMerged(lead) {
            return Self.remainder(transcript[words[i].range.upperBound...])
        } else if Self.leads.contains(lead) {
            i += 1
        } else if Self.isTwoWordLead(lead, word(i + 1)) {
            i += 2
        } else {
            return nil
        }

        guard let name = word(i) else { return nil }
        let rest = Self.remainder(transcript[words[i].range.upperBound...])
        if Self.names.contains(name), !(name == "may" && word(i + 1) == "i") { return rest }
        if name == "ma", word(i + 1) == "est" {  // "Ok, ma est quelle heure est-il ?"
            return Self.remainder(transcript[words[i + 1].range.upperBound...])
        }
        if name == "mais" { return StopRequest.matches(rest) ? rest : nil }  // "Ok mais, stop."
        if name == "maybe" { return rest.isEmpty ? "" : nil }  // "Okay, maybe.": the phrase alone
        if Self.isNameGluedToStop(name) { return Self.remainder("Stop " + rest) }  // "Okay, Maestop."
        return nil
    }

    /// Nothing understood yet, or an "OK" whose name was misheard ("Ok mais.", "Okay, bye.").
    public func mayStartWithPhrase(_ transcript: String) -> Bool {
        let words = Self.words(transcript)
        let i = Self.afterFillers(words)
        guard i < words.count else { return true }
        return Self.leads.contains(words[i].folded)
            || Self.isTwoWordLead(words[i].folded, i + 1 < words.count ? words[i + 1].folded : nil)
    }

    /// The name and "stop" written as one word: "Maestop".
    static func isNameGluedToStop(_ word: String) -> Bool {
        names.contains { word.hasPrefix($0) && ["stop", "stoppe"].contains(String(word.dropFirst($0.count))) }
    }

    /// "O.K." and "Au quai".
    static func isTwoWordLead(_ first: String, _ second: String?) -> Bool {
        first == "o" && second == "k" || first == "au" && second == "quai"
    }

    /// The "OK" and the name written as one word: "Okemae", "Hokemae".
    static func isMerged(_ word: String) -> Bool {
        ["hokay", "hoke", "hok", "okay", "okey", "oke", "ok"].contains {
            word.hasPrefix($0) && names.contains(String(word.dropFirst($0.count)))
        }
    }

    static func words(_ transcript: String) -> [(range: Range<String.Index>, folded: String)] {
        transcript.matches(of: /[\p{L}\p{N}]+/).map { (range: $0.range, folded: fold($0.output)) }
    }

    /// Where the words after the fillers ("euh", "bon") begin.
    static func afterFillers(_ words: [(range: Range<String.Index>, folded: String)]) -> Int {
        var i = 0
        while i < min(2, words.count), fillers.contains(words[i].folded) { i += 1 }
        return i
    }

    /// Lower case, without accents: "Maé", "Maë" and "Mae" are the same word.
    static func fold(_ word: Substring) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
    }

    /// What was said after the phrase, as written, without the punctuation that separated them, capitalized:
    /// ", quelle heure est-il ?" → "Quelle heure est-il ?".
    static func remainder(_ text: some StringProtocol) -> String {
        guard let start = text.firstIndex(where: { $0.isLetter || $0.isNumber }) else { return "" }
        let rest = text[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }
}

/// "stop", "arrête", "tais-toi", "chut"…: a request that only asks Maé to be quiet. In the wake-word mode « OK Maé,
/// stop » silences her without an answer.
public enum StopRequest {
    private static let phrases: Set<String> = [
        "stop", "stoppe", "stop stop", "stop merci", "arrete", "arrete toi", "arrete merci", "arrete de parler",
        "tais toi", "chut", "silence", "ca suffit", "c est bon", "c est bon merci", "attends",
        "be quiet", "quiet", "shut up", "enough", "that s enough",
    ]

    public static func matches(_ text: String) -> Bool {
        var s = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        s = s.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        return phrases.contains(s.split(separator: " ").joined(separator: " "))
    }
}
