# Voice Edit of the Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dictation over a text selection becomes an AI instruction for that text; the result replaces the selection (or lands in the clipboard when the target field moved on).

**Architecture:** `VoiceInkEngine.toggleRecord` captures the selection via Accessibility at recording start into a `SelectionEditContext`. `TranscriptionPipeline.run` receives it, skips prompt detection and the regular enhancement, and sends one request (`AIEnhancementService.editSelection` → shared `chatCompletion` transport). Before paste, the captured selection is re-verified against the live one: same app + same text → normal paste, anything else → clipboard fallback. `LastPasteTracker` is cleared for such pastes.

**Tech Stack:** Swift / SwiftUI / AppKit AX API, swift-testing.

**Spec:** `docs/superpowers/specs/2026-09-24-voice-edit-selection-design.md`

## Global Constraints

- Decisions in the spec's "Decisions (locked)" section are not up for revision: automatic trigger, one AI request decides instruction-vs-content, own toggle (default on, independent of AI Enhancement), AX-only capture with no clipboard fallback at capture time.
- Toggle key: `IsSelectionVoiceEditEnabled`, registered `true` in `AppDefaults`.
- Selection limit: `SelectedTextEnhancementSettings.maxInputLength()` (default 4000), shared with enhance-selected-text.
- Transport rename: `AIEnhancementService.reviewAutoLearnCandidates` → `chatCompletion(systemPrompt:userContent:provider:modelName:timeout:)`; both Auto Learn and selection edit pass `max(baseTimeout, 30)` (exposed as `backgroundTimeout`).
- `SkipShortEnhancement` does not apply to selection edits. No clipboard/screen context, no custom vocabulary in the request.
- `promptName` recorded as `"Selection Edit"`.
- Build/test command (repo root, ad-hoc signing):
  `xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug -destination 'platform=macOS' -xcconfig LocalBuild.xcconfig -parallel-testing-enabled NO CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" CODE_SIGN_ENTITLEMENTS="$PWD/VoiceInk/VoiceInk.local.entitlements" -only-testing:VoiceInkTests/<Suite> 2>&1 | grep -E '✘|error:|Test run with|TEST (SUCCEEDED|FAILED)'`
- Never run the whole VoiceInkTests target: `RetranscribeInPlaceTests` crashes (known).
- The project uses file-system-synchronized groups — new `.swift` files need no pbxproj edit.
- `xcodebuild` does not add keys to `Localizable.xcstrings`; new keys are added by hand with a python script preserving key order: `python json.dumps(d, ensure_ascii=False, indent=2) + "\n"`.
- Conventional commits, no AI attribution / Co-Authored-By, no push.
- Target suites to pass before delivery: SelectionEditTests, AutoLearnTests, DictionaryImportExportTests, QuickHistoryTests, ShortcutMonitorTests, DoubleTapShortcutTests.

## Review Focus

- **Selection changed between capture and paste** (user kept typing in the field): expect the result in the clipboard and the new text untouched — pinned by `unreadableSelectionGoesToClipboard` / `changedTextGoesToClipboard`; the live re-check at paste time is Task 3.
- **Apps that do not expose `AXSelectedText`** (Electron): capture must return `nil` and the recording stays a normal dictation — pinned by `nilSelectionMeansNoCapture`.
- **Password fields** (`AXSecureTextField` via role or subrole): never captured, so a password is never sent to a cloud model — pinned by `secureRoleMeansNoCapture`.
- **Empty model result**: nothing pasted, selection intact, warning shown, dictated text saved — Task 3's `guard !result.isEmpty` throw in `editSelection` plus the pipeline's failure branch.
- **Feature works with the AI Enhancement master switch off** (own toggle): the pipeline's selection-edit branch must not require `isEnhancementEnabled` — Task 3 gates only on `isConfigured`.

---

### Task 1: SelectionEditService pure core + tests

**Files:**
- Create: `VoiceInk/Services/SelectionEditService.swift`
- Create: `VoiceInkTests/SelectionEditTests.swift`
- Modify: `VoiceInk/Models/AIPrompts.swift` (append `selectionEdit` prompt)

**Interfaces:**
- Consumes: `FocusedTextAccessibility.selectedText()/focusedRole()/focusedSubrole()`, `SelectedTextEnhancementSettings.maxInputLength()`.
- Produces:
  - `struct SelectionEditContext: Equatable { let text: String; let bundleID: String? }`
  - `SelectionEditService.isEnabledKey: String`, `SelectionEditService.isEnabled: Bool`
  - `SelectionEditService.captureDecision(isEnabled:isProviderConfigured:selection:focusedRole:focusedSubrole:maxInputLength:frontmostBundleID:) -> SelectionEditContext?` (pure)
  - `SelectionEditService.capture(isProviderConfigured: Bool) -> SelectionEditContext?` (`@MainActor`, live AX read)
  - `enum SelectionEditService.PasteDecision: Equatable { case paste, clipboard }`
  - `SelectionEditService.pasteDecision(context:frontmostBundleID:currentSelection:) -> PasteDecision` (pure)
  - `SelectionEditService.makeUserMessage(selectedText:spokenText:) -> String` (pure)
  - `AIPrompts.selectionEdit: String`

- [x] **Step 1: Write the failing tests**

Create `VoiceInkTests/SelectionEditTests.swift`:

```swift
import Foundation
import Testing
@testable import VoiceInk

struct SelectionEditTests {

    // MARK: - Capture decision

    private func capture(
        isEnabled: Bool = true,
        configured: Bool = true,
        selection: String? = "hello",
        role: String? = "AXTextArea",
        subrole: String? = nil,
        maxLength: Int = 100,
        bundleID: String? = "com.apple.TextEdit"
    ) -> SelectionEditContext? {
        SelectionEditService.captureDecision(
            isEnabled: isEnabled,
            isProviderConfigured: configured,
            selection: selection,
            focusedRole: role,
            focusedSubrole: subrole,
            maxInputLength: maxLength,
            frontmostBundleID: bundleID
        )
    }

    @Test func disabledMeansNoCapture() {
        #expect(capture(isEnabled: false) == nil)
    }

    @Test func unconfiguredProviderMeansNoCapture() {
        #expect(capture(configured: false) == nil)
    }

    @Test func nilSelectionMeansNoCapture() {
        #expect(capture(selection: nil) == nil)
    }

    @Test func emptySelectionMeansNoCapture() {
        #expect(capture(selection: "") == nil)
    }

    @Test func whitespaceSelectionMeansNoCapture() {
        #expect(capture(selection: "  \n\t ") == nil)
    }

    @Test func overLimitSelectionMeansNoCapture() {
        #expect(capture(selection: "abcdef", maxLength: 5) == nil)
    }

    @Test func atLimitCaptures() {
        #expect(capture(selection: "abcde", maxLength: 5)?.text == "abcde")
    }

    @Test func secureRoleMeansNoCapture() {
        #expect(capture(role: "AXSecureTextField") == nil)
        #expect(capture(subrole: "AXSecureTextField") == nil)
    }

    @Test func normalCaptureCarriesTextAndBundle() {
        #expect(capture() == SelectionEditContext(text: "hello", bundleID: "com.apple.TextEdit"))
    }

    // MARK: - Paste decision

    private let context = SelectionEditContext(text: "вторник", bundleID: "com.apple.TextEdit")

    @Test func sameAppSameTextPastes() {
        #expect(
            SelectionEditService.pasteDecision(
                context: context,
                frontmostBundleID: "com.apple.TextEdit",
                currentSelection: "вторник"
            ) == .paste
        )
    }

    @Test func differentAppGoesToClipboard() {
        #expect(
            SelectionEditService.pasteDecision(
                context: context,
                frontmostBundleID: "com.google.Chrome",
                currentSelection: "вторник"
            ) == .clipboard
        )
    }

    @Test func changedTextGoesToClipboard() {
        #expect(
            SelectionEditService.pasteDecision(
                context: context,
                frontmostBundleID: "com.apple.TextEdit",
                currentSelection: "среда"
            ) == .clipboard
        )
    }

    @Test func unreadableSelectionGoesToClipboard() {
        #expect(
            SelectionEditService.pasteDecision(
                context: context,
                frontmostBundleID: "com.apple.TextEdit",
                currentSelection: nil
            ) == .clipboard
        )
        #expect(
            SelectionEditService.pasteDecision(
                context: context,
                frontmostBundleID: nil,
                currentSelection: "вторник"
            ) == .clipboard
        )
    }

    // MARK: - User message

    @Test func userMessageKeepsBlocksApart() {
        let message = SelectionEditService.makeUserMessage(selectedText: "SEL", spokenText: "SPK")
        #expect(message.contains("<SELECTED_TEXT>\nSEL\n</SELECTED_TEXT>"))
        #expect(message.contains("<TRANSCRIPT>\nSPK\n</TRANSCRIPT>"))
        let selectedRange = message.range(of: "SEL")!
        let transcriptHeader = message.range(of: "<TRANSCRIPT>")!
        let spokenRange = message.range(of: "SPK")!
        #expect(selectedRange.upperBound < transcriptHeader.lowerBound)
        #expect(transcriptHeader.upperBound < spokenRange.lowerBound)
    }
}
```

- [x] **Step 2: Run the tests to verify they fail (compile error: types missing)**

Run the build/test command with `-only-testing:VoiceInkTests/SelectionEditTests`.
Expected: FAIL — "cannot find 'SelectionEditService' in scope".

- [x] **Step 3: Implement the service**

Create `VoiceInk/Services/SelectionEditService.swift`:

```swift
import Foundation
import AppKit

/// Context captured at recording start for a "voice edit of the selection" run.
struct SelectionEditContext: Equatable {
    let text: String
    let bundleID: String?
}

enum SelectionEditService {
    static let isEnabledKey = "IsSelectionVoiceEditEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: isEnabledKey)
    }

    /// Pure capture gate; `capture()` feeds it live AX / workspace values.
    static func captureDecision(
        isEnabled: Bool,
        isProviderConfigured: Bool,
        selection: String?,
        focusedRole: String?,
        focusedSubrole: String?,
        maxInputLength: Int,
        frontmostBundleID: String?
    ) -> SelectionEditContext? {
        guard isEnabled, isProviderConfigured else { return nil }
        guard let selection,
              !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard selection.count <= maxInputLength else { return nil }
        // Secure fields report role `AXTextField` + this subrole; some apps put the
        // name straight into the role, so both are checked.
        let secure = kAXSecureTextFieldSubrole as String
        guard focusedRole != secure, focusedSubrole != secure else { return nil }
        return SelectionEditContext(text: selection, bundleID: frontmostBundleID)
    }

    /// Reads the live selection while the target app still owns focus. Call at
    /// recording start, next to `KeyboardLayoutLanguageService.captureCurrentLayout()`.
    /// `nil` ⇒ ordinary dictation (no AX selection, disabled, unconfigured, secure field…).
    @MainActor
    static func capture(isProviderConfigured: Bool) -> SelectionEditContext? {
        captureDecision(
            isEnabled: isEnabled,
            isProviderConfigured: isProviderConfigured,
            selection: FocusedTextAccessibility.selectedText(),
            focusedRole: FocusedTextAccessibility.focusedRole(),
            focusedSubrole: FocusedTextAccessibility.focusedSubrole(),
            maxInputLength: SelectedTextEnhancementSettings.maxInputLength(),
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
    }

    enum PasteDecision: Equatable {
        case paste
        case clipboard
    }

    /// Verifies at paste time that the focused field still shows the captured selection;
    /// anything else falls back to the clipboard so unseen text is never overwritten.
    static func pasteDecision(
        context: SelectionEditContext,
        frontmostBundleID: String?,
        currentSelection: String?
    ) -> PasteDecision {
        guard frontmostBundleID == context.bundleID,
              let currentSelection,
              currentSelection == context.text else {
            return .clipboard
        }
        return .paste
    }

    static func makeUserMessage(selectedText: String, spokenText: String) -> String {
        """
        <SELECTED_TEXT>
        \(selectedText)
        </SELECTED_TEXT>
        <TRANSCRIPT>
        \(spokenText)
        </TRANSCRIPT>
        """
    }
}
```

Append to `AIPrompts` in `VoiceInk/Models/AIPrompts.swift` (before the closing `}`):

```swift
    static let selectionEdit = """
    <SYSTEM_INSTRUCTIONS>
    <SELECTED_TEXT> is text the user selected. <TRANSCRIPT> is what they dictated.
    If the transcript is an instruction about the selected text (rewrite, translate,
    shorten, expand, fix, change tone or format), apply it and output only the text
    that replaces the selection. Otherwise the transcript is new text meant to replace
    the selection: output it verbatim.
    Keep the selection's language and formatting unless the instruction says otherwise.
    No commentary, preamble, quotes or code fences unless the content itself is code.
    </SYSTEM_INSTRUCTIONS>
    """
```

- [x] **Step 4: Run the tests to verify they pass**

Run with `-only-testing:VoiceInkTests/SelectionEditTests`.
Expected: PASS, `Test run with … tests passed`.

- [x] **Step 5: Commit**

```bash
git add VoiceInk/Services/SelectionEditService.swift VoiceInkTests/SelectionEditTests.swift VoiceInk/Models/AIPrompts.swift
git commit -m "feat: selection edit capture and paste decisions"
```

---

### Task 2:### Task 3:### Task 4:### Task 5: