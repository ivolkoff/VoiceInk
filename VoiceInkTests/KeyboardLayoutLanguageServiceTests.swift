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

    /// The cached layout language must be readable from a background thread without
    /// touching the main-thread-only Text Input Source API. Reproduces the crash where
    /// `currentLanguageCode()` called TIS on the Swift concurrency cooperative pool.
    @Test func cachedLanguageIsVisibleAcrossThreads() async {
        KeyboardLayoutLanguageService.updateCachedLanguage("ru")
        #expect(KeyboardLayoutLanguageService.currentLanguageCode() == "ru")

        let background = await Task.detached {
            KeyboardLayoutLanguageService.currentLanguageCode()
        }.value
        #expect(background == "ru")

        KeyboardLayoutLanguageService.updateCachedLanguage(nil)
        #expect(KeyboardLayoutLanguageService.currentLanguageCode() == nil)
    }

    /// Capturing on the main thread refreshes the cache from the live input source,
    /// overwriting any stale value. This is what keeps transcription in sync with the
    /// keyboard even when VoiceInk ran in the background while the layout changed.
    @MainActor
    @Test func captureOverwritesStaleCacheFromLiveInputSource() {
        KeyboardLayoutLanguageService.updateCachedLanguage("zz-stale-sentinel")
        KeyboardLayoutLanguageService.captureCurrentLayout()
        #expect(KeyboardLayoutLanguageService.currentLanguageCode() != "zz-stale-sentinel")

        KeyboardLayoutLanguageService.updateCachedLanguage(nil)
    }
}
