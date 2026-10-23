import SwiftUI

extension TextStyle {
    static let pageRange = TextStyle(.sans, 13, weight: 500, lineHeight: 18, tabular: true)
}

extension EnvironmentValues {
    /// The page a paged list opens on (still pictures of its later pages); 0, the first, otherwise.
    @Entry var firstListPage = 0
}

/// A long list of a card, ten items at a time, newest first: what Maé remembers, a source's last information. Under the
/// items, a hairline and a footer saying which ones are shown ("11–20 of 37"), with "Newer" and "Older"; nothing more
/// when everything fits in one page. `content` lays out the items of the page shown.
struct PagedList<Item, Content: View>: View {
    static var pageSize: Int { 10 }

    let items: [Item]
    @ViewBuilder let content: ([Item]) -> Content
    /// The page the user went to; until then, `firstListPage`.
    @State private var chosen: Int?
    @Environment(\.firstListPage) private var first

    var body: some View {
        let count = items.count
        let pages = max(1, (count + Self.pageSize - 1) / Self.pageSize)
        let page = min(max(chosen ?? first, 0), pages - 1)  // fewer items since: the last page there is
        let start = page * Self.pageSize
        let end = min(start + Self.pageSize, count)
        content(Array(items[start..<end]))
        if pages > 1 {
            Hairline()
            ListPageFooter(first: start + 1, last: end, total: count,
                           newer: page > 0 ? { chosen = page - 1 } : nil,
                           older: page < pages - 1 ? { chosen = page + 1 } : nil)
        }
    }
}

/// "11–20 of 37" on the left; "Newer" and "Older" on the right, greyed at either end.
private struct ListPageFooter: View {
    let first: Int
    let last: Int
    let total: Int
    let newer: (() -> Void)?
    let older: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Text("\(first)–\(last) of \(total)")
                .textStyle(.pageRange)
                .foregroundStyle(Palette.inkMuted)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button { newer?() } label: {
                HStack(spacing: 6) {
                    IconView(icon: .back, size: 16)
                    Text("Newer")
                }
            }
            .buttonStyle(WindowButtonStyle())
            .disabled(newer == nil)
            Button { older?() } label: {
                HStack(spacing: 6) {
                    Text("Older")
                    IconView(icon: .forward, size: 16)
                }
            }
            .buttonStyle(WindowButtonStyle())
            .disabled(older == nil)
        }
        .frame(minHeight: 58)
        .accessibilityElement(children: .contain)
    }
}
