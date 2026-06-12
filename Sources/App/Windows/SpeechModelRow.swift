import SwiftUI

/// Speech-model status + downloader, shared by the Setup window and the
/// Settings → Transcription tab. Shows whether the selected engine's model is
/// on disk, and downloads it (with live progress) so the first dictation never
/// stalls on a ~500 MB surprise. Reflects the current engine/model picks.
struct SpeechModelRow: View {
    /// `.setup` = compact icon row; `.settings` = label/value Form row.
    enum Context { case setup, settings }
    var context: Context = .setup

    @AppStorage(SettingsKeys.sttEngine) private var engine = RoutingEngine.Kind.parakeet.rawValue
    @AppStorage(SettingsKeys.whisperModel) private var whisperModel = "base.en"

    private enum DownloadState: Equatable {
        case unknown, needed, downloading(Double), done, failed(String)
    }
    @State private var state: DownloadState = .unknown

    private var isParakeet: Bool { engine == RoutingEngine.Kind.parakeet.rawValue }
    private var title: String {
        isParakeet ? "Speech model — Parakeet v3" : "Speech model — Whisper (\(whisperModel))"
    }

    var body: some View {
        Group {
            switch context {
            case .setup: setupRow
            case .settings: settingsRow
            }
        }
        .onAppear { refresh() }
        .onChange(of: engine) { refresh() }
        .onChange(of: whisperModel) { refresh() }
        .animation(.spring(duration: 0.3, bounce: 0.3), value: state)
    }

    // Setup window: icon + title + detail + trailing control.
    private var setupRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 15))
                .foregroundStyle(.cyan)
                .frame(width: 28, height: 28)
                .background(.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detailText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            trailing
        }
    }

    // Settings form: LabeledContent with status, plus a progress bar below
    // while downloading so it doesn't crush the row height.
    private var settingsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                trailing
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusLabel)
                    Text(detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusLabel: String {
        switch state {
        case .done: "Model ready"
        case .downloading: "Downloading model…"
        case .failed: "Download failed"
        default: "Model not downloaded"
        }
    }

    private var detailText: String {
        switch state {
        case .failed(let message):
            "Download failed: \(message)"
        case .downloading:
            "Dictation works as soon as this finishes."
        case .done:
            "On disk and running fully offline."
        default:
            "Download now to avoid the wait on your first dictation."
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .unknown:
            ProgressView().controlSize(.small)
        case .needed, .failed:
            Button(state == .needed ? "Download" : "Retry") { download() }
                .controlSize(.small)
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .frame(width: 90)
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .transition(.scale(scale: 0.25).combined(with: .opacity))
        }
    }

    private func refresh() {
        if case .downloading = state { return }
        let downloaded = isParakeet
            ? ParakeetEngine.isDownloaded
            : WhisperKitEngine.isDownloaded(variant: whisperModel)
        state = downloaded ? .done : .needed
    }

    private func download() {
        state = .downloading(0)
        let parakeet = isParakeet
        let variant = whisperModel
        Task {
            do {
                let onProgress: @Sendable (Double) -> Void = { fraction in
                    Task { @MainActor in
                        if case .downloading = state { state = .downloading(fraction) }
                    }
                }
                if parakeet {
                    try await ParakeetEngine.download(progress: onProgress)
                } else {
                    try await WhisperKitEngine.download(variant: variant, progress: onProgress)
                }
                state = .done
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
