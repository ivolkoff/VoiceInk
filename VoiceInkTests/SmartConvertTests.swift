import Testing
@testable import VoiceInk

@MainActor
struct SmartConvertTests {
    private func run(_ text: String) -> String? {
        guard let l = TestLayouts.usAndRussian(),
              SystemDictionary.isAvailable("ru"), SystemDictionary.isAvailable("en") else { return nil }
        let map = LayoutMapper.bidirectionalMap(l.us, l.ru)
        return SmartConvert.selection(text, latLang: "en", cyrLang: "ru", map: map)
    }

    @Test func flipsGarbageAndKeepsValidWords() {
        guard let out = run("iPhone ghbdtn") else { return }
        #expect(out == "iPhone привет")
    }

    @Test func flipsBothDirectionsInMixedGarbage() {
        guard let out = run("ghbdtn ьшк") else { return }
        // «ьшк» is ru-layout garbage, its fix is Latin "mir" — the plan's expected "мир"
        // (Cyrillic) is unreachable through a US↔RU character map.
        #expect(out == "привет mir")
    }

    @Test func pullsShortWordsInTheDirectionOfTheirNeighbours() {
        guard let out = run("z yt vjue") else { return }
        #expect(out == "я не могу")
    }

    @Test func scientificSingleLetterStaysWhenNeighboursAreValid() {
        guard let out = run("vitamin c") else { return }
        #expect(out == "vitamin c")
    }

    @Test func keepsTrailingPunctuationLiteral() {
        guard let out = run("ghbdtn,") else { return }
        #expect(out == "привет,")
    }

    @Test func languageClassification() {
        #expect(SmartConvert.isCyrillicLang("ru-RU"))
        #expect(SmartConvert.isLatinLang("en"))
        #expect(!SmartConvert.isLatinLang("he"))
    }
}
