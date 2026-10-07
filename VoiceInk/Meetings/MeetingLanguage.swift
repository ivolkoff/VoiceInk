import Foundation
import NaturalLanguage

enum MeetingLanguage {
    static let auto = "auto"
    static let dominantMinCharacters = 200
    static let confidentOtherMinCharacters = 40
    static let minProbability = 0.8

    struct Detection: Equatable {
        let code: String
        let probability: Double
    }

    static func voiceInkCode(_ nlCode: String) -> String {
        switch nlCode {
        case "zh-Hans", "zh-Hant": return "zh"
        case "nb": return "no"
        default: return String(nlCode.split(separator: "-").first ?? Substring(nlCode))
        }
    }

    static func detect(_ text: String) -> Detection? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 5).max(by: { $0.value < $1.value }),
              best.key != .undetermined else { return nil }
        return Detection(code: voiceInkCode(best.key.rawValue), probability: best.value)
    }

    static func dominantLanguage(detection: Detection?, characterCount: Int, supported: Set<String>) -> String? {
        guard characterCount >= dominantMinCharacters,
              let detection,
              detection.probability >= minProbability,
              supported.contains(detection.code) else { return nil }
        return detection.code
    }

    // A chunk confidently in another language is a real switch (a guest speaking English), not a misdetection.
    static func pass2Indices(
        chunkTexts: [String],
        language: String,
        detect: (String) -> Detection? = MeetingLanguage.detect
    ) -> [Int] {
        chunkTexts.indices.filter { index in
            let text = chunkTexts[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return false }
            let detection = detect(text)
            if let detection, detection.code != language,
               detection.probability >= minProbability, text.count >= confidentOtherMinCharacters {
                return false
            }
            return detection?.code != language
        }
    }
}
