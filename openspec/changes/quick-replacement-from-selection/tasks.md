## 1. Add Insert mode to Quick Add panel

- [x] 1.1 Add `.insert` case to `DictionaryQuickAddView.Mode` with label "Insert", icon `"text.insert"`, panelHeight 340
- [x] 1.2 Render `insertView` from `inputArea` when mode is `.insert`
- [x] 1.3 Focus the search field on appear and on switching to `.insert`
- [x] 1.4 Reset input state and resize on `.onChange(of: mode)`
- [x] 1.5 Change default mode from `.vocabulary` to `.insert`

## 2. Capture the current selection

- [x] 2.1 Add `@State private var selectedText` and fetch it in `.onAppear` via `SelectedTextService.fetchSelectedText()`
- [x] 2.2 Show the captured selection as a "Replace …" row when present
- [x] 2.3 Show a duplicate warning when the selection is already a trigger of some replacement

## 3. Build Insert mode UI

- [x] 3.1 Add `insertSearch` state and a `filteredReplacements` computed property (case-insensitive match on original/replacement)
- [x] 3.2 Build `insertView`: selection row, search/target field, scrollable list of replacement rows
- [x] 3.3 Each row shows `originalText → replacementText` with an edit affordance
- [x] 3.4 Empty state ("no replacements yet") with a button to switch to `.replacement`

## 4. Wire up create / extend

- [x] 4.1 With selection + no match: create a new replacement (selection → typed text) via `DictionaryService.addWordReplacement`
- [x] 4.2 With selection + match (or row click): append the selection as a new trigger token to the matched entry
- [x] 4.3 Without selection: ↵/click opens the `.replacement` tab pre-filled (edit existing or create from typed text)
- [x] 4.4 Guard against adding a token that already exists — show inline warning, do not show a false success notification

## 5. Stabilization fixes

- [x] 5.1 Move the success notification inside the "token actually added" branch (no false "added" toast)
- [x] 5.2 Recompute panel height on `selectedText` change and include the warning/selection-row allowance in `desiredHeight`
- [x] 5.3 Localize notification titles via `String.localizedStringWithFormat(String(localized:), …)`

## 6. Verify

- [x] 6.1 Build the project — no compile errors (only pre-existing warnings)
- [ ] 6.2 Manual: hotkey with a selection → "Replace <selection>" shown, ↵ creates replacement
- [ ] 6.3 Manual: clicking an existing row with a selection appends the trigger token
- [ ] 6.4 Manual: no selection → search filters; ↵ on match opens edit, ↵ on miss opens create
- [ ] 6.5 Manual: duplicate token shows warning, no false success toast
- [ ] 6.6 Manual: Vocabulary and Word Replacement tabs still work
