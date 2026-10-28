#if canImport(Network)
import Foundation
import Network

/// One sign-in with the user's account at a connected tool, all of it but the browser: finds where to sign in, registers
/// the app when the service lets apps do so, gives the page to open, waits for the browser to come back to this Mac and
/// trades the code it brings for the tokens (see the top of MCPAuthorization.swift).
///
/// The browser comes back to a loopback address this Mac listens on for the length of the sign-in
/// (`http://127.0.0.1:<port>/callback`, RFC 8252), reachable from this Mac only. To a service that registers no app
/// (Home Assistant), the app is that address's `/openmae` page: the same scheme and host as the way back, as it asks.
public actor MCPAccountSignIn {
    public nonisolated let address: URL
    private let returnTo: URL?
    private let session: URLSession
    private var redirect: LoopbackRedirect?
    private var pending: Pending?

    private struct Pending {
        var plan: MCPAuthorizationPlan
        var client: MCPClientIdentity
        var pkce: MCPPKCE
        var state: String
        var redirect: URL
    }

    /// How long the browser has to come back.
    static let patience: Duration = .seconds(15 * 60)

    /// `returnTo`: where the browser goes once it came back with the code (the app's own scheme, so that the browser's
    /// window of the sign-in closes itself); nil: a page that says to go back to the app.
    public init(address: URL, returnTo: URL? = nil, configuration: URLSessionConfiguration = .ephemeral) {
        self.address = address
        self.returnTo = returnTo
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    /// The page where the user signs in, to open in the browser.
    public func prepare() async throws -> URL {
        stop()
        let redirect = try await LoopbackRedirect.start(returnTo: returnTo)
        self.redirect = redirect
        do {
            let plan = try await MCPAuthorization.discover(address, session: session)
            var client = MCPClientIdentity(id: redirect.client.absoluteString)
            if plan.server.registrationEndpoint != nil {
                client = try await MCPAuthorization.register(plan.server, redirect: redirect.callback, session: session)
            }
            let pending = Pending(plan: plan, client: client, pkce: MCPPKCE(), state: MCPPKCE().verifier,
                                  redirect: redirect.callback)
            self.pending = pending
            return MCPAuthorization.authorizationURL(plan, client: client.id, redirect: pending.redirect,
                                                     pkce: pending.pkce, state: pending.state)
        } catch {
            stop()
            throw error
        }
    }

    /// Waits for the browser to come back, then trades its code for the tokens. `cancelled` when `cancel()` was called
    /// first, or after `patience`.
    public func finish() async throws -> MCPCredentials {
        guard let redirect, let pending else { throw MCPSignInError.cancelled }
        defer { stop() }
        let timer = Task {
            try await Task.sleep(for: Self.patience)
            redirect.cancel()
        }
        defer { timer.cancel() }
        guard let answer = await redirect.next() else { throw MCPSignInError.cancelled }
        guard answer["state"] == pending.state else { throw MCPSignInError.refused("state") }
        if let error = answer["error"] {
            throw MCPSignInError.refused(answer["error_description"].flatMap { $0.isEmpty ? nil : $0 } ?? error)
        }
        guard let code = answer["code"], !code.isEmpty else { throw MCPSignInError.refused("no code") }
        return try await MCPAuthorization.exchange(code: code, plan: pending.plan, client: pending.client,
                                                   redirect: pending.redirect, pkce: pending.pkce, session: session)
    }

    /// The browser's window closed: stops waiting (nothing changes once the browser came back).
    public func cancel() {
        redirect?.cancel()
    }

    private func stop() {
        redirect?.cancel()
        redirect = nil
    }
}

/// Listens on a loopback address for the browser's way back: the query of the first `GET /callback`.
final class LoopbackRedirect: @unchecked Sendable {
    /// Set once, before `start` returns.
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let returnTo: URL?
    private let queue = DispatchQueue(label: "mcp-sign-in-redirect")
    private let answers: AsyncStream<[String: String]>
    private let continuation: AsyncStream<[String: String]>.Continuation
    private let lock = NSLock()
    private var answered = false

    /// Where the browser comes back.
    var callback: URL { URL(string: "http://127.0.0.1:\(port)/callback")! }
    /// The app, to a service that registers none.
    var client: URL { URL(string: "http://127.0.0.1:\(port)/openmae")! }

    private init(listener: NWListener, returnTo: URL?) {
        self.listener = listener
        self.returnTo = returnTo
        let made = AsyncStream<[String: String]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        answers = made.stream
        continuation = made.continuation
    }

    /// Listens on 127.0.0.1, on a port the system gives.
    static func start(returnTo: URL?) async throws -> LoopbackRedirect {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        guard let listener = try? NWListener(using: parameters) else { throw MCPSignInError.unreachable }
        let redirect = LoopbackRedirect(listener: listener, returnTo: returnTo)
        let queue = redirect.queue
        let ready = AsyncStream<UInt16?>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.continuation.yield(listener.port?.rawValue)
            case .failed, .cancelled: ready.continuation.yield(nil)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak redirect] connection in
            guard let redirect else { return connection.cancel() }
            connection.start(queue: queue)
            redirect.receive(connection, buffer: Data())
        }
        listener.start(queue: queue)
        var port: UInt16?
        for await given in ready.stream {
            port = given
            break
        }
        guard let port, port != 0 else {
            listener.cancel()
            throw MCPSignInError.unreachable
        }
        redirect.port = port
        return redirect
    }

    /// The query of the browser's way back; nil once cancelled.
    func next() async -> [String: String]? {
        for await answer in answers { return answer }
        return nil
    }

    func cancel() {
        continuation.finish()
        listener.cancel()
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.answer(String(decoding: buffer[..<end.lowerBound], as: UTF8.self), on: connection)
            } else if complete || error != nil || buffer.count > 65536 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func answer(_ head: String, on connection: NWConnection) {
        let line = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let components = URLComponents(string: String(parts[1])),
              components.path == "/callback"
        else {
            return send("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", on: connection)
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil { query[item.name] = item.value ?? "" }
        let first = lock.withLock {
            defer { answered = true }
            return !answered
        }
        if first { continuation.yield(query) }
        if let returnTo {
            send("HTTP/1.1 302 Found\r\nLocation: \(returnTo.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                 on: connection)
        } else {
            let page = "<!doctype html><meta charset=\"utf-8\"><title>\(AppIdentity.name)</title>"
                + "<p>\(AppIdentity.name): you can close this window.</p>"
            send("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(Data(page.utf8).count)\r\n"
                + "Cache-Control: no-store\r\nConnection: close\r\n\r\n" + page, on: connection)
        }
    }

    private func send(_ response: String, on connection: NWConnection) {
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif
