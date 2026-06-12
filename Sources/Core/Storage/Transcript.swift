import Foundation
import SwiftData

/// One history entry (ARCHITECTURE.md §6.6). Audio is not retained — only text
/// and timings — unless the opt-in audio retention setting (P3) is enabled.
@Model
final class Transcript {
    var createdAt: Date
    var rawText: String
    /// Present only when the mode ran an LLM pass.
    var enhancedText: String?
    var modeName: String
    /// Frontmost app at insertion time.
    var appBundleID: String?
    var audioDuration: TimeInterval
    var transcriptionTime: TimeInterval
    var enhancementTime: TimeInterval?

    init(createdAt: Date = .now,
         rawText: String,
         enhancedText: String? = nil,
         modeName: String,
         appBundleID: String? = nil,
         audioDuration: TimeInterval,
         transcriptionTime: TimeInterval,
         enhancementTime: TimeInterval? = nil) {
        self.createdAt = createdAt
        self.rawText = rawText
        self.enhancedText = enhancedText
        self.modeName = modeName
        self.appBundleID = appBundleID
        self.audioDuration = audioDuration
        self.transcriptionTime = transcriptionTime
        self.enhancementTime = enhancementTime
    }
}
