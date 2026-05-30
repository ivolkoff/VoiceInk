## Context

VoiceInk's post-transcription pipeline is `transcribe → filter → format → word-replace → prompt-detect → AI enhance → paste → auto-send` (`TranscriptionPipeline.swift`). The valuable tail of that pipeline already exists as reusable, input-agnostic pieces:

- `SelectedTextService.fetchSelectedText()` — captures the frontmost app's selection via `SelectedTextKit` (accessibility + menu-action strategies). Already used to gather selected-text context for enhancement (`AIEnhancementService.swift:148`).
- `AIEnhancementService.enhance(_ text:) async throws -> (String, TimeInterval, String?)` (line 383) — runs arbitrary input text through the active prompt / Power Mode config via `LLMkit`.
- `CursorPaster.startPasteAtCursor(_ text:)` — pastes text at the cursor; with a live selection this replaces it. Handles clipboard save/restore.
- Global hotkeys: `ShortcutAction` enum + `ShortcutMonitor`/`RecordingShortcutManager` dispatch; `globalUtilityActions` lists no-recorder utility actions.

So the feature is **composition, not new infrastructure**: a hotkey that feeds the current selection into the existing enhance→paste tail. The user framed it exactly this way — "the pipeline continues, but instead of audio-derived text, the selected text."

Constraints: must not record audio, must not clobber the original text on failure, and must guard against accidentally sending huge documents (the select-all fallback makes this a real risk).

## Goals / Non-Goals

**Goals:**
- One global hotkey: selection (or select-all fallback) → enhance with the configured prompt → paste over selection.
- Reuse `SelectedTextService`, `AIEnhancementService.enhance(_:)`, `CursorPaster` unchanged in behavior.
- Configurable max-input-length guard with a sensible default.
- Works with any configured `CustomPrompt`/Power Mode (summarizer is just one).

**Non-Goals:**
- Audio/recording involvement.
- A bespoke summarizer prompt or prompt-authoring UI (existing prompt system is used).
- Streaming/incremental paste, chained multi-prompt flows, per-app prompt routing.
- Reworking the transcription pipeline.

## Decisions

### Decision 1: A thin orchestrator service, not pipeline reuse
Add a small `SelectedTextEnhancementService` (MainActor) that sequences: capture → length-guard → `enhance` → paste. Rationale: `TranscriptionPipeline` is built around an audio `Transcription` model and persistence; threading a non-audio path through it would add branching and coupling. A dedicated orchestrator calls the same leaf services directly, keeping both paths simple. Alternative (parameterize `TranscriptionPipeline` with a text source) — rejected as over-coupled.

### Decision 2: Reuse the active enhancement config (parity with voice)
The action uses `AIEnhancementService`'s current `selectedPromptId`/Power Mode — the same config the voice flow uses — rather than introducing a separate "selection prompt" setting. Rationale: matches the user's mental model ("same pipeline, different input"), zero new prompt config, and any prompt can be made active. The hotkey is a single global action (in `globalUtilityActions`). Alternative (bind a specific prompt per hotkey / numbered slots) — deferred; can be layered on later without changing this contract.

### Decision 3: Select-all fallback via the focused field, guarded by the length limit
When `fetchSelectedText()` returns nil/empty, synthesize a select-all in the focused field (or use `SelectedTextKit`'s capability) and re-capture. Because select-all can grab an entire large document, the **max-length guard is the safety valve**: if the captured text exceeds the configured limit, abort before any AI call and notify. Rationale: gives the convenient "just summarize everything" behavior the user asked for, without runaway requests/cost. Default limit chosen to comfortably cover normal paragraphs/emails while blocking whole-document accidents (e.g. a few thousand characters), stored in `UserDefaults`.

### Decision 4: Non-destructive on failure
Capture the original selection/clipboard state and only paste on success. On "not configured", "no text", "too large", or AI error → no paste, surface a brief notification. Rationale: the action overwrites user content in third-party apps; a failed run must never destroy the source text. `CursorPaster` already restores the clipboard; the orchestrator adds the "don't paste on failure" guard.

### Decision 5: Reuse the global shortcut machinery
Add a `ShortcutAction` case, include it in `globalUtilityActions`, register/dispatch through the existing `ShortcutMonitor`/`RecordingShortcutManager`. Rationale: consistent UX with existing utility shortcuts (paste-last, retry, etc.) and free settings integration.

## Risks / Trade-offs

- **Select-all clobbers/moves content in non-text apps** → Only trigger select-all when an editable text element is focused; if capture still yields nothing usable, abort with a notice rather than guessing.
- **Accidental huge input (cost/latency)** → Max-length guard aborts before the AI call; default tuned conservatively; user-adjustable.
- **Paste replaces the wrong thing if focus changed between capture and paste** → Keep the capture→paste window tight; rely on `CursorPaster`'s existing paste-at-cursor semantics; document that focus must remain on the target field.
- **Accessibility permission required** → `SelectedTextService`/select-all need Accessibility access; if denied, surface the same permission guidance the app already uses.
- **Selection capture flakiness across apps** → `SelectedTextKit` uses accessibility + menu-action strategies already; failures degrade to the "no text found" notice, never a wrong paste.
- **Clipboard contamination** → Reuse `CursorPaster`'s save/restore so the user's clipboard is preserved.

## Migration Plan

1. Add the `ShortcutAction` case + storage/display names; include in `globalUtilityActions`.
2. Add the max-input-length `UserDefaults` setting (with default) and its settings UI control.
3. Add select-all fallback to `SelectedTextService`.
4. Implement `SelectedTextEnhancementService` (capture → guard → enhance → paste, non-destructive).
5. Wire dispatch in `ShortcutMonitor`/`RecordingShortcutManager`; add notifications for the abort/error cases.
6. Manual verification across a few target apps (notes, browser field, editor).
7. Rollback: feature is additive — reverting the commit removes the action and setting; no data/state migration.

## Open Questions

- Default max-input length value (characters) — propose a conservative default (~4000) and let the user raise it.
- Should select-all be attempted in *all* focused contexts or only when an editable AX text element is detected? Default: only editable text elements, to avoid surprising behavior.
- Should there be a brief visual indicator (e.g. the notch/menu-bar) while the AI request is in flight, mirroring the recorder? Default: a lightweight status/notification, not the full recorder UI.
