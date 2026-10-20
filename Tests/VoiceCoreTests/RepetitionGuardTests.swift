import Testing

@testable import VoiceCore

/// An answer that goes round in circles is stopped (`RepetitionGuard`); one that only repeats itself a little goes on.
@Suite("Answers that go round in circles")
struct RepetitionGuardTests {
    /// The index of the token at which the guard stops the answer; nil when it lets it go to its end.
    func stop(_ tokens: [Int]) -> Int? {
        var guardian = RepetitionGuard()
        return tokens.indices.first { guardian.add(tokens[$0]) }
    }

    /// A sentence, then « […] » (three tokens here) over and over, as the model wrote after answers cut off: stopped at
    /// the eighth mark, before the voice could read the run.
    @Test func aShortRunOverAndOverIsStopped() {
        let sentence = Array(100..<112)
        let mark = [7, 8, 9]
        #expect(stop(sentence + Array(repeating: mark, count: 30).joined()) == sentence.count + 8 * mark.count - 1)
        #expect(stop(Array(repeating: 5, count: 30)) == 23)  // the same token 24 times
        #expect(stop(Array(repeating: [1, 2], count: 12).joined().map { $0 }) == 23)  // the same two, 12 times
    }

    /// The same sentence of ten tokens three times in a row is stopped at the end of the third; twice goes on.
    @Test func aSentenceThreeTimesInARowIsStopped() {
        let sentence = Array(200..<210)
        #expect(stop(sentence + sentence + [1, 2, 3] + Array(300..<330)) == nil)
        #expect(stop([1, 2, 3, 4, 5] + sentence + sentence + sentence) == 5 + 3 * sentence.count - 1)
    }

    /// A word said three times for emphasis, the same two tokens eleven times, and a long answer without repeats go on.
    @Test func ordinaryAnswersGoOn() {
        #expect(stop([1, 2, 3, 4, 3, 4, 3, 4, 5, 6] + Array(10..<60)) == nil)
        #expect(stop(Array(repeating: [1, 2], count: 11).joined() + [3]) == nil)
        #expect(stop(Array(0..<400)) == nil)
    }
}
