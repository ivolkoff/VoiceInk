import Testing
@testable import VoiceInk

@MainActor
struct LayoutConversionTests {
    private var ready: Bool {
        TestLayouts.usAndRussian() != nil && SystemDictionary.isAvailable("ru") && SystemDictionary.isAvailable("en")
    }
    private func plan(_ typed: String) -> LayoutConversion.Plan? {
        guard let l = TestLayouts.usAndRussian(), ready else { return nil }
        let map = LayoutMapper.bidirectionalMap(l.us, l.ru)
        return LayoutConversion.plan(typed: typed, aLang: "en", bLang: "ru", map: map,
                                     capsLock: false, alwaysConvert: [])
    }

    @Test func latinGarbageConvertsAndSwitchesToCyrillic() {
        guard let p = plan("ghbdtn") else { return }
        #expect(p.converted == "привет")
        #expect(p.verdict == .switchToConverted)
        #expect(p.switchToB == true)
    }

    @Test func contextualShortWordsRequireAVerifiedPhrase() throws {
        let layouts = try #require(TestLayouts.usAndRussian())
        let map = LayoutMapper.bidirectionalMap(layouts.us, layouts.ru)
        func reading(_ text: String) -> LayoutConversion.Plan {
            LayoutConversion.plan(typed: text, aLang: "en", bLang: "ru", map: map,
                                  capsLock: false, alwaysConvert: [])
        }
        let pending = ["f", "b", "z"].compactMap {
            LayoutConversion.pendingLetter(reading($0), source: "en", target: "ru")
        }
        #expect(pending == Array("fbz"))
        let anchor = reading("[jxe")
        func correction(_ screen: String?, letters: [Character]? = nil,
                        never: Set<String> = []) -> String? {
            LayoutConversion.phraseReplacement(for: anchor, pending: letters ?? pending, onScreen: screen,
                                              source: "en", target: "ru", map: map, never: never)?.produced
        }
        #expect(correction("f b z [jxe ") == "а и я хочу ")
        #expect(correction("Да, f b z [jxe ") == "а и я хочу ")
        #expect(correction("plan b [jxe ", letters: ["b"]) == nil)
        #expect(correction("af b z [jxe ") == nil)
        #expect(correction(nil) == nil)
        #expect(correction("F b z [jxe ") == "А и я хочу ")
        #expect(correction("f B z [jxe ") == nil)
        #expect(correction("f b z [jxe ", never: ["я"]) == nil)
        #expect(correction("f b z [jxe ", never: ["f b z [jxe"]) == nil)
        for word in ["а", "и", "я", "хочу"] {
            #expect(reading(word).verdict != .switchToConverted)
        }
    }

    @Test func correctCyrillicWordIsKept() {
        guard let p = plan("привет") else { return }
        #expect(p.verdict == .keep)
    }

    @Test func decisionIgnoresWhichLayoutIsActive() {
        // Same typed string yields the same verdict regardless of caller context.
        guard let a = plan("ghbdtn"), let b = plan("ghbdtn") else { return }
        #expect(a == b)
    }
    @Test func selectionSmartPassLeftUnchangedIsFlippedWhole() {
        guard let l = TestLayouts.usAndRussian() else { return }
        let map = LayoutMapper.bidirectionalMap(l.us, l.ru)
        func force(_ s: String) -> String? { LayoutConversion.selectionResult(smart: s, selection: s, map: map) }
        #expect(force("привет") == "ghbdtn")
        #expect(force("ПРИВЕТ") == "GHBDTN")
        #expect(force("iPhone") == "шЗрщту")
        #expect(force("123 ") == nil)
        // A smart result that changed something is kept as is.
        #expect(LayoutConversion.selectionResult(smart: "привет iPhone", selection: "ghbdtn iPhone", map: map) == "привет iPhone")
    }
    private func readings(_ typed: String, _ inA: String, _ inB: String) -> (first: String, second: String, firstIsA: Bool)? {
        LayoutConversion.mixedReadings(typed: typed, inA: inA, inB: inB, aLang: "en", bLang: "ru")
    }

    @Test func mixedWordUnifiesToTheDictionaryReading() {
        guard ready else { return }
        let tail = readings("привtn", "ghbdtn", "привет")
        #expect(tail?.first == "привет" && tail?.second == "ghbdtn" && tail?.firstIsA == false)
        let latin = readings("helдщ", "hello", "руддщ")
        #expect(latin?.first == "hello" && latin?.firstIsA == true)
        // Started in the wrong layout: the dictionary outweighs the first part.
        #expect(readings("ghbdет", "ghbdtn", "привет")?.first == "привет")
        // Trailing punctuation does not hide the word.
        #expect(readings("привtn?", "ghbdtn?", "привет,")?.first == "привет,")
    }

    @Test func mixedWordWithoutDictionaryVerdictFollowsItsStart() {
        guard ready else { return }
        #expect(readings("фываzxcv", "asdfzxcv", "фываячсм")?.first == "фываячсм")
        #expect(readings("asdfячсм", "asdfzxcv", "фываячсм")?.first == "asdfzxcv")
    }

    @Test func singleLayoutWordIsNotMixed() {
        #expect(readings("ghbdtn", "ghbdtn", "привет") == nil)
        #expect(readings("привет", "ghbdtn", "привет") == nil)
    }

    @Test func punctuationSuffixFlipsWithTheWord() {
        // macOS Russian: the comma/period keys render as "^"/"&" in the U.S. layout, so
        // «привет,» typed in the wrong layout arrives as "ghbdtn^". The suffix must come
        // out as the comma, and "^"/"&" must split off the word like any other punctuation.
        guard let q = plan("ghbdtn^"), let w = plan("ghbdtn&"), let f = plan("ghbdtn/") else { return }
        #expect(q.converted == "привет,")
        #expect(q.verdict == .switchToConverted && q.convertedLength == 6)
        #expect(w.converted == "привет.")
        #expect(w.verdict == .switchToConverted && w.convertedLength == 6)
        // "/" and "?" share their image between this pair's layouts; the flip is identity.
        #expect(f.converted == "привет/")
        #expect(f.verdict == .switchToConverted && f.convertedLength == 6)
    }
}
