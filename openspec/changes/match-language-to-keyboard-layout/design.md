## Context

Transcription language is stored in `UserDefaults` under `SelectedLanguage` (default `"en"`, see `AppDefaults.swift:29`). Every transcription engine reads this key independently at transcribe time and passes it to its backend:

- `LibWhisper.swift:38` → `params.language`
- `NativeAppleTranscriptionService.swift:63` → `SpeechTranscriber`
- `CloudTranscriptionService.swift:97`, `StreamingTranscriptionService.swift:134`, `FluidAudioTranscriptionService.swift:104`, `OpenAICompatibleTranscriptionService.swift:39`

`TranscriptionLanguageSupport.validLanguageOrFallback(_:for:)` (`LanguageDictionary.swift:27`) already validates a code against a model's supported languages and falls back. The macOS Text Input Source (TIS) API is already used in the repo (`CursorPaster.swift:154`, `Shortcut.swift:232`) via `TISCopyCurrentKeyboardInputSource()`, but never for `kTISPropertyInputSourceLanguages`.

Because each engine reads `SelectedLanguage` directly and at different moments, there is no single point that controls the effective language. This change introduces one.

## Goals / Non-Goals

**Goals:**
- At recording start, use the current keyboard layout's language for transcription when the toggle is ON.
- Validate the detected language against the active model and fall back gracefully.
- Single shared resolver so all six engines behave identically.
- Do not mutate the user's stored `SelectedLanguage`.

**Non-Goals:**
- No automatic switching of the keyboard layout itself.
- No per-app or per-language profiles.
- No change to how models are selected or downloaded.
- No new UI beyond the toggle + a layout-driven indicator.

## Decisions

### 1. Centralize language resolution behind one resolver

Add a single resolver (e.g. `TranscriptionLanguagePreference.resolved(for: model)`) that returns the effective language code. Each engine replaces its direct `UserDefaults.standard.string(forKey: "SelectedLanguage")` read with a call to the resolver, passing the active model so validation can run.

Resolution logic:
1. If `MatchLanguageToKeyboardLayout` is OFF → return `SelectedLanguage` (current behavior).
2. Else read the current layout language via `KeyboardLayoutLanguageService`.
3. If a code is found, run `validLanguageOrFallback(layoutCode, for: model)`; if the layout code is genuinely supported, return it; otherwise return `SelectedLanguage`.
4. If no layout code is found → return `SelectedLanguage`.

**Why over alternatives:** Temporarily writing `SelectedLanguage` and restoring it (option B) races with the async engines and risks leaving the wrong value persisted on crash. A transient resolver keeps the stored preference intact and is read at the same moment the engine already reads UserDefaults.

### 2. Capture the layout at recording start, not transcribe time

The keyboard layout reflects the user's intent at the moment they speak. The resolver reads the layout when the engine resolves the language (which happens as part of starting the recording/transcription flow), so a layout change after recording has begun does not retroactively change the language.

**Note:** TIS reads must run on the main thread; the service hops to main if needed.

### 3. Map layout → language via `kTISPropertyInputSourceLanguages`

`TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)` returns a `CFArray` of ISO language codes for the active input source; the first element is the primary language (e.g. `en`, `ru`, `de`). Normalize to the base language code (strip region, lowercased) before validation, since model language keys are base codes.

**Why over `kTISPropertyInputSourceID` string parsing:** the languages property is the documented, locale-correct source of the layout's language and avoids brittle string matching on input-source identifiers.

### 4. Toggle default ON, picker becomes the fallback

`MatchLanguageToKeyboardLayout` registered as `true` in `AppDefaults`. When ON, `LanguageSelectionView` shows the toggle and labels the manual picker as the fallback used when the layout language isn't supported. Turning it OFF returns to today's fully manual behavior. English-only and autodetect (Gemini) models are unaffected because the resolver still defers to model validation.

## Risks / Trade-offs

- **Layout language ≠ spoken language** (user has Russian layout but speaks English) → Mitigation: the toggle is discoverable and can be turned OFF; manual `SelectedLanguage` remains the fallback and the override is per-recording, not sticky.
- **Unsupported layout language on an English-only model** → Mitigation: `validLanguageOrFallback` keeps English; resolver returns `SelectedLanguage`/`en`.
- **TIS main-thread requirement / nil results in edge cases** → Mitigation: service returns `nil` on any failure and the resolver falls back to `SelectedLanguage`; no crash path.
- **Six engines must all route through the resolver** → Mitigation: mechanical change; a follow-up check greps for remaining direct `forKey: "SelectedLanguage"` reads to ensure none bypass the resolver.

## Migration Plan

No data migration. New default-on key registered at launch. Rollback = remove the toggle / force resolver to return `SelectedLanguage`.

## Open Questions

- Should the menu-bar language item also surface the live layout-detected language (read-only), or only the settings page? Default: settings page indicator only; revisit if users want live feedback.
