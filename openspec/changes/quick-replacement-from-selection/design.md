## Context

The existing `DictionaryQuickAddPanel` is a floating `NSPanel` with two modes: **Vocabulary** (add new words) and **Word Replacement** (add a new original→replacement pair). It is toggled via the `quickAddToDictionary` global shortcut and already queries all `WordReplacement` and `VocabularyWord` entries via SwiftData `@Query`.

`SelectedTextService.fetchSelectedText()` returns the current selection in the frontmost app via accessibility / menu-action strategies. Because the panel is a `.nonactivatingPanel`, the previous app keeps its selection while the panel is shown, so the selection can be captured on appear.

## Goals / Non-Goals

**Goals:**
- Capture the current selection on panel open and use it as the original side of a replacement.
- One keystroke to create a new replacement (selection → typed target) or extend an existing one.
- Keep the panel usable with no selection: search/filter and edit existing replacements.
- Reuse the existing `WordReplacement` model and `DictionaryService` add/dedup logic.

**Non-Goals:**
- No paste-at-cursor / text insertion. The mode does not write text back into the frontmost app.
- No data model changes (no new fields or entities).
- No shortcut/configuration changes.

## Decisions

### 1. New "Insert" mode

Add a third `.insert` mode alongside `.vocabulary` and `.replacement`. The mode shows the captured selection, an input field, and a searchable list of existing replacements. The `.replacement` mode keeps its manual create-pair UI unchanged.

### 2. Default mode on open

Default to `.insert` (was `.vocabulary`). The most common action is reacting to a wrong word that is already selected, so the selection-driven flow is front and center.

### 3. Selection capture timing

Capture the selection in `.onAppear` via `Task { selectedText = await SelectedTextService.fetchSelectedText() ?? "" }`. The panel is non-activating, so the previous app's selection is still valid. When the selection arrives, the panel resizes to fit the extra "Replace …" row.

### 4. Create vs. extend

- **No match found** for the typed target → create a new `WordReplacement` via `DictionaryService.addWordReplacement`.
- **Match found** (or row clicked) with a selection → append the selection as an additional comma-separated trigger token to the matched entry's `originalText`, unless that token already exists.
- **Token already exists** → show an inline warning/error and do nothing (no false "added" notification).

### 5. Behavior without a selection

The input becomes a local search filter (matches `originalText` or `replacementText`, case-insensitive). ↵ on a match or a row click opens the `.replacement` tab pre-filled for editing; ↵ with no match opens it pre-filled with the typed text as the original.

### 6. Panel height

`.insert` uses a base height of 340. The panel grows by ~30pt when a selection is present (extra "Replace …" row) and by ~24pt when an error or duplicate warning line is shown. Height is recomputed on changes to `mode`, `errorMessage`, and `selectedText`.

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| Selection not captured (no AX permission / non-text context) | Falls back gracefully to the no-selection search flow; `fetchSelectedText` returns nil → empty string |
| Duplicate trigger token added silently | Guard against existing token; show inline warning, suppress the success notification |
| Warning/selection row clipped by fixed height | `desiredHeight` adds the row and warning allowances and resizes on the relevant `onChange`s |
| Long replacement list feels slow | Single `@Query`; filtering is client-side O(n) over a small array (expected < 500 entries) |
