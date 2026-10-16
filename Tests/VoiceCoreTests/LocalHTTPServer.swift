import Foundation
import Network

@testable import VoiceCore

/// A small HTTP server on a local port, for the pretend services of the tests (`FakeSearXNG`, `FakeBrave`): it reads
/// each whole request, keeps it, sends what `route` answers and closes the connection.
final class LocalHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        /// The path and the query, as sent: "/search?q=PSG".
        var target: String
        /// By lowercased name.
        var headers: [String: String]
        var body: Data

        var path: String { String(target.prefix { $0 != "?" }) }
        /// The fields of its query ("?q=PSG&count=5"), decoded.
        var query: [String: String] { Self.fields(target.firstIndex(of: "?").map { String(target[$0...].dropFirst()) } ?? "") }
        /// The fields of its body, as an HTML form sends them ("q=PSG&format=json"), decoded.
        var form: [String: String] { Self.fields(String(decoding: body, as: UTF8.self)) }

        private static func fields(_ text: String) -> [String: String] {
            var fields: [String: String] = [:]
            for pair in text.split(separator: "&") {
                let field = pair.split(separator: "=", maxSplits: 1).map {
                    $0.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
                }
                if field.count == 2 { fields[field[0]] = field[1] }
            }
            return fields
        }
    }

    struct Response: Sendable {
        var status: Int
        var body: String
        var type = "application/json"
        /// "WWW-Authenticate: Basic realm=…", each followed by "\r\n".
        var headers = ""
        /// Sent after that many seconds: a slow server.
        var delay: TimeInterval = 0

        static func json(_ value: JSONValue, status: Int = 200) -> Response {
            Response(status: status, body: String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self))
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "local-http-server")
    private var listener: NWListener?
    private var log: [Request] = []
    private(set) var port: UInt16 = 0

    var requests: [Request] { lock.withLock { log } }

    func start(_ route: @escaping @Sendable (Request) -> Response) async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let queue = queue
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: queue)
            self?.receive(connection, buffer: Data(), route: route)
        }
        let ready = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port?.rawValue { ready.continuation.yield(port) }
        }
        listener.start(queue: queue)
        for await port in ready.stream {
            self.port = port
            break
        }
    }

    func stop() {
        listener?.cancel()
    }

    private func receive(_ connection: NWConnection, buffer: Data, route: @escaping @Sendable (Request) -> Response) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.lock.withLock { self.log.append(request) }
                let response = route(request)
                self.queue.asyncAfter(deadline: .now() + response.delay) { Self.send(response, on: connection) }
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer, route: route)
            }
        }
    }

    /// A whole request (headers, and as many bytes of body as they announce), or nil while it is incomplete.
    private static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = head.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(parts[0]), target: String(parts[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private static func send(_ response: Response, on connection: NWConnection) {
        let data = Data(response.body.utf8)
        let head = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Status")\r\n"
            + "Content-Type: \(response.type)\r\nContent-Length: \(data.count)\r\n\(response.headers)Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
