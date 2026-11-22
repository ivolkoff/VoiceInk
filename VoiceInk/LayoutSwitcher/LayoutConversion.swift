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

    /// These keys can spell a one-letter word in the other layout. Defer until a later word confirms it.
    static func pendingLetter(_ plan: Plan, source: String, target: String) -> Character? {
        guard plan.verdict == .undecided,
              Set([String(source.prefix(2)), String(target.prefix(2))]) == ["en", "ru"],
              plan.typed.count == 1, let letter = plan.typed.first, letter.isLowercase,
              plan.converted.count == 1, let flipped = plan.converted.first,
              ShortWords.isSingle(flipped, lang: target),
              !ShortWords.isSingle(letter, lang: source) else { return nil }
        return letter
    }

    /// Extend an accepted single-word correction only across a verified, freshly typed suffix.
    static func phraseReplacement(for plan: Plan, pending: [Character], onScreen: String?,
                                  source: String, target: String, map: [Character: Character],
                                  never: Set<String>) -> (original: String, produced: String)? {
        guard plan.verdict == .switchToConverted, plan.convertedLength >= 3,
              !pending.isEmpty, let onScreen else { return nil }
        let prefix = pending.map(String.init).joined(separator: " ")
        let typed = prefix + " " + plan.typed + " "
        let original = String(onScreen.suffix(typed.count))
        // TextEdit can capitalize the first letter after the key was captured. Preserve its case
        // and require every remaining character (including whitespace) to match exactly.
        let capitalized = original != typed
        if capitalized {
            guard let first = typed.first, original == first.uppercased() + typed.dropFirst() else { return nil }
        }

        let before = onScreen.dropLast(original.count)
        if let boundary = before.last, !boundary.isWhitespace { return nil }
        // A label in the source language ("plan b", "vitamin c") belongs with its left neighbour.
        let left = before.reversed().drop(while: { $0 == " " }).prefix(while: { $0.isLetter })
        if !left.isEmpty, scriptMatchesLang(String(left.reversed()), lang: source) { return nil }
        var converted: [String] = []
        for letter in pending {
            guard let flipped = map[letter], ShortWords.isSingle(flipped, lang: target),
                  !LayoutPolicy.isNeverWord(String(letter), String(flipped), never: never)
            else { return nil }
            converted.append(capitalized && converted.isEmpty ? flipped.uppercased() : String(flipped))
        }
        let produced = converted.joined(separator: " ") + " " + plan.converted + " "
        guard !LayoutPolicy.isNeverWord(String(original.dropLast()), String(produced.dropLast()), never: never)
        else { return nil }
        return (original, produced)
    }

    /// A word typed partly in each layout of the pair («привtn»): its two whole-word readings,
    /// the likelier first. `inA`/`inB` are the same keys rendered in each layout. nil when
    /// `typed` already is one of them.
    @MainActor
    static func mixedReadings(typed: String, inA: String, inB: String,
                              aLang: String, bLang: String) -> (first: String, second: String, firstIsA: Bool)? {
        guard typed != inA, typed != inB, inA.count == typed.count, inB.count == typed.count else { return nil }
        let aValid = isDictionaryWord(inA, lang: aLang), bValid = isDictionaryWord(inB, lang: bLang)
        let firstIsA: Bool
        if aValid != bValid {
            firstIsA = aValid
        } else {
            // No dictionary verdict: the layout the word was started in.
            firstIsA = zip(typed, zip(inA, inB)).first { $0.1.0 != $0.1.1 }.map { $0.0 == $0.1.0 } ?? true
        }
        return firstIsA ? (inA, inB, true) : (inB, inA, false)
    }

    @MainActor
    private static func isDictionaryWord(_ s: String, lang: String) -> Bool {
        let core = String(s.prefix(LayoutDetector.splitTrailingPunctuation(s).coreLength))
        return core.count >= 2 && core.allSatisfy(\.isLetter) && SystemDictionary.isAvailable(lang)
            && SystemDictionary.isValidWord(core.lowercased(), lang: lang)
    }

    /// A selection the smart pass left untouched is flipped whole: selecting and pressing the
    /// hotkey is an explicit request, and pressing it again undoes. nil when nothing flips.
    /// `map` must be the bidirectional character map of the pair.
    static func selectionResult(smart: String, selection: String, map: [Character: Character]) -> String? {
        if smart != selection { return smart }
        let forced = LayoutMapper.convertText(selection, map: map)
        return forced == selection ? nil : forced
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
