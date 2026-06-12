import Foundation

/// P3 stub: embedded llama.cpp inference, the future *default* provider
/// (ARCHITECTURE.md §5) — a truly self-contained app with no external install.
///
/// Planned implementation:
///  - Link llama.cpp as an xcframework built by a pinned-version script (its
///    SwiftPM packaging has been historically unstable), Metal backend enabled.
///  - Small Swift wrapper over the C API: load GGUF → tokenize chat template →
///    sample → detokenize. Single in-flight request; utterances are short.
///  - GGUF model management mirrors the Whisper-model UX: default ~4B-class
///    model downloaded on first LLM-mode use into App Support/Models, with a
///    settings picker for alternatives.
///  - Memory policy: lazy load on first enhance, unload after an idle timeout so
///    the app isn't holding gigabytes between dictations (ARCHITECTURE.md §10).
final class LlamaCppProvider: LLMProvider {
    func isAvailable() async -> Bool {
        false // until the model is downloaded and the engine lands
    }

    func enhance(_ transcript: String,
                 systemPrompt: String,
                 model: String?,
                 temperature: Double?) async throws -> String {
        throw LLMError.unimplemented
    }

    func listModels() async throws -> [String] {
        [] // will list downloaded GGUFs + the curated downloadable set
    }
}
