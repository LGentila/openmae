#if os(macOS)
import CryptoKit
import Foundation
import Security
import VoiceCore

// A small ACME client (RFC 8555) for the certificate of the Mac's inbound name: its own account (no e-mail), the
// HTTP-01 challenge answered through the public relay, a CSR made here by hand, and the certificate chain in PEM.
// Let's Encrypt in production; its staging server, or Pebble (its test server), while trying things out.

public enum ACMEError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The server answered with an error document (RFC 8555 §6.7): its type and detail.
    case server(type: String, detail: String, status: Int)
    case unexpected(String)
    /// The authorization or the order ended invalid: the detail of what failed, as the server says it.
    case invalid(String)
    case timeout

    public var description: String {
        switch self {
        case .server(let type, let detail, let status):
            "\(status) \(type.replacingOccurrences(of: "urn:ietf:params:acme:error:", with: "")): \(detail)"
        case .unexpected(let what): "unexpected answer: \(what)"
        case .invalid(let detail): "refused: \(detail)"
        case .timeout: "no answer in time"
        }
    }
}

/// Where certificates come from.
public struct ACMEServer: Sendable, Equatable {
    public var directory: URL
    /// Certificates trusted for the server's own HTTPS, besides the system's: Pebble's test root.
    public var trustedRoots: [Data]

    public init(directory: URL, trustedRoots: [Data] = []) {
        self.directory = directory
        self.trustedRoots = trustedRoots
    }

    public static let letsEncrypt = ACMEServer(directory: URL(string: "https://acme-v02.api.letsencrypt.org/directory")!)
    public static let letsEncryptStaging =
        ACMEServer(directory: URL(string: "https://acme-staging-v02.api.letsencrypt.org/directory")!)

    /// Production, unless the user default `ACMEDirectory` says "staging" or gives a directory's address (with
    /// `ACMERootCertificate`, a PEM file of the test server's root, for Pebble: honoured in debug builds only).
    public static func fromDefaults(_ defaults: UserDefaults = .standard, allowTestRoot: Bool) -> ACMEServer {
        let value = defaults.string(forKey: "ACMEDirectory")?.trimmingCharacters(in: .whitespaces) ?? ""
        switch value.lowercased() {
        case "", "production": return .letsEncrypt
        case "staging": return .letsEncryptStaging
        default:
            guard let url = URL(string: value), url.scheme == "https" else { return .letsEncrypt }
            var roots: [Data] = []
            if allowTestRoot, let path = defaults.string(forKey: "ACMERootCertificate"),
               let pem = try? String(contentsOfFile: path, encoding: .utf8)
            {
                roots = PEM.certificates(in: pem)
            }
            return ACMEServer(directory: url, trustedRoots: roots)
        }
    }
}

/// The ACME account's key: P-256, signing with ES256.
public struct ACMEAccountKey: Sendable {
    public let key: P256.Signing.PrivateKey

    public init(key: P256.Signing.PrivateKey = .init()) {
        self.key = key
    }

    /// The public key as a JWK (RFC 7517), its members in the order RFC 7638 needs for the thumbprint.
    var jwk: [String: String] {
        let point = key.publicKey.x963Representation  // 0x04 ‖ x ‖ y
        return ["crv": "P-256", "kty": "EC", "x": Base64URL.encode(point[1..<33]), "y": Base64URL.encode(point[33..<65])]
    }

    /// RFC 7638: SHA-256 of the JWK's required members, sorted, without spaces.
    public var thumbprint: String {
        let j = jwk
        let canonical = #"{"crv":"\#(j["crv"]!)","kty":"\#(j["kty"]!)","x":"\#(j["x"]!)","y":"\#(j["y"]!)"}"#
        return Base64URL.encode(Data(SHA256.hash(data: Data(canonical.utf8))))
    }

    /// What the HTTP-01 challenge answers for `token`.
    public func keyAuthorization(_ token: String) -> String { token + "." + thumbprint }
}

/// One certificate order: account, order, HTTP-01 challenge, finalisation, download.
public actor ACMEClient {
    private let server: ACMEServer
    private let accountKey: ACMEAccountKey
    private let session: URLSession
    private let delegate: TrustDelegate
    private var directory: [String: Any]?
    private var nonce: String?
    /// The account's URL (the JWS "kid"), once made or found.
    public private(set) var accountURL: URL?

    public init(server: ACMEServer, accountKey: ACMEAccountKey, accountURL: URL? = nil) {
        self.server = server
        self.accountKey = accountKey
        self.accountURL = accountURL
        delegate = TrustDelegate(roots: server.trustedRoots.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "OpenMae-ACME/1"]
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Obtains a certificate for `domain`, its key made here: `answer` leaves each HTTP-01 challenge's key
    /// authorization where the server will fetch it (the relay), and returns once it is there. Returns the chain, in
    /// PEM, leaf first.
    public func certificate(for domain: String, key: P256.Signing.PrivateKey,
                            answer: @Sendable (_ token: String, _ keyAuthorization: String) async throws -> Void)
        async throws -> String
    {
        try await loadDirectory()
        try await ensureAccount()
        let (orderURL, order) = try await post(try endpoint("newOrder"),
                                               payload: ["identifiers": [["type": "dns", "value": domain]]])
        guard let orderURL, let authorizations = order["authorizations"] as? [String],
              let finalize = (order["finalize"] as? String).flatMap(URL.init(string:))
        else { throw ACMEError.unexpected("order") }
        for case let url? in authorizations.map(URL.init(string:)) {
            try await authorize(url, answer: answer)
        }
        let csr = CSR.make(domain: domain, key: key)
        var (_, state) = try await post(finalize, payload: ["csr": Base64URL.encode(csr)])
        let deadline = ContinuousClock.now + .seconds(90)
        while state["status"] as? String != "valid" {
            switch state["status"] as? String {
            case "invalid": throw ACMEError.invalid(Self.problem(in: state) ?? "the order was refused")
            case "pending", "ready", "processing": break
            default: throw ACMEError.unexpected("order status \(state["status"] ?? "none")")
            }
            guard ContinuousClock.now < deadline else { throw ACMEError.timeout }
            try await Task.sleep(for: .seconds(1))
            state = try await post(orderURL, payload: nil).1
        }
        guard let certificate = (state["certificate"] as? String).flatMap(URL.init(string:)) else {
            throw ACMEError.unexpected("no certificate in the order")
        }
        let (data, _) = try await signedRequest(certificate, payload: nil, accept: "application/pem-certificate-chain")
        let pem = String(decoding: data, as: UTF8.self)
        guard !PEM.certificates(in: pem).isEmpty else { throw ACMEError.unexpected("certificate chain") }
        return pem
    }

    // MARK: - Steps

    private func ensureAccount() async throws {
        guard accountURL == nil else { return }
        // No contact: Let's Encrypt no longer sends expiry e-mails, and the Mac renews by itself.
        let (location, account) = try await post(try endpoint("newAccount"), payload: ["termsOfServiceAgreed": true],
                                                 useJWK: true)
        guard let location, account["status"] as? String ?? "valid" == "valid" else {
            throw ACMEError.unexpected("account")
        }
        accountURL = location
    }

    private func authorize(_ url: URL, answer: @Sendable (String, String) async throws -> Void) async throws {
        var authorization = try await post(url, payload: nil).1
        if authorization["status"] as? String == "valid" { return }  // authorized lately: nothing to prove
        guard let challenges = authorization["challenges"] as? [[String: Any]],
              let http = challenges.first(where: { $0["type"] as? String == "http-01" }),
              let token = http["token"] as? String, let challengeURL = (http["url"] as? String).flatMap(URL.init(string:))
        else { throw ACMEError.unexpected("no http-01 challenge") }
        try await answer(token, accountKey.keyAuthorization(token))
        _ = try await post(challengeURL, payload: [String: String]())  // "ready": the server may fetch it now
        let deadline = ContinuousClock.now + .seconds(90)
        while true {
            switch authorization["status"] as? String {
            case "valid": return
            case "pending": break
            default:
                let detail = ((authorization["challenges"] as? [[String: Any]]) ?? []).compactMap(Self.problem(in:)).first
                throw ACMEError.invalid(detail ?? "the authorization is \(authorization["status"] ?? "unknown")")
            }
            guard ContinuousClock.now < deadline else { throw ACMEError.timeout }
            try await Task.sleep(for: .seconds(1))
            authorization = try await post(url, payload: nil).1
        }
    }

    private static func problem(in object: [String: Any]) -> String? {
        guard let error = object["error"] as? [String: Any] else { return nil }
        return error["detail"] as? String ?? error["type"] as? String
    }

    // MARK: - Requests

    private func endpoint(_ name: String) throws -> URL {
        guard let url = (directory?[name] as? String).flatMap(URL.init(string:)) else {
            throw ACMEError.unexpected("no \(name) in the directory")
        }
        return url
    }

    private func loadDirectory() async throws {
        guard directory == nil else { return }
        let (data, response) = try await session.data(from: server.directory)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ACMEError.unexpected("directory") }
        directory = object
    }

    private func freshNonce() async throws -> String {
        if let nonce {
            self.nonce = nil
            return nonce
        }
        try await loadDirectory()
        var request = URLRequest(url: try endpoint("newNonce"))
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        guard let nonce = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Replay-Nonce") else {
            throw ACMEError.unexpected("no nonce")
        }
        return nonce
    }

    /// A signed POST whose answer is a JSON object; a nil payload is a POST-as-GET. Returns the Location header too.
    private func post(_ url: URL, payload: Any?, useJWK: Bool = false) async throws -> (URL?, [String: Any]) {
        let (data, response) = try await signedRequest(url, payload: payload, useJWK: useJWK)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let location = response.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:))
        return (location, object)
    }

    private func signedRequest(_ url: URL, payload: Any?, useJWK: Bool = false, accept: String? = nil,
                               retried: Bool = false) async throws -> (Data, HTTPURLResponse)
    {
        try await loadDirectory()
        var protected: [String: Any] = ["alg": "ES256", "nonce": try await freshNonce(), "url": url.absoluteString]
        if useJWK || accountURL == nil {
            protected["jwk"] = accountKey.jwk
        } else {
            protected["kid"] = accountURL!.absoluteString
        }
        let header = Base64URL.encode(try JSONSerialization.data(withJSONObject: protected, options: [.sortedKeys]))
        let body = try payload.map { Base64URL.encode(try JSONSerialization.data(withJSONObject: $0)) } ?? ""
        let signature = try accountKey.key.signature(for: Data("\(header).\(body)".utf8)).rawRepresentation
        let jws = ["protected": header, "payload": body, "signature": Base64URL.encode(signature)]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/jose+json", forHTTPHeaderField: "Content-Type")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        request.httpBody = try JSONSerialization.data(withJSONObject: jws)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ACMEError.unexpected("not HTTP") }
        nonce = http.value(forHTTPHeaderField: "Replay-Nonce")
        guard (200..<300).contains(http.statusCode) else {
            let problem = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let type = problem?["type"] as? String ?? ""
            if type == "urn:ietf:params:acme:error:badNonce", !retried {
                return try await signedRequest(url, payload: payload, useJWK: useJWK, accept: accept, retried: true)
            }
            throw ACMEError.server(type: type, detail: problem?["detail"] as? String ?? "", status: http.statusCode)
        }
        return (data, http)
    }

    /// Trusts the test server's root on top of the system's, for its HTTPS only.
    private final class TrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        let roots: [SecCertificate]

        init(roots: [SecCertificate]) {
            self.roots = roots
        }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
            async -> (URLSession.AuthChallengeDisposition, URLCredential?)
        {
            guard !roots.isEmpty, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust
            else { return (.performDefaultHandling, nil) }
            SecTrustSetAnchorCertificates(trust, roots as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, false)
            return SecTrustEvaluateWithError(trust, nil) ? (.useCredential, URLCredential(trust: trust))
                : (.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - CSR and DER

/// A PKCS #10 certificate request for one DNS name, signed with its P-256 key: the name as common name and as the only
/// subject alternative name (all Let's Encrypt looks at).
public enum CSR {
    public static func make(domain: String, key: P256.Signing.PrivateKey) -> Data {
        let name = DER.sequence(DER.set(DER.sequence(DER.oid([0x55, 0x04, 0x03]), DER.utf8(domain))))
        let san = DER.sequence(DER.sequence(DER.oid([0x55, 0x1D, 0x11]),
                                            DER.octetString(DER.sequence(DER.tagged(0x82, Array(domain.utf8))))))
        // [0] attributes: extensionRequest (PKCS #9) holding the extensions.
        let extensionRequest = DER.sequence(DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x0E]), DER.set(san))
        let info = DER.sequence(DER.integer([0]), name, Array(key.publicKey.derRepresentation),
                                DER.tagged(0xA0, extensionRequest))
        let signature = (try? key.signature(for: Data(info)).derRepresentation) ?? Data()
        return Data(DER.sequence(info, DER.ecdsaWithSHA256, DER.bitString(Array(signature))))
    }
}

/// Just enough DER for a certificate request and a test certificate.
enum DER {
    static func tagged(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        let n = content.count
        let length: [UInt8] = n < 0x80 ? [UInt8(n)] : n < 0x100 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 0xFF)]
        return [tag] + length + content
    }

    static func sequence(_ parts: [UInt8]...) -> [UInt8] { tagged(0x30, parts.flatMap { $0 }) }
    static func set(_ parts: [UInt8]...) -> [UInt8] { tagged(0x31, parts.flatMap { $0 }) }
    static func oid(_ bytes: [UInt8]) -> [UInt8] { tagged(0x06, bytes) }
    static func integer(_ bytes: [UInt8]) -> [UInt8] { tagged(0x02, bytes) }
    static func utf8(_ text: String) -> [UInt8] { tagged(0x0C, Array(text.utf8)) }
    static func octetString(_ bytes: [UInt8]) -> [UInt8] { tagged(0x04, bytes) }
    static func bitString(_ bytes: [UInt8]) -> [UInt8] { tagged(0x03, [0] + bytes) }
    static let ecdsaWithSHA256 = sequence(oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))

    static func utcTime(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tagged(0x17, Array(formatter.string(from: date).utf8))
    }

    /// A self-signed certificate for `domain` (tests, and nothing else).
    static func selfSigned(domain: String, key: P256.Signing.PrivateKey, from: Date, until: Date) -> Data {
        let name = sequence(set(sequence(oid([0x55, 0x04, 0x03]), utf8(domain))))
        let san = sequence(sequence(oid([0x55, 0x1D, 0x11]), octetString(sequence(tagged(0x82, Array(domain.utf8))))))
        var serial = (0..<8).map { _ in UInt8.random(in: 0...255) }
        serial[0] = serial[0] & 0x7F | 0x01
        let tbs = sequence(tagged(0xA0, integer([2])), integer(serial), ecdsaWithSHA256, name,
                           sequence(utcTime(from), utcTime(until)), name, Array(key.publicKey.derRepresentation),
                           tagged(0xA3, san))
        let signature = (try? key.signature(for: Data(tbs)).derRepresentation) ?? Data()
        return Data(sequence(tbs, ecdsaWithSHA256, bitString(Array(signature))))
    }
}

/// Certificates in PEM.
public enum PEM {
    /// The DER of each certificate in `text`, in order.
    public static func certificates(in text: String) -> [Data] {
        var out: [Data] = []
        var current: String?
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line == "-----BEGIN CERTIFICATE-----" {
                current = ""
            } else if line == "-----END CERTIFICATE-----" {
                if let body = current, let der = Data(base64Encoded: body) { out.append(der) }
                current = nil
            } else if current != nil {
                current! += line
            }
        }
        return out
    }

    public static func encode(_ certificates: [Data]) -> String {
        certificates.map { der in
            let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
        }.joined()
    }
}
#endif
