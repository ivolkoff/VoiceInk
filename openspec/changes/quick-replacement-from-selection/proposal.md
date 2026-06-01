## Why

VoiceInk's dictionary lets users define word replacements (an original word/phrase → a corrected replacement). Today the only way to add one is to open the Quick Add panel, switch to the Word Replacement tab, and type both sides by hand. The common real-world trigger — "the transcription got *this* word wrong, replace it with *that*" — requires retyping the wrong word manually, even though it is already selected on screen.

The Quick Add panel should use the current selection in the frontmost app as the starting point, so adding or extending a replacement takes one keystroke instead of full manual entry.

## What Changes

- The Quick Add panel gains a new **Insert** mode that reads the user's current text selection (via `SelectedTextService`) when the panel opens.
- The panel defaults to **Insert** mode so the selection-driven flow is immediately available.
- **With a selection:** the panel shows the selected word as "Replace …" and offers a field for what to replace it with.
  - Typing a new target and pressing ↵ creates a new `WordReplacement` (selection → typed text).
  - If the typed target matches an existing replacement, or the user clicks an existing row, the selection is appended as an additional trigger token to that replacement instead of creating a duplicate.
  - If the selection is already a trigger of some replacement, a warning is shown and no duplicate is created.
- **Without a selection:** the Insert field acts as a search/filter over existing replacements. Pressing ↵ on a match (or clicking a row) opens the Word Replacement tab pre-filled for editing; ↵ with no match opens it pre-filled to create a new entry.
- Empty state (no replacements yet) shows a prompt with a button to the Word Replacement tab.

## Capabilities

### New Capabilities
- `quick-replacement-from-selection`: Use the current text selection in the Quick Add panel to quickly create a new word replacement or extend an existing one, and to browse/edit existing replacements.

### Modified Capabilities

<!-- No existing specs are modified — this is a new UI capability built on the existing WordReplacement data model. -->

## Impact

- **Files to modify:**
  - `VoiceInk/Views/Dictionary/DictionaryQuickAddPanel.swift` — add the Insert mode, selection capture, list/search UI, and create/extend wiring; default to Insert mode.
  - `VoiceInk/Services/DictionaryService.swift` — normalize trimmed original/replacement on add.
- **Files reused as-is:**
  - `VoiceInk/Services/SelectedTextService.swift` — `fetchSelectedText()` provides the current selection.
- **Data model:** No changes. Uses the existing `WordReplacement` SwiftData model.
- **Shortcut:** No changes. The existing `quickAddToDictionary` hotkey triggers the same panel.
- **Dependencies:** None new.
