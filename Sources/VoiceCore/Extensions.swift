import Foundation

/// Extension point of the open core.
///
/// The core ships with NO extension. Future modules (free or premium, open or closed source) plug in
/// here without modifying the core: they can add a sentence to the system prompt, or answer a request
/// themselves (a local skill) instead of the language model. No licensing logic lives in the core.
public protocol ConversationExtension: Sendable {
    /// Stable identifier, e.g. "com.example.timer".
    var identifier: String { get }

    /// A short sentence describing what the extension can do, appended to the system prompt.
    /// Keep it constant during a session (changing the system prompt is costly).
    func systemPromptAddendum(language: SpeechLanguage) -> String?

    /// Returns a complete spoken answer to handle the request locally, or nil to let the model answer.
    func answer(to userText: String, language: SpeechLanguage) async -> String?
}

extension ConversationExtension {
    public func systemPromptAddendum(language: SpeechLanguage) -> String? { nil }
    public func answer(to userText: String, language: SpeechLanguage) async -> String? { nil }
}
