import Foundation
import Testing

@testable import VoiceCore

/// « OK Maé » read in real transcripts (Tests/Fixtures/wake-word-fr.json): what speech recognition wrote for the phrase,
/// and for the sentences that must never wake Maé.
@Suite("Wake word")
struct WakeWordTests {
    struct Corpus: Decodable {
        struct Wake: Decodable {
            let heard: String
            let request: String
        }

        let wake: [Wake]
        let missed: [String]
        let traps: [String]
        let otherPhrases: [String]
    }

    static let corpus: Corpus? = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/wake-word-fr.json")
        return try? JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }()

    let detector = OKMaeWakeWord()

    @Test func corpusIsThere() throws {
        let corpus = try #require(Self.corpus)
        #expect(corpus.wake.count == 10 && corpus.missed.count > 8)
        #expect(corpus.traps.count > 100 && corpus.otherPhrases.count > 80)
    }

    @Test func readsThePhraseAsSpeechRecognitionWritesIt() throws {
        for wake in try #require(Self.corpus).wake {
            #expect(detector.request(in: wake.heard) == wake.request, "\(wake.heard)")
        }
    }

    @Test func everydaySentencesNeverWakeMae() throws {
        let corpus = try #require(Self.corpus)
        for sentence in corpus.traps + corpus.missed + corpus.otherPhrases {
            #expect(detector.request(in: sentence) == nil, "\(sentence)")
        }
    }

    @Test func thePhraseAloneIsAnEmptyRequest() {
        for alone in ["OK Maé.", "Ok Mae !", "Okay, Mae ?", "O.K. Maé", "Oké Mahé…", "ok mae"] {
            #expect(detector.request(in: alone) == "", "\(alone)")
        }
    }

    @Test func theRequestKeepsItsWords() {
        #expect(detector.request(in: "OK Maé, mets un minuteur de 10 minutes.") == "Mets un minuteur de 10 minutes.")
        #expect(detector.request(in: "Ok Mae quelle heure est-il") == "Quelle heure est-il")
        #expect(detector.request(in: "Okay Mae, what time is it?") == "What time is it?")
        #expect(detector.request(in: "Euh, OK Maé, et demain ?") == "Et demain ?")
        #expect(detector.request(in: "OK Maé, stop.") == "Stop.")
        // Written in one word, while Maé was telling a story.
        #expect(detector.request(in: "Okemae, raconte-moi une longue histoire de dragon.")
            == "Raconte-moi une longue histoire de dragon.")
        // « OK Maé, stop » heard as "OK mais, stop": taken for it, since at worst it silences Maé.
        #expect(detector.request(in: "Ok mais, stop.") == "Stop.")
        #expect(detector.request(in: "OK mais arrête !") == "Arrête !")
        #expect(detector.request(in: "Ok mais.") == nil)
    }

    /// How speech recognition wrote « OK Maé » said by a real voice, at home.
    @Test func readsARealVoice() {
        for (heard, request) in [("Okay, my", ""), ("Okay my", ""), ("Okay, my.", ""), ("Okay May.", ""),
                                 ("Au quai Mahé, quelle heure est-il?", "Quelle heure est-il?"),
                                 ("Ok, Mahé, raconte-moi une histoire.", "Raconte-moi une histoire."),
                                 ("Ok Maï, raconte-moi l'histoire.", "Raconte-moi l'histoire."),
                                 ("Okay, my stop.", "Stop."), ("Hokemae, quelle heure est-il ?", "Quelle heure est-il ?"),
                                 ("Ok Mah, raconte-moi une histoire.", "Raconte-moi une histoire."), ("Okay, Maybe.", ""),
                                 ("Okay, Maestop.", "Stop")]
        {
            #expect(detector.request(in: heard) == request, "\(heard)")
        }
        for sentence in ["Okay, bye.", "Yeah.", "Le Hokemae n'est pas bien détecté.", "Au quai de la gare.",
                         "Okay, maybe later.", "Allo, allo ?", "Test, test.", "Stop, stop."]
        {
            #expect(detector.request(in: sentence) == nil, "\(sentence)")
        }
    }

    /// A piece cut short by a pause may be the phrase misheard: an "OK" then anything, or nothing understood.
    @Test func aStartThatMayBeThePhraseMisheard() {
        for start in ["Okay, bye.", "Ok mais.", "OK.", "Euh, okay…", "Au quai", "", "Mm-hmm."] {
            #expect(detector.mayStartWithPhrase(start), "\(start)")
        }
        for start in ["Le gouvernement a présenté hier son projet de loi.", "Mais quelle heure est-il ?", "Emmae?"] {
            #expect(!detector.mayStartWithPhrase(start), "\(start)")
        }
    }

    /// Only the very start of the sentence counts; "mais", "Emma est", "may I", other names keep their meaning.
    @Test func lookAlikesKeepTheirMeaning() {
        for sentence in ["Mais quelle heure est-il ?", "Emma est arrivée hier soir.", "Hey, may I ask you something?",
                         "OK, may I ask you something?", "OK mais je préfère demain.", "Ok, Marie, tu viens ?",
                         "OK Maël, on y va.", "OK Maéva, à table.", "Elle habite à Mahé, aux Seychelles.",
                         "Je lui ai dit : OK Maé, vas-y.", "Mahé, quelle heure est-il ?", "OK, mets la table.",
                         "Okay, ma chérie.", "Hé Maé, quelle heure est-il ?", "Coucou Maé, quelle heure est-il ?"]
        {
            #expect(detector.request(in: sentence) == nil, "\(sentence)")
        }
    }

    @Test func stopRequestsAreRecognized() {
        for stop in ["Stop.", "Arrête !", "Tais-toi.", "Chut.", "C’est bon.", "Ça suffit.", "stop, merci"] {
            #expect(StopRequest.matches(stop), "\(stop)")
        }
        for request in ["Stoppe le minuteur.", "Arrête le minuteur.", "Quelle heure est-il ?", "Annule."] {
            #expect(!StopRequest.matches(request), "\(request)")
        }
    }

    @Test func olderSettingsKeepTheirWayOfTalking() throws {
        let pushToTalk = #"{"audioMode":"speakers","pushToTalk":true}"#
        #expect(try JSONDecoder().decode(AssistantSettings.self, from: Data(pushToTalk.utf8)).listening == .pushToTalk)
        var settings = AssistantSettings()
        settings.listening = .wakeWord
        settings.wakeLog = true
        let again = try JSONDecoder().decode(AssistantSettings.self, from: JSONEncoder().encode(settings))
        #expect(again.listening == .wakeWord && again.wakeLog)
        let unknown = #"{"listening":"somethingNew"}"#  // a later version's mode
        #expect(try JSONDecoder().decode(AssistantSettings.self, from: Data(unknown.utf8)).listening == .handsFree)
        // An earlier version reading these settings keeps push-to-talk.
        struct Earlier: Decodable { let pushToTalk: Bool }
        settings.listening = .pushToTalk
        #expect(try JSONDecoder().decode(Earlier.self, from: JSONEncoder().encode(settings)).pushToTalk)
        settings.listening = .wakeWord
        #expect(try !JSONDecoder().decode(Earlier.self, from: JSONEncoder().encode(settings)).pushToTalk)
    }
}
