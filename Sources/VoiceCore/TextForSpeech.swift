import Foundation

/// Removes what a language model writes but a voice must never say: hidden reasoning blocks and
/// control tags (`<think>…</think>` for Qwen, `<|channel>thought…<channel|>` for Gemma 4,
/// any other `<|…|>`-style tag). Works on a stream: text arrives in small pieces and a tag may be
/// split across two pieces, so a possible tag start is held back until it can be decided.
///
/// Gemma 4 26B also writes ` much` where it means one of its own marks, right after a thought block it closed (it often
/// writes empty ones, `<|channel>thought\n<channel|>`, after the one its template gives it), and goes on with whatever
/// that mark would have opened: ` much_thought\n` for a thought block, ` mucher_web{requete:…}<tool_call|>` for a call
/// written as text, garbage (` muchjeke__`). The user heard « much_thought » and calls read out: in 19 of 20 runs of a
/// request in voice-cli journal-bench, with the system prompt of the time. So `much` right after a block, or at the start
/// of the text (the template's block just before it), opens a thought block too, until `<channel|>`.
///
/// The end of the text (`flush`, at the end of each of the model's answers) also ends a block left open: Gemma 4 26B may
/// open one of its own, write its answer in it and end there, or write a call after it; left open, the block swallowed
/// the request's next answer whole, the summary of the call's result.
public struct ReasoningFilter: Sendable {
    private static let blocks: [(start: String, end: String)] = [
        ("<think>", "</think>"),
        ("<|channel>", "<channel|>"),
    ]
    /// What Gemma 4 26B writes in place of one of its marks (see above), and the end of the block it opens.
    private static let markInWords = "much"
    private static let thoughtEnd = "<channel|>"
    private var buffer = ""
    private var insideBlockEnd: String?
    /// At the start of the text, or right after a block's end: `markInWords` there opens a block.
    private var afterBlock = true

    public init() {}

    public mutating func push(_ text: String) -> String {
        buffer += text
        return drain(final: false)
    }

    /// The rest of the text, at its end: a block still open ends with it, and the next text starts afresh.
    public mutating func flush() -> String {
        let out = drain(final: true)
        buffer = ""
        insideBlockEnd = nil
        afterBlock = true
        return out
    }

    private mutating func drain(final: Bool) -> String {
        var out = ""
        while !buffer.isEmpty {
            if let end = insideBlockEnd {
                if let r = buffer.range(of: end) {
                    buffer = String(buffer[r.upperBound...])
                    insideBlockEnd = nil
                    afterBlock = true
                    continue
                }
                // Keep only what could be the start of the end marker.
                buffer = String(buffer.suffix(end.count - 1))
                if final { buffer = "" }
                return out
            }
            if afterBlock {
                let word = buffer.drop { $0.isWhitespace }
                if word.hasPrefix(Self.markInWords) {
                    buffer = String(word.dropFirst(Self.markInWords.count))
                    insideBlockEnd = Self.thoughtEnd
                    afterBlock = false
                    continue
                }
                // Nothing but white space yet, or « m », « mu », « muc »: wait for the rest.
                if Self.markInWords.hasPrefix(word), !final { return out }
                afterBlock = false
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
                // A stray control tag: dropped. The end of a thought block whose start went unseen is a block's end.
                if buffer[tag] == Self.thoughtEnd { afterBlock = true }
                buffer = String(buffer[tag.upperBound...])
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
///
/// The white space around the pieces is cut off; `pieces(adding:)` also gives, with each piece, the white space the
/// model wrote before it, which the history keeps (see `SpeakableText.record`).
///
/// With `leavesOutSaveClaims`, the sentences that say something was noted, remembered or saved (`SaveClaims`) are left
/// out, with the white space after them: each sentence waits for its end before it is cut into pieces, except a first
/// piece cut at its comma, which goes as early as without it when its words say nothing of the kind (the rest of its
/// sentence is then left out if the whole sentence does). The voice never says a sentence that is taken back.
public struct SentenceChunker: Sendable {
    /// A piece of the text, and the white space the model wrote before it, since the end of the previous piece ("\n\n"
    /// between two paragraphs; `remainingPieces` ends the text, the next piece starts a new one).
    public struct Piece: Sendable, Equatable {
        public var text: String
        public var separator: String

        public init(_ text: String, after separator: String = "") {
            self.text = text
            self.separator = separator
        }
    }

    /// Minimum length of a first piece cut at a comma (shorter cuts sound choppy).
    public var firstPieceMinCharacters = 20
    /// Fewer words than this are never sent alone to the voice (except the very end of an answer).
    public var minWords = 5
    /// Safety net for text without punctuation: cut at a space after this many characters.
    public var maxPieceCharacters = 220
    /// Leaves out the sentences that say something was noted, remembered or saved (`SaveClaims`): on while the memory is
    /// offered and nothing was saved in the turn (`VoicePipeline.answerWithTools`). Read as each sentence ends.
    public var leavesOutSaveClaims = false
    /// The sentences left out (`leavesOutSaveClaims`), in order, as the model wrote them.
    public private(set) var leftOutClaims: [String] = []

    private var buffer = ""
    private var emitted = 0
    /// The white space cut off since the end of the last piece's text: the next piece's separator, so far.
    private var space = ""
    /// With `leavesOutSaveClaims`: the model's words not given to the pieces yet, the current sentence so far.
    private var held = ""
    /// The beginning of the current sentence already given to the pieces (a first piece cut at its comma).
    private var sentenceStart = ""
    /// A sentence was just left out: the white space after it goes with it.
    private var afterLeftOut = false

    public init() {}

    public mutating func push(_ text: String) -> [String] {
        pieces(adding: text).map(\.text)
    }

    public mutating func flush() -> [String] {
        remainingPieces().map(\.text)
    }

    /// The pieces `text` completes, each with the white space before it.
    public mutating func pieces(adding text: String) -> [Piece] {
        guard leavesOutSaveClaims || !held.isEmpty else { return cutting(text) }
        held += text
        var pieces: [Piece] = []
        while let words = nextWords(final: false) { pieces += cutting(words) }
        return pieces
    }

    /// The rest of the text as a last piece (the end of an answer, or of what the model said before a tool call).
    public mutating func remainingPieces() -> [Piece] {
        var pieces: [Piece] = []
        while let words = nextWords(final: true) { pieces += cutting(words) }
        sentenceStart = ""
        afterLeftOut = false
        let rest = take(buffer)
        buffer = ""
        emitted = 0
        space = ""
        return pieces + (rest.map { [$0] } ?? [])
    }

    /// The pieces that the words given to the voice complete.
    private mutating func cutting(_ text: String) -> [Piece] {
        buffer += text
        var pieces: [Piece] = []
        while let cut = nextCut(in: buffer) {
            let raw = String(buffer[..<cut])
            buffer = String(buffer[cut...])
            if let piece = take(raw) {
                pieces.append(piece)
                emitted += 1
            }
        }
        return pieces
    }

    /// The next words of `held` given to the pieces (empty when they were left out), or nil when what is held waits for
    /// more (`final`: nothing more will come).
    private mutating func nextWords(final: Bool) -> String? {
        guard !held.isEmpty else { return nil }
        guard leavesOutSaveClaims else {
            defer {
                held = ""
                sentenceStart = ""
            }
            return held
        }
        if let first = held.first, first.isWhitespace {
            // Between two sentences, or after a first piece cut at a comma: no sentence of its own.
            let white = String(held.prefix { $0.isWhitespace })
            held.removeFirst(white.count)
            if afterLeftOut { return "" }
            if !sentenceStart.isEmpty { sentenceStart += white }
            return white
        }
        afterLeftOut = false
        let end = SaveClaims.sentenceEnd(in: held[...])
        // A first piece goes at its comma as without this (`firstPieceMinCharacters`), when nothing in it says so: as
        // soon as it is written, the sentence's end known or not.
        if emitted == 0, let cut = firstPieceCut(before: end ?? held.endIndex) {
            let clause = String(held[..<cut])
            held.removeSubrange(..<cut)
            sentenceStart += clause
            return clause
        }
        if let end {
            let sentence = String(held[..<end])
            held.removeSubrange(..<end)
            return decided(sentence)
        }
        if final {
            defer { held = "" }
            return decided(held)
        }
        // A sentence that does not end (no punctuation): its words go once long enough to be cut, up to their last space,
        // when nothing in them says so.
        if held.count >= maxPieceCharacters, let space = held.lastIndex(where: { $0 == " " || $0 == "\n" }),
           !SaveClaims.holdsAClaim(sentenceStart + held[..<space])
        {
            let words = String(held[..<space])
            held.removeSubrange(..<space)
            sentenceStart += words
            return words
        }
        return nil
    }

    /// A whole sentence (`sentenceStart` and `sentence`, the part not given yet): `sentence` when it says nothing was
    /// saved, otherwise nothing, and the sentence counts among those left out.
    private mutating func decided(_ sentence: String) -> String {
        let whole = sentenceStart + sentence
        sentenceStart = ""
        guard SaveClaims.claims(whole) else { return sentence }
        leftOutClaims.append(whole.trimmingCharacters(in: .whitespacesAndNewlines))
        afterLeftOut = true
        return ""
    }

    /// Where in `held`, before `end` (its sentence's end), the first piece would be cut at a comma, a semicolon or a colon,
    /// with what was given before it: right after it, when its words say nothing was saved. Nil when no first piece would
    /// be cut there (yet), or when its words hold such a claim (the whole sentence waits for its end).
    private func firstPieceCut(before end: String.Index) -> String.Index? {
        var index = held.startIndex
        while index < end {
            let next = held.index(after: index)
            guard next < held.endIndex else { return nil }
            if ",;:".contains(held[index]), held[next] == " " || held[next] == "\n" {
                let clause = held[..<next]
                let probe = buffer + clause + String(held[next])
                if nextCut(in: probe) == probe.index(before: probe.endIndex) {
                    return SaveClaims.holdsAClaim(sentenceStart + clause) ? nil : next
                }
            }
            index = next
        }
        return nil
    }

    /// `raw` without the white space around it, after the white space before it; nil when it is only white space, which
    /// then goes to the next piece's separator.
    private mutating func take(_ raw: String) -> Piece? {
        let scalars = raw.unicodeScalars
        let isText: (Unicode.Scalar) -> Bool = { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard let first = scalars.firstIndex(where: isText), let last = scalars.lastIndex(where: isText) else {
            space += raw
            return nil
        }
        let piece = Piece(String(scalars[first...last]), after: space + String(scalars[..<first]))
        space = String(scalars[scalars.index(after: last)...])
        return piece
    }

    /// Where the first piece of `buffer` ends, if it is complete.
    private func nextCut(in buffer: String) -> String.Index? {
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

    /// How many words `text` holds, counted as for `minWords` (« C'est » and « trente-huit » are one each).
    public static func words(in text: String) -> Int {
        var words = 0
        var previousIsLetter = false
        for c in text {
            if c.isLetter, !previousIsLetter { words += 1 }
            previousIsLetter = c.isLetter || c == "'" || c == "’" || c == "-"
        }
        return words
    }
}

/// Final clean-up of a piece of text before it reaches the voice.
public enum SpeakableText {
    /// `keepingLineBreaks`: the white space that holds a line break stays as the model wrote it (the answer as the
    /// history keeps it, see `record`); only runs of spaces become one.
    public static func clean(_ text: String, keepingLineBreaks: Bool = false) -> String {
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
        // An ellipsis in brackets (« […] », « [...] », « (…) »), alone or in runs: the mark of a cut, never words. The
        // history once ended the answers cut off with it; the model copied it into its own answers, dozens in a row,
        // and the voice read them as noise for seconds. Out of the history too, so that the model never sees it as its
        // own. Brackets left empty go with it, and ellipses in a row are one.
        s = s.replacingOccurrences(of: #"[ \t]*[(\[]\s*(?:…|\.{2,})\s*[)\]]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]*[(\[]\s*[)\]]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?:…|\.{3})(?:\s*(?:…|\.{3}))+"#, with: "…", options: .regularExpression)
        // Links: say nothing rather than read an URL letter by letter.
        s = s.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        // Emojis and pictographs.
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { !isPictograph($0) }))
        // The model's own marks, last (taking anything out after them could join the pieces of one): the app's sentences
        // quote texts from outside (an event's title, what another system sent), and the history keeps what is said as
        // Maé's words (`ModelMarkers`).
        s = ModelMarkers.strip(s)
        // Runs of spaces become one; non-breaking spaces stay (French typography, shown in the transcript).
        let spaces = #"[^\S\u00A0\u202F]+"#
        if keepingLineBreaks {
            var kept = ""
            var rest = s[...]
            while let run = rest.range(of: spaces, options: .regularExpression) {
                kept += rest[..<run.lowerBound]
                kept += rest[run].contains(where: \.isNewline) ? String(rest[run]) : " "
                rest = rest[run.upperBound...]
            }
            s = kept + rest
        } else {
            s = s.replacingOccurrences(of: spaces, with: " ", options: .regularExpression)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adds a piece of an answer to the answer as the history keeps it: cleaned as for the voice, but with the line
    /// breaks the model wrote, after the white space it wrote before the piece (`separator`; a space when there is none:
    /// the app's own sentences, the first piece after a tool call). The history then holds the answer as the model
    /// wrote it, paragraphs included, which its memory of the answer (the KV cache) still matches at the next request.
    /// Joined with spaces, an answer in paragraphs sent the next request back to a snapshot, to compute the whole answer
    /// again (after a short story in two paragraphs: 197 tokens in 866 ms instead of 54 in 495 ms, with Gemma 4 26B on the
    /// reference Mac).
    public static func record(_ piece: String, after separator: String = "", in answer: inout String) {
        let written = clean(piece, keepingLineBreaks: true)
        guard !written.isEmpty else { return }
        answer += (answer.isEmpty ? "" : separator.isEmpty ? " " : separator) + written
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
            // The built-in sources' numbers: "1,2 %", "18 °C", "18°".
            s = s.replacingOccurrences(of: #"(\d) ?%"#, with: "$1 pour cent", options: .regularExpression)
            s = s.replacingOccurrences(of: #"(\d) ?° ?C\b"#, with: "$1 degrés", options: .regularExpression)
            s = s.replacingOccurrences(of: #"(\d) ?°"#, with: "$1 degrés", options: .regularExpression)
        } else {
            s = s.replacingOccurrences(of: #"(\d) ?%"#, with: "$1 percent", options: .regularExpression)
            s = s.replacingOccurrences(of: #"(\d) ?° ?C\b"#, with: "$1 degrees Celsius", options: .regularExpression)
            s = s.replacingOccurrences(of: #"(\d) ?°"#, with: "$1 degrees", options: .regularExpression)
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
