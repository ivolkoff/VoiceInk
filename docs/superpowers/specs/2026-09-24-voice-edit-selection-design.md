# Voice edit of the selection — design

Date: 2026-09-24.

## Problem

The user selects text in any app and dictates. Today the dictation replaces the
selection verbatim, or with the "Assistant" prompt switched on by hand, the
enhancement sees the selection as `<CURRENTLY_SELECTED_TEXT>` context, read only
after recording (`AIEnhancementService.swift:166-176`). The user wants the
dictation over a selection to act as an instruction for that text ("translate
to English", "make it shorter", "turn into a list") and to have the result
replace the selection, without switching prompts.

## Decisions (locked)

- **Trigger: automatic.** A non-empty selection at recording start turns the
  recording into a selection edit. No new shortcut.
- **AI decides instruction vs. content.** One request: if the dictation is an
  instruction about the selection, the model applies it; otherwise it returns
  the dictation verbatim, which then replaces the selection as today.
- **Own toggle**, independent of the "AI Enhancement" switch (the existing
  enhance-selected-text hotkey already bypasses that switch). Default on.
- **Capture via Accessibility at recording start** (approach A). No clipboard
  or menu-copy fallback: in apps that do not expose `AXSelectedText` (part of
  Electron) the recording stays a normal dictation.

## Flow

1. **Capture.** `VoiceInkEngine.toggleRecord`, start branch, next to
   `KeyboardLayoutLanguageService.captureCurrentLayout()` (focus still belongs
   to the target app): `SelectionEditService.capture()` reads
   `FocusedTextAccessibility.selectedText()` (AX, 0.5 s messaging timeout) and
   the frontmost app's bundle ID. It returns
   `SelectionEditContext { text, bundleID }` only when all hold:
   - `IsSelectionVoiceEditEnabled` is on;
   - the enhancement AI provider is configured (`AIEnhancementService.isConfigured`);
   - the selection is non-empty after trimming whitespace;
   - its length is ≤ `SelectedTextEnhancementSettings.maxInputLength()`
     (4000 by default, shared with enhance-selected-text);
   - the focused role is not `AXSecureTextField`.

   Otherwise `nil`, and the recording is an ordinary dictation. The engine keeps
   the context for this recording and hands it to the pipeline; it is cleared
   on cancel and after the pipeline run.
2. **Pipeline.** `TranscriptionPipeline.run` takes `selectionEdit: SelectionEditContext?`.
   After transcription, output filter, formatting and word replacements, when a
   context is present:
   - prompt detection (trigger words) and the regular enhancement are skipped;
   - `onStateChange(.enhancing)`, then `enhancementService.editSelection(selectedText:spokenText:)`;
   - success: `finalPastedText` = result; `transcription.enhancedText` = result,
     `promptName` = "Selection Edit", model name, duration and the request
     messages are recorded like an enhancement;
   - failure (error, timeout, empty result): nothing is pasted, the selection
     stays intact, a warning notification is shown, the transcription is saved
     with the dictated text.

   Cancellation is checked before and after the request, as for enhancement.
3. **Verify before paste.** `SelectionEditService.pasteDecision(context:frontmostBundleID:currentSelection:)`:
   - same bundle ID and `FocusedTextAccessibility.selectedText()` equals the
     captured text → `.paste`;
   - anything else, including `nil` from AX → `.clipboard`.

   `.paste`: the normal `CursorPaster` path; it replaces the selection. No
   trailing space (`AppendTrailingSpace` is ignored), otherwise replacing a word
   mid-sentence leaves a double space. `.clipboard`: the result is put on the
   pasteboard and a notification says the selection changed and the result is
   in the clipboard.
4. **Aftermath.** `LastPasteTracker` is cleared for this paste, so the
   re-transcribe-last hotkey cannot replace the edit result with a
   re-transcription of the spoken instruction. Auto Send (Power Mode) behaves as
   for normal dictation. Auto Learn: the previous observation is already
   retired at recording start (`VoiceInkEngine.swift:186`); the result paste is
   observed like any paste.

## AI request

- **Provider and model**: the enhancement ones, `aiService.selectedProvider` and
  `aiService.currentModel`, so a Power Mode per-app provider applies. Ollama,
  Local CLI, Anthropic, OpenAI-compatible and Custom (with its headers) work.
- **Transport**: rename `AIEnhancementService.reviewAutoLearnCandidates` to
  `chatCompletion(systemPrompt:userContent:provider:modelName:timeout:)`; Auto
  Learn keeps passing `max(baseTimeout, 30)`, the edit passes the same.
  `AIEnhancementOutputFilter` strips `<think>` blocks as today.
- **New method** `AIEnhancementService.editSelection(selectedText:spokenText:) async throws -> String`:
  builds the user message, calls `chatCompletion`, sets `lastSystemMessageSent`
  and `lastUserMessageSent`, throws on an empty result.
- **Not sent**: clipboard context, screen context, custom vocabulary.
- **System prompt** `AIPrompts.selectionEdit`:

  ```
  <SYSTEM_INSTRUCTIONS>
  <SELECTED_TEXT> is text the user selected. <TRANSCRIPT> is what they dictated.
  If the transcript is an instruction about the selected text (rewrite, translate,
  shorten, expand, fix, change tone or format), apply it and output only the text
  that replaces the selection. Otherwise the transcript is new text meant to replace
  the selection: output it verbatim.
  Keep the selection's language and formatting unless the instruction says otherwise.
  No commentary, preamble, quotes or code fences unless the content itself is code.
  </SYSTEM_INSTRUCTIONS>
  ```
- **User message**:

  ```
  <SELECTED_TEXT>
  …
  </SELECTED_TEXT>
  <TRANSCRIPT>
  …
  </TRANSCRIPT>
  ```

Expected: select "вторник", say "понедельник" → "понедельник"; select a
paragraph, say "переведи на английский" → the translation; select a paragraph,
say "сделай списком" → a list.

## Settings

- Toggle "Edit selection by voice" with a one-line description in
  `EnhancementSettingsView`; key `IsSelectionVoiceEditEnabled`, registered as
  `true` in `AppDefaults`.
- Backup: `GeneralBackup.isSelectionVoiceEditEnabled`, exported and imported.
- ru translations for every new string in `Localizable.xcstrings`.

## Edge cases

- `SkipShortEnhancement` does not apply: short commands ("shorter") are the norm.
- Long results paste in chunks as today; the first chunk replaces the selection.
- Trial-expired prefix is added by the pipeline as for any paste.
- Not supported: retry / re-enhance of such a transcription from history. The
  selected text is not stored, so the edit cannot be repeated; a retry runs the
  regular enhancement on the spoken text.

## Testing

Unit tests (swift-testing) in `VoiceInkTests/SelectionEditTests.swift` on the
pure parts of `SelectionEditService`:

- capture decision: disabled, provider not configured, empty or whitespace-only
  selection, over the limit, secure field → `nil`; the normal case → a context
  with the text and bundle ID;
- paste decision: same app and same text → `.paste`; different app, different
  text, `nil` selection → `.clipboard`;
- user message builder: both blocks present, selection and transcript not swapped.

Manual checklist (not automatable): TextEdit, Notes and a Chrome textarea with
the three examples above; Slack or VS Code (expected: ordinary dictation over the
selection); an invalid API key (expected: nothing pasted, selection intact,
notification shown).
