import Foundation

/// The model's own marks, written as text: what its tokenizer reads as one of its special tokens wherever it finds it,
/// in any text (Gemma 4's `<|turn>` and `<turn|>`, `<|tool_call>` and `<tool_call|>`, `<|tool_response>` and
/// `<tool_response|>`, `<|"|>`, `<|channel>`…, and `<bos>`, `<eos>`, `<pad>`, `<unk>`, `<mask>`: the 24 of the three
/// models, all caught by `pattern`).
///
/// The conversation reaches the model through its chat template, whose render is then tokenized as a whole: a mark
/// written in a text from outside (a search's snippet, an agent's report, an event someone invited the user to, a
/// shortcut's output, information another system sent) becomes the token itself. It could close the string it is in
/// (`<|"|>`), the tool's response or the turn, and open what reads like the user's turn or one of the model's own calls.
/// So every string of a tool's result goes into the conversation without them (`ChatMessage.result(of:_:)`), and so does
/// what is said, which the history keeps as Maé's words (`SpeakableText.clean`: the app's sentences quote outside texts,
/// such as an event's title or what another system sent).
public enum ModelMarkers {
    /// `<|…>` and `<…|>`, the shape of every Gemma 4 mark but five (and of other models' marks: `<|im_end|>`,
    /// `<|endoftext|>`), and those five. Nothing else: a tag (`<b>`), a comparison (`a < b`), a pipe (`a | b`) stay.
    static let pattern = #"<\|[^<>\s]{0,40}>|<[^<>\s|]{1,40}\|>|<(?:bos|eos|pad|unk|mask)>"#

    /// `text` with each mark replaced by a space, so that what stood on both sides of one cannot join into another
    /// (`<|<turn|>turn>`); the rest as it was.
    ///
    /// Taking anything else out afterwards could join the pieces of a mark again (`<|tu[ … ]rn>`, once the ellipsis in
    /// brackets is gone): this comes last, and only white space is tidied after it.
    public static func strip(_ text: String) -> String {
        guard text.contains("<") else { return text }
        return text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
    }

    /// Every string of `value`, its objects' keys included, stripped (`strip(_:)`); the rest as it was.
    public static func strip(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text): .string(strip(text))
        case .array(let items): .array(items.map { strip($0) })
        case .object(let fields):
            .object(Dictionary(fields.map { (strip($0.key), strip($0.value)) }, uniquingKeysWith: { first, _ in first }))
        case .null, .bool, .int, .double: value
        }
    }
}
