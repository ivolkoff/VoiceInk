import Foundation

/// Per-word conversion of a selection between a Latin-script and a Cyrillic-script layout: a
/// word flips only when it is garbage in its own script and a real word after the flip, so
/// «iPhone стоит» survives while «ghbdtn ьшк» is fixed in both directions. Unresolved short
/// tokens follow the direction their neighbours flipped in.
/// Port of RuSwitcher SmartConvert.swift (MIT, © Rashns).
enum SmartConvert {
    private enum Script { case cyr, lat, other, mixed }
    private enum WordDecision { case keep, flip(String, Script), unresolved }

    private static let cyr1: Set<Character> = ["я", "в", "с", "к", "о", "у", "а", "и"]
    private static let lat1: Set<Character> = ["a", "i"]

    @MainActor
    static func selection(_ text: String, latLang: String, cyrLang: String, map: [Character: Character]) -> String {
        let toks = tokenize(text)
        var results = [String?](repeating: nil, count: toks.count)
        var pending: [Int] = []
        var flippedCyr = 0, flippedLat = 0

        for (i, tok) in toks.enumerated() {
            guard tok.isWord else { results[i] = tok.str; continue }
            if dominantScript(letterCore(tok.str)) == .mixed {
                // Mixed-script token: each run is judged on its own, dictionary-confirmed flips only.
                var out = ""
                for run in scriptRuns(tok.str) {
                    if case let .flip(s, toScript) = decideWord(run, latLang: latLang, cyrLang: cyrLang, map: map) {
                        out += s
                        if toScript == .cyr { flippedCyr += 1 } else if toScript == .lat { flippedLat += 1 }
                    } else {
                        out += run
                    }
                }
                results[i] = out
                continue
            }
            switch decideWord(tok.str, latLang: latLang, cyrLang: cyrLang, map: map) {
            case .keep:
                results[i] = tok.str
            case let .flip(s, toScript):
                results[i] = s
                if toScript == .cyr { flippedCyr += 1 } else if toScript == .lat { flippedLat += 1 }
            case .unresolved:
                pending.append(i)
            }
        }

        // Signal = direction of the words that actually flipped. Both directions or none ⇒ no signal.
        let target: Script? = (flippedCyr > 0 && flippedLat == 0) ? .cyr
            : (flippedLat > 0 && flippedCyr == 0) ? .lat : nil
        for i in pending { results[i] = signalFlip(toks[i].str, target: target, map: map) }
        return results.map { $0 ?? "" }.joined()
    }

    /// «делаghbdtn,» → ["дела", "ghbdtn,"]: new run where the letter script changes; non-letters stay with the current run.
    private static func scriptRuns(_ s: String) -> [String] {
        var runs: [String] = []
        var current = ""
        var currentScript: Script = .other
        for ch in s {
            let script = dominantScript(String(ch))
            if script != .other, currentScript != .other, script != currentScript {
                runs.append(current)
                current = ""
            }
            if script != .other { currentScript = script }
            current.append(ch)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    @MainActor
    private static func decideWord(_ w: String, latLang: String, cyrLang: String, map: [Character: Character]) -> WordDecision {
        let core = letterCore(w)
        let script = dominantScript(core)
        guard core.count >= 1, script == .cyr || script == .lat else { return .keep }
        if LayoutDetector.isAllCaps(core) || LayoutDetector.looksLikeCodeIdentifier(core) { return .keep }

        let wordLang = (script == .cyr) ? cyrLang : latLang
        let flipLang = (script == .cyr) ? latLang : cyrLang
        let flippedScript: Script = (script == .cyr) ? .lat : .cyr

        if core.count == 1 { return .unresolved }
        if core.count == 2 {
            if let cur = ShortWords.common(wordLang), cur.contains(core.lowercased()) { return .keep }
            let whole = LayoutMapper.convertText(w, map: map)
            let wc = letterCore(whole)
            if wc.count == 2, let oth = ShortWords.common(flipLang), oth.contains(wc.lowercased()) {
                return .flip(whole, flippedScript)
            }
            return .unresolved
        }

        if SystemDictionary.isValidWord(core.lowercased(), lang: wordLang) { return .keep }
        let whole = LayoutMapper.convertText(w, map: map)
        let wc = letterCore(whole)
        if wc.count >= 2, wc.allSatisfy({ $0.isLetter }), SystemDictionary.isValidWord(wc.lowercased(), lang: flipLang) {
            return .flip(whole, flippedScript)
        }
        let (body, suffix) = splitTrailingNonLetters(w)
        if !suffix.isEmpty, !body.isEmpty {
            let bflip = LayoutMapper.convertText(body, map: map)
            let bc = letterCore(bflip)
            if bc.count >= 2, bc.allSatisfy({ $0.isLetter }), SystemDictionary.isValidWord(bc.lowercased(), lang: flipLang) {
                return .flip(bflip + suffix, flippedScript)
            }
        }
        return .unresolved
    }

    /// Only 1–2 letter tokens follow the signal: longer unresolved words are brands/terms the
    /// dictionary didn't confirm, not garbage. Single letters must also be frequent words.
    private static func signalFlip(_ orig: String, target: Script?, map: [Character: Character]) -> String {
        guard let target else { return orig }
        var lead = "", trail = ""
        var chars = Array(orig)
        while let f = chars.first, !f.isLetter { lead.append(f); chars.removeFirst() }
        while let l = chars.last, !l.isLetter { trail = String(l) + trail; chars.removeLast() }
        let core = String(chars)
        guard !core.isEmpty, core.count <= 2, dominantScript(core) != target else { return orig }
        let flipped = LayoutMapper.convertText(core, map: map)
        if core.count == 1 {
            guard let fch = letterCore(flipped).first,
                  (target == .cyr ? cyr1 : lat1).contains(Character(fch.lowercased())) else { return orig }
        }
        return lead + flipped + trail
    }

    private static let cyrillicLangs: Set<String> = ["ru", "uk", "be", "bg", "sr", "mk", "kk", "ky", "mn", "tg"]
    private static let nonLatinLangs: Set<String> = ["he", "iw", "el", "hy", "ka", "ar", "fa", "yi"]

    static func isCyrillicLang(_ lang: String) -> Bool {
        cyrillicLangs.contains(String(lang.lowercased().prefix(2)))
    }

    static func isLatinLang(_ lang: String) -> Bool {
        let two = String(lang.lowercased().prefix(2))
        return !cyrillicLangs.contains(two) && !nonLatinLangs.contains(two)
    }

    private static func dominantScript(_ s: String) -> Script {
        var cyr = 0, lat = 0
        for u in s.unicodeScalars {
            if u.value >= 0x0400 && u.value <= 0x04FF { cyr += 1 }
            else if (u.value >= 0x41 && u.value <= 0x5A) || (u.value >= 0x61 && u.value <= 0x7A) { lat += 1 }
        }
        if cyr > 0 && lat > 0 { return .mixed }
        if cyr > 0 { return .cyr }
        if lat > 0 { return .lat }
        return .other
    }

    private static func letterCore(_ s: String) -> String {
        var chars = Array(s)
        while let f = chars.first, !f.isLetter { chars.removeFirst() }
        while let l = chars.last, !l.isLetter { chars.removeLast() }
        return String(chars)
    }

    private static func splitTrailingNonLetters(_ s: String) -> (body: String, suffix: String) {
        var body = Array(s); var suffix = ""
        while let l = body.last, !l.isLetter { suffix = String(l) + suffix; body.removeLast() }
        return (String(body), suffix)
    }

    /// Alternating word / whitespace runs; joining them back gives the input unchanged.
    private static func tokenize(_ s: String) -> [(isWord: Bool, str: String)] {
        var out: [(Bool, String)] = []
        var cur = ""
        var curWS: Bool?
        for ch in s {
            let ws = ch.isWhitespace
            if let w = curWS {
                if ws == w { cur.append(ch) } else { out.append((!w, cur)); cur = String(ch); curWS = ws }
            } else {
                curWS = ws; cur = String(ch)
            }
        }
        if let w = curWS, !cur.isEmpty { out.append((!w, cur)) }
        return out
    }
}
