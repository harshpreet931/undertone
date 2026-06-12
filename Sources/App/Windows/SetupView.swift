import AVFoundation
import ApplicationServices
import SwiftUI

/// Live permission state, repolled every second while the Setup window is
/// open. Polling is the only option: macOS has no notification for TCC
/// changes, and the ad-hoc dev signature means grants can silently lapse
/// after a rebuild — exactly the case this window exists to surface.
@MainActor
@Observable
final class PermissionsModel {
    enum Status {
        case granted, notYetAsked, denied

        var ok: Bool { self == .granted }
    }

    private(set) var microphone: Status = .notYetAsked
    private(set) var accessibility: Status = .notYetAsked
    private(set) var llmReachable: Bool?

    func refresh() {
        microphone = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notYetAsked
        default: .denied
        }
        accessibility = AXIsProcessTrusted() ? .granted : .denied
    }

    func checkLLM() {
        Task {
            llmReachable = await OpenAICompatProvider().isAvailable()
        }
    }

    var allRequiredGranted: Bool { microphone.ok && accessibility.ok }

    static func needsSetup() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
            || !AXIsProcessTrusted()
            || !RoutingEngine.selectedModelDownloaded
    }
}

/// First-run / troubleshooting checklist: every confusing failure mode of the
/// app (no audio, "copied to clipboard" instead of inserting) is a permission
/// issue, and this window shows exactly which one.
struct SetupView: View {
    @State private var model = PermissionsModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(24)

            Divider()

            VStack(spacing: 14) {
                PermissionRow(
                    icon: "mic.fill",
                    iconColor: .red,
                    title: "Microphone",
                    detail: "Required to hear you. Audio never leaves this Mac.",
                    status: model.microphone
                ) {
                    requestMicrophone()
                }

                PermissionRow(
                    icon: "accessibility",
                    iconColor: .blue,
                    title: "Accessibility",
                    detail: "Required to type the result at your cursor. Without it, text only lands on the clipboard.",
                    status: model.accessibility
                ) {
                    requestAccessibility()
                }

                SpeechModelRow()

                llmRow
            }
            .padding(20)

            Divider()

            HStack {
                if model.allRequiredGranted {
                    Label("Ready — press ⌘⇧Space anywhere to dictate", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
                Spacer()
                Button(model.allRequiredGranted ? "Done" : "Later") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480)
        .task {
            model.refresh()
            model.checkLLM()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.refresh()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set up Undertone")
                .font(.title2.weight(.semibold))
            Text("Two macOS permissions make dictation work everywhere. If dictation stops inserting text after an app update, re-grant Accessibility here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var llmRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 15))
                .foregroundStyle(.purple)
                .frame(width: 28, height: 28)
                .background(.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Local AI server").font(.system(size: 13, weight: .medium))
                    Text("OPTIONAL")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                Text("Powers AI modes (Email, Message…). Plain dictation works without it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            switch model.llmReachable {
            case .none:
                ProgressView().controlSize(.small)
            case .some(true):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .some(false):
                Text("Not running")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func requestMicrophone() {
        switch model.microphone {
        case .notYetAsked:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in model.refresh() }
            }
        default:
            openPrivacyPane("Privacy_Microphone")
        }
    }

    private func requestAccessibility() {
        // Puts the app in the Accessibility list (unchecked) and prompts.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        openPrivacyPane("Privacy_Accessibility")
    }

    private func openPrivacyPane(_ anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        NSWorkspace.shared.open(url)
    }
}

/// Pre-downloads the selected engine's speech model so the first dictation
/// doesn't stall on a ~500 MB surprise. Reflects the Settings engine pick.
private struct SpeechModelRow: View {
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
        .onAppear { refresh() }
        .onChange(of: engine) { refresh() }
        .onChange(of: whisperModel) { refresh() }
        .animation(.spring(duration: 0.3, bounce: 0.3), value: state)
    }

    private var detailText: String {
        switch state {
        case .failed(let message):
            "Download failed: \(message)"
        case .downloading:
            "Downloading — dictation works as soon as this finishes."
        default:
            "Runs fully offline. Downloading now avoids the wait on your first dictation."
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .unknown:
            ProgressView().controlSize(.small)
        case .needed, .failed:
            Button("Download") { download() }
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

private struct PermissionRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let detail: String
    let status: PermissionsModel.Status
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)
                .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if status.ok {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.iconPop)
            } else {
                Button(status == .notYetAsked ? "Allow" : "Open Settings…", action: action)
                    .controlSize(.small)
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.3), value: status.ok)
    }
}

private extension AnyTransition {
    static let iconPop = AnyTransition.scale(scale: 0.25).combined(with: .opacity)
}
