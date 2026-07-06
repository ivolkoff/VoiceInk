//
//  RetranscribeHotkeyTests.swift
//  VoiceInkTests
//

import Foundation
import Testing
@testable import VoiceInk

struct LanguageResolverTests {

    private func model(provider: ModelProvider, languages: [String: String]) -> CloudModel {
        CloudModel(
            name: "m",
            displayName: "M",
            description: "",
            provider: provider,
            speed: 0,
            accuracy: 0,
            isMultilingual: true,
            supportedLanguages: languages
        )
    }

    @Test func exactBaseMatch() {
        let m = model(provider: .whisper, languages: ["en": "English", "ru": "Russian", "auto": "Auto"])
        #expect(TranscriptionLanguagePreference.supportedCode(forLayoutLanguage: "en", model: m) == "en")
        #expect(TranscriptionLanguagePreference.supportedCode(forLayoutLanguage: "ru", model: m) == "ru")
    }

    @Test func prefersUSRegionVariant() {
        let m = model(provider: .nativeApple, languages: ["en-US": "English (US)", "en-GB": "English (UK)", "en-AU": "English (AU)"])
        #expect(TranscriptionLanguagePreference.supportedCode(forLayoutLanguage: "en", model: m) == "en-US")
    }

    @Test func fallsBackToSortedVariantWhenNoUS() {
        let m = model(provider: .nativeApple, languages: ["fr-FR": "French (FR)", "fr-CA": "French (CA)"])
        #expect(TranscriptionLanguagePreference.supportedCode(forLayoutLanguage: "fr", model: m) == "fr-CA")
    }

    @Test func unsupportedLanguageReturnsNil() {
        let m = model(provider: .nativeApple, languages: ["en-US": "English (US)", "en-GB": "English (UK)"])
        #expect(TranscriptionLanguagePreference.supportedCode(forLayoutLanguage: "ru", model: m) == nil)
    }

    @Test func neverReturnsAutoForAnUnsupportedLanguage() {
        let m = model(provider: .whisper, languages: ["auto": "Auto", "en": "English"])
        #expect(TranscriptionLanguagePreference.supportedCode(forLayoutLanguage: "fr", model: m) == nil)
    }
}

@MainActor
struct LastPasteTrackerTests {

    @Test func recordThenClear() {
        let id = UUID()
        LastPasteTracker.shared.record(transcriptionID: id, pastedText: "hola ", targetBundleID: "com.example", posted: true)

        let ctx = LastPasteTracker.shared.context
        #expect(ctx?.transcriptionID == id)
        #expect(ctx?.pastedText == "hola ")
        #expect(ctx?.targetBundleID == "com.example")
        #expect(ctx?.posted == true)

        LastPasteTracker.shared.clear()
        #expect(LastPasteTracker.shared.context == nil)
    }
}
