import AppKit

/// System-dictionary lookups through NSSpellChecker: local, no bundled data, ~0.1 ms per word.
/// The first call spins up the AppleSpell XPC service (hundreds of ms on main), hence `warmUp()`.
enum SystemDictionary {
    @MainActor private static let checker = NSSpellChecker.shared
    @MainActor private static var cachedLanguages: [String]?

    @MainActor static func isAvailable(_ lang: String) -> Bool {
        let two = String(lang.prefix(2))
        return languages().contains { String($0.prefix(2)) == two }
    }

    @MainActor static func isValidWord(_ word: String, lang: String) -> Bool {
        let range = checker.checkSpelling(of: word, startingAt: 0, language: lang,
                                          wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }

    @MainActor static func warmUp() {
        _ = languages()
        _ = isValidWord("test", lang: "en")
    }

    @MainActor private static func languages() -> [String] {
        if let cachedLanguages { return cachedLanguages }
        let langs = checker.availableLanguages
        cachedLanguages = langs
        return langs
    }
}

enum LayoutVerdict: Equatable {
    case switchToConverted, keep, undecided
}

/// Decides whether a word was typed in the wrong layout. Precision over recall: any doubt is
/// `.undecided` and nothing happens — the manual trigger still works.
/// Port of RuSwitcher AutoSwitch.swift (MIT, © Rashns) without the Hebrew branch.
enum LayoutDetector {
    @MainActor
    static func decide(typed: String, converted: String, currentLang: String, otherLang: String,
                       capsLock: Bool, alwaysConvert: Set<String> = []) -> LayoutVerdict {
        // always-convert matches the target form so a correctly typed word can't ping-pong.
        if alwaysConvert.contains(converted.lowercased()) { return .switchToConverted }
        guard typed.count >= 2 else { return .undecided }
        // ё/х/ъ/ж/э/б/ю live on punctuation keys, so `typed` may contain punctuation while
        // the conversion is all letters; the dictionary decides that case.
        guard typed.allSatisfy({ $0.isLetter }) || converted.allSatisfy({ $0.isLetter }) else {
            return .undecided
        }
        if !capsLock {
            if isAllCaps(typed) { return .undecided }
            if looksLikeCodeIdentifier(typed) { return .undecided }
        }

        let cur = String(currentLang.prefix(2))
        let oth = String(otherLang.prefix(2))

        if typed.count == 2 {
            guard let othShort = ShortWords.common(oth) else { return .undecided }
            if let curShort = ShortWords.common(cur), curShort.contains(typed.lowercased()) { return .keep }
            return othShort.contains(converted.lowercased()) ? .switchToConverted : .undecided
        }

        guard SystemDictionary.isAvailable(oth) else { return .undecided }
        guard SystemDictionary.isValidWord(converted.lowercased(), lang: oth) else { return .keep }
        if SystemDictionary.isAvailable(cur), SystemDictionary.isValidWord(typed.lowercased(), lang: cur) {
            return .keep
        }
        return .switchToConverted
    }

    /// Decision for a whole typed word including trailing punctuation («ghbdtn,» → «привет,»).
    /// `. , ; :` are letters on ЙЦУКЕН, so «levf.» reads both as «думаю» and as «дума.»; when
    /// both readings are real words the verdict is `.undecided`. `convertedLength` says how many
    /// leading pairs to convert; the rest is retyped literally.
    @MainActor
    static func decideWord(pairs: [KeyChars], currentLang: String, otherLang: String,
                           capsLock: Bool, alwaysConvert: Set<String> = []) -> (verdict: LayoutVerdict, convertedLength: Int) {
        let typed = String(pairs.map(\.original))
        let converted = String(pairs.map(\.converted))
        let (coreLength, suffix) = splitTrailingPunctuation(typed)
        guard !suffix.isEmpty, coreLength > 0 else {
            let v = decide(typed: typed, converted: converted, currentLang: currentLang,
                           otherLang: otherLang, capsLock: capsLock, alwaysConvert: alwaysConvert)
            return (v, pairs.count)
        }
        let core = String(pairs.prefix(coreLength).map(\.original))
        let convertedCore = String(pairs.prefix(coreLength).map(\.converted))
        let coreVerdict = decide(typed: core, converted: convertedCore, currentLang: currentLang,
                                 otherLang: otherLang, capsLock: capsLock, alwaysConvert: alwaysConvert)
        let oth = String(otherLang.prefix(2))
        let fullReading = converted.allSatisfy { $0.isLetter }
            && SystemDictionary.isAvailable(oth)
            && SystemDictionary.isValidWord(converted.lowercased(), lang: oth)
        guard fullReading else { return (coreVerdict, coreLength) }
        switch coreVerdict {
        case .switchToConverted:
            return (.undecided, pairs.count)
        case .keep:
            return (.keep, pairs.count)
        case .undecided:
            let v = decide(typed: typed, converted: converted, currentLang: currentLang,
                           otherLang: otherLang, capsLock: capsLock, alwaysConvert: alwaysConvert)
            return (v, pairs.count)
        }
    }

    /// Splits punctuation stuck to the end of a word. Digits, hyphen, @ and # are not split so
    /// URLs and code keep tripping the detector's vetoes; quotes are skipped because smart
    /// punctuation and dead-key layouts change them under our feet.
    static func splitTrailingPunctuation(_ s: String) -> (coreLength: Int, suffix: String) {
        let punct: Set<Character> = [",", ".", "!", "?", ";", ":", ")", "`", "[", "]"]
        var core = s[...]
        while let last = core.last, punct.contains(last) { core = core.dropLast() }
        return (core.count, String(s.dropFirst(core.count)))
    }

    static func isAllCaps(_ s: String) -> Bool {
        s == s.uppercased() && s != s.lowercased()
    }

    /// Inner capital (camelCase) or Latin and Cyrillic in one token — code, not a word.
    static func looksLikeCodeIdentifier(_ s: String) -> Bool {
        for (i, c) in s.enumerated() where i > 0 && c.isUppercase { return true }
        var hasLatin = false, hasCyrillic = false
        for u in s.unicodeScalars {
            switch u.value {
            case 0x41...0x5A, 0x61...0x7A: hasLatin = true
            case 0x0400...0x04FF: hasCyrillic = true
            default: break
            }
        }
        return hasLatin && hasCyrillic
    }
}
