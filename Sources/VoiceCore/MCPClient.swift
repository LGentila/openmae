import Foundation

// A small client of the Model Context Protocol, for the connected tools: a service reached at an address (Home
// Assistant, …) whose tools become actions Maé can call. Only the Streamable HTTP transport (MCP 2025-03-26 and later):
// each JSON-RPC message is POSTed to the address, and the answer comes back as JSON or as a stream of server-sent
// events. The old HTTP+SSE transport (a GET stream, then POSTs to another address) is not spoken. A program on this Mac
// is spoken to over its standard input and output instead (MCPProgramClient.swift).

/// What reaches one connected tool's MCP server: `MCPClient` for a service at an address, `MCPProgramClient` for a
/// program this Mac starts.
public protocol MCPConnection: Actor {
    /// Every tool, all pages of the list.
    func listTools() async throws -> [MCPTool]
    /// Calls a tool. A failure the tool reports (`isError`) is a result, not an error.
    func call(_ name: String, arguments: [String: JSONValue]) async throws -> MCPCallResult
    /// The server said its list of tools changed (`notifications/tools/list_changed`) since it was last listed.
    var toolsChanged: Bool { get }
}

/// Why a connected tool could not be reached or used.
public enum MCPError: Error, Sendable, Codable, Equatable {
    /// Nothing answers at the address (wrong address, the service is off, another network).
    case unreachable
    /// It did not answer in time.
    case noAnswer
    /// 401 or 403: the token is wrong or was revoked, or the account may not connect.
    case unauthorized
    /// Something answered, but not an MCP server (a web page, a 404…): what it was.
    case notMCP(String)
    /// The server refused the request (a JSON-RPC error): its message.
    case refused(String)
    /// A program on this Mac: its command is not on this Mac, or is not a program (the command as typed: "npx").
    case notFound(String)
    /// A program on this Mac ended before it answered, or could not be started: the last line it wrote (on its error
    /// output, else on its output), else why it could not start; empty when it said nothing.
    case ended(String)
}

/// A tool a connected service offers, as its `tools/list` gives it.
public struct MCPTool: Sendable, Codable, Equatable {
    public var name: String
    /// A title for people, when the server gives one ("Turn on").
    public var title: String?
    public var description: String
    /// Its arguments, a JSON Schema object.
    public var inputSchema: JSONValue
    /// The server says it only reads (`annotations.readOnlyHint`); nil when it says nothing.
    public var readOnlyHint: Bool?

    public init(name: String, title: String? = nil, description: String, inputSchema: JSONValue = ["type": "object"],
                readOnlyHint: Bool? = nil)
    {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnlyHint = readOnlyHint
    }
}

/// What a tool call gave back.
public struct MCPCallResult: Sendable, Equatable {
    /// Its text contents, one after the other (structured content written as JSON when there is no text).
    public var text: String
    /// The tool says it failed (`isError`).
    public var isError: Bool

    public init(text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }
}

/// The messages of the protocol and how their answers are read, whatever carries them.
enum MCPMessages {
    /// `initialize`'s parameters: the protocol version asked for, no capability of the client's own (no roots, no
    /// sampling: a server asks nothing of Maé), its name.
    static var initialize: [String: JSONValue] {
        ["protocolVersion": .string(MCPClient.protocolVersion), "capabilities": .object([:]),
         "clientInfo": ["name": .string(AppIdentity.name), "version": "1"]]
    }

    /// The protocol version the server answered `initialize` with; throws when the answer is not one.
    static func initialized(_ result: JSONValue) throws -> String? {
        guard case .object(let info) = result, info["protocolVersion"] != nil || info["capabilities"] != nil else {
            throw MCPError.notMCP("initialize")
        }
        return info["protocolVersion"]?.text
    }

    /// One page of `tools/list`: its tools, and the cursor of the next page (nil: the last one).
    static func page(_ result: JSONValue) throws -> (tools: [MCPTool], next: String?) {
        guard case .object(let page) = result, case .array(let items)? = page["tools"] else {
            throw MCPError.notMCP("tools/list")
        }
        let next = page["nextCursor"]?.text
        return (items.compactMap(tool), next?.isEmpty == false ? next : nil)
    }

    /// What `tools/call` gave back: its text contents, one after the other (structured content written as JSON when
    /// there is no text).
    static func callResult(_ result: JSONValue) throws -> MCPCallResult {
        guard case .object(let object) = result else { throw MCPError.notMCP("tools/call") }
        var texts: [String] = []
        if case .array(let content)? = object["content"] {
            for item in content {
                guard case .object(let part) = item else { continue }
                if part["type"]?.text == "text", let text = part["text"]?.text {
                    texts.append(text)
                } else if case .object(let resource)? = part["resource"], let text = resource["text"]?.text {
                    texts.append(text)
                }
            }
        }
        if texts.isEmpty, let structured = object["structuredContent"],
           let data = try? JSONEncoder().encode(structured)
        {
            texts.append(String(decoding: data, as: UTF8.self))
        }
        return MCPCallResult(text: texts.joined(separator: "\n"), isError: object["isError"]?.boolean ?? false)
    }

    static func tool(_ value: JSONValue) -> MCPTool? {
        guard case .object(let item) = value, let name = item["name"]?.text, !name.isEmpty else { return nil }
        var annotations: [String: JSONValue] = [:]
        if case .object(let a)? = item["annotations"] { annotations = a }
        let title = item["title"]?.text ?? annotations["title"]?.text
        return MCPTool(name: name, title: title?.isEmpty == false ? title : nil,
                       description: item["description"]?.text ?? "",
                       inputSchema: item["inputSchema"] ?? ["type": "object"],
                       readOnlyHint: annotations["readOnlyHint"]?.boolean)
    }
}

/// Talks to one MCP server at an address. Connects on first use (`initialize`, then `notifications/initialized`), keeps
/// the server's session (`Mcp-Session-Id`) and starts a new one when the server forgot it (404 to a request in a
/// session).
public actor MCPClient: MCPConnection {
    /// The protocol version asked for; the server answers with the one it speaks, used from then on.
    public static let protocolVersion = "2025-06-18"

    public nonisolated let address: URL
    private let token: String?
    private let timeout: Duration
    private let session: URLSession
    private var sessionID: String?
    private var negotiatedVersion: String?
    private var connected = false
    private var nextID = 1
    /// The server said its list of tools changed (`notifications/tools/list_changed`), in a stream it sent.
    public private(set) var toolsChanged = false

    /// `token`: sent as `Authorization: Bearer` (nil: no access, nothing is sent). `timeout`: for each request, the whole
    /// answer included.
    public init(address: URL, token: String?, timeout: Duration = .seconds(15),
                configuration: URLSessionConfiguration = .ephemeral)
    {
        self.address = address
        self.token = token.flatMap { $0.isEmpty ? nil : $0 }
        self.timeout = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    /// The address as typed: "homeassistant.local:8123/api/mcp" gets http:// on the home network (a .local name, an IP
    /// address of the home network, localhost), https:// otherwise. nil when it cannot be one.
    public static func address(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        var written = text
        if !text.contains("://") {
            let host = text.split(separator: "/").first?.split(separator: ":").first.map(String.init) ?? ""
            written = (isHomeNetwork(host) ? "http://" : "https://") + text
        }
        guard let url = URL(string: written), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    /// A name or an address of the home network: localhost, a .local name, a private IPv4 address, a name without a dot.
    public static func isHomeNetwork(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if ["localhost", "127.0.0.1", "::1"].contains(host) || host.hasSuffix(".local") || host.hasSuffix(".lan")
            || host.hasSuffix(".home.arpa") || !host.contains(".") && !host.contains(":")
        {
            return true
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return host.hasPrefix("fe80:") || host.hasPrefix("fd") }
        return parts[0] == 10 || parts[0] == 192 && parts[1] == 168 || parts[0] == 172 && (16...31).contains(parts[1])
            || parts[0] == 169 && parts[1] == 254
    }

    // MARK: - The protocol

    /// `initialize`, then `notifications/initialized`. Done once; again after the server forgot the session.
    public func connect() async throws {
        guard !connected else { return }
        sessionID = nil
        negotiatedVersion = nil
        let result = try await request("initialize", MCPMessages.initialize, connecting: true)
        negotiatedVersion = try MCPMessages.initialized(result)
        connected = true
        try await notify("notifications/initialized")
    }

    /// Every tool, all pages of the list.
    public func listTools() async throws -> [MCPTool] {
        try await connect()
        var tools: [MCPTool] = []
        var cursor: String?
        for _ in 0..<50 {
            let page = try MCPMessages.page(try await request("tools/list", cursor.map { ["cursor": .string($0)] } ?? [:]))
            tools += page.tools
            cursor = page.next
            if cursor == nil { break }
        }
        toolsChanged = false
        return tools
    }

    /// Calls a tool. A failure the tool reports (`isError`) is a result, not an error.
    public func call(_ name: String, arguments: [String: JSONValue]) async throws -> MCPCallResult {
        try await connect()
        return try MCPMessages.callResult(try await request("tools/call", ["name": .string(name),
                                                                           "arguments": .object(arguments)]))
    }

    // MARK: - JSON-RPC over HTTP

    private func notify(_ method: String) async throws {
        let message: JSONValue = ["jsonrpc": "2.0", "method": .string(method)]
        _ = try await post(message, id: nil)
    }

    /// Sends a request and gives its result. The server forgot the session (404): connects again, once.
    private func request(_ method: String, _ params: [String: JSONValue], connecting: Bool = false) async throws
        -> JSONValue
    {
        do {
            return try await send(method, params)
        } catch HTTPStatus.notFound where sessionID != nil && !connecting {
            connected = false
            try await connect()
            return try await send(method, params)
        } catch HTTPStatus.notFound {
            throw MCPError.notMCP("404")
        }
    }

    private func send(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let message: JSONValue = ["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": .object(params)]
        guard let answer = try await post(message, id: id) else { throw MCPError.notMCP("no answer to \(method)") }
        guard case .object(let response) = answer else { throw MCPError.notMCP("not JSON-RPC") }
        if case .object(let error)? = response["error"] {
            throw MCPError.refused(error["message"]?.text ?? "error \(error["code"]?.text ?? "")")
        }
        guard let result = response["result"] else { throw MCPError.notMCP("not JSON-RPC") }
        return result
    }

    /// A 404, told apart so that a forgotten session can be started again.
    private enum HTTPStatus: Error { case notFound }

    /// POSTs one message; for a request, its response (from a JSON body, or from the stream of events), within the
    /// timeout.
    private func post(_ message: JSONValue, id: Int?) async throws -> JSONValue? {
        var request = URLRequest(url: address)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(message)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let negotiatedVersion { request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        request.timeoutInterval = Double(timeout.components.seconds) + 1
        let session = session
        let exchange = Task { () throws -> (JSONValue?, String?, Bool) in
            try await Self.exchange(request, id: id, session: session)
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            exchange.cancel()
        }
        defer { timer.cancel() }
        do {
            let (answer, newSession, changed) = try await exchange.value
            if let newSession { sessionID = newSession }
            if changed { toolsChanged = true }
            return answer
        } catch let error as MCPError {
            throw error
        } catch let error as HTTPStatus {
            throw error
        } catch {
            if exchange.isCancelled || (error as? URLError)?.code == .timedOut { throw MCPError.noAnswer }
            throw MCPError.unreachable
        }
    }

    /// One HTTP exchange: the response to `id` (nil for a notification), the session the server gave, and whether it
    /// said its tools changed.
    private static func exchange(_ request: URLRequest, id: Int?, session: URLSession) async throws
        -> (JSONValue?, String?, Bool)
    {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.notMCP("not HTTP") }
        let newSession = http.value(forHTTPHeaderField: "Mcp-Session-Id")
        switch http.statusCode {
        case 401, 403: throw MCPError.unauthorized
        case 404: throw HTTPStatus.notFound
        case 202, 204: return (nil, newSession, false)
        case 200..<300: break
        default: throw MCPError.notMCP("HTTP \(http.statusCode)")
        }
        guard let id else { return (nil, newSession, false) }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if type.contains("text/event-stream") {
            var changed = false
            var data = ""
            var line: [UInt8] = []
            // Lines by hand: an empty line ends an event, and `AsyncBytes.lines` leaves empty lines out.
            func event(_ text: String) -> JSONValue? {
                guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return nil }
                let messages: [JSONValue] = if case .array(let batch) = value { batch } else { [value] }
                var answer: JSONValue?
                for message in messages {
                    guard case .object(let object) = message else { continue }
                    if object["method"]?.text == "notifications/tools/list_changed" { changed = true }
                    if object["method"] == nil, object["id"]?.integer == id { answer = message }
                }
                return answer
            }
            func endOfLine() -> JSONValue? {
                var text = String(decoding: line, as: UTF8.self)
                line.removeAll()
                if text.hasSuffix("\r") { text.removeLast() }
                if text.isEmpty {
                    defer { data = "" }
                    return data.isEmpty ? nil : event(data)
                }
                if text.hasPrefix("data:") {
                    let piece = text.dropFirst(5)
                    data += (data.isEmpty ? "" : "\n") + (piece.first == " " ? String(piece.dropFirst()) : String(piece))
                }
                return nil
            }
            for try await byte in bytes {
                if byte == 0x0A {
                    if let answer = endOfLine() { return (answer, newSession, changed) }
                } else {
                    line.append(byte)
                }
            }
            if !line.isEmpty, let answer = endOfLine() { return (answer, newSession, changed) }
            if !data.isEmpty, let answer = event(data) { return (answer, newSession, changed) }
            throw MCPError.notMCP("no answer in the stream")
        }
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count > 4_000_000 { throw MCPError.notMCP("answer too long") }
        }
        guard type.contains("json"), let value = try? JSONDecoder().decode(JSONValue.self, from: body) else {
            throw MCPError.notMCP(type.isEmpty ? "not JSON" : type)
        }
        if case .array(let batch) = value {
            return (batch.first { if case .object(let o) = $0 { o["id"]?.integer == id } else { false } }, newSession, false)
        }
        return (value, newSession, false)
    }
}
