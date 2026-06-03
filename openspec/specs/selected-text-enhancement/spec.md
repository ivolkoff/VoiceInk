# selected-text-enhancement Specification

## Purpose
TBD - created by archiving change enhance-selected-text. Update Purpose after archive.
## Requirements
### Requirement: Global hotkey enhances selected text
The app SHALL provide a global keyboard shortcut that, when pressed, runs the configured AI enhancement on the user's current text selection and pastes the result over that selection in the active application, without recording audio. The action SHALL use the same enhancement configuration (active prompt / Power Mode) as the post-transcription pipeline.

#### Scenario: Selected text is enhanced and pasted back
- **WHEN** text is selected in the frontmost app and the user presses the enhance-selected-text shortcut
- **THEN** the selection is captured, sent through `AIEnhancementService` with the active prompt, and the AI result replaces the selection in that app

#### Scenario: Shortcut is registered as a global action
- **WHEN** shortcut settings are shown
- **THEN** the enhance-selected-text action is bindable as a global shortcut alongside other utility actions

### Requirement: Select-all fallback when nothing is selected
WHEN no text is selected, the app SHALL fall back to selecting all text in the focused input/field and use that as the input, rather than doing nothing.

#### Scenario: No selection falls back to whole field
- **WHEN** the user presses the shortcut with no active text selection in an editable field
- **THEN** the app selects all text in that field and uses it as the enhancement input

#### Scenario: Fallback yields no text
- **WHEN** the shortcut is pressed, nothing is selected, and the select-all fallback returns no usable text
- **THEN** the app performs no enhancement and no paste, and surfaces a brief notice that no text was found

### Requirement: Maximum input length guard
The app SHALL enforce a configurable maximum input length (in characters). WHEN the captured text exceeds the configured limit, the app SHALL abort before calling the AI service and notify the user, so the action cannot accidentally process very large text. The limit SHALL have a sensible default and be user-adjustable.

#### Scenario: Input under the limit proceeds
- **WHEN** the captured text length is at or below the configured maximum
- **THEN** the enhancement proceeds normally

#### Scenario: Input over the limit is aborted
- **WHEN** the captured text length exceeds the configured maximum
- **THEN** no AI request is made, the clipboard/selection is left unchanged, and the user is notified that the text was too large

#### Scenario: Limit is configurable with a default
- **WHEN** the user has not changed the setting
- **THEN** a sensible default maximum is in effect, and the user can adjust it in settings

### Requirement: Enhancement availability and failure handling
The action SHALL require that AI enhancement is enabled and configured; otherwise it SHALL notify the user instead of failing silently. WHEN the AI request fails, the original selected text SHALL remain unchanged.

#### Scenario: Enhancement not configured
- **WHEN** the user presses the shortcut while AI enhancement is disabled or unconfigured
- **THEN** no paste occurs and the user is informed that enhancement must be enabled/configured

#### Scenario: AI request fails
- **WHEN** the AI request returns an error
- **THEN** the original selection is not overwritten and the user is notified of the failure

