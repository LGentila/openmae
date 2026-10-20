/// Stops an answer that goes round in circles: the same short run of tokens again and again, which a model writes until
/// its token limit once it loops (« […] […] […] … », dozens in a row, read by the voice for 19 s in the app with
/// Gemma 4 26B; or a word, or a sentence, over and over). True once the answer's tokens end with one run of 1 to
/// `longestRun` tokens repeated, in a row, at least `minimumRepeats` times and over `minimumSpan` tokens or more: the
/// same token 24 times, the same two 12 times, the same three 8 times, …, the same sentence of 8 to 16 tokens 3 times.
/// A word said three times for emphasis (« très, très, très »), a refrain said twice, go on.
public struct RepetitionGuard: Sendable {
    public var longestRun = 16
    public var minimumSpan = 24
    public var minimumRepeats = 3
    private var tokens: [Int] = []

    public init() {}

    /// Adds the answer's next token: true when the answer now loops.
    public mutating func add(_ token: Int) -> Bool {
        tokens.append(token)
        let count = tokens.count
        guard count >= minimumSpan else { return false }
        for run in 1...longestRun {
            let span = run * max(minimumRepeats, (minimumSpan + run - 1) / run)
            guard span <= count else { continue }
            // The last `span` tokens are copies of the last `run` ones.
            if (count - span..<count - run).allSatisfy({ tokens[$0] == tokens[$0 + run] }) { return true }
        }
        return false
    }
}
