import Foundation
import SwiftData

/// A dictation mode (ARCHITECTURE.md §5): how the transcript is post-processed
/// and which apps auto-activate it.
@Model
final class Mode {
    var name: String
    /// SF Symbol name for menus.
    var icon: String
    var llmEnabled: Bool
    /// The user-editable instruction sent as the system prompt.
    var systemPrompt: String
    /// Per-mode overrides; nil falls back to global settings.
    var llmModel: String?
    var temperature: Double?
    var language: String?
    /// Bundle IDs that auto-activate this mode when frontmost (ARCHITECTURE.md §6.3).
    var appBundleIDs: [String]
    var isDefault: Bool

    init(name: String,
         icon: String = "text.bubble",
         llmEnabled: Bool = false,
         systemPrompt: String = "",
         llmModel: String? = nil,
         temperature: Double? = nil,
         language: String? = nil,
         appBundleIDs: [String] = [],
         isDefault: Bool = false) {
        self.name = name
        self.icon = icon
        self.llmEnabled = llmEnabled
        self.systemPrompt = systemPrompt
        self.llmModel = llmModel
        self.temperature = temperature
        self.language = language
        self.appBundleIDs = appBundleIDs
        self.isDefault = isDefault
    }
}

/// Snapshot handed to `DictationSession` so the pipeline isn't coupled to SwiftData.
struct ModeConfig {
    var name: String
    var llmEnabled: Bool
    var systemPrompt: String
    var llmModel: String?
    var temperature: Double?
    var language: String?

    init(_ mode: Mode) {
        name = mode.name
        llmEnabled = mode.llmEnabled
        systemPrompt = mode.systemPrompt
        llmModel = mode.llmModel
        temperature = mode.temperature
        language = mode.language
    }

    /// Used before any modes exist (or if the store fails): plain transcription.
    static let transcriptOnly = ModeConfig(name: "Transcript")

    private init(name: String) {
        self.name = name
        llmEnabled = false
        systemPrompt = ""
    }
}
