import CryptoKit
import Foundation
import Network
import Security
import Testing
import VoiceCore

@testable import OpenMaeLink

// Received information from the internet, the Mac's side: the ACME pieces, the certificate's renewal, the HTTPS server
// on 127.0.0.1 fed by tubes, and compartmentalisation on that path.

@Suite("Received information from the internet")
struct InboundInternetTests {
    // MARK: - ACME pieces

    @Test func keyAuthorization() {
        let key = ACMEAccountKey()
        let jwk = key.jwk
        #expect(jwk["kty"] == "EC" && jwk["crv"] == "P-256")
        #expect(jwk["x"]?.count == 43 && jwk["y"]?.count == 43)
        // RFC 7638: SHA-256 of the required members in lexicographic order, without spaces.
        let canonical = "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"\(jwk["x"]!)\",\"y\":\"\(jwk["y"]!)\"}"
        #expect(key.thumbprint == Base64URL.encode(Data(SHA256.hash(data: Data(canonical.utf8)))))
        #expect(key.keyAuthorization("tok-en_1") == "tok-en_1." + key.thumbprint)
        #expect(key.thumbprint.count == 43)
    }

    @Test func csrIsReadByOpenSSL() throws {
        let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
        guard FileManager.default.isExecutableFile(atPath: openssl.path) else { return }
        let domain = "4zvomamapw57cf63xyx4cjb3qe.in.openmae.com"
        let csr = CSR.make(domain: domain, key: P256.Signing.PrivateKey())
        let file = FileManager.default.temporaryDirectory.appending(path: "csr-\(UUID().uuidString).der")
        try csr.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = openssl
        process.arguments = ["req", "-inform", "DER", "-in", file.path, "-noout", "-verify", "-text"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(output)")
        #expect(output.contains("verify OK") || output.contains("Certificate request self-signature verify OK"))
        #expect(output.contains("DNS:\(domain)"))
        #expect(output.contains("CN=\(domain)") || output.contains("CN = \(domain)"))
    }

    @Test func pemRoundTrip() {
        let key = P256.Signing.PrivateKey()
        let der = DER.selfSigned(domain: "a.example.test", key: key, from: Date(), until: Date() + 3600)
        let pem = PEM.encode([der, der])
        #expect(PEM.certificates(in: pem) == [der, der])
        #expect(PEM.certificates(in: "nothing") == [])
    }

    @Test func renewalAtTwoThirds() throws {
        let key = P256.Signing.PrivateKey()
        let from = Date(timeIntervalSince1970: 1_800_000_000)
        let until = from + 90 * 86_400
        let der = DER.selfSigned(domain: "a.example.test", key: key, from: from, until: until)
        let certificate = InboundCertificate(domain: "a.example.test", chain: PEM.encode([der]),
                                             directory: ACMEServer.letsEncrypt.directory)
        let validity = try #require(certificate.validity)
        #expect(abs(validity.from.timeIntervalSince(from)) < 1 && abs(validity.until.timeIntervalSince(until)) < 1)
        let renewal = try #require(certificate.renewal)
        #expect(abs(renewal.timeIntervalSince(from + 60 * 86_400)) < 1)
        #expect(certificate.identity(key: key) != nil)
        #expect(certificate.identity(key: P256.Signing.PrivateKey()) == nil)  // not its key
    }

    @Test func acmeServerFromDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "acme-tests-\(UUID().uuidString)"))
        #expect(ACMEServer.fromDefaults(defaults, allowTestRoot: true) == .letsEncrypt)
        defaults.set("staging", forKey: "ACMEDirectory")
        #expect(ACMEServer.fromDefaults(defaults, allowTestRoot: true) == .letsEncryptStaging)
        defaults.set("http://insecure.example/dir", forKey: "ACMEDirectory")
        #expect(ACMEServer.fromDefaults(defaults, allowTestRoot: true) == .letsEncrypt)
        defaults.set("https://127.0.0.1:14000/dir", forKey: "ACMEDirectory")
        #expect(ACMEServer.fromDefaults(defaults, allowTestRoot: false).directory.absoluteString == "https://127.0.0.1:14000/dir")
    }

    @Test func inboundDomainsFromTheRelay() {
        #expect(InboundHost.validDomain("In.OpenMae.com") == "in.openmae.com")
        #expect(InboundHost.validDomain("openmae") == nil)
        #expect(InboundHost.validDomain("in..openmae.com") == nil)
        #expect(InboundHost.validDomain("in.openmae.com/x") == nil)
        #expect(InboundHost.validDomain("in.open mae.com") == nil)
    }

    /// Against Pebble, Let's Encrypt's test server, when one runs: `PEBBLE_DIRECTORY` (its directory's address) and
    /// `PEBBLE_ROOT` (the PEM of its API's root), Pebble started with `PEBBLE_VA_ALWAYS_VALID=1`.
    @Test func certificateFromPebble() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["PEBBLE_DIRECTORY"].flatMap(URL.init(string:)),
              let rootPath = environment["PEBBLE_ROOT"]
        else { return }
        let roots = PEM.certificates(in: try String(contentsOfFile: rootPath, encoding: .utf8))
        let client = ACMEClient(server: ACMEServer(directory: directory, trustedRoots: roots), accountKey: ACMEAccountKey())
        let domain = "4zvomamapw57cf63xyx4cjb3qe.in.example.test"
        let key = P256.Signing.PrivateKey()
        let answered = Answers()
        let chain = try await client.certificate(for: domain, key: key) { token, keyAuthorization in
            await answered.add(token, keyAuthorization)
        }
        let certificate = InboundCertificate(domain: domain, chain: chain, directory: directory)
        #expect(certificate.certificates.count >= 2)  // the leaf and its intermediate
        #expect(certificate.identity(key: key) != nil)
        let validity = try #require(certificate.validity)
        #expect(validity.until > Date() + 30 * 86_400)
        let summary = try #require(certificate.certificates.first.flatMap { SecCertificateCopySubjectSummary($0) as String? })
        #expect(summary == domain)
    }

    private actor Answers {
        var all: [String: String] = [:]
        func add(_ token: String, _ keyAuthorization: String) { all[token] = keyAuthorization }
    }

    // MARK: - The HTTPS server and its tubes

    /// A plain TCP listener standing for the relay: each connection to it becomes a tube, piped into the server.
    private final class FakeRelay: @unchecked Sendable {
        let listener: NWListener
        let ready = AsyncStream<UInt16>.makeStream()

        init(pipeInto server: InboundTLSServer, caller: String) throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: parameters)
            let queue = DispatchQueue(label: "fake-relay")
            listener.newConnectionHandler = { connection in
                connection.stateUpdateHandler = { state in
                    if case .ready = state {
                        let tube = StreamTransport(connection, queue: queue, started: true)
                        Task { await server.pipe(tube, from: caller) }
                    }
                }
                connection.start(queue: queue)
            }
            let ready = ready
            let listener = listener
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port { ready.continuation.yield(port.rawValue) }
            }
            listener.start(queue: queue)
        }

        func port() async -> UInt16 {
            for await port in ready.stream { return port }
            return 0
        }
    }

    /// A TLS client for `domain` trusting only `root`, through `port` on 127.0.0.1; sends `request`, returns the answer.
    private func tlsExchange(port: UInt16, domain: String, root: SecCertificate, request: String) async throws -> String {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, domain)
        // The test certificate is checked by what it is (the system's policy wants more of a real one).
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            complete(chain?.first.map { SecCertificateCopyData($0) as Data } == SecCertificateCopyData(root) as Data)
        }, .global())
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!,
                                      using: NWParameters(tls: tls))
        let queue = DispatchQueue(label: "tls-client")
        let answer = AsyncStream<String>.makeStream()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
                var received = Data()
                func read() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                        if let data { received.append(data) }
                        if complete || error != nil {
                            answer.continuation.yield(String(decoding: received, as: UTF8.self))
                        } else {
                            read()
                        }
                    }
                }
                read()
            case .failed(let error), .waiting(let error):
                answer.continuation.yield("failed: \(error)")
            default:
                break
            }
        }
        connection.start(queue: queue)
        defer { connection.cancel() }
        return try await withThrowingTaskGroup(of: String.self) { tasks in
            tasks.addTask {
                for await text in answer.stream { return text }
                return ""
            }
            tasks.addTask {
                try await Task.sleep(for: .seconds(10))
                return "timed out"
            }
            defer { tasks.cancelAll() }
            return try await tasks.next()!
        }
    }

    @Test func httpsServerThroughATube() async throws {
        let domain = "4zvomamapw57cf63xyx4cjb3qe.in.example.test"
        let key = P256.Signing.PrivateKey()
        let der = DER.selfSigned(domain: domain, key: key, from: Date() - 60, until: Date() + 3600)
        let certificate = InboundCertificate(domain: domain, chain: PEM.encode([der]), directory: ACMEServer.letsEncrypt.directory)
        let (identity, chain) = try #require(certificate.identity(key: key))
        let callers = Callers()
        let server = InboundTLSServer { transport, caller in
            Task {
                await callers.add(caller)
                var request = Data()
                for await input in transport.incoming {
                    guard case .bytes(let data) = input else { break }
                    request.append(data)
                    if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
                }
                await callers.add(String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")[0])
                transport.send(HTTPResponse.json(202, ["status": "queued"]))
                try? await Task.sleep(for: .milliseconds(200))
                transport.close()
            }
        }
        try await server.start(identity: identity, chain: chain)
        defer { server.stop() }
        let relay = try FakeRelay(pipeInto: server, caller: "203.0.113.7")
        defer { relay.listener.cancel() }
        let port = await relay.port()
        let answer = try await tlsExchange(port: port, domain: domain, root: chain[0],
                                           request: "GET /in/secret?text=hi HTTP/1.1\r\nHost: \(domain)\r\n\r\n")
        #expect(answer.hasPrefix("HTTP/1.1 202"), "\(answer)")
        #expect(await callers.all == ["203.0.113.7", "GET /in/secret?text=hi HTTP/1.1"])
    }

    @Test func connectionsNotFromATubeAreClosed() async throws {
        let domain = "4zvomamapw57cf63xyx4cjb3qe.in.example.test"
        let key = P256.Signing.PrivateKey()
        let der = DER.selfSigned(domain: domain, key: key, from: Date() - 60, until: Date() + 3600)
        let certificate = InboundCertificate(domain: domain, chain: PEM.encode([der]), directory: ACMEServer.letsEncrypt.directory)
        let (identity, chain) = try #require(certificate.identity(key: key))
        let handled = Callers()
        let server = InboundTLSServer { _, caller in Task { await handled.add(caller) } }
        try await server.start(identity: identity, chain: chain)
        defer { server.stop() }
        let port = try #require(server.currentPort)
        // Straight to the server, as another program of this Mac would.
        let answer = try await tlsExchange(port: port, domain: domain, root: chain[0],
                                           request: "GET /in/secret HTTP/1.1\r\nHost: \(domain)\r\n\r\n")
        #expect(!answer.hasPrefix("HTTP/1.1"))
        #expect(await handled.all.isEmpty)
    }

    private actor Callers {
        var all: [String] = []
        func add(_ caller: String) { all.append(caller) }
    }

    // MARK: - Compartmentalisation

    @Test func onlyInternetSourcesThroughThePublicRelay() async throws {
        let secrets = MemoryInboundSecrets()
        let identity = FileIdentityStore(url: FileManager.default.temporaryDirectory
            .appending(path: "inbound-internet-tests-\(UUID().uuidString)/keys"))
        let host = InboundHost(announcer: nil, identityStore: identity, secrets: secrets, storeURL: nil)
        let home = await host.addSource(name: "Maison", origin: .home)
        let internet = await host.addSource(name: "Internet", origin: .internet)
        func deliver(_ source: UUID, path: InboundPath) async -> String {
            let body = "Bonjour"
            let tube = MemoryTube("POST /in/\(secrets.secret(for: source)!) HTTP/1.1\r\nHost: x\r\n"
                + "Content-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
            await host.serve(tube, from: "203.0.113.7", path: path)
            return tube.response
        }
        #expect(await deliver(home, path: .publicRelay).hasPrefix("HTTP/1.1 404"))
        #expect(await deliver(internet, path: .homeRelay).hasPrefix("HTTP/1.1 404"))
        #expect(await deliver(internet, path: .publicRelay).hasPrefix("HTTP/1.1 202"))
        let homeLog = await host.current.logs[home] ?? []
        #expect(homeLog.first?.result == .wrongPath && homeLog.first?.path == .publicRelay)
    }

    @Test func internetAddresses() async throws {
        let secrets = MemoryInboundSecrets()
        let identity = FileIdentityStore(url: FileManager.default.temporaryDirectory
            .appending(path: "inbound-internet-tests-\(UUID().uuidString)/keys"))
        let host = InboundHost(announcer: nil, identityStore: identity, secrets: secrets, storeURL: nil)
        let source = await host.addSource(name: "Internet", origin: .internet)
        // No relay: not offered, and no address.
        #expect(await host.current.internetPath == .notOffered)
        #expect(await host.current.addresses[source] == nil)
    }

    /// A tube in memory whose request is all there.
    private final class MemoryTube: LinkTransport, @unchecked Sendable {
        let path = LinkPath.relay
        let incoming: AsyncStream<TransportInput>
        private let sink: AsyncStream<TransportInput>.Continuation
        private let lock = NSLock()
        private var sent = Data()

        init(_ request: String) {
            (incoming, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
            sink.yield(.bytes(Data(request.utf8)))
        }

        func send(_ bytes: Data) { lock.withLock { sent.append(bytes) } }
        func sendDatagram(_ datagram: Data) {}
        func close() { sink.finish() }
        var response: String { lock.withLock { String(decoding: sent, as: UTF8.self) } }
    }
}
