//
//  SelectedTextEnhancementLogicTests.swift
//  VoiceInkTests
//

import Foundation
import Testing
@testable import VoiceInk

struct SelectedTextEnhancementLogicTests {

    // MARK: - SelectedTextCaptureResult

    @Test func captureResultExposesText() {
        #expect(SelectedTextCaptureResult.selection("hi").text == "hi")
        #expect(SelectedTextCaptureResult.selectedAll("doc").text == "doc")
        #expect(SelectedTextCaptureResult.noText.text == nil)
    }

    // MARK: - Decision: no usable text

    @Test func noTextAborts() {
        #expect(SelectedTextEnhancementDecision.decide(capture: .noText, maxInputLength: 100) == .abortNoText)
    }

    @Test func whitespaceOnlySelectionAborts() {
        #expect(SelectedTextEnhancementDecision.decide(capture: .selection("   \n\t "), maxInputLength: 100) == .abortNoText)
    }

    // MARK: - Decision: max-length guard (before any AI call)

    @Test func overLimitAbortsWithLengthAndLimit() {
        #expect(
            SelectedTextEnhancementDecision.decide(capture: .selection("abcdef"), maxInputLength: 5)
                == .abortTooLong(length: 6, limit: 5)
        )
    }

    @Test func selectedAllOverLimitAborts() {
        #expect(
            SelectedTextEnhancementDecision.decide(capture: .selectedAll("abcdef"), maxInputLength: 5)
                == .abortTooLong(length: 6, limit: 5)
        )
    }

    // MARK: - Decision: proceed

    @Test func atLimitProceeds() {
        #expect(
            SelectedTextEnhancementDecision.decide(capture: .selection("hello"), maxInputLength: 5)
                == .proceed(text: "hello")
        )
    }

    @Test func underLimitProceeds() {
        #expect(
            SelectedTextEnhancementDecision.decide(capture: .selection("hi"), maxInputLength: 100)
                == .proceed(text: "hi")
        )
        #expect(
            SelectedTextEnhancementDecision.decide(capture: .selectedAll("whole field"), maxInputLength: 100)
                == .proceed(text: "whole field")
        )
    }

    @Test func proceedPreservesUntrimmedText() {
        #expect(
            SelectedTextEnhancementDecision.decide(capture: .selection("  padded  "), maxInputLength: 100)
                == .proceed(text: "  padded  ")
        )
    }

    // MARK: - Max-length setting

    @Test func defaultMaxLengthIs4000() {
        #expect(SelectedTextEnhancementSettings.defaultMaxInputLength == 4000)
    }

    @Test func unsetReturnsDefault() {
        let defaults = makeDefaults()
        #expect(SelectedTextEnhancementSettings.maxInputLength(defaults: defaults) == SelectedTextEnhancementSettings.defaultMaxInputLength)
    }

    @Test func storedValueHonored() {
        let defaults = makeDefaults()
        defaults.set(8000, forKey: SelectedTextEnhancementSettings.maxInputLengthKey)
        #expect(SelectedTextEnhancementSettings.maxInputLength(defaults: defaults) == 8000)
    }

    @Test func zeroStoredFallsBackToDefault() {
        let defaults = makeDefaults()
        defaults.set(0, forKey: SelectedTextEnhancementSettings.maxInputLengthKey)
        #expect(SelectedTextEnhancementSettings.maxInputLength(defaults: defaults) == SelectedTextEnhancementSettings.defaultMaxInputLength)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "stk.logic.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
