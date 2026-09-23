import Foundation
import Testing
@testable import VoiceInk

/// Runs only where the U.S. (or ABC) and Russian layouts are installed (enabled or not).
enum TestLayouts {
    static func usAndRussian() -> (us: Data, ru: Data)? {
        let all = LayoutPair.allLayouts()
        let us = all.first { ["com.apple.keylayout.US", "com.apple.keylayout.ABC"].contains(LayoutPair.sourceID($0)) }
        let ru = all.first { LayoutPair.sourceID($0) == "com.apple.keylayout.Russian" }
        guard let us, let ru, let usData = LayoutPair.layoutData(us), let ruData = LayoutPair.layoutData(ru) else { return nil }
        return (usData, ruData)
    }
}

struct LayoutMapperTests {
    // g h b d t n on ANSI: kVK_ANSI_G … kVK_ANSI_N
    private let ghbdtn: [TypedKey] = [5, 4, 11, 2, 17, 45].map { TypedKey(keyCode: $0, shift: false, caps: false) }

    @Test func rendersTheSameKeysInBothLayouts() {
        guard let l = TestLayouts.usAndRussian() else { return }
        let pairs = LayoutMapper.convert(ghbdtn, from: l.us, to: l.ru)
        #expect(pairs.map { String($0.map(\.original)) } == "ghbdtn")
        #expect(pairs.map { String($0.map(\.converted)) } == "привет")
    }

    @Test func apostropheIsADeadKeyOnUSInternationalOnly() {
        guard let l = TestLayouts.usAndRussian(),
              let intl = LayoutPair.allLayouts()
                .first(where: { LayoutPair.sourceID($0) == "com.apple.keylayout.USInternational-PC" })
                .flatMap(LayoutPair.layoutData) else { return }
        #expect(LayoutMapper.isDeadKey(keyCode: 39, layout: intl, shift: false, caps: false))
        #expect(!LayoutMapper.isDeadKey(keyCode: 39, layout: l.us, shift: false, caps: false))
    }

    @Test func reconstructFillsMissingCharsFromLayout() {
        guard let l = TestLayouts.usAndRussian() else { return }
        // Every key lost its type-time character (TIS returned nil), as in the intermittent bug.
        let keysNoChar = [5, 4, 11, 2, 17, 45].map { TypedKey(keyCode: $0, shift: false, caps: false, char: nil) }
        #expect(LayoutMapper.reconstruct(keysNoChar, currentData: l.us, pairA: l.us, pairB: l.ru) == "ghbdtn")
    }

    @Test func reconstructPrefersTheStoredCharacter() {
        guard let l = TestLayouts.usAndRussian() else { return }
        // Stored char wins over what the current layout would render for the same key code.
        let keys = [TypedKey(keyCode: 5, shift: false, caps: false, char: "п")]
        #expect(LayoutMapper.reconstruct(keys, currentData: l.us, pairA: l.us, pairB: l.ru) == "п")
    }

    @Test func reconstructMixesStoredAndRefilledChars() {
        guard let l = TestLayouts.usAndRussian() else { return }
        let keys = [
            TypedKey(keyCode: 5, shift: false, caps: false, char: "g"),
            TypedKey(keyCode: 4, shift: false, caps: false, char: nil),   // refilled from US → 'h'
            TypedKey(keyCode: 11, shift: false, caps: false, char: "b"),
        ]
        #expect(LayoutMapper.reconstruct(keys, currentData: l.us, pairA: l.us, pairB: l.ru) == "ghb")
    }

    @Test func shiftAndCapsProduceUppercase() {
        guard let l = TestLayouts.usAndRussian() else { return }
        #expect(LayoutMapper.character(keyCode: 5, layout: l.us, shift: true, caps: false) == "G")
        #expect(LayoutMapper.character(keyCode: 5, layout: l.ru, shift: false, caps: true) == "П")
    }

    @Test func punctuationKeysBecomeLetters() {
        guard let l = TestLayouts.usAndRussian() else { return }
        // ';' is «ж», ',' is «б»
        #expect(LayoutMapper.character(keyCode: 41, layout: l.ru, shift: false, caps: false) == "ж")
        #expect(LayoutMapper.character(keyCode: 43, layout: l.ru, shift: false, caps: false) == "б")
    }

    @Test func characterMapFlipsText() {
        guard let l = TestLayouts.usAndRussian() else { return }
        let map = LayoutMapper.bidirectionalMap(l.us, l.ru)
        #expect(LayoutMapper.convertText("ghbdtn vbh", map: map) == "привет мир")
        #expect(LayoutMapper.convertText("руддщ", map: map) == "hello")
    }

    @Test func combiningMarksAreLeftAlone() {
        guard let l = TestLayouts.usAndRussian() else { return }
        let map = LayoutMapper.bidirectionalMap(l.us, l.ru)
        let withMark = "a\u{0301}b"
        #expect(LayoutMapper.convertText(withMark, map: map) == withMark)
    }

    @Test func autoDetectPicksLatinFirst() {
        let all = LayoutPair.allLayouts()
        guard let ids = LayoutPair.autoDetectIDs(from: all) else { return }
        #expect(ids.0 != ids.1)
        let first = all.first { LayoutPair.sourceID($0) == ids.0 }
        #expect(first.flatMap(LayoutPair.languageCode) == "en")
    }
}
