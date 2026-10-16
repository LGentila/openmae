import SwiftUI
import VoiceCore

/// The live transcript under the orb: who is speaking, then the sentence in progress, word after word.
/// One sentence at a time; at rest, only an invitation to talk.
struct LiveTranscript: View {
    enum Invitation: Equatable {
        /// `orShortcut`: "… or press ⌥ Space" too (the global shortcut works).
        case speak(orShortcut: Bool)
        case holdSpace(orShortcut: Bool)
        case loading(LoadingStep?)
        /// An iPhone has the conversation: the Mac's microphone and speakers are off.
        case onPhone
        /// Any other sentence (the iPhone's).
        case message(Text)
    }

    let state: PipelineState
    /// What the user said in this exchange, and Maé's answer so far.
    let user: TranscriptEntry?
    let answer: TranscriptEntry?
    let invitation: Invitation
    var layout = TranscriptLayout.mac

    @Environment(\.stillFrame) private var stillFrame
    /// How many words of which sentence are shown.
    @State private var shown = Shown()

    private struct Shown: Equatable {
        var sentence: UUID?
        var count = 0
    }

    /// The sentence being shown: the user's while Maé thinks, then Maé's answer as it is spoken.
    private struct Sentence {
        var id: UUID
        var words: [String]
        /// The two most recent words are tinted.
        var tintsRecentWords: Bool
        /// Seconds between two words. Maé's text comes ahead of the voice: it is shown at the pace of speech.
        var pace: Double
    }

    var body: some View {
        ZStack(alignment: .top) {
            if state == .listening {
                InvitationView(invitation: invitation)
                    .padding(.top, layout.invitationTop)
                    .transition(.opacity)
            } else {
                VStack(spacing: 8) {
                    Text(verbatim: state == .speaking ? user?.text ?? "" : "")
                        .textStyle(.previousLine)
                        .foregroundStyle(Palette.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: layout.previousLineWidth, minHeight: 20)
                    SpeakerChip(state: state)
                    if let sentence { words(of: sentence) }
                }
                .transition(.asymmetric(insertion: .modifier(active: Rise(amount: 1, distance: 8),
                                                             identity: Rise(amount: 0, distance: 8)),
                                        removal: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, layout.horizontalPadding)
        .animation(Easing.animation(Easing.rise, Timing.rise), value: state == .listening)
        .task(id: [sentence?.id.uuidString ?? "", String(sentence?.words.count ?? 0)]) { await reveal() }
    }

    private var sentence: Sentence? {
        switch state {
        case .thinking:
            user.map { Sentence(id: $0.id, words: TranscriptWords.split($0.text), tintsRecentWords: false, pace: 0.035) }
        case .speaking:
            answer.map { Sentence(id: $0.id, words: TranscriptWords.split($0.text), tintsRecentWords: true, pace: 0.26) }
        case .listening, .userSpeaking:
            nil
        }
    }

    private func words(of sentence: Sentence) -> some View {
        let count = stillFrame != nil ? sentence.words.count
            : shown.sentence == sentence.id ? min(shown.count, sentence.words.count) : 0
        let deep = StatePalette(state).deep
        let style = layout.words
        return WordFlow(spacing: 0.28 * style.size, lineHeight: style.lineHeight, maxLines: 3,
                        maxWidth: layout.wordsWidth) {
            ForEach(0..<count, id: \.self) { i in
                Text(verbatim: sentence.words[i])
                    .textStyle(style)
                    .foregroundStyle(sentence.tintsRecentWords && i >= count - 2 ? deep : Palette.ink)
                    .animation(.easeInOut(duration: 0.7), value: i >= count - 2)
                    .fixedSize()
                    .transition(.modifier(active: BlurredRise(amount: 1), identity: BlurredRise(amount: 0))
                        .animation(Easing.animation(Easing.rise, Timing.word)))
            }
        }
        .id(sentence.id)
        .padding(.vertical, 4)
        .clipped()
        .padding(.vertical, -4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: sentence.words.joined(separator: " ")))
    }

    /// Shows the words one after the other.
    private func reveal() async {
        guard let sentence, stillFrame == nil else { return }
        if shown.sentence != sentence.id { shown = Shown(sentence: sentence.id) }
        while shown.count < sentence.words.count {
            shown.count += 1  // only the new word moves: the others jump to their new place
            try? await Task.sleep(for: .seconds(sentence.pace))
            if Task.isCancelled { return }
        }
    }
}

/// The transcript's sizes: the Mac window's, or the iPhone's, narrower.
struct TranscriptLayout {
    var horizontalPadding: CGFloat = 60
    var previousLineWidth: CGFloat = 640
    var wordsWidth: CGFloat = 540
    var words = TextStyle.transcript
    var invitationTop: CGFloat = 24

    static let mac = TranscriptLayout()
}

/// "You", "Maé is thinking…", "Maé", with a blinking dot of the state's colour.
private struct SpeakerChip: View {
    let state: PipelineState
    @State private var dimmed = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(StatePalette(state).glow)
                .frame(width: 8, height: 8)
                .opacity(dimmed ? 0.35 : 1)
                .animation(.easeOut(duration: 0.4), value: state)
            title
                .textStyle(.chip)
                .foregroundStyle(Palette.ink)
                .contentTransition(.opacity)
        }
        .padding(.leading, 11)
        .padding(.trailing, 14)
        .frame(height: 30)
        .background(Palette.white, in: Capsule())
        .hairline(Capsule())
        .animation(.easeOut(duration: Timing.ui), value: state)
        .repeatsWhileVisible($dimmed, .easeInOut(duration: 0.7))
    }

    private var title: Text {
        switch state {
        case .userSpeaking: Text("You")
        case .thinking: Text("Maé is thinking…")
        case .listening, .speaking: Text(verbatim: "Maé")
        }
    }
}

/// At rest: how to start talking. While the models load: what is loading.
private struct InvitationView: View {
    let invitation: LiveTranscript.Invitation

    var body: some View {
        Group {
            switch invitation {
            case .speak(let orShortcut):
                if orShortcut {
                    HStack(spacing: 8) {
                        Text("Speak whenever you like or press")
                        KeyCap(title: Text("⌥ Space"))
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    Text("Speak whenever you like")
                }
            case .holdSpace(let orShortcut):
                HStack(spacing: 8) {
                    Text("Hold")
                    KeyCap(title: Text("Space"))
                    if orShortcut {
                        Text("or press")
                        KeyCap(title: Text("⌥ Space"))
                    } else {
                        Text("to talk")
                    }
                }
                .accessibilityElement(children: .combine)
            case .loading(let step):
                VStack(spacing: 6) {
                    Text(StateText.loading(step))
                        .foregroundStyle(Palette.ink)
                    Text("The first launch can take a minute or two.")
                        .textStyle(.note)
                }
            case .onPhone:
                Text("Your Mac has turned off its microphone and speakers.")
            case .message(let text):
                text
            }
        }
        .textStyle(.prompt)
        .foregroundStyle(Palette.inkMuted)
        .multilineTextAlignment(.center)
    }
}

/// Appears from slightly lower, like the design's transcript.
private struct Rise: ViewModifier {
    /// 1: hidden below, 0: in place.
    let amount: Double
    let distance: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(y: distance * amount)
            .opacity(1 - amount)
    }
}

/// A word appears from slightly lower and blurred. (Only for text: a blur, even of zero, smears what
/// touches the edges of the view.)
private struct BlurredRise: ViewModifier {
    let amount: Double

    func body(content: Content) -> some View {
        content
            .offset(y: 6 * amount)
            .blur(radius: 3 * amount)
            .opacity(1 - amount)
    }
}

/// Words on centred lines, at most `maxLines` of them: when the sentence grows longer, its first lines go up
/// out of sight (the container clips them).
private struct WordFlow: Layout {
    var spacing: CGFloat
    var lineHeight: CGFloat
    var maxLines: Int
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? maxWidth, maxWidth)
        let lines = lines(subviews, width: width)
        return CGSize(width: width, height: CGFloat(min(lines.count, maxLines)) * lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = lines(subviews, width: bounds.width)
        let hidden = max(0, lines.count - maxLines)
        for (row, line) in lines.enumerated() {
            let y = bounds.minY + (CGFloat(row - hidden) + 0.5) * lineHeight
            var x = bounds.midX - line.width / 2
            for i in line.range {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .leading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private func lines(_ subviews: Subviews, width: CGFloat) -> [(range: Range<Int>, width: CGFloat)] {
        var lines: [(range: Range<Int>, width: CGFloat)] = []
        var start = 0
        var lineWidth: CGFloat = 0
        for i in subviews.indices {
            let wordWidth = subviews[i].sizeThatFits(.unspecified).width
            if i > start, lineWidth + spacing + wordWidth > width {
                lines.append((start..<i, lineWidth))
                start = i
                lineWidth = wordWidth
            } else {
                lineWidth += (i > start ? spacing : 0) + wordWidth
            }
        }
        if start < subviews.count { lines.append((start..<subviews.count, lineWidth)) }
        return lines
    }
}

/// Splits a sentence into the words shown one by one. A lone punctuation mark stays with its word, after
/// a non-breaking space, so that no line starts with "?" or "»".
enum TranscriptWords {
    static func split(_ text: String) -> [String] {
        var words: [String] = []
        var opening = ""
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init) {
            if token.allSatisfy({ "?!:;»%".contains($0) }), let last = words.popLast() {
                words.append(last + "\u{00A0}" + token)
            } else if token == "«" {
                opening += token + "\u{00A0}"
            } else {
                words.append(opening + token)
                opening = ""
            }
        }
        if !opening.isEmpty { words.append(opening.trimmingCharacters(in: .whitespaces)) }
        return words
    }
}
