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
        return supportedCode(forLayoutLanguage: layout, model: model)
    }

    /// The language a normal (non-overridden) transcription of `model` resolves to — the same
    /// `layoutOverride ?? SelectedLanguage` resolution the services use. Stored on a record so the
    /// UI can show which language it was transcribed in.
    static func resolvedLanguage(for model: any TranscriptionModel) -> String? {
        layoutOverride(for: model) ?? UserDefaults.standard.string(forKey: "SelectedLanguage")
    }

    /// Resolves a layout base language (e.g. "en", "ru") to a concrete code the model
    /// supports: an exact base match, else a deterministic BCP-47 variant ("en" -> "en-US"
    /// for Apple native), else `nil` when the model does not support that language.
    ///
    /// Unlike `layoutOverride`, this ignores the `MatchLanguageToKeyboardLayout` preference and
    /// never returns "defer" — callers that force a language (the re-transcribe hotkey) need a
    /// concrete answer.
    static func supportedCode(forLayoutLanguage layout: String, model: any TranscriptionModel) -> String? {
        let supported = TranscriptionLanguageSupport.languages(for: model)
        if supported[layout] != nil {
            return layout
        }
        let variants = supported.keys
            .filter { $0.lowercased() == layout || $0.lowercased().hasPrefix(layout + "-") }
        // Prefer the "-US" region (e.g. "en" -> "en-US") over the alphabetical first ("en-AU").
        return variants.first(where: { $0.lowercased() == "\(layout)-us" }) ?? variants.sorted().first
    }
}
