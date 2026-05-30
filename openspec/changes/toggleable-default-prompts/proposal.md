## Why

Users currently cannot disable the two predefined prompts ("Default" and "Assistant") that ship with VoiceInk. These prompts are always present in the prompts list, always participate in trigger-word detection, and cannot be removed. Users who want to use only their own custom prompts must see and potentially accidentally select these built-in prompts. Adding enable/disable toggles gives users full control over which prompts participate in enhancement — reducing UI clutter and preventing unintended trigger activation.

## What Changes

- **Enable/disable toggles** for the two predefined prompts ("Default" and "Assistant") in the enhancement prompts list
- Disabled prompts are **hidden from the prompt selection popover** (the recorder popover)
- Disabled prompts **do not participate in trigger-word detection** — speaking a trigger word tied to a disabled prompt will not activate it
- Disabled prompts can be **re-enabled** at any time from the settings/popover UI
- The enhancement system automatically falls back to the first **enabled** prompt when the currently selected one is disabled
- **No breaking changes** — existing prompts retain their enabled state; all prompts default to enabled for backward compatibility

## Capabilities

### New Capabilities
- `toggleable-prompts`: Enable/disable individual prompts (both predefined and custom), affecting visibility, selection, and trigger-word activation behavior

### Modified Capabilities
- (none — no existing specs to modify)

## Impact

- **CustomPrompt model**: `isActive` field semantics shift from unused to "is this prompt enabled?"; default changes from `false` to `true`
- **AIEnhancementService**: New computed property `enabledPrompts`; `activePrompt` fallback logic; `setActivePrompt` guard for disabled prompts; `togglePromptEnabled` method
- **PromptDetectionService**: Only iterates enabled prompts for trigger word matching
- **EnhancementPromptPopover**: Shows only enabled prompts; rows gain a toggle affordance (icon + action) for predefined prompts
- **EnhancementSettingsView / ReorderablePromptGrid**: Disabled prompts are visually distinguished; toggle control for each prompt in the grid
- **Localization**: New UI strings for enable/disable actions
