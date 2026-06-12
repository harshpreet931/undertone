import Foundation
import SwiftData

/// Custom vocabulary (ARCHITECTURE.md §6.7). Injected at two points:
/// 1. joined into the Whisper initial prompt to bias recognition, and
/// 2. when `replacement` is set, applied as a correction rule (LLM prompt rule
///    for LLM modes; local string replacement otherwise).
@Model
final class VocabularyEntry {
    var phrase: String
    var replacement: String?

    init(phrase: String, replacement: String? = nil) {
        self.phrase = phrase
        self.replacement = replacement
    }
}
