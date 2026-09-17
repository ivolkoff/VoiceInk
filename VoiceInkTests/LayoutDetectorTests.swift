import Testing
@testable import VoiceInk

@MainActor
struct LayoutDetectorTests {
    /// Both dictionaries must exist on the machine; otherwise the dictionary tests are no-ops.
    private var dictionariesAvailable: Bool {
        SystemDictionary.isAvailable("ru") && SystemDictionary.isAvailable("en")
    }

    private func pairs(_ typed: String, _ converted: String) -> [KeyChars] {
        zip(typed, converted).map { KeyChars(original: $0, converted: $1) }
    }

    private func decide(_ typed: String, _ converted: String, cur: String = "en", oth: String = "ru",
                        caps: Bool = false, always: Set<String> = []) -> LayoutVerdict {
        LayoutDetector.decide(typed: typed, converted: converted, currentLang: cur, otherLang: oth,
                              capsLock: caps, alwaysConvert: always)
    }

    @Test func garbageThatIsARealWordInTheOtherLayoutConverts() {
        guard dictionariesAvailable else { return }
        #expect(decide("ghbdtn", "привет") == .switchToConverted)
        #expect(decide("привет", "ghbdtn", cur: "ru", oth: "en") == .keep)
    }

    @Test func realWordInCurrentLayoutIsKept() {
        guard dictionariesAvailable else { return }
        #expect(decide("hello", "руддщ") == .keep)
    }

    @Test func wordValidInBothLayoutsIsKept() {
        guard dictionariesAvailable else { return }
        // "vs" reads as «мы»; both are listed as frequent, so neither direction fires.
        #expect(decide("vs", "мы") == .keep)
    }

    @Test func digitsCodeAndAcronymsAreUndecided() {
        #expect(decide("gh1", "пр1") == .undecided)
        #expect(decide("ghbDtn", "привет") == .undecided)
        #expect(decide("GHBDTN", "ПРИВЕТ") == .undecided)
        #expect(decide("ghbвет", "привет") == .undecided)
    }

    @Test func capsLockDisablesTheCapsVetoes() {
        guard dictionariesAvailable else { return }
        #expect(decide("GHBDTN", "ПРИВЕТ", caps: true) == .switchToConverted)
    }

    @Test func singleLetterIsUndecided() {
        #expect(decide("z", "я") == .undecided)
    }

    @Test func twoLetterWordsUseTheFrequencyList() {
        #expect(decide("yt", "не") == .switchToConverted)
        // «не» is in the current-language list, so it is kept — same shape as "to" below;
        // the plan expected .switchToConverted here, contradicting its own detector logic.
        #expect(decide("не", "yt", cur: "ru", oth: "en") == .keep)
        #expect(decide("qq", "йй") == .undecided)
        #expect(decide("to", "ещ") == .keep)
    }

    @Test func alwaysConvertOverridesEverything() {
        #expect(decide("GH1", "ПР1", always: ["пр1"]) == .switchToConverted)
    }

    @Test func splitsTrailingPunctuation() {
        #expect(LayoutDetector.splitTrailingPunctuation("ghbdtn,").coreLength == 6)
        #expect(LayoutDetector.splitTrailingPunctuation("ghbdtn,").suffix == ",")
        #expect(LayoutDetector.splitTrailingPunctuation("ghbdtn").suffix == "")
        #expect(LayoutDetector.splitTrailingPunctuation("a,b").suffix == "")
        #expect(LayoutDetector.splitTrailingPunctuation("x?!").suffix == "?!")
    }

    @Test func trailingCommaIsKeptLiteral() {
        guard dictionariesAvailable else { return }
        // ',' is «б» on ЙЦУКЕН: «приветб» is not a word, so only the core converts.
        let r = LayoutDetector.decideWord(pairs: pairs("ghbdtn,", "приветб"),
                                          currentLang: "en", otherLang: "ru", capsLock: false)
        #expect(r.verdict == .switchToConverted)
        #expect(r.convertedLength == 6)
    }

    @Test func ambiguousTrailingPeriodIsUndecided() {
        guard dictionariesAvailable else { return }
        // «levf.» is both «думаю» and «дума.» — leave it to the manual trigger.
        let r = LayoutDetector.decideWord(pairs: pairs("levf.", "думаю"),
                                          currentLang: "en", otherLang: "ru", capsLock: false)
        #expect(r.verdict == .undecided)
    }

    @Test func realWordWithTrailingPeriodIsKept() {
        guard dictionariesAvailable else { return }
        let r = LayoutDetector.decideWord(pairs: pairs("hello.", "руддщю"),
                                          currentLang: "en", otherLang: "ru", capsLock: false)
        #expect(r.verdict == .keep)
    }
}
