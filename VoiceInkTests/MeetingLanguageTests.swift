import Foundation
import Testing
@testable import VoiceInk

struct MeetingLanguageTests {
    @Test func mapsNaturalLanguageCodes() {
        #expect(MeetingLanguage.voiceInkCode("zh-Hans") == "zh")
        #expect(MeetingLanguage.voiceInkCode("zh-Hant") == "zh")
        #expect(MeetingLanguage.voiceInkCode("nb") == "no")
        #expect(MeetingLanguage.voiceInkCode("pt-BR") == "pt")
        #expect(MeetingLanguage.voiceInkCode("ru") == "ru")
    }

    @Test func detectsRussianAndEnglish() {
        let russian = "Давайте обсудим план релиза на пятницу. Нужно закрыть оставшиеся задачи, проверить сборку и договориться, кто отвечает за выкладку."
        let english = "Let's go over the release plan for Friday. We need to close the remaining tasks, check the build and agree on who owns the rollout."
        #expect(MeetingLanguage.detect(russian)?.code == "ru")
        #expect(MeetingLanguage.detect(english)?.code == "en")
        #expect(MeetingLanguage.detect("") == nil)
    }

    @Test func dominantLanguageDecision() {
        let supported: Set<String> = ["auto", "ru", "en"]
        let ru = MeetingLanguage.Detection(code: "ru", probability: 0.95)
        #expect(MeetingLanguage.dominantLanguage(detection: ru, characterCount: 500, supported: supported) == "ru")
        #expect(MeetingLanguage.dominantLanguage(detection: ru, characterCount: 150, supported: supported) == nil)
        #expect(MeetingLanguage.dominantLanguage(detection: .init(code: "ru", probability: 0.6), characterCount: 500, supported: supported) == nil)
        #expect(MeetingLanguage.dominantLanguage(detection: .init(code: "ja", probability: 0.99), characterCount: 500, supported: supported) == nil)
        #expect(MeetingLanguage.dominantLanguage(detection: nil, characterCount: 500, supported: supported) == nil)
    }

    @Test func pass2SelectsMisdetectedChunks() {
        let long = String(repeating: "x", count: 120)
        let detections: [String: MeetingLanguage.Detection] = [
            "Okay.": .init(code: "en", probability: 0.9),
            long: .init(code: "en", probability: 0.95),
            "Привет всем": .init(code: "ru", probability: 0.99),
        ]
        let texts = ["Okay.", long, "Привет всем", " "]
        let detect: (String) -> MeetingLanguage.Detection? = { detections[$0] }
        #expect(MeetingLanguage.pass2Indices(chunkTexts: texts, language: "ru", retranscribeAll: false, detect: detect) == [0])
        #expect(MeetingLanguage.pass2Indices(chunkTexts: texts, language: "ru", retranscribeAll: true, detect: detect) == [0, 2])
    }
}
