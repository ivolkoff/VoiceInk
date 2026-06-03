## 1. Shortcut action

- [x] 1.1 Add a new `ShortcutAction` case (e.g. `.enhanceSelectedText`) with `storageName` and `displayName` in `VoiceInk/Shortcuts/ShortcutAction.swift`
- [x] 1.2 Add the new action to `globalUtilityActions` (and `legacyKeyboardShortcutActions` if needed for migration)
- [x] 1.3 Register and dispatch the action in `ShortcutMonitor.swift` / `RecordingShortcutManager.swift` to call the new orchestrator

## 2. Settings: max input length

- [x] 2.1 Add a `UserDefaults` key + sensible default for the maximum input length (characters)
- [x] 2.2 Surface the max-length setting in the enhancement/shortcut settings UI (and the shortcut binding row)

## 3. Selected-text capture

- [x] 3.1 Add a select-all fallback to `SelectedTextService` (used only when an editable text element is focused) and return captured text or nil
- [x] 3.2 Ensure capture distinguishes "has selection", "selected all via fallback", and "no usable text"

## 4. Orchestrator service

- [x] 4.1 Create `SelectedTextEnhancementService` (MainActor) sequencing: capture → length-guard → enhance → paste
- [x] 4.2 Guard: abort + notify when AI enhancement is disabled/unconfigured (reuse `AIEnhancementService.isConfigured`/`isEnhancementEnabled`)
- [x] 4.3 Guard: abort + notify when captured text exceeds the configured max length (before any AI call)
- [x] 4.4 Guard: abort + notify when no usable text is found
- [x] 4.5 Run enhancement via `AIEnhancementService.enhance(_:)` using the active prompt / Power Mode
- [x] 4.6 On success, paste the result over the selection via `CursorPaster.startPasteAtCursor(_:)`; on failure, leave original text untouched and notify

## 5. Verification

- [x] 5.1 With text selected in a target app, pressing the shortcut replaces the selection with the AI result
- [x] 5.2 With nothing selected in an editable field, select-all fallback captures the field and enhances it
- [x] 5.3 Input exceeding the max length aborts with a notice and no AI call / no paste
- [x] 5.4 Enhancement disabled/unconfigured shows the proper notice and does not paste
- [x] 5.5 Simulated AI failure leaves the original selection intact and notifies the user
- [x] 5.6 Clipboard contents are preserved after the action (save/restore works)
- [x] 5.7 Voice/transcription flow is unaffected (regression check)
