## ADDED Requirements

### Requirement: Toggle to match transcription language to keyboard layout

VoiceInk SHALL provide a user setting "Match transcription language to keyboard layout", persisted as `MatchLanguageToKeyboardLayout`, defaulting to enabled (ON). When OFF, transcription uses the manually selected `SelectedLanguage` exactly as before.

#### Scenario: Default enabled
- **WHEN** the app launches for the first time with no stored value for `MatchLanguageToKeyboardLayout`
- **THEN** the setting is treated as ON

#### Scenario: Disabling restores manual behavior
- **WHEN** the user turns the toggle OFF
- **THEN** the transcription language equals the manually selected `SelectedLanguage` and the keyboard layout is ignored

### Requirement: Resolve transcription language from keyboard layout at recording start

When the toggle is ON, VoiceInk SHALL read the current macOS keyboard input source language at the start of each recording and use it as the transcription language for that recording, after validating it against the active model's supported languages.

#### Scenario: Layout language supported by model
- **WHEN** the toggle is ON and the current keyboard layout's language (e.g. Russian) is supported by the active transcription model
- **THEN** that language (e.g. `ru`) is used as the transcription language for the recording

#### Scenario: English layout maps to English
- **WHEN** the toggle is ON and the current keyboard layout is an English layout
- **THEN** `en` is used as the transcription language for the recording

#### Scenario: Layout language not supported by model
- **WHEN** the toggle is ON and the current layout's language is not in the active model's supported languages
- **THEN** VoiceInk falls back to the manually selected `SelectedLanguage`

#### Scenario: Layout language cannot be determined
- **WHEN** the toggle is ON but no language can be read from the current input source
- **THEN** VoiceInk falls back to the manually selected `SelectedLanguage`

### Requirement: Detection does not mutate the stored manual language

Resolving the language from the keyboard layout SHALL be transient for the duration of a recording and SHALL NOT overwrite the persisted `SelectedLanguage` value.

#### Scenario: Stored preference preserved
- **WHEN** a recording is transcribed using a layout-detected language different from `SelectedLanguage`
- **THEN** the stored `SelectedLanguage` value is unchanged after the recording completes

### Requirement: Language settings UI reflects layout-driven mode

The language settings UI SHALL expose the toggle and indicate when the transcription language is being driven by the keyboard layout rather than the manual picker.

#### Scenario: Picker shown as layout-driven
- **WHEN** the toggle is ON and the active model is multilingual
- **THEN** the UI indicates the language follows the keyboard layout while keeping the manual picker available as the fallback selection

#### Scenario: Manual picker active when toggle off
- **WHEN** the toggle is OFF
- **THEN** the manual language picker behaves exactly as it does today
