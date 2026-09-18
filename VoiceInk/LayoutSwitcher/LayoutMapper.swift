import Carbon

/// One typed key rendered in both layouts of the pair.
struct KeyChars: Equatable {
    let original: Character
    let converted: Character
}

/// Key code → character in a given layout through UCKeyTranslate. Pure over the layout's
/// `uchr` data, so it can be tested against any installed layout.
/// Port of RuSwitcher DynamicKeyMapping.swift (MIT, © Rashns).
enum LayoutMapper {
    /// Main key block (letters, digits, punctuation). Space/Return/Tab are inside this range;
    /// the engine handles them before asking the mapper.
    static let typeableKeyCodes: ClosedRange<UInt16> = 0...50

    static func character(keyCode: UInt16, layout: Data, shift: Bool, caps: Bool) -> Character? {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layout.withUnsafeBytes { raw -> OSStatus in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(ptr, keyCode, UInt16(kUCKeyActionDown), modifiers(shift: shift, caps: caps),
                                  UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysMask),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        guard s.count == 1, let c = s.first, c.isLetter || c.isNumber || c.isPunctuation || c.isSymbol else { return nil }
        return c
    }

    /// Dead key: UCKeyTranslate with dead keys enabled returns no character and a pending state.
    /// A word containing one has more keys than screen characters, so it is never converted.
    static func isDeadKey(keyCode: UInt16, layout: Data, shift: Bool, caps: Bool) -> Bool {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layout.withUnsafeBytes { raw -> OSStatus in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(ptr, keyCode, UInt16(kUCKeyActionDown), modifiers(shift: shift, caps: caps),
                                  UInt32(LMGetKbdType()), 0, &deadKeyState, chars.count, &length, &chars)
        }
        return status == noErr && length == 0 && deadKeyState != 0
    }

    /// The on-screen word from a run of keys. Each key's character was captured at type time,
    /// but TIS occasionally returns no layout data then, leaving `char` nil; here we refill those
    /// from the current layout (the same one the just-typed word came from), then the pair's two
    /// layouts. The manual trigger must never bail just because one key failed to resolve at type
    /// time — that was the intermittent "nothing to convert".
    static func reconstruct(_ keys: [TypedKey], currentData: Data?, pairA: Data, pairB: Data) -> String {
        String(keys.map { key -> Character in
            if let c = key.char { return c }
            for data in [currentData, pairA, pairB].compactMap({ $0 }) {
                if let c = character(keyCode: key.keyCode, layout: data, shift: key.shift, caps: key.caps) { return c }
            }
            return " "   // unreachable for a typeable key: at least one layout renders it
        })
    }

    /// Per-key characters in both layouts; nil when a key has no character in either layout or
    /// is a dead key in the source layout.
    static func convert(_ keys: [TypedKey], from source: Data, to target: Data) -> [KeyChars]? {
        var out: [KeyChars] = []
        out.reserveCapacity(keys.count)
        for k in keys {
            if isDeadKey(keyCode: k.keyCode, layout: source, shift: k.shift, caps: k.caps) { return nil }
            guard let o = character(keyCode: k.keyCode, layout: source, shift: k.shift, caps: k.caps),
                  let c = character(keyCode: k.keyCode, layout: target, shift: k.shift, caps: k.caps) else { return nil }
            out.append(KeyChars(original: o, converted: c))
        }
        return out
    }

    /// source→target over the main block. Unshifted first: on layouts without case the shifted
    /// character equals the plain one and must not overwrite the lowercase mapping.
    static func characterMap(from source: Data, to target: Data) -> [Character: Character] {
        var map: [Character: Character] = [:]
        for keyCode in typeableKeyCodes {
            for shift in [false, true] {
                guard let s = character(keyCode: keyCode, layout: source, shift: shift, caps: false),
                      let t = character(keyCode: keyCode, layout: target, shift: shift, caps: false),
                      s != t, map[s] == nil else { continue }
                map[s] = t
            }
        }
        return map
    }

    /// Both directions merged. On shared punctuation keys («.» is «ю» one way and «/» the other)
    /// a letter wins: flipping script matters more than flipping a symbol.
    static func bidirectionalMap(_ a: Data, _ b: Data) -> [Character: Character] {
        var map = characterMap(from: a, to: b)
        for (k, v) in characterMap(from: b, to: a) {
            if let existing = map[k] {
                if !existing.isLetter && v.isLetter { map[k] = v }
            } else {
                map[k] = v
            }
        }
        return map
    }

    /// Flips every mapped character. Decomposed input is precomposed first; text with combining
    /// marks is returned untouched — a half-converted mix is worse than nothing.
    static func convertText(_ input: String, map: [Character: Character]) -> String {
        let text = input.precomposedStringWithCanonicalMapping
        if input.unicodeScalars.contains(where: { $0.properties.generalCategory == .nonspacingMark })
            || text.unicodeScalars.contains(where: { $0.properties.generalCategory == .nonspacingMark }) {
            return input
        }
        return String(text.map { map[$0] ?? $0 })
    }

    private static func modifiers(shift: Bool, caps: Bool) -> UInt32 {
        var mods: UInt32 = shift ? (UInt32(shiftKey >> 8) & 0xFF) : 0
        if caps { mods |= UInt32(alphaLock >> 8) & 0xFF }
        return mods
    }
}
