import KeyboardShortcuts
import SwiftUI

/// The Settings scene content: hotkey + sounds, Whisper model pick, and the
/// local-LLM endpoint. Everything persists via @AppStorage under SettingsKeys;
/// the engine and LLM provider re-read those defaults on use, so changes apply
/// without relaunching.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ModesSettingsTab()
                .tabItem { Label("Modes", systemImage: "slider.horizontal.3") }
            VocabularySettingsTab()
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
            TranscriptionSettingsTab()
                .tabItem { Label("Transcription", systemImage: "waveform") }
            EnhancementSettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 560)
    }
}

private struct GeneralSettingsTab: View {
    @AppStorage(SettingsKeys.playSounds) private var playSounds = true

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Dictation shortcut", name: .toggleDictation)
            } footer: {
                Text("Tap to start and tap again to finish — or hold it down and release to finish. Esc cancels a recording.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Play sounds when recording starts and stops", isOn: $playSounds)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TranscriptionSettingsTab: View {
    @AppStorage(SettingsKeys.sttEngine) private var engine = RoutingEngine.Kind.parakeet.rawValue
    @AppStorage(SettingsKeys.whisperModel) private var model = "base.en"

    /// Curated WhisperKit model names (argmaxinc/whisperkit-coreml repo).
    private static let models: [(name: String, label: String, detail: String)] = [
        ("tiny.en", "Tiny", "Fastest · English only · ~75 MB"),
        ("base.en", "Base", "Fast · English only · ~145 MB"),
        ("small.en", "Small", "Balanced · English only · ~480 MB"),
        ("medium", "Medium", "Accurate · Multilingual · ~1.5 GB"),
        ("distil-large-v3", "Distil Large v3", "Fast + accurate · English only · ~1.5 GB"),
        ("large-v3-v20240930", "Large v3 Turbo", "Most accurate · Multilingual · ~1.6 GB"),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $engine) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Parakeet v3 — recommended")
                        Text("Fastest by far (Neural Engine) · punctuation built in · 25 European languages · ~500 MB")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(RoutingEngine.Kind.parakeet.rawValue)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Whisper")
                        Text("100 languages · vocabulary biasing for names/jargon · slower")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(RoutingEngine.Kind.whisper.rawValue)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Speech-to-text engine")
            } footer: {
                Text("Models download on the next dictation, then run fully offline. Switching applies immediately. Custom vocabulary phrases only bias recognition on Whisper; replacement rules work on both.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if engine == RoutingEngine.Kind.whisper.rawValue {
                Section {
                    Picker("Whisper model", selection: $model) {
                        ForEach(Self.models, id: \.name) { entry in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.label)
                                Text(entry.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(entry.name)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Whisper model")
                } footer: {
                    Text("Larger models are more accurate but slower to load and transcribe.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct EnhancementSettingsTab: View {
    @AppStorage(SettingsKeys.llmBaseURL) private var baseURL = "http://localhost:11434/v1"
    @AppStorage(SettingsKeys.llmModel) private var model = "qwen3:4b"

    private enum TestResult: Equatable {
        case testing
        case ok([String])
        case failed(String)
    }
    @State private var testResult: TestResult?

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $baseURL, prompt: Text("http://localhost:11434/v1"))
                    .autocorrectionDisabled()
                TextField("Model", text: $model, prompt: Text("qwen3:4b"))
                    .autocorrectionDisabled()
            } header: {
                Text("Local LLM server")
            } footer: {
                Text("Any OpenAI-compatible endpoint: Ollama (:11434/v1), LM Studio (:1234/v1), or llama-server (:8080/v1). Used by AI modes like Message and Email; plain transcription never needs it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Button("Test Connection") {
                        testConnection()
                    }
                    .disabled(testResult == .testing)
                } label: {
                    testStatus
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: baseURL) { testResult = nil }
        .onChange(of: model) { testResult = nil }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch testResult {
        case nil:
            Text("Connection")
                .foregroundStyle(.secondary)
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .ok(let models):
            let known = models.contains(model)
            Label {
                Text(known
                     ? "Connected — “\(model)” is available"
                     : "Connected, but “\(model)” isn’t in the server’s model list")
            } icon: {
                Image(systemName: known ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(known ? .green : .orange)
            }
        case .failed(let message):
            Label {
                Text("Not reachable: \(message)").lineLimit(2)
            } icon: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
    }

    private func testConnection() {
        testResult = .testing
        Task {
            // Fresh provider reads the just-edited defaults.
            do {
                let models = try await OpenAICompatProvider().listModels()
                testResult = .ok(models)
            } catch {
                testResult = .failed(error.localizedDescription)
            }
        }
    }
}
