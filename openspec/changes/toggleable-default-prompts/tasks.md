## 1. Model — Make `isActive` functional with default `true`

- [x] 1.1 Change `CustomPrompt.isActive` default from `false` to `true` in the initializer
- [x] 1.2 Verify `PredefinedPrompts.createDefaultPrompts()` uses the new default (both Default and Assistant start enabled)
- [x] 1.3 Verify `initializePredefinedPrompts()` preserves existing `isActive` when updating predefined prompts (no behavior change needed — already does this)

## 2. Service — Filter and fallback logic

- [x] 2.1 Add `enabledPrompts: [CustomPrompt]` computed property to `AIEnhancementService` (filters `customPrompts` by `isActive == true`)
- [x] 2.2 Add `isPromptEnabled(_:)` helper to check a prompt's enabled state by ID
- [x] 2.3 Add `togglePromptEnabled(_:)` method to toggle a prompt's `isActive` state, with auto-fallback: if disabling the currently selected prompt, re-assign `selectedPromptId` to the first enabled prompt (or first prompt if none enabled)
- [x] 2.4 Guard `activePrompt` getter: if `selectedPromptId` points to a disabled prompt, return `nil` (let callers handle the fallback)
- [x] 2.5 Guard `enhance()`: if `activePrompt` is nil (all prompts disabled), fall back to first predefined prompt and show a notification

## 3. Detection — Skip disabled prompts

- [x] 3.1 In `PromptDetectionService.analyzeText()`, change `enhancementService.allPrompts` to `enhancementService.enabledPrompts` for trigger word iteration
- [x] 3.2 Verify that speaking a disabled prompt's trigger word does not activate it

## 4. Settings UI — Toggle controls in the prompt grid

- [x] 4.1 Update `CustomPrompt.promptIcon()` to accept an `isEnabled` parameter and render a dimmed/disabled visual state when `isEnabled == false`
- [x] 4.2 Add a small toggle icon overlay (e.g., power icon or circle with line) on each prompt icon in `ReorderablePromptGrid` that calls `enhancementService.togglePromptEnabled(_:)`
- [x] 4.3 Ensure the toggle does not interfere with existing drag-to-reorder, double-click-to-edit, and single-click-to-select gestures

## 5. Popover UI — Filter to enabled prompts only

- [x] 5.1 In `EnhancementPromptPopover`, change `enhancementService.allPrompts` to `enhancementService.enabledPrompts` so only enabled prompts appear in the selection list
- [x] 5.2 Verify that disabled prompts do not appear in the popover

## 6. Final verification

- [x] 6.1 Test: toggle Default prompt off → verify it disappears from popover and cannot be selected via trigger words (manual — needs Xcode build)
- [x] 6.2 Test: toggle Assistant prompt off → verify the same (manual)
- [x] 6.3 Test: disable currently selected prompt → verify auto-fallback to next enabled prompt (manual)
- [x] 6.4 Test: disable all prompts → verify enhancement falls back gracefully with notification (manual)
- [x] 6.5 Test: re-enable a disabled prompt → verify it reappears in popover (manual)
- [x] 6.6 Run LSP diagnostics on all modified files
