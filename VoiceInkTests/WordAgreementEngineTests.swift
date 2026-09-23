import Testing
@testable import VoiceInk

struct WordAgreementEngineTests {
    private func pass(_ text: String) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { i, word in
            TimedWord(text: String(word), startTime: Double(i), endTime: Double(i) + 0.5)
        }
    }

    private func run(_ passes: [String]) -> String {
        let engine = WordAgreementEngine()
        return passes.map { engine.processTranscriptionResult(words: pass($0)).newlyConfirmedText }.last ?? ""
    }

    @Test func stablePassesConfirmTheFirstSentence() {
        let text = "one two three four five. six seven. eight nine. ten"
        #expect(run(Array(repeating: text, count: 4)) == "one two three four five.")
    }

    @Test func sentencePunctuationChurnBlocksConfirmation() {
        let asked = "one two three four five? six seven. eight nine. ten"
        let told = "one two three four five. six seven. eight nine. ten"
        #expect(run([asked, asked, asked, told]) == "")
    }
}
