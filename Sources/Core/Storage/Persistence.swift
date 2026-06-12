import Foundation
import SwiftData

/// SwiftData container setup + first-run seeding (ARCHITECTURE.md §6.6, §8).
enum Persistence {
    static func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Mode.self, Transcript.self, VocabularyEntry.self)
    }

    /// Last-resort fallback when the on-disk store can't be opened: the app
    /// keeps working (modes, history UI), it just won't persist across launches.
    static func makeInMemoryContainer() -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        // In-memory creation has no I/O to fail; a crash here means the schema
        // itself is broken, which no fallback can save.
        return try! ModelContainer(for: Mode.self, Transcript.self, VocabularyEntry.self,
                                   configurations: config)
    }

    /// Starter modes from ARCHITECTURE.md §5, created once on first launch.
    @MainActor
    static func seedStarterModesIfNeeded(in context: ModelContext) throws {
        let existing = try context.fetchCount(FetchDescriptor<Mode>())
        guard existing == 0 else { return }

        let starters = [
            Mode(name: "Transcript", icon: "text.quote", isDefault: true),
            Mode(name: "Message", icon: "message",
                 llmEnabled: true,
                 systemPrompt: "Rewrite this dictated text as a casual chat message. Remove filler words and false starts. Keep it short and natural."),
            Mode(name: "Email", icon: "envelope",
                 llmEnabled: true,
                 systemPrompt: "Rewrite this dictated text as a clear, professional email body. Fix grammar and structure into paragraphs. Do not invent a subject line or signature."),
            Mode(name: "Notes", icon: "list.bullet",
                 llmEnabled: true,
                 systemPrompt: "Convert this dictated text into concise bullet-point notes. Preserve all facts; drop filler."),
            Mode(name: "Prompt", icon: "terminal",
                 llmEnabled: true,
                 systemPrompt: "Rewrite this dictated text as a precise instruction for an AI coding assistant. Keep technical terms exactly as spoken. Remove filler and repetition."),
        ]
        starters.forEach(context.insert)
        try context.save()
    }
}
