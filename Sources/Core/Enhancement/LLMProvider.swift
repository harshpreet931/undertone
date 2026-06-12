import Foundation

/// Pluggable local-LLM enhancement (ARCHITECTURE.md §5). Implementations:
/// `OpenAICompatProvider` (P2, first working provider), `LlamaCppProvider`
/// (P3, embedded — becomes the default), `AppleFMProvider` (P3+, macOS 26).
/// Provider choice is a settings decision; modes may override the model
/// per-mode but never the provider.
protocol LLMProvider: AnyObject {
    func isAvailable() async -> Bool
    /// Rewrites a raw transcript per the mode's instructions. Callers degrade to
    /// the raw transcript on failure — an unavailable provider must never lose
    /// an utterance (ARCHITECTURE.md §5).
    func enhance(_ transcript: String,
                 systemPrompt: String,
                 model: String?,
                 temperature: Double?) async throws -> String
    /// Backs the settings model picker and the "Test provider" button.
    func listModels() async throws -> [String]
}

enum LLMPromptRules {
    /// Appended to every mode's system prompt so models return clean output.
    static let outputGuard = "Return only the rewritten text, with no preamble, quotes, or explanation."
}

enum LLMError: Error {
    case emptyResponse
    case serverError(String)
    case unimplemented
}
