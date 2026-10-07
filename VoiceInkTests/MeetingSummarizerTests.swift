import Foundation
import Testing
@testable import VoiceInk

struct MeetingSummarizerTests {
    @Test func languageNames() {
        #expect(MeetingSummarizer.languageName("ru") == "Russian")
        #expect(MeetingSummarizer.languageName("de-DE") == "German")
        #expect(MeetingSummarizer.languageName(nil) == "the same language as the transcript")
        #expect(MeetingSummarizer.languageName("auto") == "the same language as the transcript")
    }

    @Test func ollamaContextSizeIsClamped() {
        #expect(MeetingSummarizer.ollamaContextSize(characters: 100) == 4_096)
        #expect(MeetingSummarizer.ollamaContextSize(characters: 30_000) == 12_048)
        #expect(MeetingSummarizer.ollamaContextSize(characters: 200_000) == 32_768)
    }
}
