import Foundation

/// Delegates to whichever engine is picked in Settings (read per call, so a
/// switch applies on the next dictation without relaunching). Both engines are
/// kept alive so flipping back doesn't re-load models.
final class RoutingEngine: TranscriptionEngine {
    enum Kind: String {
        case parakeet, whisper
    }

    private let parakeet = ParakeetEngine()
    private let whisper = WhisperKitEngine()

    var onDownloadProgress: (@Sendable (Double) -> Void)? {
        didSet {
            parakeet.onDownloadProgress = onDownloadProgress
            whisper.onDownloadProgress = onDownloadProgress
        }
    }

    static var selectedKind: Kind {
        Kind(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.sttEngine) ?? "") ?? .parakeet
    }

    /// Whether the selected engine's model files are on disk (Setup window).
    static var selectedModelDownloaded: Bool {
        switch selectedKind {
        case .parakeet:
            ParakeetEngine.isDownloaded
        case .whisper:
            WhisperKitEngine.isDownloaded(
                variant: UserDefaults.standard.string(forKey: SettingsKeys.whisperModel) ?? "base.en")
        }
    }

    private var current: TranscriptionEngine {
        switch Self.selectedKind {
        case .parakeet: parakeet
        case .whisper: whisper
        }
    }

    var isReady: Bool { current.isReady }

    func prepare() async throws {
        try await current.prepare()
    }

    func transcribe(_ audio: TranscribableAudio,
                    options: TranscriptionOptions) async throws -> TranscriptionOutput {
        try await current.transcribe(audio, options: options)
    }
}
