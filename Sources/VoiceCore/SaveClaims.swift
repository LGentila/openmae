import Foundation

/// The model's words that say something was noted, remembered or saved, or will be: « C'est noté », « J'ai bien
/// retenu… », « Je l'ai enregistré dans ma mémoire », « Je note que… », « Je la garde en tête », « Je prends note… »,
/// « Je m'en souviendrai », "I've noted that". Said with no call to the memory, nothing was, and the user believes Maé
/// will remember it. The app leaves such sentences out of what Maé says while nothing was saved in the turn
/// (`SentenceChunker.leavesOutSaveClaims`), and the benches count those the model writes (voice-cli actions-bench and
/// dialogue-bench): one rule for both.
///
/// Questions and offers aside: a sentence that ends with « ? » (« Tu veux que je le note ? ») or offers (« Si tu veux,
/// je le retiens ») promises nothing, and « Je peux la noter pour toi » says nothing was.
///
/// Gemma 4 E2B answered facts said in passing so in 2 to 6 of 12 a run of actions-bench on the memory corpus
/// (« C'est une bonne nouvelle. Je note que tu as arrêté de fumer il y a trois mois. »), whatever the memory's rules
/// said (`MemoryCatalog.promptAddendum`); Gemma 4 26B once to three times a run (« D'accord, c'est noté. Tu veux que je
/// retienne cette information ? »).
public enum SaveClaims {
    /// Whether one sentence (`sentences`) says that something was saved.
    public static func claims(_ sentence: String) -> Bool {
        let sentence = typed(sentence).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.hasSuffix("?"), sentence.range(of: offer, options: [.regularExpression, .caseInsensitive]) == nil
        else { return false }
        return holdsAClaim(sentence)
    }

    /// The sentences of `text` that say something was saved, in order.
    public static func claimingSentences(in text: String) -> [String] {
        sentences(text).filter(claims)
    }

    /// Whether any sentence of `text` says that something was saved.
    public static func saysItWasSaved(_ text: String) -> Bool {
        sentences(text).contains(where: claims)
    }

    /// What the voice gets of a whole answer when the app leaves those sentences out, as it does while the answer streams
    /// (`SentenceChunker.leavesOutSaveClaims`): its pieces, the history's answer (`SpeakableText.record`), and the
    /// sentences left out.
    public static func spoken(_ text: String) -> (pieces: [SentenceChunker.Piece], said: String, leftOut: [String]) {
        var chunker = SentenceChunker()
        chunker.leavesOutSaveClaims = true
        let pieces = chunker.pieces(adding: text) + chunker.remainingPieces()
        return (pieces, said(pieces), chunker.leftOutClaims)
    }

    /// The last pieces of an answer whose claims of a save were left out, when nothing was said before them in the turn
    /// and nothing follows them: with nothing left to say, the acknowledgement (`MemoryPhrases.acknowledged`); with a
    /// single piece too short for the voice to say it surely (fewer than `SentenceChunker.minWords` words once cleaned,
    /// « C'est une bonne nouvelle. »: before, the claim made it long enough), that piece followed by the thanks
    /// (`MemoryPhrases.thanks`). Otherwise the pieces as they are.
    public static func ending(_ last: [SentenceChunker.Piece], language: SpeechLanguage) -> [SentenceChunker.Piece] {
        let words = SpeakableText.clean(said(last))
        if words.isEmpty { return [SentenceChunker.Piece(MemoryPhrases.acknowledged(language))] }
        guard last.count == 1, SentenceChunker.words(in: words) < SentenceChunker().minWords else { return last }
        return [SentenceChunker.Piece(last[0].text + " " + MemoryPhrases.thanks(language), after: last[0].separator)]
    }

    /// Pieces as the history keeps them.
    private static func said(_ pieces: [SentenceChunker.Piece]) -> String {
        var said = ""
        for piece in pieces { SpeakableText.record(piece.text, after: piece.separator, in: &said) }
        return said
    }

    /// The sentences of a text, each without the white space around it: a white space after « . », « ! », « ? » or « … »
    /// begins the next one, and so does a line break.
    public static func sentences(_ text: String) -> [String] {
        var rest = text[...]
        var found: [String] = []
        while true {
            rest = rest.drop { $0.isWhitespace }
            guard !rest.isEmpty else { return found }
            guard let end = sentenceEnd(in: rest) else {
                found.append(String(rest))
                return found
            }
            found.append(String(rest[..<end]))
            rest = rest[end...]
        }
    }

    /// Where the first sentence of `text` ends: right after its « . », « ! », « ? » or « … » when white space follows, or
    /// where a line break begins; nil when the text so far ends inside it.
    static func sentenceEnd(in text: Substring) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isNewline { return index }
            let next = text.index(after: index)
            if ".!?…".contains(character), next < text.endIndex, text[next].isWhitespace { return next }
            index = next
        }
        return nil
    }

    /// Whether words hold one of the claims, whatever follows them (a question, an offer): the beginning of a sentence
    /// that does goes to the voice only once the whole sentence is known (`SentenceChunker.leavesOutSaveClaims`).
    static func holdsAClaim(_ words: String) -> Bool {
        let words = typed(words)
        return patterns.contains { words.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// Typographic apostrophes as straight ones, as the patterns have them.
    private static func typed(_ text: String) -> String {
        text.replacingOccurrences(of: "’", with: "'")
    }

    private static let kept = "(noté|retenu|enregistré|mémorisé|sauvegardé|gardé|consigné|pris note)"
    private static let keeping = "(note|retiens|enregistre|mémorise|sauvegarde|garde|consigne)"
    private static let patterns = [
        // « C'est noté », « C'est bien retenu », « C'est dans ma mémoire ».
        #"\bc'est (bien |donc |déjà |maintenant |désormais )?"# + kept,
        #"\bc'est (bien |donc |déjà |maintenant |désormais )?(dans ma mémoire|en mémoire)"#,
        // « Noté, … », « Bien noté. »
        #"^(bien )?noté\b"#,
        // « J'ai bien noté… », « J'en ai pris note », « Je l'ai enregistré », « Je te l'ai noté ».
        #"\bj'(en )?ai (bien |donc |déjà )?"# + kept,
        #"\bje (te |t')?(l'|les )ai (bien |donc |déjà )?(noté|retenu|enregistré|mémorisé|sauvegardé|gardé|ajouté|mis)"#,
        // « Je note que… », « Je la retiens », « Je garde ça en tête » (not « Tu veux que je le note »).
        #"(?<!que )\bje (te |t')?(le |la |les |l')?"# + keeping + #"\b"#,
        #"\b(je|j'en) prends (bien |bonne |donc )?note\b"#,
        // « Je le retiendrai », « Je vais le noter », « Je m'en souviendrai », « Je ne l'oublierai pas ».
        #"\bje (te |t')?(le |la |les |l')?(noterai|retiendrai|enregistrerai|mémoriserai|garderai)\b"#,
        #"\bje vais (te |t')?(le |la |les |l')?(noter|retenir|enregistrer|mémoriser|garder|m'en souvenir)\b"#,
        #"\bje (m'en |me |me le |me la |me les )(souviendrai|rappellerai)\b"#,
        #"\bje ne (l'|les |le |la )?oublierai (pas|jamais)\b"#,
        #"\b(i've|i have|i) (noted|saved|stored|memorized|made a note)\b"#, #"\b(i'll|i will) (remember|note|keep)\b"#,
        #"^noted\b"#,
    ]
    private static let offer = #"\bsi tu (le |la |l')?(veux|voulais|souhaites|préfères|désires)\b|\bif you (want|like)\b"#
}
