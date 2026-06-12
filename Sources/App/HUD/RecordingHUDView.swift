import SwiftUI

/// The floating dictation HUD: a translucent capsule pinned above the bottom
/// edge of the screen. Shows a live mic waveform + timer while recording, then
/// morphs through the pipeline states and flashes the outcome before fading.
/// Hosted click-through in `HUDPanel`; all show/hide motion lives here.
struct RecordingHUDView: View {
    let session: DictationSession

    private enum Phase: Equatable {
        case hidden, recording, transcribing, enhancing, inserting, success
        case failure(String)
    }

    @State private var levels: [Float] = restingLevels
    @State private var startedAt = Date.now
    @State private var flash: Phase?
    @State private var flashTask: Task<Void, Never>?

    private static let barCount = 26
    private static let restingLevels = [Float](repeating: 0, count: barCount)

    private var phase: Phase {
        switch session.state {
        case .idle: flash ?? .hidden
        case .recording: .recording
        case .transcribing: .transcribing
        case .enhancing: .enhancing
        case .inserting: .inserting
        }
    }

    var body: some View {
        let phase = self.phase
        let visible = phase != .hidden

        card(for: phase)
            .scaleEffect(visible ? 1 : 0.92, anchor: .bottom)
            .offset(y: visible ? 0 : 10)
            .opacity(visible ? 1 : 0)
            .blur(radius: visible ? 0 : 3)
            // Springy enter, softer/quicker exit.
            .animation(visible ? .spring(duration: 0.4, bounce: 0.22)
                               : .easeOut(duration: 0.22), value: visible)
            .animation(.spring(duration: 0.35, bounce: 0), value: phase)
            .animation(.easeOut(duration: 0.18), value: session.liveTranscript)
            .environment(\.colorScheme, .dark)
            .frame(width: HUDPanel.size.width, height: HUDPanel.size.height,
                   alignment: .bottom)
            .padding(.bottom, 0)
            .onChange(of: session.state) { old, new in
                stateChanged(from: old, to: new)
            }
            .onChange(of: session.audioLevel) { _, level in
                guard session.state == .recording else { return }
                levels.removeFirst()
                levels.append(level)
            }
    }

    /// Starts as a capsule (the 23pt radius equals half the single-row height)
    /// and grows into a rounded card as live transcript lines appear — same
    /// continuous shape throughout, so the morph is seamless.
    private func card(for phase: Phase) -> some View {
        let shape = RoundedRectangle(cornerRadius: 23, style: .continuous)

        return VStack(spacing: 8) {
            if let live = liveLine(for: phase) {
                Text(live)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.primary.opacity(phase == .recording ? 0.92 : 0.55))
                    .lineLimit(3)
                    .truncationMode(.head)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 330, alignment: .leading)
                    .transition(.statusText)
            }
            HStack(spacing: 10) {
                statusIcon(for: phase)
                centerContent(for: phase)
            }
            .frame(height: 26)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(.black.opacity(0.22))
            }
        }
        .overlay {
            shape.strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        .padding(.bottom, 18)
    }

    /// Live hypothesis text: bright while recording, dimmed as a "draft" while
    /// the final transcription/enhancement replaces it. A model download takes
    /// over the slot — that wait would otherwise read as a hang.
    private func liveLine(for phase: Phase) -> String? {
        switch phase {
        case .recording, .transcribing, .enhancing:
            if let progress = session.modelDownloadProgress {
                return progress < 1
                    ? "Downloading speech model… \(Int(progress * 100))%"
                    : "Loading speech model…"
            }
            guard let live = session.liveTranscript, !live.isEmpty else { return nil }
            return live
        default:
            return nil
        }
    }

    @ViewBuilder
    private func statusIcon(for phase: Phase) -> some View {
        ZStack {
            switch phase {
            case .recording:
                PulsingDot().transition(.iconCrossfade)
            case .transcribing:
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative)
                    .foregroundStyle(.cyan)
                    .transition(.iconCrossfade)
            case .enhancing:
                Image(systemName: "sparkles")
                    .symbolEffect(.pulse)
                    .foregroundStyle(.purple)
                    .transition(.iconCrossfade)
            case .inserting:
                Image(systemName: "text.cursor")
                    .foregroundStyle(.secondary)
                    .transition(.iconCrossfade)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.iconCrossfade)
            case .failure:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .transition(.iconCrossfade)
            case .hidden:
                EmptyView()
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .frame(width: 18, height: 18)
    }

    @ViewBuilder
    private func centerContent(for phase: Phase) -> some View {
        switch phase {
        case .recording:
            HStack(spacing: 12) {
                WaveformView(levels: levels)
                Text(startedAt, style: .timer)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
                EscapeHint()
            }
            .transition(.statusText)
        case .transcribing:
            statusLabel("Transcribing…")
        case .enhancing:
            statusLabel("Enhancing…")
        case .inserting:
            statusLabel("Inserting…")
        case .success:
            statusLabel("Inserted")
        case .failure(let message):
            statusLabel(message)
                .lineLimit(1)
                .truncationMode(.tail)
        case .hidden:
            EmptyView()
        }
    }

    private func statusLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
            .transition(.statusText)
    }

    private func stateChanged(from old: DictationSession.State,
                              to new: DictationSession.State) {
        switch new {
        case .recording:
            flashTask?.cancel()
            flash = nil
            startedAt = .now
        case .idle:
            levels = Self.restingLevels
            if let error = session.lastError {
                setFlash(.failure(error), for: 2.6)
            } else if old == .inserting {
                setFlash(.success, for: 1.2)
            }
        default:
            break
        }
    }

    private func setFlash(_ value: Phase, for seconds: Double) {
        flashTask?.cancel()
        flash = value
        flashTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            flash = nil
        }
    }
}

/// Scrolling level-history bars: new RMS values enter on the right and flow
/// left, springing toward each new height.
private struct WaveformView: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.85))
                    .frame(width: 2.5, height: height(for: levels[index]))
            }
        }
        .frame(height: 26)
        .animation(.spring(duration: 0.25, bounce: 0), value: levels)
    }

    /// Speech RMS lives around 0.02–0.2; the power curve lifts quiet speech
    /// so the bars feel alive without clipping on loud input.
    private func height(for level: Float) -> CGFloat {
        let normalized = min(1, pow(Double(level) * 9, 0.7))
        return 3 + CGFloat(normalized) * 23
    }
}

/// Tiny keycap-styled "esc" hint shown while recording. The action label sits
/// outside the keycap so it can't be misread as "esc to finish" — the panel is
/// click-through, so a tooltip alone would never be seen.
private struct EscapeHint: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("esc")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                }
            Text("cancel")
                .font(.system(size: 9, weight: .regular, design: .rounded))
        }
        .foregroundStyle(.secondary)
        .opacity(0.7)
    }
}

/// Recording indicator: solid red dot with a ring that pulses outward.
private struct PulsingDot: View {
    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 9, height: 9)
            .background {
                Circle()
                    .stroke(.red.opacity(0.6), lineWidth: 1.5)
                    .phaseAnimator([0.0, 1.0]) { ring, progress in
                        ring
                            .scaleEffect(1 + progress * 1.3)
                            .opacity(1 - progress)
                    } animation: { _ in .easeOut(duration: 1.2) }
            }
    }
}

private struct IconCrossfade: ViewModifier {
    var progress: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.25 + 0.75 * progress)
            .opacity(progress)
            .blur(radius: 4 * (1 - progress))
    }
}

private extension AnyTransition {
    /// Icon swap: scale 0.25→1, opacity 0→1, blur 4→0.
    static let iconCrossfade = AnyTransition.modifier(
        active: IconCrossfade(progress: 0),
        identity: IconCrossfade(progress: 1)
    )

    /// Status text swap: old line drifts up and out, new line rises in.
    static let statusText = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .offset(y: 6)),
        removal: .opacity.combined(with: .offset(y: -6))
    )
}
