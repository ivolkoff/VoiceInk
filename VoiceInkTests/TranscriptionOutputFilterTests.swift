import Foundation
import Testing
@testable import VoiceInk

@MainActor
struct TranscriptionOutputFilterTests {

    private func withFillers(_ words: [String], enabled: Bool, _ body: () throws -> Void) rethrows {
        let manager = FillerWordManager.shared
        let savedWords = manager.fillerWords
        let savedEnabled = UserDefaults.standard.bool(forKey: "RemoveFillerWords")
        defer {
            manager.fillerWords = savedWords
            UserDefaults.standard.set(savedEnabled, forKey: "RemoveFillerWords")
        }
        manager.fillerWords = words
        UserDefaults.standard.set(enabled, forKey: "RemoveFillerWords")
        try body()
    }

    @Test func fillerRemovalSwallowsThePunctuationItCarried() {
        withFillers(["um"], enabled: true) {
            #expect(TranscriptionOutputFilter.filter("wait um? what") == "wait what")
            #expect(TranscriptionOutputFilter.filter("wait um, what") == "wait what")
        }
    }

    @Test func fillerInsideAHyphenatedWordIsKept() {
        withFillers(["ну", "um"], enabled: true) {
            #expect(TranscriptionOutputFilter.filter("ну-ка") == "ну-ка")
            #expect(TranscriptionOutputFilter.filter("um-hmm") == "um-hmm")
        }
    }

    @Test func whitespaceCollapseKeepsParagraphBreaks() {
        withFillers([], enabled: false) {
            #expect(TranscriptionOutputFilter.filter("para one\n\npara two") == "para one\n\npara two")
            #expect(TranscriptionOutputFilter.filter("double  spaced") == "double spaced")
        }
    }
}
