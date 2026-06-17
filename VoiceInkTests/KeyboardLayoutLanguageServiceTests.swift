//
//  KeyboardLayoutLanguageServiceTests.swift
//  VoiceInkTests
//

import Foundation
import Testing
@testable import VoiceInk

struct KeyboardLayoutLanguageServiceTests {

    @Test func normalizesBaseCode() {
        #expect(KeyboardLayoutLanguageService.normalize("en") == "en")
        #expect(KeyboardLayoutLanguageService.normalize("ru") == "ru")
    }

    @Test func stripsRegionAndLowercases() {
        #expect(KeyboardLayoutLanguageService.normalize("en-US") == "en")
        #expect(KeyboardLayoutLanguageService.normalize("ru-RU") == "ru")
        #expect(KeyboardLayoutLanguageService.normalize("EN") == "en")
    }

    @Test func returnsNilForEmpty() {
        #expect(KeyboardLayoutLanguageService.normalize("") == nil)
        #expect(KeyboardLayoutLanguageService.normalize("  ") == nil)
    }
}
