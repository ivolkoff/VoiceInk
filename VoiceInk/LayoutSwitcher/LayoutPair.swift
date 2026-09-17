import Carbon

/// The two keyboard layouts the switcher converts between. TIS calls that read the current
/// source are main-thread-only (see KeyboardLayoutLanguageService), hence the @MainActor marks.
/// Port of RuSwitcher LayoutSwitcher.swift (MIT, © Rashns).
enum LayoutPair {
    struct Resolved {
        let current: TISInputSource
        let other: TISInputSource
        let currentLang: String
        let otherLang: String
        let currentData: Data
        let otherData: Data
    }

    /// Enabled keyboard layouts (input methods like Japanese/Chinese are excluded: nothing to convert).
    static func enabledLayouts() -> [TISInputSource] {
        list(includeAllInstalled: false)
    }

    /// Every installed layout, enabled or not. Tests use it so they don't depend on the user's set.
    static func allLayouts() -> [TISInputSource] {
        list(includeAllInstalled: true)
    }

    private static func list(includeAllInstalled: Bool) -> [TISInputSource] {
        let conditions: CFDictionary = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as Any,
        ] as CFDictionary
        return TISCreateInputSourceList(conditions, includeAllInstalled)?.takeRetainedValue() as? [TISInputSource] ?? []
    }

    static func sourceID(_ source: TISInputSource) -> String {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    static func localizedName(_ source: TISInputSource) -> String {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return sourceID(source) }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    static func layoutData(_ source: TISInputSource) -> Data? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    }

    /// BCP-47 language of a layout. Third-party `.keylayout` files often declare no language
    /// (macOS then returns "" first), so fall back to the script of what the home row types.
    static func languageCode(_ source: TISInputSource) -> String? {
        if let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
           let langs = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String],
           let first = langs.first, !first.isEmpty {
            return first
        }
        guard let data = layoutData(source) else { return nil }
        for keyCode: UInt16 in [0, 1, 2, 3, 38, 40, 37] {
            guard let scalar = LayoutMapper.character(keyCode: keyCode, layout: data, shift: false, caps: false)?
                .unicodeScalars.first, scalar.properties.isAlphabetic else { continue }
            switch scalar.value {
            case 0x0400...0x04FF: return "ru"
            case 0x0041...0x005A, 0x0061...0x007A: return "en"
            case 0x0370...0x03FF: return "el"
            case 0x0530...0x058F: return "hy"
            case 0x10A0...0x10FF: return "ka"
            default: continue
            }
        }
        return nil
    }

    @MainActor
    static func current() -> TISInputSource? {
        TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }

    /// Enable only when actually disabled: enabling an already-enabled third-party layout
    /// triggers a system security prompt on every switch.
    static func select(_ source: TISInputSource) {
        if let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled),
           Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue() != kCFBooleanTrue {
            TISEnableInputSource(source)
        }
        TISSelectInputSource(source)
    }

    /// The Latin layout and the first other one. nil when fewer than two layouts are available.
    static func autoDetectIDs(from layouts: [TISInputSource]) -> (String, String)? {
        let first = layouts.first { languageCode($0) == "en" }
            ?? layouts.first { layout in ["ABC", "US", "British"].contains { sourceID(layout).contains($0) } }
            ?? layouts.first
        guard let first else { return nil }
        let firstID = sourceID(first)
        guard let second = layouts.first(where: { sourceID($0) != firstID }) else { return nil }
        return (firstID, sourceID(second))
    }

    /// nil when the current layout is not one of the pair — then nothing is converted.
    @MainActor
    static func resolve(layout1ID: String, layout2ID: String) -> Resolved? {
        let layouts = enabledLayouts()
        var id1 = layout1ID, id2 = layout2ID
        if id1.isEmpty || id2.isEmpty {
            guard let auto = autoDetectIDs(from: layouts) else { return nil }
            if id1.isEmpty { id1 = auto.0 == id2 ? auto.1 : auto.0 }
            if id2.isEmpty { id2 = auto.1 == id1 ? auto.0 : auto.1 }
        }
        guard let current = current() else { return nil }
        let currentID = sourceID(current)
        let otherID: String
        if currentID == id1 { otherID = id2 } else if currentID == id2 { otherID = id1 } else { return nil }
        guard let other = layouts.first(where: { sourceID($0) == otherID }),
              let currentLang = languageCode(current), let otherLang = languageCode(other),
              let currentData = layoutData(current), let otherData = layoutData(other) else { return nil }
        return Resolved(current: current, other: other, currentLang: currentLang, otherLang: otherLang,
                        currentData: currentData, otherData: otherData)
    }
}
