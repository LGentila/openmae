import AppKit
import AuthenticationServices
import VoiceCore

/// "With my account" of a connected tool: the user signs in in the browser (`ASWebAuthenticationSession`, a private one:
/// nothing of it stays in Safari), which comes back to this Mac through `MCPAccountSignIn`'s loopback address. That
/// address then sends the browser to the app's own scheme, which closes the window.
@MainActor
final class AccountSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static let scheme = "openmae"
    private var session: ASWebAuthenticationSession?

    /// Signs in to the tool at `address`: its credentials, or why not (`MCPSignInError`).
    static func signIn(_ address: URL) async throws -> MCPCredentials {
        let signIn = MCPAccountSignIn(address: address, returnTo: URL(string: "\(scheme)://signed-in"))
        let page = try await signIn.prepare()
        let browser = AccountSignIn()
        browser.open(page) { await signIn.cancel() }
        defer { browser.close() }
        return try await signIn.finish()
    }

    /// Opens the page; `closed` when the window closed before the browser came back.
    private func open(_ page: URL, closed: @escaping @Sendable () async -> Void) {
        let session = ASWebAuthenticationSession(url: page, callbackURLScheme: Self.scheme) { _, error in
            if error != nil { Task { await closed() } }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = true
        self.session = session
        if !session.start() { Task { await closed() } }
    }

    private func close() {
        session?.cancel()
        session = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) ?? ASPresentationAnchor()
        }
    }
}
