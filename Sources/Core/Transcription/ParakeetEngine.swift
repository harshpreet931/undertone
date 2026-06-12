import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT v3 on the Neural Engine via FluidAudio — the primary
/// dictation engine: ~110x realtime on M-series, punctuation + capitalization
/// built into the model, 25 (European) languages, ~66 MB working memory.
///
/// Trade-offs vs `WhisperKitEngine`: no `initialPrompt` vocabulary biasing
/// (vocabulary replacement rules still apply downstream), and no support for
/// non-European languages — the Settings engine picker covers both cases.
///
/// Model: CC-BY-4.0 (attribution in README) · Library: Apache 2.0.
final class ParakeetEngine: TranscriptionEngine {
    enum EngineError: Error { case notReady }

    var onDownloadProgress: (@Sendable (Double) -> Void)?
    private var manager: AsrManager?

    var isReady: Bool { manager != nil }

    /// Whether the Core ML model files are already on disk — drives the Setup
    /// window's model row so the ~500 MB download can happen ahead of the
    /// first dictation.
    static var isDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3))
    }

    /// Download without loading (Setup window): `prepare()` later finds the
    /// files on disk and skips straight to loading.
    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await AsrModels.download(progressHandler: { update in
            progress(update.fractionCompleted)
        })
    }

    func prepare() async throws {
        guard manager == nil else { return }
        let progress = onDownloadProgress
        let models = try await AsrModels.downloadAndLoad(progressHandler: { update in
            progress?(update.fractionCompleted)
        })
        manager = AsrManager(config: .default, models: models)
    }

    func transcribe(_ audio: TranscribableAudio,
                    options: TranscriptionOptions) async throws -> TranscriptionOutput {
        try await prepare()
        guard let manager else { throw EngineError.notReady }

        // Fresh decoder state per utterance; dictation chunks are independent.
        var decoderState = try TdtDecoderState()
        let started = Date()
        let result = try await manager.transcribe(audio, decoderState: &decoderState)

        return TranscriptionOutput(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: options.language,
            inferenceTime: Date().timeIntervalSince(started)
        )
    }
}
