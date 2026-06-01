## ADDED Requirements

### Requirement: Quick Add panel defaults to Insert mode and captures the selection

The Quick Add panel SHALL default to the "Insert" mode when opened via the global hotkey, and SHALL capture the current text selection from the frontmost application on appear.

#### Scenario: Panel opens in Insert mode
- **WHEN** the user presses the "Quick Add to Dictionary" hotkey
- **THEN** the panel opens with the "Insert" tab selected and the input field focused

#### Scenario: Selection captured and displayed
- **WHEN** the panel opens while text is selected in the frontmost app
- **THEN** the panel displays the selected text as the original ("Replace") side of a replacement

#### Scenario: No selection available
- **WHEN** the panel opens with no selection (or accessibility access is unavailable)
- **THEN** the input field acts as a search field over existing replacements

---

### Requirement: Create a replacement from the selection

With a captured selection, the panel SHALL create a new word replacement using the selection as the original text and the typed text as the replacement text.

#### Scenario: Create new replacement
- **WHEN** the user has a selection, types a target, and presses ↵, and no existing replacement matches
- **THEN** a new `WordReplacement` is created with the selection as original and the typed text as replacement, and a success notification is shown

#### Scenario: Extend an existing replacement
- **WHEN** the user has a selection and the typed target matches an existing replacement, or clicks an existing row
- **THEN** the selection is appended as an additional trigger token to that replacement's original text

#### Scenario: Duplicate trigger is rejected
- **WHEN** the selection is already a trigger token of the targeted replacement
- **THEN** the panel shows an inline warning and does NOT add a duplicate or show a success notification

---

### Requirement: Browse and edit existing replacements without a selection

When no selection is present, the panel SHALL display a searchable list of existing replacements and allow editing them.

#### Scenario: Search filters the list
- **WHEN** the user types in the search field
- **THEN** the list shows only entries whose original or replacement text contains the query (case-insensitive)

#### Scenario: Edit a matched replacement
- **WHEN** the user presses ↵ on a match or clicks a row
- **THEN** the Word Replacement tab opens pre-filled with that entry for editing

#### Scenario: Create from a missing search term
- **WHEN** the user presses ↵ and no replacement matches the typed text
- **THEN** the Word Replacement tab opens pre-filled with the typed text as the original

#### Scenario: Empty state
- **WHEN** no replacements have been configured
- **THEN** the panel shows a "no replacements yet" message with a button to switch to the Word Replacement tab
