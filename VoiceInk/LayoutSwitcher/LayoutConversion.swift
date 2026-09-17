import Foundation

/// Plans a wrong-layout conversion from the characters actually produced at type time,
/// independent of which layout is active now. `typed` is what is on screen; `converted`
/// is `typed` flipped through the pair's character map. The source language is chosen by
/// the script of `typed`, not by the current keyboard layout.
enum LayoutConversion {
    struct Plan: Equatable {
        let typed: String
        let converted: String
        let verdict: LayoutVerdict
        let convertedLength: Int
        /// true when the converted text is in side B's script, so after typing it the
        /// system layout must switch to side B (and vice-versa).
        let switchToB: Bool
    }

    /// `map` must be the bidirectional character map of the pair (LayoutMapper.bidirectionalMap).
    @MainActor
    static func plan(typed: String, aLang: String, bLang: String,
                     map: [Character: Character], capsLock: Bool,
                     alwaysConvert: Set<String>) -> Plan {
        let converted = LayoutMapper.convertText(typed, map: map)
        let pairs = zip(typed, converted).map { KeyChars(original: $0, converted: $1) }
        // Which side did the user actually type in? Decide by the script of `typed`.
        let typedIsA = scriptMatchesLang(typed, lang: aLang)
        let currentLang = typedIsA ? aLang : bLang
        let otherLang = typedIsA ? bLang : aLang
        let decision = LayoutDetector.decideWord(pairs: pairs, currentLang: currentLang,
                                                 otherLang: otherLang, capsLock: capsLock,
                                                 alwaysConvert: alwaysConvert)
        return Plan(typed: typed, converted: converted, verdict: decision.verdict,
                    convertedLength: decision.convertedLength, switchToB: typedIsA)
    }

    /// True when the dominant letter script of `s` matches the (Latin/Cyrillic) family of `lang`.
    static func scriptMatchesLang(_ s: String, lang: String) -> Bool {
        var cyr = 0, lat = 0
        for u in s.unicodeScalars {
            if u.value >= 0x0400 && u.value <= 0x04FF { cyr += 1 }
            else if (u.value >= 0x41 && u.value <= 0x5A) || (u.value >= 0x61 && u.value <= 0x7A) { lat += 1 }
        }
        let sCyr = cyr >= lat
        return sCyr ? SmartConvert.isCyrillicLang(lang) : SmartConvert.isLatinLang(lang)
    }
}
