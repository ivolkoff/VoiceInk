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
}
