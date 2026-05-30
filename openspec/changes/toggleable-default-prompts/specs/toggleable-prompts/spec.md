## ADDED Requirements

### Requirement: Default prompt enabled state
All prompts SHALL default to enabled (`isActive = true`). The two predefined prompts ("Default" and "Assistant") SHALL be enabled by default when a user first launches the app or when the prompts are initialized.

#### Scenario: First launch default state
- **WHEN** the app launches for the first time and `customPrompts` is empty
- **THEN** `initializePredefinedPrompts()` creates both predefined prompts with `isActive = true`

#### Scenario: App upgrade preserves enabled state
- **WHEN** the app is upgraded and predefined prompts already exist in `customPrompts`
- **THEN** the existing `isActive` values are preserved during re-initialization

### Requirement: Toggle prompt enabled state
Users SHALL be able to toggle any prompt (predefined or custom) between enabled and disabled states. The toggle MUST be accessible from the Enhancement Settings view.

#### Scenario: Enable a disabled prompt
- **WHEN** a user clicks the enable toggle for a disabled prompt in the settings grid
- **THEN** the prompt's `isActive` field is set to `true` and the prompt becomes visible in the popover

#### Scenario: Disable an enabled prompt
- **WHEN** a user clicks the disable toggle for an enabled prompt in the settings grid
- **THEN** the prompt's `isActive` field is set to `false` and the prompt is hidden from the popover

### Requirement: Hide disabled prompts from popover
The enhancement prompt popover (`EnhancementPromptPopover`) SHALL display only enabled prompts. Disabled prompts MUST NOT appear in the popover list.

#### Scenario: Popover shows only enabled prompts
- **WHEN** the user opens the enhancement prompt popover
- **THEN** only prompts with `isActive = true` are shown in the list

#### Scenario: Disabled prompt disappears from popover
- **WHEN** a user disables a prompt that was previously visible in the popover
- **THEN** the prompt is no longer shown in the popover on next open

### Requirement: Visual distinction for disabled prompts in settings
The settings grid (`ReorderablePromptGrid`) SHALL visually distinguish disabled prompts from enabled ones. Disabled prompts SHALL appear dimmed/less opaque.

#### Scenario: Disabled prompt visual state
- **WHEN** a prompt is disabled
- **THEN** its icon in the settings grid is displayed at reduced opacity with a visual indicator showing it is disabled

#### Scenario: Re-enabling restores full opacity
- **WHEN** a disabled prompt is re-enabled
- **THEN** its icon returns to full opacity in the settings grid

### Requirement: Trigger-word detection skips disabled prompts
`PromptDetectionService.analyzeText()` MUST only check enabled prompts for trigger-word matching. A disabled prompt with trigger words MUST NOT be activated when those words are spoken.

#### Scenario: Disabled prompt trigger word ignored
- **WHEN** the user speaks a trigger word that belongs to a disabled prompt
- **THEN** the prompt is not activated and the enhancement prompt selection remains unchanged

#### Scenario: Enabled prompt trigger word detected
- **WHEN** the user speaks a trigger word that belongs to an enabled prompt
- **THEN** the prompt is activated as before (existing behavior preserved)

### Requirement: Auto-fallback when current prompt is disabled
If the currently selected prompt (`selectedPromptId`) is disabled, the system SHALL automatically select the first enabled prompt. If no enabled prompts exist, the system SHALL temporarily use the first predefined prompt.

#### Scenario: Current prompt disabled, other enabled prompts exist
- **WHEN** the user disables the currently selected prompt and other enabled prompts exist
- **THEN** `selectedPromptId` is updated to the first enabled prompt

#### Scenario: All prompts disabled
- **WHEN** all prompts are disabled and enhancement is triggered
- **THEN** the system uses the first predefined prompt for the request and shows a notification that no prompts are enabled

### Requirement: Toggle control in settings grid
Each prompt icon in `ReorderablePromptGrid` SHALL have a toggle overlay or control to switch its enabled state without opening the prompt editor.

#### Scenario: Click toggle to disable
- **WHEN** the user clicks the toggle on an enabled prompt in the settings grid
- **THEN** the prompt's `isActive` changes to `false` and the visual state updates

#### Scenario: Click toggle to enable
- **WHEN** the user clicks the toggle on a disabled prompt in the settings grid
- **THEN** the prompt's `isActive` changes to `true` and the visual state updates
