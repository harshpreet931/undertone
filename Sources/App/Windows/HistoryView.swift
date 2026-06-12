import SwiftData
import SwiftUI

/// Searchable dictation history (ARCHITECTURE.md §6.6). Reads the same
/// SwiftData store the session writes into; rows copy with one click.
struct HistoryView: View {
    @Query(sort: \Transcript.createdAt, order: .reverse)
    private var transcripts: [Transcript]
    @Environment(\.modelContext) private var context

    @State private var search = ""
    @State private var confirmingClear = false

    private var filtered: [Transcript] {
        guard !search.isEmpty else { return transcripts }
        return transcripts.filter {
            $0.rawText.localizedCaseInsensitiveContains(search)
                || ($0.enhancedText?.localizedCaseInsensitiveContains(search) ?? false)
                || $0.modeName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    ContentUnavailableView(
                        search.isEmpty ? "No dictations yet" : "No matches",
                        systemImage: search.isEmpty ? "mic.slash" : "magnifyingglass",
                        description: Text(search.isEmpty
                            ? "Press ⌘⇧Space anywhere to dictate. Everything you say lands here."
                            : "No transcripts match “\(search)”.")
                    )
                } else {
                    List {
                        if search.isEmpty {
                            StatsHeader(transcripts: transcripts)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 12, trailing: 12))
                        }
                        ForEach(filtered) { transcript in
                            TranscriptRow(transcript: transcript)
                                .contextMenu {
                                    Button("Copy") { copy(transcript.finalText) }
                                    if transcript.enhancedText != nil {
                                        Button("Copy Raw Transcript") { copy(transcript.rawText) }
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) { delete(transcript) }
                                }
                        }
                        .onDelete { offsets in
                            offsets.map { filtered[$0] }.forEach(delete)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .searchable(text: $search, prompt: "Search transcripts")
            .navigationTitle("History")
            .navigationSubtitle("\(transcripts.count) dictation\(transcripts.count == 1 ? "" : "s")")
            .toolbar {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear All", systemImage: "trash") { confirmingClear = true }
                        .disabled(transcripts.isEmpty)
                }
            }
            .confirmationDialog("Delete all \(transcripts.count) dictations?",
                                isPresented: $confirmingClear) {
                Button("Delete All", role: .destructive) {
                    transcripts.forEach(context.delete)
                    try? context.save()
                }
            } message: {
                Text("This can't be undone.")
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func delete(_ transcript: Transcript) {
        context.delete(transcript)
        try? context.save()
    }
}

private extension Transcript {
    /// What actually got inserted: the enhanced text when a mode ran an LLM
    /// pass, the raw transcription otherwise.
    var finalText: String { enhancedText ?? rawText }
}

/// Words dictated, speaking speed, and time saved versus typing — the payoff
/// view that makes the habit stick.
private struct StatsHeader: View {
    let transcripts: [Transcript]

    /// Average typing speed used as the "time saved" baseline.
    private static let typingWPM = 40.0

    private var words: Int {
        transcripts.reduce(0) { $0 + $1.finalText.split(whereSeparator: \.isWhitespace).count }
    }
    private var speakingSeconds: Double {
        transcripts.reduce(0) { $0 + $1.audioDuration }
    }
    private var dictationWPM: Double {
        speakingSeconds > 0 ? Double(words) / (speakingSeconds / 60) : 0
    }
    private var savedSeconds: Double {
        max(0, Double(words) / Self.typingWPM * 60 - speakingSeconds)
    }

    var body: some View {
        HStack(spacing: 8) {
            StatTile(value: words.formatted(.number.notation(.compactName)),
                     label: "words dictated")
            StatTile(value: dictationWPM.formatted(.number.precision(.fractionLength(0))),
                     label: "words / minute")
            StatTile(value: Duration.seconds(savedSeconds)
                        .formatted(.units(allowed: [.hours, .minutes, .seconds],
                                          width: .narrow, maximumUnitCount: 2)),
                     label: "saved vs typing ~40 wpm")
        }
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TranscriptRow: View {
    let transcript: Transcript
    @State private var hovering = false
    @State private var justCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(transcript.finalText)
                .font(.system(size: 13))
                .lineLimit(3)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Text(transcript.modeName)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

                Text(transcript.createdAt, format: .relative(presentation: .named))
                Text("·")
                Text(Duration.seconds(transcript.audioDuration),
                     format: .units(allowed: [.minutes, .seconds], width: .narrow))
                    .monospacedDigit()

                Spacer()

                if hovering || justCopied {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript.finalText, forType: .string)
                        justCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            justCopied = false
                        }
                    } label: {
                        Label(justCopied ? "Copied" : "Copy",
                              systemImage: justCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(justCopied ? .green : .secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(height: 20)
        }
        .padding(.vertical, 4)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.15), value: justCopied)
    }
}
