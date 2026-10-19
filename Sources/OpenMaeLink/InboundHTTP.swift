#if os(macOS)
import Foundation

/// A minimal HTTP/1.1 server side for received information: one request per connection, then the answer, and the
/// connection closes. No dependency: deliveries are a few kilobytes at most.

/// A request's line and headers.
struct HTTPRequestHead: Sendable, Equatable {
    var method: String
    /// The path and query, as sent.
    var target: String
    /// Names in lowercase; a repeated header's values joined with ", ".
    var headers: [String: String]

    var path: String {
        String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    /// The query's parameters, decoded ("+" as a space), the first value of each.
    var query: [String: String] {
        guard let mark = target.firstIndex(of: "?") else { return [:] }
        var out: [String: String] = [:]
        for pair in target[target.index(after: mark)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ s: Substring) -> String {
                String(s).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(s)
            }
            let name = decode(parts[0])
            if out[name] == nil { out[name] = parts.count > 1 ? decode(parts[1]) : "" }
        }
        return out
    }
}

enum HTTPReadError: Error, Equatable {
    /// 400: not an HTTP/1.1 request.
    case badRequest
    /// 413: a body over the limit.
    case tooLarge
    /// 431: headers over 16 KB.
    case headersTooLarge
    /// 501: a transfer encoding other than `chunked`.
    case unsupportedEncoding
}

/// Reads one request as its bytes arrive: the head first, so that the address is checked before anything else, then
/// the body, by `Content-Length` or `chunked`.
struct HTTPRequestReader {
    static let maxHead = 16 * 1024
    let maxBody: Int
    private var buffer = Data()
    private(set) var head: HTTPRequestHead?
    /// Where the body starts in `buffer`.
    private var bodyStart = 0

    init(maxBody: Int) {
        self.maxBody = maxBody
    }

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// The head once it is complete, nil until then.
    mutating func readHead() throws(HTTPReadError) -> HTTPRequestHead? {
        if let head { return head }
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maxHead { throw .headersTooLarge }
            return nil
        }
        guard end.lowerBound <= Self.maxHead, let text = String(data: buffer[..<end.lowerBound], encoding: .utf8) else {
            throw end.lowerBound > Self.maxHead ? .headersTooLarge : .badRequest
        }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."), requestLine[1].hasPrefix("/") else {
            throw .badRequest
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw .badRequest }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw .badRequest }
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        let head = HTTPRequestHead(method: String(requestLine[0]).uppercased(), target: String(requestLine[1]),
                                   headers: headers)
        if let length = head.headers["content-length"] {
            guard let n = Int(length), n >= 0 else { throw .badRequest }
        }
        self.head = head
        bodyStart = end.upperBound
        return head
    }

    /// The body once it is complete, nil until then. Call after `readHead` returned the head (and the address was
    /// checked: the size and the encoding are refused only then, so that an unknown address learns nothing).
    func readBody() throws(HTTPReadError) -> Data? {
        guard let head else { return nil }
        let rest = buffer[bodyStart...]
        if let encoding = head.headers["transfer-encoding"]?.lowercased(), encoding != "chunked" {
            throw .unsupportedEncoding
        }
        if let length = head.headers["content-length"].flatMap({ Int($0) }), length > maxBody { throw .tooLarge }
        if head.headers["transfer-encoding"]?.lowercased() == "chunked" {
            // Chunk sizes and extensions add a little; far more is not a body of the allowed size.
            if rest.count > 2 * maxBody + 4096 { throw .tooLarge }
            return try Self.dechunk(rest, maxBody: maxBody)
        }
        let length = head.headers["content-length"].flatMap { Int($0) } ?? 0
        if rest.count > maxBody { throw .tooLarge }
        return rest.count >= length ? Data(rest.prefix(length)) : nil
    }

    /// A chunked body: each chunk's size in hexadecimal (extensions after ";" ignored), its bytes, then a size of zero
    /// and trailers up to an empty line.
    private static func dechunk(_ data: Data, maxBody: Int) throws(HTTPReadError) -> Data? {
        var body = Data()
        var i = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data[i...].range(of: crlf) else {
                if data.distance(from: i, to: data.endIndex) > 1024 { throw .badRequest }
                return nil
            }
            guard let line = String(data: data[i..<lineEnd.lowerBound], encoding: .ascii),
                  let size = Int(line.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "",
                                 radix: 16), size >= 0
            else { throw .badRequest }
            i = lineEnd.upperBound
            if size == 0 {
                // Trailers, if any, up to the empty line.
                while true {
                    guard let end = data[i...].range(of: crlf) else { return nil }
                    if end.lowerBound == i { return body }
                    i = end.upperBound
                }
            }
            if body.count + size > maxBody { throw .tooLarge }
            guard data.distance(from: i, to: data.endIndex) >= size + 2 else { return nil }
            body.append(data[i..<data.index(i, offsetBy: size)])
            i = data.index(i, offsetBy: size)
            guard data[i...].starts(with: crlf) else { throw .badRequest }
            i = data.index(i, offsetBy: 2)
        }
    }
}

enum HTTPResponse {
    /// A complete answer with a JSON body; the connection closes after it.
    static func json(_ status: Int, _ body: [String: String]) -> Data {
        let json = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(json.count)\r\n"
        if status == 405 { head += "Allow: GET, POST\r\n" }
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + json
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 413: "Content Too Large"
        case 422: "Unprocessable Content"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}
#endif
