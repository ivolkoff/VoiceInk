## Context

The app ships two predefined prompts ("Default" and "Assistant") created in `PredefinedPrompts.createDefaultPrompts()` and synchronized into the user's prompt list via `AIEnhancementService.initializePredefinedPrompts()`. These prompts cannot be removed, hidden, or disabled. The `CustomPrompt` model already has an `isActive: Bool` field that defaults to `false` and is persisted via Codable but is never read to affect behavior — it is dead code.

The prompt system has three surfaces:
1. **Popover** (`EnhancementPromptPopover` + `EnhancementPromptRow`) — quick prompt selection from the recorder
2. **Settings** (`EnhancementSettingsView` + `ReorderablePromptGrid`) — full prompt list with drag reorder
3. **Detection** (`PromptDetectionService.analyzeText()`) — trigger-word matching across all prompts

All three surfaces need to respect an enabled/disabled state.

## Goals / Non-Goals

**Goals:**

- Users can toggle each predefined prompt on/off from the enhancement popover and settings grid
- Disabled prompts are hidden from the popover selection list
- Disabled prompts are visually distinguished in the settings grid (dimmed, with a toggle)
- Trigger-word detection skips disabled prompts
- When the currently selected prompt is disabled, the system auto-selects the first enabled prompt
- Backward compatible — all existing prompts are enabled by default

**Non-Goals:**

- Removing or deleting predefined prompts (only disable)
- Bulk enable/disable actions
- Prompt-level scheduling or time-based activation
- Per-prompt permission or role-based access control

## Decisions

### Decision 1: Use existing `isActive` field (rename to `isEnabled` conceptually)

**Chosen:** Shift the semantics of `isActive` from unused flag to "is this prompt enabled?". Change the default from `false` to `true`.

**Alternatives considered:**
- **New `isEnabled` field** — would require a new coding key, migration, and leave dead code. Avoided.
- **Keep `isActive` default `false` and add `isEnabled` with default `true`** — two booleans for the same purpose is confusing.

**Rationale:** Single source of truth. The field already exists, is persisted, and has the right semantics. Changing the default from `false` to `true` is safe because `false` was never functionally meaningful (it was dead code).

### Decision 2: Filter at the service layer, not the view layer

**Chosen:** Add `enabledPrompts` computed property to `AIEnhancementService` that filters `customPrompts` by `isActive == true`. Views use this property instead of `allPrompts` where appropriate.

**Rationale:** Ensures disabled prompts are filtered uniformly across all UI surfaces and in trigger detection. Single point of change.

### Decision 3: Separate display lists — popover shows only enabled, settings shows all

**Chosen:** The popover (`EnhancementPromptPopover`) shows only enabled prompts for quick selection. The settings grid (`EnhancementSettingsView` / `ReorderablePromptGrid`) shows all prompts with visual distinction for disabled ones plus a toggle affordance.

**Rationale:** Quick-select should be clutter-free. Settings is the management surface where users expect to see and toggle prompts. This matches macOS conventions (e.g., input sources list shows disabled sources dimmed).

### Decision 4: Settings panel toggle instead of inline popover toggle

**Chosen:** Toggling prompts on/off is done via the settings panel (gear icon → Enhancement Settings) rather than adding a switch directly in the popover. The popover remains a selection surface.

**Rationale:** The popover is designed for quick selection, not management. The settings panel (`EnhancementSettingsPanel`) is the existing management surface where context, timeout, and shortcuts are configured. Adding prompt toggles there alongside the grid is consistent.

### Decision 5: Prompt detection skips disabled prompts

**Chosen:** `PromptDetectionService.analyzeText()` uses `enhancementService.enabledPrompts` instead of `enhancementService.allPrompts`.

**Rationale:** A disabled prompt with trigger words should not activate when the user speaks those words. This is the core user requirement — preventing unintended activation.

## Risks / Trade-offs

- **[Data loss on migration]** Users who previously had `isActive = false` saved in UserDefaults will now see those prompts as enabled after the default change. → Mitigation: `isActive` was never set to `true` anywhere in the codebase, so existing users always have `isActive = false`. This means ALL prompts would flip from "disabled" (dead state) to "enabled" on first launch. If we want to preserve `false`, we need a migration key. I recommend accepting the flip since `false` never meant "disabled" before.

- **[Preferences panel](EnhancementSettingsPanel) scope creep** — the panel is already 150+ lines with context toggles, skip-short, timeout, and shortcuts. Adding prompt enable/disable toggles there might feel like dumping too much. → Mitigation: Add toggles directly to the `ReorderablePromptGrid` in `EnhancementSettingsView` (the main settings form), not inside the gear panel. Each prompt icon in the grid gets a small power-toggle overlay.

- **[Predefined prompt re-initialization]** `initializePredefinedPrompts()` runs on every `init` and could potentially reset the `isActive` state. → Mitigation: Already handled — the method preserves `updatedPrompt.isActive` when updating existing prompts. We also need to ensure the first-time init respects the new `true` default.

- **[Edge case: all prompts disabled]** If the user disables every prompt, enhancement has no prompt to use. → Mitigation: Guard in `enhance()` — if no enabled prompts exist, fall back to the first predefined prompt (temporarily treat it as enabled for the request). Show a notification informing the user.
