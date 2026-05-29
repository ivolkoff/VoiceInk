## 1. Shortcut action

- [ ] 1.1 Add a new `ShortcutAction` case (e.g. `.enhanceSelectedText`) with `storageName` and `displayName` in `VoiceInk/Shortcuts/ShortcutAction.swift`
- [ ] 1.2 Add the new action to `globalUtilityActions` (and `legacyKeyboardShortcutActions` if needed for migration)
- [ ] 1.3 Register and dispatch the action in `ShortcutMonitor.swift` / `RecordingShortcutManager.swift` to call the new orchestrator

## 2. Settings: max input length

- [ ] 2.1 Add a `UserDefaults` key + sensible default for the maximum input length (characters)
- [ ] 2.2 Surface the max-length setting in the enhancement/shortcut settings UI (and the shortcut binding row)

## 3. Selected-text capture

- [ ] 3.1 Add a select-all fallback to `SelectedTextService` (used only when an editable text element is focused) and return captured text or nil
- [ ] 3.2 Ensure capture distinguishes "has selection", "selected all via fallback", and "no usable text"

## 4. Orchestrator service

- [ ] 4.1 Create `SelectedTextEnhancementService` (MainActor) sequencing: capture → length-guard → enhance → paste
- [ ] 4.2 Guard: abort + notify when AI enhancement is disabled/unconfigured (reuse `AIEnhancementService.isConfigured`/`isEnhancementEnabled`)
- [ ] 4.3 Guard: abort + notify when captured text exceeds the configured max length (before any AI call)
- [ ] 4.4 Guard: abort + notify when no usable text is found
- [ ] 4.5 Run enhancement via `AIEnhancementService.enhance(_:)` using the active prompt / Power Mode
- [ ] 4.6 On success, paste the result over the selection via `CursorPaster.startPasteAtCursor(_:)`; on failure, leave original text untouched and notify

## 5. Verification

- [ ] 5.1 With text selected in a target app, pressing the shortcut replaces the selection with the AI result
- [ ] 5.2 With nothing selected in an editable field, select-all fallback captures the field and enhances it
- [ ] 5.3 Input exceeding the max length aborts with a notice and no AI call / no paste
- [ ] 5.4 Enhancement disabled/unconfigured shows the proper notice and does not paste
- [ ] 5.5 Simulated AI failure leaves the original selection intact and notifies the user
- [ ] 5.6 Clipboard contents are preserved after the action (save/restore works)
- [ ] 5.7 Voice/transcription flow is unaffected (regression check)
