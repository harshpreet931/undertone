import AppKit
import SwiftData
import SwiftUI

/// Mode list + editor (ARCHITECTURE.md §5, §6.3): custom prompts, per-mode LLM
/// settings, and the app rules that drive automatic mode switching.
struct ModesSettingsTab: View {
    @Query(sort: \Mode.name) private var modes: [Mode]
    @Environment(\.modelContext) private var context
    @State private var selectedID: PersistentIdentifier?

    private var selected: Mode? {
        modes.first { $0.persistentModelID == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(modes) { mode in
                        Label {
                            Text(mode.name)
                            if mode.isDefault {
                                Text("default")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: mode.icon)
                        }
                        .tag(mode.persistentModelID)
                    }
                }
                .listStyle(.sidebar)

                Divider()
                HStack(spacing: 2) {
                    Button {
                        let mode = Mode(name: "New Mode", llmEnabled: true,
                                        systemPrompt: "Rewrite this dictated text…")
                        context.insert(mode)
                        try? context.save()
                        selectedID = mode.persistentModelID
                    } label: {
                        Image(systemName: "plus")
                    }
                    Button {
                        guard let selected else { return }
                        selectedID = nil
                        context.delete(selected)
                        try? context.save()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selected == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 170)

            Divider()

            if let mode = selected {
                ModeEditor(mode: mode, allModes: modes)
            } else {
                ContentUnavailableView("Select a mode", systemImage: "slider.horizontal.3",
                                       description: Text("Modes decide how dictation is post-processed — and which apps switch to them automatically."))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 460)
        .onAppear { selectedID = modes.first?.persistentModelID }
    }
}

private struct ModeEditor: View {
    @Bindable var mode: Mode
    let allModes: [Mode]

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $mode.name)
                HStack {
                    TextField("Icon (SF Symbol)", text: $mode.icon)
                    Image(systemName: validIcon)
                        .foregroundStyle(.secondary)
                }
                Toggle("Default mode", isOn: defaultBinding)
            }

            Section {
                Toggle("Rewrite with AI", isOn: $mode.llmEnabled)
                if mode.llmEnabled {
                    TextEditor(text: $mode.systemPrompt)
                        .font(.system(size: 12))
                        .frame(height: 90)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quaternary.opacity(0.5),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            } header: {
                Text("Post-processing")
            } footer: {
                if mode.llmEnabled {
                    Text("The instruction sent to your local LLM along with the transcript.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(mode.appBundleIDs, id: \.self) { bundleID in
                    HStack {
                        Text(appName(for: bundleID))
                        Text(bundleID)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button {
                            mode.appBundleIDs.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Menu("Add Running App…") {
                    ForEach(runningApps, id: \.bundleID) { app in
                        Button(app.name) {
                            if !mode.appBundleIDs.contains(app.bundleID) {
                                mode.appBundleIDs.append(app.bundleID)
                            }
                        }
                    }
                }
            } header: {
                Text("Auto-activate in these apps")
            } footer: {
                Text("When one of these apps is frontmost, dictation uses this mode automatically (unless a mode is picked manually in the menu).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var validIcon: String {
        NSImage(systemSymbolName: mode.icon, accessibilityDescription: nil) != nil
            ? mode.icon : "questionmark.square.dashed"
    }

    /// Default is exclusive: turning it on here clears it everywhere else.
    private var defaultBinding: Binding<Bool> {
        Binding {
            mode.isDefault
        } set: { isOn in
            if isOn {
                for other in allModes where other.isDefault {
                    other.isDefault = false
                }
            }
            mode.isDefault = isOn
        }
    }

    private var runningApps: [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return (app.localizedName ?? bundleID, bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID.components(separatedBy: ".").last ?? bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}

/// Vocabulary list (ARCHITECTURE.md §6.7): phrases bias Whisper toward the
/// right spelling; an optional replacement becomes a hard correction rule.
struct VocabularySettingsTab: View {
    @Query(sort: \VocabularyEntry.phrase) private var entries: [VocabularyEntry]
    @Environment(\.modelContext) private var context

    var body: some View {
        Form {
            Section {
                ForEach(entries) { entry in
                    VocabularyRow(entry: entry) {
                        context.delete(entry)
                        try? context.save()
                    }
                }
                Button {
                    context.insert(VocabularyEntry(phrase: ""))
                    try? context.save()
                } label: {
                    Label("Add Phrase", systemImage: "plus")
                }
            } header: {
                Text("Custom vocabulary")
            } footer: {
                Text("Names, jargon, and brands Whisper gets wrong. The phrase biases recognition; fill in “replaces” to also hard-correct a common mishearing — e.g. phrase “Juspay”, replaces “just pay”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct VocabularyRow: View {
    @Bindable var entry: VocabularyEntry
    let onDelete: () -> Void

    private var replacementBinding: Binding<String> {
        Binding {
            entry.replacement ?? ""
        } set: { value in
            entry.replacement = value.isEmpty ? nil : value
        }
    }

    var body: some View {
        HStack {
            TextField("Phrase", text: $entry.phrase, prompt: Text("Phrase"))
            Image(systemName: "arrow.left")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField("Replaces", text: replacementBinding, prompt: Text("mishearing (optional)"))
            Button {
                onDelete()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }
}
