import Foundation

/// Reads the tool name of a call the way the model meant it. The smaller models misspell one now and then
/// ("crer_rappel" for "creer_rappel"): a name one or two letters away from a tool's, and from no other tool's, is
/// that tool. Capitals, accents, dashes and spaces do not count ("Créer-rappel").
///
/// Further than that, the name is refused and the model is given the real ones for its second try: a wrong word
/// is not a slip, and only the model knows what it meant ("lire_rappels" is three letters from "lister_rappels",
/// "cocher_rappel" three from "creer_rappel"). Two tools are at least five letters apart, so a slip of two can only
/// stand for one of them.
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
