## 1. Setting & default

- [x] 1.1 Register `MatchLanguageToKeyboardLayout = true` in `AppDefaults.swift`
- [x] 1.2 Confirm no existing key collides with `MatchLanguageToKeyboardLayout`

## 2. Keyboard layout language detection

- [x] 2.1 Add `KeyboardLayoutLanguageService` reading `TISCopyCurrentKeyboardInputSource()` + `TISGetInputSourceProperty(_, kTISPropertyInputSourceLanguages)` on the main thread
- [x] 2.2 Normalize the primary code to a base language code (strip region, lowercase), return `nil` on any failure
- [x] 2.3 Unit-test normalization for `en`, `en-US`, `ru`, `ru-RU`, and empty/nil inputs (authored + compiles; runtime blocked — app test-host crashes at bootstrap in this env, pre-existing)

## 3. Shared language resolver

- [x] 3.1 Add `TranscriptionLanguagePreference.layoutOverride(for: model)`: toggle OFF → `nil` (use `SelectedLanguage`); toggle ON → layout code if supported by model, else `nil` (BCP-47 models keep manual region when in the layout family)
- [x] 3.2 Ensure the resolver never writes `SelectedLanguage` (transient only)

## 4. Route engines through the resolver

- [x] 4.1 Route `LibWhisper`/`WhisperTranscriptionService` (resolve in service, pass into `fullTranscribe(samples:language:)`)
- [x] 4.2 Route `NativeAppleTranscriptionService.swift`
- [x] 4.3 Route `CloudTranscriptionService.swift` (`selectedLanguage(for:)`)
- [x] 4.4 Route `StreamingTranscriptionService.swift`
- [x] 4.5 Route `FluidAudioTranscriptionService.swift`
- [x] 4.6 Route `OpenAICompatibleTranscriptionService.swift` (`buildRequestBody(audioURL:model:boundary:)`)
- [x] 4.7 Grep the repo confirms remaining `forKey: "SelectedLanguage"` reads are only resolver fallbacks, the model-change validation gate, and the whisper prompt selector (see note)

## 5. Settings UI

- [x] 5.1 Add the "Match transcription language to keyboard layout" toggle (`@AppStorage("MatchLanguageToKeyboardLayout")`) to `LanguageSelectionView.swift`
- [x] 5.2 When ON + multilingual model, label the manual picker as the fallback / layout-driven; keep picker functional
- [x] 5.3 English-only and Gemini-autodetect models unaffected (english-only supports only `en` → layout falls back; gemini language UI stays disabled)

## 6. Verify

- [x] 6.1 Build the project — no compile errors (BUILD SUCCEEDED)
- [ ] 6.2 Manual: toggle ON, English layout → record English speech → transcribed as `en`
- [ ] 6.3 Manual: toggle ON, Russian layout → record Russian speech → transcribed as `ru`
- [ ] 6.4 Manual: toggle ON, layout language unsupported by model → falls back to `SelectedLanguage`
- [ ] 6.5 Manual: toggle OFF → behaves exactly as today (manual picker only)
- [ ] 6.6 Manual: confirm stored `SelectedLanguage` is unchanged after a layout-driven recording

## Notes / follow-up

- `WhisperPrompt.updateTranscriptionPrompt()` still builds the language-specific whisper initial-prompt from `SelectedLanguage`, not the resolved layout language. When the layout override differs from `SelectedLanguage`, the whisper vocab-hint prompt may be in the wrong language (transcription language itself is correct). Out of scope here; consider resolving the prompt language alongside the transcription language in a follow-up.
