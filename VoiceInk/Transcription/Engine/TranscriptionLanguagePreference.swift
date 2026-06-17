import Foundation

/// Resolves a layout-driven transcription language override.
///
/// When "Match transcription language to keyboard layout" is enabled, the current
/// keyboard layout language is used for transcription — provided the active model
/// supports it. Otherwise this returns `nil` and callers fall back to the manually
/// selected `SelectedLanguage`. The stored `SelectedLanguage` is never mutated.
enum TranscriptionLanguagePreference {
    static let matchKeyboardLayoutKey = "MatchLanguageToKeyboardLayout"

    /// Returns a transcription language code derived from the current keyboard layout,
    /// or `nil` to defer to the manually selected `SelectedLanguage`.
    static func layoutOverride(for model: any TranscriptionModel) -> String? {
        guard UserDefaults.standard.bool(forKey: matchKeyboardLayoutKey) else { return nil }
        guard let layout = KeyboardLayoutLanguageService.currentLanguageCode() else { return nil }

        let supported = TranscriptionLanguageSupport.languages(for: model)

        // Exact base-code match (whisper / cloud / fluid use base codes like "en", "ru").
        if supported[layout] != nil {
            return layout
        }

        // BCP-47 models (e.g. Apple native: "en-US"). Keep the user's manual region
        // choice when it already belongs to the layout language family.
        let manual = UserDefaults.standard.string(forKey: "SelectedLanguage")?.lowercased()
        if let manual, manual == layout || manual.hasPrefix(layout + "-"),
           supported.keys.contains(where: { $0.lowercased() == manual }) {
            return nil
        }

        // Otherwise pick a deterministic supported variant of the layout language.
        if let variant = supported.keys
            .filter({ $0.lowercased() == layout || $0.lowercased().hasPrefix(layout + "-") })
            .sorted()
            .first {
            return variant
        }

        // Layout language not supported by this model → defer to manual selection.
        return nil
    }
}
