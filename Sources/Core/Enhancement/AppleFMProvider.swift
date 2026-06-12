import Foundation

/// P3+ stub: Apple Foundation Models framework (macOS 26+) as an optional
/// zero-download provider (ARCHITECTURE.md §5).
///
/// Planned implementation, gated behind `#available(macOS 26, *)` since the
/// app's floor is 14.4 (the FoundationModels import itself must be isolated,
/// e.g. via a conditionally-compiled file or weak-linked shim):
///  - `LanguageModelSession(instructions: systemPrompt + outputGuard)` per
///    enhance call; `respond(to: transcript)` returns the rewrite.
///  - `isAvailable()` maps `SystemLanguageModel.default.availability` (device
///    eligibility + Apple Intelligence enabled + model downloaded).
///  - `model`/`temperature` parameters are ignored — the OS manages one model;
///    `listModels()` returns a single descriptive entry.
final class AppleFMProvider: LLMProvider {
    func isAvailable() async -> Bool {
        false // requires macOS 26 + Apple Intelligence; see doc comment
    }

    func enhance(_ transcript: String,
                 systemPrompt: String,
                 model: String?,
                 temperature: Double?) async throws -> String {
        throw LLMError.unimplemented
    }

    func listModels() async throws -> [String] {
        []
    }
}
