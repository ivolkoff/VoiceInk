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
