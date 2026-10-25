import Foundation

/// Reads the tool name of a call the way the model meant it. The smaller models misspell one now and then
/// ("crer_rappel" for "creer_rappel"): a name one or two letters away from a tool's, and from no other tool's, is
/// that tool. Capitals, accents, dashes and spaces do not count ("Créer-rappel").
///
/// Further than that, the name is refused and the model is given the real ones for its second try: a wrong word
/// is not a slip, and only the model knows what it meant ("lire_rappels" is three letters from "lister_rappels",
/// "cocher_rappel" three from "creer_rappel"). Two tools are at least five letters apart, so a slip of two can only
/// stand for one of them.
///
/// The smallest model also writes one of the memory's actions as a tool's name (`tout_oublier {}`): that is the
/// memory's call with that action (`read`).
public enum ToolNames {
    /// The name among `names` that `written` stands for: itself, or the only one at most two letters away (one for
    /// a name of fewer than eight letters, none under four). nil when there is none, or more than one.
    public static func match(_ written: String, among names: [String]) -> String? {
        if names.contains(written) { return written }
        let key = folded(written)
        let near = names.filter { name in
            let target = folded(name)
            return distance(key, target) <= min(2, target.count / 4)
        }
        return near.count == 1 ? near[0] : nil
    }

    /// The tool among `names` that a call named `written` is for: the one its name stands for (`match`), or the memory,
    /// when it is among them and the name is one of its actions (`MemoryCatalog.actionWrittenAsTool`). nil when none.
    public static func tool(for written: String, among names: [String]) -> String? {
        if let name = match(written, among: names) { return name }
        guard names.contains(MemoryCatalog.name), MemoryCatalog.actionWrittenAsTool(written) != nil else { return nil }
        return MemoryCatalog.name
    }

    /// The call as the model meant it: under the name of its tool (`tool(for:among:)`), unchanged when it stands for
    /// none. A memory action written as a tool's name (`tout_oublier {}`) becomes the memory's call with that action,
    /// its arguments as written (an `action` of their own kept).
    public static func read(_ call: ToolCall, among names: [String]) -> ToolCall {
        guard let name = tool(for: call.name, among: names), name != call.name else { return call }
        var read = call
        read.name = name
        if name == MemoryCatalog.name, read.arguments["action"] == nil,
           let action = MemoryCatalog.actionWrittenAsTool(call.name)
        {
            read.arguments["action"] = .string(action.rawValue)
        }
        return read
    }

    /// What the model is told when the name it wrote stands for no tool.
    public static func unknown(_ written: String, among names: [String]) -> String {
        "Outil inconnu : \(written). Les outils existants sont : \(names.joined(separator: ", "))."
    }

    /// Lower case, without accents, "_" for dashes and spaces.
    static func folded(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: #"[\s-]+"#, with: "_", options: .regularExpression)
    }

    /// How many letters to add, remove, change, or swap with the next one, to go from `a` to `b`.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        // d[i][j]: the distance between the first i letters of a and the first j letters of b.
        var d = (0...a.count).map { i in (0...b.count).map { j in i == 0 ? j : j == 0 ? i : 0 } }
        for i in 1...a.count {
            for j in 1...b.count {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }
}
