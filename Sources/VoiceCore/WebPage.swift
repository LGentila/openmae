import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession on Linux and Windows
#endif

// Reading the page of a search result: when the snippets do not hold the answer (a share's price, opening hours), the
// model asks for one result's page by its number. The app fetches it as an app that says its name, keeps its readable
// text (no scripts, menus or cookie banners), and gives the model the passages around the words looked for. Only the
// address the search gave is fetched: never one the model or a page wrote.

/// A page as the model reads it.
public struct WebPage: Sendable, Codable, Equatable {
    /// How much of a page's text the model reads: 4,500 characters, 1,000 to 1,300 tokens. Gemma 4 26B reads about 250
    /// tokens a second on the reference Mac: with 6,000, the answer came 7 s after the page (1,600 to 1,800 tokens).
    public static let readLimit = 4_500

    /// The site the model names ("boursorama.com"), as for the search results.
    public var site: String
    public var title: String
    /// The readable text: one block (a paragraph, a table row, a heading) per line.
    public var text: String
    /// When the page says it was published, or last updated.
    public var published: Date?

    public init(site: String, title: String, text: String, published: Date? = nil) {
        self.site = site
        self.title = title
        self.text = text
        self.published = published
    }
}

/// Why a page could not be read.
public enum WebPageError: Error, Sendable, Codable, Equatable {
    /// 401, 403, 429, 451: the site does not let programs in.
    case refused
    /// The site shows a cookie wall first (a consent page).
    case consentWall
    /// 404, 410.
    case notFound
    /// No answer in time, or no connection to it.
    case unreachable
    /// Not a web page (a PDF, an image), or one whose text only a browser shows (written by its scripts).
    case notReadable
    /// Another HTTP status.
    case unexpected(status: Int)
}

/// Fetches a page and keeps its readable text.
public protocol WebPageReader: Sendable {
    func read(_ url: URL, language: SpeechLanguage) async throws -> WebPage
}

/// Reads pages over HTTP, as an app that says its name, never as a browser: no cookies, no cache, no scripts run.
public final class HTTPPageReader: WebPageReader {
    /// The longest a page may take, whatever its size.
    public static let defaultTimeout: TimeInterval = 6
    /// Bytes of a page kept at most: the text of the biggest pages comes long before (1.2 MB for a share's page on
    /// Boursorama, 2.4 MB on CNBC).
    static let byteLimit = 4_000_000

    private let userAgent: String
    private let session: URLSession

    public init(timeout: TimeInterval = HTTPPageReader.defaultTimeout, userAgent: String = AppIdentity.userAgent) {
        self.userAgent = userAgent
        session = .forWebSearch(timeout: timeout)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func read(_ url: URL, language: SpeechLanguage) async throws -> WebPage {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml;q=0.9,text/plain;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue(language == .french ? "fr-FR,fr;q=0.9,en;q=0.5" : "en;q=0.9,fr;q=0.5",
                         forHTTPHeaderField: "Accept-Language")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is URLError {
            throw WebPageError.unreachable
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw WebPageError.unexpected(status: 0) }
        let landed = http.url ?? url
        switch http.statusCode {
        case 200..<300: break
        case 401, 403, 429, 451: throw WebPageError.refused
        case 404, 410: throw WebPageError.notFound
        default: throw WebPageError.unexpected(status: http.statusCode)
        }
        if ReadablePage.isConsentPage(landed) { throw WebPageError.consentWall }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let html = type.isEmpty || type.contains("html") || type.contains("xml")
        guard html || type.hasPrefix("text/plain") else { throw WebPageError.notReadable }
        let body = data.prefix(Self.byteLimit)
        let text = ReadablePage.decode(body, contentType: type)
        let site = WebResult.site(of: landed) ?? WebResult.site(of: url) ?? ""
        let page = html ? ReadablePage.page(html: text, site: site)
            : WebPage(site: site, title: "", text: ReadablePage.lines(of: text).joined(separator: "\n"))
        if ReadablePage.isConsentWall(page) { throw WebPageError.consentWall }
        guard page.text.count >= ReadablePage.minimumText else { throw WebPageError.notReadable }
        return page
    }
}

/// The readable text of a web page.
public enum ReadablePage {
    /// A page with less text than this shows its content through its scripts: there is nothing to read without a
    /// browser.
    static let minimumText = 200

    /// The text of a page's bytes, in the encoding its server or its <meta> says (UTF-8 otherwise, Windows Latin-1 if
    /// that fails).
    public static func decode(_ data: Data, contentType: String = "") -> String {
        var name = charset(in: contentType)
        if name == nil {
            let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
            if let range = head.range(of: #"<meta[^>]+charset\s*=\s*["']?([a-z0-9_\-]+)"#, options: .regularExpression) {
                name = charset(in: String(head[range]))
            }
        }
        if let name, name != "utf-8", name != "utf8" {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
    }

    private static func charset(in text: String) -> String? {
        guard let range = text.range(of: #"charset\s*=\s*["']?[A-Za-z0-9_\-]+"#, options: .regularExpression) else {
            return nil
        }
        return text[range].split(separator: "=").last.map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased()
        }
    }

    /// A page the browser lands on to ask for its cookies first (consent.yahoo.com, consent.google.com…).
    static func isConsentPage(_ url: URL) -> Bool {
        let host = url.host()?.lowercased() ?? ""
        let path = url.path().lowercased()
        return host.hasPrefix("consent.") || host.hasPrefix("guce.") || path.contains("collectconsent")
            || path.hasPrefix("/consent")
    }

    /// Little text, most of it about accepting cookies: a cookie wall, not the page.
    static func isConsentWall(_ page: WebPage) -> Bool {
        guard page.text.count < 1_500 else { return false }
        let text = fold(page.text)
        return (text.contains("cookie") || text.contains("consent")) && (text.contains("accept") || text.contains("refus"))
    }

    // MARK: - From HTML to text

    /// The page's title, readable text and date. The text is that of its main part (`<main>`, or its articles) when it
    /// has one, else of the whole page; scripts, styles, menus, headers and footers of the site, forms' buttons, hidden
    /// parts and cookie banners are left out.
    public static func page(html: String, site: String) -> WebPage {
        var parser = HTMLText(html)
        parser.run()
        var text = parser.mainText
        if text.count < minimumText {
            // What usually marks a menu, a banner or a site's header may also mark a page's content: little text left
            // without them, read it again with them.
            var lenient = HTMLText(html, guessing: false)
            lenient.run()
            if lenient.mainText.count > text.count {
                parser = lenient
                text = lenient.mainText
            }
        }
        let title = clean(parser.title.isEmpty ? parser.firstHeading : parser.title)
        return WebPage(site: site, title: title, text: text, published: parser.published)
    }

    /// The lines of a plain text: trimmed, without empty ones.
    static func lines(of text: String) -> [String] {
        text.components(separatedBy: .newlines).map(clean).filter { !$0.isEmpty }
    }

    /// One line: single spaces (no-break ones included), no soft hyphens, "..." as "…", and nothing that looks like the
    /// model's own marks (`<|tool_call>`, `<turn|>`, `<|"|>`, `<eos>`: `ModelMarkers`): written on a page, they could
    /// pass for the end of the page's text and the start of something else. The marks go last, as `ModelMarkers.strip`
    /// asks (taking out a soft hyphen after them could join the pieces of one again); only white space is tidied after.
    static func clean(_ text: String) -> String {
        ModelMarkers.strip(text.replacingOccurrences(of: "\u{00AD}", with: "").replacingOccurrences(of: "...", with: "…"))
            .replacingOccurrences(of: "[\\s\u{00A0}\u{202F}\u{2009}\u{200B}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Lower case, without accents.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
    }

    // MARK: - The passages the model reads

    /// What the model reads of a text: all of it when it is short; otherwise its beginning (a page says what matters
    /// first: a share's price, an article's lead) and the passages around the words looked for (`words`: the search's
    /// keywords and the user's question), rarest words first, in the page's order, with "[…]" where text was left out.
    public static func excerpt(_ text: String, words: [String], limit: Int = WebPage.readLimit) -> String {
        guard text.count > limit else { return text }
        let lines = text.components(separatedBy: "\n").flatMap { split($0) }
        let keys = keywords(words)
        let folded = lines.map(fold)
        // How rare each word is on this page: a word on every line (the share's name, on its page) tells little.
        var weights: [String: Double] = [:]
        for key in keys {
            let found = folded.filter { contains($0, key) }.count
            if found > 0 { weights[key] = log(1 + Double(lines.count) / Double(found)) }
        }
        let scores = folded.map { line in weights.reduce(0) { $0 + (contains(line, $1.key) ? $1.value : 0) } }

        var kept = Set<Int>()
        var used = 0
        func keep(_ index: Int) -> Bool {
            guard !kept.contains(index) else { return true }
            // The line, its line break, and room for a "[…]" before it: the excerpt never outgrows the limit.
            let cost = lines[index].count + 5
            guard used + cost <= limit else { return false }
            kept.insert(index)
            used += cost
            return true
        }
        // The beginning: a fifth of what is read.
        for index in lines.indices {
            guard used + lines[index].count + 5 <= limit / 5, keep(index) else { break }
        }
        // Then the best lines, with what comes just before (a label) and after (its value, a heading's table: a week's
        // days).
        let best = scores.indices.filter { scores[$0] > 0 }.sorted { scores[$0] > scores[$1] || scores[$0] == scores[$1] && $0 < $1 }
        for index in best {
            for neighbour in [index] + Array(max(0, index - 2)..<index).reversed() + Array(index + 1..<min(lines.count, index + 8)) {
                _ = keep(neighbour)
            }
            if used >= limit - 40 { break }
        }
        // Nothing looked for is on the page: as much of its beginning as fits.
        if best.isEmpty {
            for index in lines.indices where !keep(index) { break }
        }
        var excerpt: [String] = []
        var previous = -1
        for index in kept.sorted() {
            if index > previous + 1 { excerpt.append("[…]") }
            excerpt.append(lines[index])
            previous = index
        }
        if previous < lines.count - 1 { excerpt.append("[…]") }
        return excerpt.joined(separator: "\n")
    }

    /// A long line (a paragraph) as sentences of a few hundred characters, so that a passage is no longer than needed.
    private static func split(_ line: String) -> [String] {
        guard line.count > 400 else { return [line] }
        var pieces: [String] = []
        var current = ""
        for sentence in line.split(separator: " ", omittingEmptySubsequences: true) {
            current += (current.isEmpty ? "" : " ") + sentence
            if current.count >= 300, let last = sentence.last, ".!?".contains(last) || current.count >= 600 {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// The words worth looking for: folded, at least three letters (or two digits), not a word every French or English
    /// sentence has; long words cut to their stem ("horaires" → "horair", found in "horaire").
    static func keywords(_ words: [String]) -> [String] {
        var keys: [String] = []
        for text in words {
            for word in fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) {
                let digits = word.allSatisfy(\.isNumber)
                guard digits ? word.count >= 2 : word.count >= 3, !stopWords.contains(word) else { continue }
                let key = digits || word.count < 6 ? word : String(word.prefix(max(5, word.count - 2)))
                if !keys.contains(key) { keys.append(key) }
            }
        }
        return keys
    }

    /// Whether a folded line has a word starting with this key.
    private static func contains(_ line: String, _ key: String) -> Bool {
        var start = line.startIndex
        while let range = line.range(of: key, range: start..<line.endIndex) {
            if range.lowerBound == line.startIndex || !line[line.index(before: range.lowerBound)].isLetter { return true }
            start = range.upperBound
        }
        return false
    }

    private static let stopWords: Set<String> = [
        "les", "des", "une", "est", "sont", "quel", "quelle", "quels", "quelles", "pour", "dans", "avec", "sur", "par",
        "aux", "que", "qui", "quoi", "comment", "combien", "cette", "ces", "son", "ses", "leur",
        "mon", "mes", "ton", "tes", "moi", "toi", "nous", "vous", "elle", "ils", "elles", "pas", "plus", "tout", "tous",
        "fait", "faire", "peut", "aujourd", "hui", "actuel", "actuelle", "actuellement", "maintenant", "moment",
        "dis", "dit", "cherche", "chercher", "trouve", "regarde", "internet", "site", "the", "and", "for", "what", "how",
        "with", "today", "now", "current",
    ]
}

/// A tolerant reader of HTML: tags, comments, scripts and entities, without building a tree. It keeps the text of
/// each block (a paragraph, a heading, a table row…) as a line, and where it was: in the page's main part, in an
/// article, or elsewhere.
struct HTMLText {
    enum Part { case main, article, all }

    private let bytes: [UInt8]
    /// Class and id names that usually mark a menu, a banner or a pop-up are read as such (see `ReadablePage.page`).
    private let guessing: Bool
    private var position = 0
    private var open: [Element] = []
    private var line: [UInt8] = []
    private var lines: [(text: String, main: Bool, article: Bool)] = []
    private(set) var title = ""
    private(set) var firstHeading = ""
    private(set) var published: Date?
    private var updated: Date?
    /// Inside the page's first `<h1>`, whose text stands for its title when it has no `<title>`.
    private var inFirstHeading = false

    private struct Element {
        var name: String
        var skipped: Bool
        var main: Bool
        var article: Bool
    }

    init(_ html: String, guessing: Bool = true) {
        bytes = Array(html.utf8)
        self.guessing = guessing
    }

    /// The text of the page's main part (`<main>`), or else of its articles, or else of the whole page.
    var mainText: String {
        for part in [Part.main, .article] {
            let text = text(part)
            if text.count >= ReadablePage.minimumText { return text }
        }
        return text(.all)
    }

    func text(_ part: Part) -> String {
        var kept: [String] = []
        for line in lines {
            switch part {
            case .main: if !line.main { continue }
            case .article: if !line.article { continue }
            case .all: break
            }
            if kept.last != line.text { kept.append(line.text) }
        }
        return kept.joined(separator: "\n")
    }

    private var skipping: Bool { open.last?.skipped ?? false }
    private var inMain: Bool { open.last?.main ?? false }
    private var inArticle: Bool { open.last?.article ?? false }

    mutating func run() {
        let count = bytes.count
        while position < count {
            let byte = bytes[position]
            if byte == UInt8(ascii: "<"), position + 1 < count {
                let next = bytes[position + 1]
                if next == UInt8(ascii: "!") {
                    skipDeclaration()
                    continue
                }
                if next == UInt8(ascii: "?") {
                    skip(past: UInt8(ascii: ">"))
                    continue
                }
                if next == UInt8(ascii: "/") || isLetter(next) {
                    tag()
                    continue
                }
            }
            if !skipping { line.append(byte) }
            position += 1
        }
        endLine()
        published = updated ?? published
    }

    // MARK: Tags

    private mutating func tag() {
        let closing = bytes[position + 1] == UInt8(ascii: "/")
        var index = position + (closing ? 2 : 1)
        let nameStart = index
        while index < bytes.count, isNameByte(bytes[index]) { index += 1 }
        let name = String(decoding: bytes[nameStart..<index], as: UTF8.self).lowercased()
        // The attributes, up to the ">" outside quotes.
        var quote: UInt8?
        let attributesStart = index
        while index < bytes.count {
            let byte = bytes[index]
            if let q = quote {
                if byte == q { quote = nil }
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                quote = byte
            } else if byte == UInt8(ascii: ">") {
                break
            }
            index += 1
        }
        let attributesText = String(decoding: bytes[attributesStart..<min(index, bytes.count)], as: UTF8.self)
        position = min(index + 1, bytes.count)
        guard !name.isEmpty else { return }
        if closing {
            close(name)
            return
        }
        let selfClosing = attributesText.hasSuffix("/")
        let attributes = Self.attributes(attributesText)
        switch name {
        case "script", "style", "textarea", "xmp":
            if name == "script", attributes["type"]?.lowercased() == "application/ld+json" {
                readStructuredData(rawText(until: name))
            } else {
                _ = rawText(until: name)
            }
            return
        case "title":
            let text = rawText(until: name)
            if title.isEmpty, open.allSatisfy({ $0.name != "svg" }) { title = Self.decoded(text) }
            return
        case "meta":
            readMeta(attributes)
            return
        case "br":
            if !skipping { endLine() }
            return
        case "td", "th":
            if !skipping, !line.isEmpty { line += Array(" | ".utf8) }
        default: break
        }
        if Self.blocks.contains(name), !skipping { endLine() }
        if Self.voidElements.contains(name) || selfClosing { return }
        let parent = open.last
        let role = attributes["role"]?.lowercased() ?? ""
        let main = (parent?.main ?? false) || name == "main" || role == "main"
        let article = (parent?.article ?? false) || name == "article"
        let skipped = (parent?.skipped ?? false) || skips(name, role: role, attributes: attributes, main: main)
        if name == "h1", firstHeading.isEmpty, !skipped { inFirstHeading = true }
        open.append(Element(name: name, skipped: skipped, main: main, article: article))
        if open.count > 512 { open.removeFirst(open.count - 512) }  // a page that never closes its tags
    }

    private mutating func close(_ name: String) {
        guard let index = open.lastIndex(where: { $0.name == name }) else { return }
        if name == "h1", inFirstHeading {
            inFirstHeading = false
            firstHeading = ReadablePage.clean(Self.decoded(String(decoding: line, as: UTF8.self)))
        }
        if Self.blocks.contains(name), !skipping { endLine() }
        open.removeSubrange(index...)
    }

    /// Whether an element's content is left out: what only a browser shows or uses (scripts' places, pictures,
    /// forms' controls), the site's menus, banners and footers, hidden parts, and what its class or id names as a
    /// menu, a banner, a pop-up or a cookie notice.
    private func skips(_ name: String, role: String, attributes: [String: String], main: Bool) -> Bool {
        if Self.skippedElements.contains(name) { return true }
        if attributes["hidden"] != nil || attributes["aria-hidden"]?.lowercased() == "true" { return true }
        if let style = attributes["style"]?.lowercased().replacingOccurrences(of: " ", with: ""),
           style.contains("display:none") || style.contains("visibility:hidden")
        {
            return true
        }
        guard guessing, !["main", "article", "body", "html"].contains(name) else { return false }
        if ["nav", "menu", "dialog"].contains(name) { return true }
        if ["header", "footer", "aside"].contains(name) { return !main && !(open.last?.article ?? false) }
        if Self.skippedRoles.contains(role) { return true }
        let names = ((attributes["class"] ?? "") + " " + (attributes["id"] ?? "")).lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return names.contains { Self.boilerplateNames.contains(String($0)) }
    }

    // MARK: Text

    private mutating func endLine() {
        guard !line.isEmpty else { return }
        let text = ReadablePage.clean(Self.decoded(String(decoding: line, as: UTF8.self)))
        line = []
        // A line of cell separators alone, or of punctuation alone, says nothing.
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        var cleaned = text
        while cleaned.hasPrefix("| ") { cleaned.removeFirst(2) }
        while cleaned.hasSuffix(" |") { cleaned.removeLast(2) }
        lines.append((cleaned, inMain, inArticle))
    }

    /// The text of an element whose content is not HTML (a script, a style, a title), up to its closing tag.
    private mutating func rawText(until name: String) -> String {
        let end = Array("</\(name)".utf8)
        let start = position
        var index = position
        while index + end.count <= bytes.count {
            if bytes[index] == UInt8(ascii: "<"), matches(end, at: index) {
                let text = String(decoding: bytes[start..<index], as: UTF8.self)
                position = index
                skip(past: UInt8(ascii: ">"))
                return text
            }
            index += 1
        }
        position = bytes.count
        return String(decoding: bytes[start...], as: UTF8.self)
    }

    private func matches(_ pattern: [UInt8], at index: Int) -> Bool {
        for (offset, byte) in pattern.enumerated() where lowercase(bytes[index + offset]) != byte { return false }
        return true
    }

    private mutating func skip(past byte: UInt8) {
        while position < bytes.count, bytes[position] != byte { position += 1 }
        position += 1
    }

    /// "<!-- … -->", "<![CDATA[ … ]]>", "<!DOCTYPE …>".
    private mutating func skipDeclaration() {
        if matches(Array("<!--".utf8), at: position) {
            let end = Array("-->".utf8)
            var index = position + 4
            while index + 3 <= bytes.count, !(bytes[index] == end[0] && bytes[index + 1] == end[1] && bytes[index + 2] == end[2]) {
                index += 1
            }
            position = min(index + 3, bytes.count)
        } else {
            skip(past: UInt8(ascii: ">"))
        }
    }

    // MARK: Dates

    private mutating func readMeta(_ attributes: [String: String]) {
        let key = (attributes["property"] ?? attributes["name"] ?? attributes["itemprop"] ?? "").lowercased()
        guard let content = attributes["content"] else { return }
        switch key {
        case "article:published_time", "datepublished", "date", "dc.date", "dc.date.issued", "pubdate":
            if published == nil { published = WebResultText.date(content) }
        case "article:modified_time", "og:updated_time", "datemodified", "last-modified":
            if updated == nil { updated = WebResultText.date(content) }
        default: break
        }
    }

    /// A page's structured data ({"datePublished": …, "dateModified": …}), for its date.
    private mutating func readStructuredData(_ text: String) {
        if published == nil, let range = text.range(of: #""datePublished"\s*:\s*"[^"]+""#, options: .regularExpression) {
            published = WebResultText.date(String(text[range].split(separator: "\"").last ?? ""))
        }
        if updated == nil, let range = text.range(of: #""dateModified"\s*:\s*"[^"]+""#, options: .regularExpression) {
            updated = WebResultText.date(String(text[range].split(separator: "\"").last ?? ""))
        }
    }

    // MARK: Helpers

    /// The attributes of a tag: `class="a b" hidden id=x` → ["class": "a b", "hidden": "", "id": "x"].
    static func attributes(_ text: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let scalars = Array(text.unicodeScalars)
        var index = 0
        func isSpace(_ s: Unicode.Scalar) -> Bool { s == " " || s == "\n" || s == "\t" || s == "\r" || s == "/" }
        while index < scalars.count {
            while index < scalars.count, isSpace(scalars[index]) { index += 1 }
            let nameStart = index
            while index < scalars.count, !isSpace(scalars[index]), scalars[index] != "=" { index += 1 }
            let name = String(String.UnicodeScalarView(scalars[nameStart..<index])).lowercased()
            guard !name.isEmpty else { index += 1; continue }
            while index < scalars.count, scalars[index] == " " { index += 1 }
            var value = ""
            if index < scalars.count, scalars[index] == "=" {
                index += 1
                while index < scalars.count, scalars[index] == " " { index += 1 }
                if index < scalars.count, scalars[index] == "\"" || scalars[index] == "'" {
                    let quote = scalars[index]
                    index += 1
                    let valueStart = index
                    while index < scalars.count, scalars[index] != quote { index += 1 }
                    value = String(String.UnicodeScalarView(scalars[valueStart..<index]))
                    index += 1
                } else {
                    let valueStart = index
                    while index < scalars.count, !isSpace(scalars[index]) { index += 1 }
                    value = String(String.UnicodeScalarView(scalars[valueStart..<index]))
                }
            }
            if attributes[name] == nil { attributes[name] = decoded(value) }
        }
        return attributes
    }

    /// The text with its entities written as the characters they stand for.
    static func decoded(_ text: String) -> String {
        text.contains("&") ? WebResultText.plain(text.replacingOccurrences(of: "<", with: "\u{FFFC}"))
            .replacingOccurrences(of: "\u{FFFC}", with: "<") : text
    }

    private func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    private func isNameByte(_ byte: UInt8) -> Bool {
        isLetter(byte) || (byte >= 0x30 && byte <= 0x39) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ":")
            || byte == UInt8(ascii: "_")
    }

    private func lowercase(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 32 : byte
    }

    static let blocks: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "caption", "dd", "details", "dialog", "div", "dl", "dt",
        "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li",
        "main", "nav", "ol", "p", "pre", "section", "summary", "table", "tbody", "tfoot", "thead", "tr", "ul",
    ]

    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
    ]

    /// Elements whose content only a browser shows or uses.
    static let skippedElements: Set<String> = [
        "noscript", "template", "svg", "math", "iframe", "object", "canvas", "video", "audio", "picture", "select",
        "button", "datalist", "option",
    ]

    static let skippedRoles: Set<String> = [
        "navigation", "banner", "contentinfo", "complementary", "dialog", "alertdialog", "menu", "menubar", "search",
        "tooltip", "toolbar",
    ]

    /// Words of class and id names that usually mark what is not the page's content.
    static let boilerplateNames: Set<String> = [
        "cookie", "cookies", "consent", "gdpr", "rgpd", "didomi", "onetrust", "cmp", "newsletter", "modal", "popup",
        "popin", "breadcrumb", "breadcrumbs", "share", "sharing", "social", "sidebar", "navbar", "nav", "menu",
        "footer", "advert", "advertisement", "ads", "pub", "outbrain", "taboola", "sr", "visually", "offscreen",
    ]
}
