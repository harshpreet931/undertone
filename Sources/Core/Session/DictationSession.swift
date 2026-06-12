import Foundation
import Observation

/// The single pipeline orchestrator (ARCHITECTURE.md §2):
/// idle → recording → transcribing → enhancing → inserting → idle.
/// Every other component does one thing and is driven from here.
@MainActor
@Observable
final class DictationSession {
    enum State: Equatable {
        case idle, recording, transcribing, enhancing, inserting
    }

    private(set) var state: State = .idle
    private(set) var lastResult: String?
    private(set) var lastError: String?

    /// Latest mic RMS per buffer (~12 Hz while recording, 0 when stopped) —
    /// drives the recording HUD's live waveform.
    private(set) var audioLevel: Float = 0

    /// Rolling interim transcription of the current utterance, shown in the
    /// HUD while recording. Best-effort: hypothesis text, never inserted.
    private(set) var liveTranscript: String?

    /// 0…1 while the Whisper model is downloading (first dictation, or after a
    /// model switch in Settings) — the HUD explains the wait instead of
    /// appearing hung.
    private(set) var modelDownloadProgress: Double?

    /// AppState wires this to HistoryStore so the session stays storage-agnostic.
    var onComplete: ((Transcript) -> Void)?

    /// Snapshot of the user's custom vocabulary, fetched fresh per utterance.
    /// Same storage-agnostic pattern as `onComplete`.
    var vocabulary: (() -> VocabularyConfig)?

    private let recorder: AudioRecorder
    private let engine: TranscriptionEngine
    private let llm: any LLMProvider
    private let inserter: TextInserter
    private var pipelineTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    /// Below this RMS the capture is treated as silence and discarded —
    /// Whisper hallucinates on near-silent audio (ARCHITECTURE.md §3).
    private let silenceRMSThreshold: Float = 0.005

    init(engine: TranscriptionEngine,
         llm: any LLMProvider = OpenAICompatProvider(),
         inserter: TextInserter,
         recorder: AudioRecorder = AudioRecorder()) {
        self.engine = engine
        self.llm = llm
        self.inserter = inserter
        self.recorder = recorder

        levelTask = Task { [weak self, recorder] in
            for await level in recorder.levelStream {
                self?.audioLevel = level
            }
        }
        engine.onDownloadProgress = { [weak self] fraction in
            Task { @MainActor in self?.modelDownloadProgress = fraction }
        }
    }

    private var levelTask: Task<Void, Never>?

    /// Hotkey entry point: idle starts recording; recording finishes the
    /// utterance; mid-pipeline presses cancel.
    func toggle(mode: ModeConfig, appBundleID: String?) {
        switch state {
        case .idle:
            begin()
        case .recording:
            finish(mode: mode, appBundleID: appBundleID)
        default:
            cancel()
        }
    }

    func begin() {
        guard state == .idle else { return }
        lastError = nil
        liveTranscript = nil
        do {
            try recorder.start()
            state = .recording
            startPreviewLoop()
        } catch {
            lastError = "Could not start recording: \(error.localizedDescription)"
        }
    }

    /// Live preview (HUD): periodically re-transcribe the rolling tail of the
    /// utterance. Whisper has no true streaming mode, so this is the standard
    /// chunked-rerun approach; the first pass also warms/downloads the model
    /// ahead of the final transcription.
    private func startPreviewLoop() {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await self?.engine.prepare()
            self?.modelDownloadProgress = nil
            while let self, !Task.isCancelled, self.state == .recording {
                let audio = self.recorder.snapshot(lastSeconds: 20)
                let seconds = Double(audio.count) / AudioRecorder.targetSampleRate
                if seconds > 1.0, AudioRecorder.rms(of: audio) > self.silenceRMSThreshold,
                   let output = try? await self.engine.transcribe(audio, options: TranscriptionOptions()),
                   !Task.isCancelled, self.state == .recording, !output.text.isEmpty {
                    self.liveTranscript = output.text
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    func finish(mode: ModeConfig, appBundleID: String?) {
        guard state == .recording else { return }
        let audio = recorder.stop()
        pipelineTask = Task { [weak self] in
            await self?.run(audio: audio, mode: mode, appBundleID: appBundleID)
        }
    }

    func cancel() {
        if state == .recording {
            _ = recorder.stop()
        }
        previewTask?.cancel()
        previewTask = nil
        pipelineTask?.cancel()
        pipelineTask = nil
        liveTranscript = nil
        modelDownloadProgress = nil
        state = .idle
    }

    private func run(audio: TranscribableAudio, mode: ModeConfig, appBundleID: String?) async {
        defer {
            liveTranscript = nil
            modelDownloadProgress = nil
            state = .idle
        }

        // WhisperKit isn't reentrant: let any in-flight preview pass drain
        // before the final transcription.
        previewTask?.cancel()
        await previewTask?.value
        previewTask = nil

        // Silence guard: end quietly rather than insert a hallucination.
        guard AudioRecorder.rms(of: audio) > silenceRMSThreshold else { return }
        let audioDuration = Double(audio.count) / AudioRecorder.targetSampleRate

        let vocab = vocabulary?() ?? VocabularyConfig()

        do {
            state = .transcribing
            var options = TranscriptionOptions(language: mode.language)
            // Vocabulary biasing (ARCHITECTURE.md §6.7): phrases enter the
            // decoder as prompt context so Whisper prefers those spellings.
            if !vocab.phrases.isEmpty {
                options.initialPrompt = vocab.phrases.joined(separator: ", ")
            }
            let output = try await engine.transcribe(audio, options: options)
            guard !output.text.isEmpty else { return }
            try Task.checkCancellation()

            // Correction rules run on the raw transcript so both the LLM input
            // and the no-LLM path see the fixed spelling.
            let correctedText = vocab.applyReplacements(to: output.text)

            var finalText = correctedText
            var enhancementTime: TimeInterval?
            if mode.llmEnabled {
                state = .enhancing
                let started = Date()
                do {
                    finalText = try await llm.enhance(correctedText,
                                                      systemPrompt: mode.systemPrompt,
                                                      model: mode.llmModel,
                                                      temperature: mode.temperature)
                    enhancementTime = Date().timeIntervalSince(started)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Degrade, never lose the utterance (ARCHITECTURE.md §5).
                    lastError = "LLM provider unavailable — inserted raw transcript"
                }
            }
            try Task.checkCancellation()

            state = .inserting
            try await inserter.insert(finalText)
            lastResult = finalText

            onComplete?(Transcript(rawText: correctedText,
                                   enhancedText: mode.llmEnabled ? finalText : nil,
                                   modeName: mode.name,
                                   appBundleID: appBundleID,
                                   audioDuration: audioDuration,
                                   transcriptionTime: output.inferenceTime,
                                   enhancementTime: enhancementTime))
        } catch is CancellationError {
            // User cancelled; state resets via defer.
        } catch InsertionError.accessibilityNotGranted {
            lastError = "Accessibility not granted — result copied to clipboard, press ⌘V"
        } catch {
            lastError = error.localizedDescription
        }
    }
}
