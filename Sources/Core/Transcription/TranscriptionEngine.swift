import Foundation

/// 16 kHz mono Float32 PCM — the pipeline's audio lingua franca (ARCHITECTURE.md §3).
/// Live dictation, file transcription, and meeting tracks all normalize to this
/// before reaching an engine, so engines never deal with formats.
typealias TranscribableAudio = [Float]

struct TranscriptionOptions {
    /// ISO 639-1 code; nil = auto-detect.
    var language: String?
    /// Vocabulary biasing via the decoder's initial prompt (ARCHITECTURE.md §6.7).
    var initialPrompt: String?
    var translateToEnglish = false

    init(language: String? = nil, initialPrompt: String? = nil, translateToEnglish: Bool = false) {
        self.language = language
        self.initialPrompt = initialPrompt
        self.translateToEnglish = translateToEnglish
    }
}

struct TranscriptionOutput {
    var text: String
    var language: String?
    /// Wall-clock inference time, recorded into history for perf visibility.
    var inferenceTime: TimeInterval
}

/// Pluggable speech-to-text (ARCHITECTURE.md §3). Implementations: WhisperKitEngine
/// (primary); planned: AppleSpeechEngine (SpeechAnalyzer, macOS 26+).
protocol TranscriptionEngine: AnyObject {
    var isReady: Bool { get }
    /// Fired with 0…1 while `prepare()` is downloading model files — drives the
    /// HUD's "Downloading model…" state. Not called when the model is cached.
    var onDownloadProgress: (@Sendable (Double) -> Void)? { get set }
    /// Loads the model, downloading it first if needed. Safe to call repeatedly.
    func prepare() async throws
    func transcribe(_ audio: TranscribableAudio,
                    options: TranscriptionOptions) async throws -> TranscriptionOutput
}
