import Foundation
import SwiftData

class WordReplacementService {
    static let shared = WordReplacementService()

    private init() {}

    func applyReplacements(to text: String, using context: ModelContext) -> String {
        let descriptor = FetchDescriptor<WordReplacement>(
            predicate: #Predicate { $0.isEnabled }
        )

        guard let replacements = try? context.fetch(descriptor), !replacements.isEmpty else {
            return text // No replacements to apply
        }

        var modifiedText = text

        // Longest-first so specific triggers match before shorter overlapping ones
        let sortedReplacements = replacements.sorted {
            $0.originalText.count > $1.originalText.count
        }

        // Apply replacements (case-insensitive)
        for replacement in sortedReplacements {
            let originalGroup = replacement.originalText
            let replacementText = replacement.replacementText

            let variants = originalGroup
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted { $0.count > $1.count }

            for original in variants {
                let usesBoundaries = usesWordBoundaries(for: original)

                if usesBoundaries {
                    // Lookarounds instead of \b so punctuation acts as a word boundary.
                    // Unicode-aware classes (\p{L}\p{N}) — an ASCII-only [a-zA-Z0-9] treats every
                    // Cyrillic/Greek/Arabic/etc. letter as a boundary, so a short rule matches
                    // inside longer words and corrupts non-Latin transcripts.
                    let escaped = NSRegularExpression.escapedPattern(for: original)
                    let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
                    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                        let range = NSRange(modifiedText.startIndex..., in: modifiedText)
                        // Escape the template: `$n` and `\` are ICU substitution
                        // syntax, so an unescaped replacement containing "$" or "\"
                        // (prices, paths, env vars) would be silently corrupted.
                        let template = NSRegularExpression.escapedTemplate(for: replacementText)
                        modifiedText = regex.stringByReplacingMatches(
                            in: modifiedText,
                            options: [],
                            range: range,
                            withTemplate: template
                        )
                    }
                } else {
                    // Fallback substring replace for non-spaced scripts
                    modifiedText = modifiedText.replacingOccurrences(of: original, with: replacementText, options: .caseInsensitive)
                }
            }
        }

        return modifiedText
    }

    private func usesWordBoundaries(for text: String) -> Bool {
        // Returns false for languages without spaces (CJK, Thai), true for spaced languages
        let nonSpacedScripts: [ClosedRange<UInt32>] = [
            0x3040...0x309F, // Hiragana
            0x30A0...0x30FF, // Katakana
            0x4E00...0x9FFF, // CJK Unified Ideographs
            0xAC00...0xD7AF, // Hangul Syllables
            0x0E00...0x0E7F, // Thai
        ]

        for scalar in text.unicodeScalars {
            for range in nonSpacedScripts {
                if range.contains(scalar.value) {
                    return false
                }
            }
        }

        return true
    }
}
