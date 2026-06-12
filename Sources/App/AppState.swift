import AppKit
import Foundation
import Observation
import SwiftData

/// Observable root: owns the pipeline components, the SwiftData container, and
/// mode resolution (ARCHITECTURE.md §2, §6.3). Created once by the app entry.
@MainActor
@Observable
final class AppState {
    let session: DictationSession
    /// P2 ships the HTTP provider; a settings picker switches to LlamaCppProvider
    /// (embedded, the eventual default) or AppleFMProvider in P3
    /// (ARCHITECTURE.md §5).
    let llm: any LLMProvider

    private let hotkeys = HotkeyManager()
    private let appMonitor = ActiveAppMonitor()
    /// Never nil: falls back to in-memory so History/Settings scenes and mode
    /// resolution keep working even if the on-disk store can't be opened.
    let container: ModelContainer
    @ObservationIgnored private var hud: HUDPanel?
    private(set) var startupError: String?

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKeys.playSounds: true,
            SettingsKeys.sttEngine: RoutingEngine.Kind.parakeet.rawValue,
            SettingsKeys.whisperModel: "base.en",
            SettingsKeys.llmBaseURL: "http://localhost:11434/v1",
            SettingsKeys.llmModel: "qwen3:4b",
        ])

        let llm = OpenAICompatProvider()
        self.llm = llm
        session = DictationSession(
            engine: RoutingEngine(),
            llm: llm,
            inserter: PasteInserter()
        )

        do {
            container = try Persistence.makeContainer()
        } catch {
            container = Persistence.makeInMemoryContainer()
            startupError = "Storage unavailable (history won't persist): \(error.localizedDescription)"
        }
        container.mainContext.autosaveEnabled = true
        try? Persistence.seedStarterModesIfNeeded(in: container.mainContext)

        hud = HUDPanel(session: session)

        session.onComplete = { [weak self] transcript in
            self?.saveTranscript(transcript)
        }
        session.vocabulary = { [weak self] in
            guard let self else { return VocabularyConfig() }
            let entries = (try? self.container.mainContext.fetch(FetchDescriptor<VocabularyEntry>())) ?? []
            var config = VocabularyConfig()
            config.phrases = entries.map(\.phrase).filter { !$0.isEmpty }
            config.replacements = entries.compactMap { entry in
                guard let replacement = entry.replacement, !replacement.isEmpty else { return nil }
                return (entry.phrase, replacement)
            }
            return config
        }
        hotkeys.onKeyDown = { [weak self] in
            self?.hotkeyPressed()
        }
        hotkeys.onKeyUp = { [weak self] in
            self?.hotkeyReleased()
        }
        hotkeys.onCancel = { [weak self] in
            self?.session.cancel()
        }
        observeSession()
    }

    func toggleDictation() {
        session.toggle(mode: resolveMode(), appBundleID: appMonitor.frontmostBundleID)
    }

    // MARK: - Hotkey: tap to toggle, hold to push-to-talk

    @ObservationIgnored private var hotkeyDownAt: Date?
    @ObservationIgnored private var pressStartedRecording = false
    /// Held longer than this = push-to-talk; release finishes the utterance.
    private let holdThreshold: TimeInterval = 0.45

    private func hotkeyPressed() {
        hotkeyDownAt = .now
        switch session.state {
        case .idle:
            pressStartedRecording = true
            session.begin()
        case .recording:
            pressStartedRecording = false
            session.finish(mode: resolveMode(), appBundleID: appMonitor.frontmostBundleID)
        default:
            // Mid-pipeline press cancels, same as the old toggle behavior.
            pressStartedRecording = false
            session.cancel()
        }
    }

    private func hotkeyReleased() {
        guard let downAt = hotkeyDownAt else { return }
        hotkeyDownAt = nil
        let heldToTalk = Date.now.timeIntervalSince(downAt) >= holdThreshold
        if pressStartedRecording, heldToTalk, session.state == .recording {
            session.finish(mode: resolveMode(), appBundleID: appMonitor.frontmostBundleID)
        }
        pressStartedRecording = false
    }

    // MARK: - Session-state reactions: Esc-to-cancel + sounds

    @ObservationIgnored private var lastState: DictationSession.State = .idle

    private func observeSession() {
        withObservationTracking {
            _ = session.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let old = self.lastState
                self.lastState = self.session.state
                self.sessionStateChanged(from: old, to: self.session.state)
                self.observeSession()
            }
        }
    }

    private func sessionStateChanged(from old: DictationSession.State,
                                     to new: DictationSession.State) {
        if new == .recording {
            hotkeys.setCancelEnabled(true)
            playSound("Pop", volume: 0.3)
        } else if old == .recording {
            hotkeys.setCancelEnabled(false)
            if new == .transcribing {
                playSound("Pop", volume: 0.18)
            }
        }
        if new == .idle, old != .recording, old != .idle, session.lastError != nil {
            playSound("Basso", volume: 0.2)
        }
    }

    private func playSound(_ name: String, volume: Float) {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.playSounds),
              let sound = NSSound(named: name) else { return }
        sound.volume = volume
        sound.play()
    }

    var modes: [Mode] {
        let descriptor = FetchDescriptor<Mode>(sortBy: [SortDescriptor(\.name)])
        return (try? container.mainContext.fetch(descriptor)) ?? []
    }

    /// User's explicit pick from the menu; nil = automatic resolution.
    var pickedModeName: String?

    /// Mode resolution (ARCHITECTURE.md §6.3):
    /// explicit pick → app rule for frontmost app → default mode.
    private func resolveMode() -> ModeConfig {
        let modes = self.modes
        guard !modes.isEmpty else { return .transcriptOnly }

        if let picked = pickedModeName, let mode = modes.first(where: { $0.name == picked }) {
            return ModeConfig(mode)
        }
        if let bundleID = appMonitor.frontmostBundleID,
           let ruled = modes.first(where: { $0.appBundleIDs.contains(bundleID) }) {
            return ModeConfig(ruled)
        }
        if let fallback = modes.first(where: \.isDefault) ?? modes.first {
            return ModeConfig(fallback)
        }
        return .transcriptOnly
    }

    private func saveTranscript(_ transcript: Transcript) {
        container.mainContext.insert(transcript)
        try? container.mainContext.save()
    }
}
