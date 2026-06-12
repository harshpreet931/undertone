import Foundation
import WhisperKit

/// Whisper via Core ML / ANE through WhisperKit (ARCHITECTURE.md §3).
/// WhisperKit owns model download and on-disk management; this wrapper only
/// adapts it to `TranscriptionEngine` so the rest of the app stays engine-agnostic.
final class WhisperKitEngine: TranscriptionEngine {
    enum EngineError: Error { case notReady }

    /// Explicit model wins; otherwise the Settings-window pick from defaults.
    private let overrideModel: String?
    private var loadedModel: String?
    private var whisperKit: WhisperKit?

    var onDownloadProgress: (@Sendable (Double) -> Void)?

    init(modelName: String? = nil) {
        overrideModel = modelName
    }

    /// e.g. "base.en" (fast default), "large-v3-v20240930" (turbo, accuracy upgrade).
    private var preferredModel: String {
        overrideModel ?? UserDefaults.standard.string(forKey: SettingsKeys.whisperModel) ?? "base.en"
    }

    var isReady: Bool { whisperKit != nil && loadedModel == preferredModel }

    func prepare() async throws {
        let wanted = preferredModel
        guard whisperKit == nil || loadedModel != wanted else { return }
        let folder = try await ensureDownloaded(wanted)
        whisperKit = try await WhisperKit(modelFolder: folder.path, load: true)
        loadedModel = wanted
    }

    /// Resolves the on-disk model folder, downloading once with progress.
    /// The folder path is remembered per variant so later launches load
    /// straight from disk — fully offline, unlike `WhisperKit(model:)`, which
    /// consults the hub on every init even when the files are cached.
    private func ensureDownloaded(_ variant: String) async throws -> URL {
        try await Self.download(variant: variant) { [onDownloadProgress] fraction in
            onDownloadProgress?(fraction)
        }
    }

    /// Setup-window helpers (same disk cache the instance path uses).
    static func isDownloaded(variant: String) -> Bool {
        guard let path = UserDefaults.standard.string(forKey: folderKey(for: variant)) else {
            return false
        }
        return FileManager.default.fileExists(atPath: path)
    }

    @discardableResult
    static func download(variant: String,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let key = folderKey(for: variant)
        if let path = UserDefaults.standard.string(forKey: key),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let folder = try await WhisperKit.download(variant: variant) { update in
            progress(update.fractionCompleted)
        }
        UserDefaults.standard.set(folder.path, forKey: key)
        return folder
    }

    private static func folderKey(for variant: String) -> String {
        "whisperModelFolder.\(variant)"
    }

    func transcribe(_ audio: TranscribableAudio,
                    options: TranscriptionOptions) async throws -> TranscriptionOutput {
        try await prepare()
        guard let whisperKit else { throw EngineError.notReady }

        var decodeOptions = DecodingOptions()
        decodeOptions.language = options.language
        decodeOptions.task = options.translateToEnglish ? .translate : .transcribe
        // Vocabulary biasing (ARCHITECTURE.md §6.7): the prompt precedes the
        // audio in the decoder's context, nudging it toward these spellings.
        if let prompt = options.initialPrompt, !prompt.isEmpty,
           let tokenizer = whisperKit.tokenizer {
            decodeOptions.promptTokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            decodeOptions.usePrefillPrompt = true
        }

        let started = Date()
        let results = try await whisperKit.transcribe(audioArray: audio, decodeOptions: decodeOptions)
        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return TranscriptionOutput(
            text: text,
            language: results.first?.language,
            inferenceTime: Date().timeIntervalSince(started)
        )
    }
}
