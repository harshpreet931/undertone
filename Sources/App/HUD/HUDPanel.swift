import AppKit
import Observation
import SwiftUI

/// Owns the borderless, click-through NSPanel that floats the dictation HUD
/// above every window and space. A bare SwiftUI scene can't express this —
/// the panel must never steal focus from the app being dictated into
/// (`.nonactivatingPanel` + `ignoresMouseEvents`).
///
/// Show/hide *motion* lives in `RecordingHUDView`; this controller only orders
/// the (transparent) panel in before the HUD animates on screen, and out again
/// well after the outcome flash has faded.
@MainActor
final class HUDPanel {
    // Tall enough for the live-transcript card (3 lines + status row + shadow).
    static let size = NSSize(width: 420, height: 170)

    private let panel: NSPanel
    private let session: DictationSession
    private var hideTask: Task<Void, Never>?

    init(session: DictationSession) {
        self.session = session

        let hosting = NSHostingView(rootView: RecordingHUDView(session: session))
        hosting.frame = NSRect(origin: .zero, size: Self.size)

        panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the HUD draws its own layered shadows
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        observeState()
    }

    /// @Observable change hook: re-arm after every fire (one-shot semantics).
    private func observeState() {
        withObservationTracking {
            _ = session.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stateChanged()
                self.observeState()
            }
        }
    }

    private func stateChanged() {
        hideTask?.cancel()
        if session.state != .idle {
            position()
            panel.orderFrontRegardless()
        } else {
            // Keep the panel up through the outcome flash (≤2.6s) + exit fade.
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3.2))
                guard !Task.isCancelled else { return }
                self?.panel.orderOut(nil)
            }
        }
    }

    /// Bottom-center of the active screen, recomputed on every show so the
    /// HUD follows the user across displays.
    private func position() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - Self.size.width / 2,
            y: visible.minY + 16
        ))
    }
}
