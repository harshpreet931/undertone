import Foundation

/// UserDefaults keys for user-tunable settings (Settings window). Defaults are
/// registered once in `AppState.init`; readers can rely on values existing.
enum SettingsKeys {
    static let playSounds = "playSounds"
    /// STT engine: "parakeet" (default) or "whisper" — see RoutingEngine.
    static let sttEngine = "sttEngine"
    /// WhisperKit model name, e.g. "base.en", "large-v3-v20240930".
    static let whisperModel = "whisperModel"
    /// OpenAI-compatible endpoint, e.g. Ollama's http://localhost:11434/v1.
    static let llmBaseURL = "llmBaseURL"
    static let llmModel = "llmModel"
    static let llmAPIKey = "llmAPIKey"
}
