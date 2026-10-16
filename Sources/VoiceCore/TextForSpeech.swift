import Foundation

/// Removes what a language model writes but a voice must never say: hidden reasoning blocks and
/// control tags (`<think>…</think>` for Qwen, `<|channel>thought…<channel|>` for Gemma 4,
/// any other `<|…|>`-style tag). Works on a stream: text arrives in small pieces and a tag may be
/// split across two pieces, so a possible tag start is held back until it can be decided.
public struct ReasoningFilter: Sendable {
    private static let blocks: [(start: String, end: String)] = [
        ("<think>", "</think>"),
        ("<|channel>", "<channel|>"),
    ]
    private var buffer = ""
    private var insideBlockEnd: String?

    public init() {}

    public mutating func push(_ text: String) -> String {
        buffer += text
        return drain(final: false)
    }

    public mutating func flush() -> String {
        let out = drain(final: true)
        buffer = ""
        return out
    }

    private mutating func drain(final: Bool) -> String {
        var out = ""
        while !buffer.isEmpty {
            if let end = insideBlockEnd {
                if let r = buffer.range(of: end) {
                    buffer = String(buffer[r.upperBound...])
                    insideBlockEnd = nil
                    continue
                }
                // Keep only what could be the start of the end marker.
                buffer = String(buffer.suffix(end.count - 1))
                if final { buffer = "" }
                return out
            }
            guard let lt = buffer.firstIndex(of: "<") else {
                out += buffer
                buffer = ""
                break
            }
            out += buffer[..<lt]
            buffer = String(buffer[lt...])
            if let block = Self.blocks.first(where: { buffer.hasPrefix($0.start) }) {
                buffer = String(buffer.dropFirst(block.start.count))
                insideBlockEnd = block.end
                continue
            }
            if let tag = buffer.range(of: #"^</?\|?[A-Za-z_][A-Za-z0-9_]*\|?>"#, options: .regularExpression),
                buffer[tag].contains("|") || buffer[tag].hasPrefix("</")
            {
                buffer = String(buffer[tag.upperBound...])  // stray control tag: drop it
                continue
            }
            let couldStillBeATag = !buffer.contains(">") && buffer.count < 24
                && buffer.range(of: #"^</?\|?[A-Za-z0-9_]*\|?$"#, options: .regularExpression) != nil
            if couldStillBeATag && !final { return out }
            out += "<"
            buffer.removeFirst()
        }
        return out
    }
}

/// Cuts the model's text into pieces the voice can start speaking as early as possible.
///
/// A piece ends at the end of a sentence. The FIRST piece of an answer may also end at a comma,
/// semicolon or colon once it holds a few words: the voice starts sooner, which is the single
/// biggest latency win measured (≈ 0.3 s).
///
/// No piece is shorter than `minWords`: Pocket TTS often renders a text of fewer than 5 words as
/// silence (heard in the app: "Salut toi." and "Ça marche." inaudible, while the latency measurement
/// counted them as the first sound). A short sentence is spoken together with the next one.
public struct SentenceChunker: Sendable {
    /// Minimum length of a first piece cut at a comma (shorter cuts sound choppy).
    public var firstPieceMinCharacters = 20
    /// Fewer words than this are never sent alone to the voice (except the very end of an answer).
    public var minWords = 5
    /// Safety net for text without punctuation: cut at a space after this many characters.
    public var maxPieceCharacters = 220

    private var buffer = ""
    private var emitted = 0

    public init() {}

    public mutating func push(_ text: String) -> [String] {
        buffer += text
        var pieces: [String] = []
        while let cut = nextCut() {
            let piece = buffer[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[cut...])
            if !piece.isEmpty {
                pieces.append(piece)
                emitted += 1
            }
        }
        return pieces
    }

    public mutating func flush() -> [String] {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        emitted = 0
        return rest.isEmpty ? [] : [rest]
    }

    private func nextCut() -> String.Index? {
        var count = 0
        var words = 0
        var previousIsLetter = false
        var lastSpace: String.Index?
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let c = buffer[index]
            let next = buffer.index(after: index)
            count += 1
            if c.isLetter, !previousIsLetter { words += 1 }
            previousIsLetter = c.isLetter || c == "'" || c == "’" || c == "-"
            if c == " " || c == "\n" { lastSpace = index }
            if words >= minWords, next < buffer.endIndex, buffer[next] == " " || buffer[next] == "\n" {
                if ".!?…".contains(c) { return next }
                if emitted == 0, ",;:".contains(c), count >= firstPieceMinCharacters { return next }
            }
            if c == "\n", words >= minWords { return next }  // a line break ends a piece
            if count >= maxPieceCharacters, let lastSpace { return lastSpace }
            index = next
        }
        return nil
    }
}

/// Final clean-up of a piece of text before it reaches the voice.
public enum SpeakableText {
    public static func clean(_ text: String) -> String {
        var s = text
        // Markdown that models sometimes produce despite the "no markdown" instruction.
        s = s.replacingOccurrences(of: #"\*\*|__|\*|`|#+ "#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*([-•]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        // A timestamp in brackets: the model copying the date line that ends the user's messages, in figures or in
        // words with the year and the time ("(jeudi 15 octobre 2026 à 18:42)", as Gemma 4 E2B writes it).
        s = s.replacingOccurrences(of: #"[(\[]\s*\d{4}-\d{2}-\d{2}(?:[T ]\d{1,2}:\d{2}(?::\d{2})?)?\s*[)\]]"#, with: "",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: #"[(\[][^()\[\]]*\b20\d{2}\b[^()\[\]]*\b\d{1,2}\s?[:h]\s?\d{2}\b[^()\[\]]*[)\]]"#,
                                   with: "", options: .regularExpression)
        // Links: say nothing rather than read an URL letter by letter.
        s = s.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        // Emojis and pictographs.
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { !isPictograph($0) }))
        // Runs of spaces become one; non-breaking spaces stay (French typography, shown in the transcript).
        s = s.replacingOccurrences(of: #"[^\S\u00A0\u202F]+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isPictograph(_ u: Unicode.Scalar) -> Bool {
        if u.properties.isEmojiPresentation { return true }
        switch u.value {
        case 0xFE0F, 0x200D, 0x1F000...0x1FAFF, 0x2600...0x27BF: return true
        default: return false
        }
    }
}

extension SpeakableText {
    /// What the voice reads, from text written for the eye: French times "10 h 30" become "10 heures 30",
    /// non-breaking spaces and typographic apostrophes become plain ones, guillemets are dropped.
    public static func forVoice(_ text: String, language: SpeechLanguage) -> String {
        var s = text.replacingOccurrences(of: "[\u{00A0}\u{202F}]", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "’", with: "'")
        s = s.replacingOccurrences(of: #"\s*[«»“”]\s*"#, with: " ", options: .regularExpression)
        if language == .french {
            s = s.replacingOccurrences(of: #"\b1 ?h ?(\d{2})\b"#, with: "1 heure $1", options: .regularExpression)
            s = s.replacingOccurrences(of: #"\b(\d{1,2}) ?h ?(\d{2})\b"#, with: "$1 heures $2", options: .regularExpression)
            s = s.replacingOccurrences(of: #"\b1 ?h\b"#, with: "1 heure", options: .regularExpression)
            s = s.replacingOccurrences(of: #"\b(\d{1,2}) ?h\b"#, with: "$1 heures", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #" +([.,:;!?])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// A short, soft two-note chime played before the app speaks on its own (a timer that rings).
public enum Chime {
    public static func samples(sampleRate: Double) -> [Float] {
        // E5 then A5, each fading out; about 0.7 s in all.
        let notes: [(frequency: Double, start: Double, length: Double)] = [(659.25, 0, 0.45), (880, 0.16, 0.55)]
        let count = Int(0.75 * sampleRate)
        var out = [Float](repeating: 0, count: count)
        for note in notes {
            let first = Int(note.start * sampleRate)
            let length = Int(note.length * sampleRate)
            for i in 0..<length where first + i < count {
                let t = Double(i) / sampleRate
                let attack = min(1, t / 0.008)
                let decay = exp(-t * 6)
                out[first + i] += Float(0.16 * attack * decay * sin(2 * .pi * note.frequency * t))
            }
        }
        return out
    }
}
