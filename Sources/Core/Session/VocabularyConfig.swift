import Foundation

/// Plain-data snapshot of the vocabulary list (ARCHITECTURE.md §6.7), handed
/// to `DictationSession` so the pipeline stays decoupled from SwiftData —
/// the same pattern as `ModeConfig`.
struct VocabularyConfig {
    /// All phrases, joined into Whisper's initial prompt to bias recognition.
    var phrases: [String] = []
    /// Hard correction rules applied to the raw transcript.
    var replacements: [(phrase: String, replacement: String)] = []

    /// Case-insensitive whole-string replacement of each rule, e.g.
    /// "just pay" → "Juspay".
    func applyReplacements(to text: String) -> String {
        var result = text
        for rule in replacements where !rule.phrase.isEmpty {
            var searchRange = result.startIndex..<result.endIndex
            while let found = result.range(of: rule.phrase,
                                           options: [.caseInsensitive],
                                           range: searchRange) {
                result.replaceSubrange(found, with: rule.replacement)
                let resumeAt = result.index(found.lowerBound,
                                            offsetBy: rule.replacement.count,
                                            limitedBy: result.endIndex) ?? result.endIndex
                searchRange = resumeAt..<result.endIndex
            }
        }
        return result
    }
}
