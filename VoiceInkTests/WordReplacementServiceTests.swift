//
//  WordReplacementServiceTests.swift
//  VoiceInkTests
//

import Foundation
import SwiftData
import Testing
@testable import VoiceInk

@MainActor
struct WordReplacementServiceTests {

    /// Applies `rules` (trigger → replacement) to `text` through an in-memory store.
    private func apply(_ text: String, rules: [(String, String)]) throws -> String {
        let container = try ModelContainer(
            for: WordReplacement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        for (original, replacement) in rules {
            context.insert(WordReplacement(originalText: original, replacementText: replacement))
        }
        return WordReplacementService.shared.applyReplacements(to: text, using: context)
    }

    // MARK: - Combining marks (NFD text)

    @Test func doesNotMatchWhenACombiningMarkFollowsTheTrigger() throws {
        // "cà" decomposed: c + a + U+0300 COMBINING GRAVE ACCENT
        let text = "uống c\u{0061}\u{0300} phê"
        #expect(try apply(text, rules: [("ca", "КОФЕ")]) == text)
    }

    @Test func doesNotMatchARussianWordEndingInACombiningMark() throws {
        // "мой" decomposed: м + о + и + U+0306 COMBINING BREVE
        let text = "это мо\u{0438}\u{0306} текст"
        #expect(try apply(text, rules: [("мои", "МОИ")]) == text)
    }

    // MARK: - Non-spaced scripts

    @Test func matchesALatinTriggerFlushAgainstIdeographs() throws {
        #expect(try apply("我用voiceink录音", rules: [("voiceink", "VoiceInk")]) == "我用VoiceInk录音")
    }

    // MARK: - Existing behavior that must not regress

    @Test func replacesAWholeWordButNotASubstring() throws {
        #expect(try apply("мираж мир", rules: [("мир", "MIR")]) == "мираж MIR")
    }

    @Test func matchesATriggerEndingInPunctuation() throws {
        #expect(
            try apply("я пишу на c++ каждый день", rules: [("c++", "C plus plus")])
                == "я пишу на C plus plus каждый день"
        )
    }

    @Test func insertsRegexTemplateCharactersLiterally() throws {
        // "$1" and "\" are ICU substitution syntax; escapedTemplate must neutralize them.
        #expect(try apply("цена тут", rules: [("цена", "$1 \\ USD")]) == "$1 \\ USD тут")
    }

    @Test func fallsBackToSubstringReplacementForCJKTriggers() throws {
        #expect(try apply("我用录音功能", rules: [("录音", "recording")]) == "我用recording功能")
    }
}
