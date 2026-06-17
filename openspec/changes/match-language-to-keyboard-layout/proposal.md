## Why

Users who switch keyboard layouts to type in a given language expect dictation to recognize that same language, but today the transcription language is a separate manual setting (`SelectedLanguage`). Bilingual users must change the language picker by hand every time they switch context (e.g. English layout → English speech, Russian layout → Russian speech), which is error-prone and easy to forget — recordings come back transcribed in the wrong language.

## What Changes

- Add a setting **"Match transcription language to keyboard layout"** (toggle, default **ON**).
- When enabled, at the start of each recording VoiceInk reads the current macOS keyboard input source language and uses it as the transcription language for that recording.
- The detected layout language is mapped to a language the active model supports; if the model does not support it (or no layout language can be determined), VoiceInk falls back to the manually selected `SelectedLanguage`.
- The manual language picker stays as the fallback and is shown as overridden/informational when the toggle is ON; turning the toggle OFF restores fully manual behavior (current behavior).
- The user's stored `SelectedLanguage` is NOT mutated by detection — the layout language is applied transiently per recording.

## Capabilities

### New Capabilities
- `keyboard-layout-language`: Detect the current keyboard input source language at recording start and resolve the transcription language from it (with model-support validation and fallback), gated by a default-on toggle.

### Modified Capabilities
<!-- No existing capability specs change at the requirement level; transcription engines consume the resolved language through a shared resolver. -->

## Impact

- **New code:**
  - `KeyboardLayoutLanguageService` — wraps `TISCopyCurrentKeyboardInputSource()` + `kTISPropertyInputSourceLanguages` to return the current layout's language code.
  - A shared language resolver that applies the toggle + layout detection + model validation, returning the effective code.
- **Modified code:**
  - All transcription engines that currently read `UserDefaults.standard.string(forKey: "SelectedLanguage")` directly route through the shared resolver instead: `LibWhisper.swift`, `NativeAppleTranscriptionService.swift`, `CloudTranscriptionService.swift`, `StreamingTranscriptionService.swift`, `FluidAudioTranscriptionService.swift`, `OpenAICompatibleTranscriptionService.swift`.
  - Language settings UI (`LanguageSelectionView.swift`) gains the toggle and an indicator that the picker is layout-driven.
  - `AppDefaults.swift` registers `MatchLanguageToKeyboardLayout = true`.
- **Reused:** `TranscriptionLanguageSupport.validLanguageOrFallback(_:for:)` for model-support validation; existing TIS usage patterns in `CursorPaster.swift` / `Shortcut.swift`.
- **Dependencies:** None new (Carbon `TISCopyCurrentKeyboardInputSource` already linked).
- **Permissions:** None new.
