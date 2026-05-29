## Why

VoiceInk can already turn speech into AI-enhanced text and paste it into the active app (transcribe → enhance → paste). The exact same enhancement value — running selected text through a configured prompt (e.g. a summarizer) and writing the result back — is unavailable for text the user *already has on screen*. Users must re-dictate or copy-paste into a separate tool. A global hotkey that feeds the **current selection** into the existing enhancement pipeline closes this gap and reuses the app's most valuable machinery for a non-voice input.

## What Changes

- Add a global keyboard shortcut action that runs the AI-enhancement-and-paste pipeline on **selected text** instead of on a transcription — no recording, no audio.
- On trigger: capture the current selection via the existing `SelectedTextService`. If nothing is selected, fall back to selecting all text in the focused field and using that.
- Feed the captured text through the **same** enhancement path used after transcription (`AIEnhancementService.enhance(_:)` with the active prompt / Power Mode config — the "summarizer with preset params").
- Paste the AI result **over the selection** via `CursorPaster`, replacing the original text in the active app.
- Add a configurable **maximum input length** (character limit) that aborts the action (with user feedback) when the captured text is too large, so the hotkey can't accidentally fire on a huge document.
- Generalized scope: the action works with **any** configured `CustomPrompt`/Power Mode, not just a summarizer.

This change is **non-BREAKING**: it adds a new optional shortcut and setting; existing voice/transcription behavior is unchanged.

## Capabilities

### New Capabilities
- `selected-text-enhancement`: A global hotkey captures the user's current text selection (with a select-all fallback), runs it through the existing AI enhancement pipeline using the configured prompt, and pastes the result over the selection — guarded by a configurable maximum input length.

### Modified Capabilities
<!-- None — openspec/specs/ has no existing committed capability specs; transcription enhancement is reused, not respecified. -->

## Impact

- **Shortcuts**: `VoiceInk/Shortcuts/ShortcutAction.swift` (new action case + storage/display names, add to global utility actions), `ShortcutMonitor.swift` / `RecordingShortcutManager.swift` (dispatch the new action).
- **New orchestrator**: a small service (e.g. `SelectedTextEnhancementService`) that wires capture → length-guard → enhance → paste, reusing `SelectedTextService`, `AIEnhancementService`, and `CursorPaster`.
- **Selected-text capture**: `VoiceInk/Services/SelectedTextService.swift` — add a select-all fallback when no selection exists.
- **Settings**: shortcut-binding UI plus a new "max input length" setting (UserDefaults key, surfaced in enhancement/shortcut settings).
- **Reused as-is**: `AIEnhancementService.enhance(_:)`, `CursorPaster.startPasteAtCursor(_:)`, `CustomPrompt`/Power Mode config — no behavior change to the voice pipeline.
- **No new third-party dependencies** (SelectedTextKit + LLMkit already vendored).
- **Out of scope**: a dedicated summarizer prompt UI (any existing prompt works), streaming/partial paste, and multi-step chained prompts.
