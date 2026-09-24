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

### Task 2: chatCompletion transport + editSelection

**Files:**
- Modify: `VoiceInk/Services/AIEnhancement/AIEnhancementService.swift:329-385` (rename + timeout param + `editSelection`)
- Modify: `VoiceInk/Services/AutoLearn/AutoLearnAIReviewer.swift:103-108` (call site)

**Interfaces:**
- Consumes: `SelectionEditService.makeUserMessage`, `AIPrompts.selectionEdit` (Task 1).
- Produces:
  - `AIEnhancementService.chatCompletion(systemPrompt: String, userContent: String, provider: AIProvider, modelName: String, timeout: TimeInterval) async throws -> String`
  - `AIEnhancementService.backgroundTimeout: TimeInterval` (`max(baseTimeout, 30)`)
  - `AIEnhancementService.editSelection(selectedText: String, spokenText: String) async throws -> String`

- [ ] **Step 1: Rename the transport**

In `AIEnhancementService.swift` replace `reviewAutoLearnCandidates(payload:systemPrompt:provider:modelName:)` with:

```swift
    /// Shared transport for requests that pick their own provider and model
    /// (Auto Learn review, selection edit) and cannot reuse `makeRequest`,
    /// which is bound to the enhancement selection and prompt.
    func chatCompletion(
        systemPrompt: String,
        userContent: String,
        provider: AIProvider,
        modelName: String,
        timeout: TimeInterval
    ) async throws -> String {
        let apiKey = APIKeyManager.shared.getAPIKey(forProvider: provider.rawValue) ?? ""

        do {
            let result: String
            switch provider {
            case .ollama:
                result = try await aiService.enhanceWithOllama(
                    text: userContent,
                    systemPrompt: systemPrompt,
                    model: modelName,
                    timeout: timeout
                )
            case .localCLI:
                result = try await aiService.enhanceWithLocalCLI(systemPrompt: systemPrompt, userPrompt: userContent)
            case .anthropic:
                result = try await AnthropicLLMClient.chatCompletion(
                    apiKey: apiKey,
                    model: modelName,
                    messages: [.user(userContent)],
                    systemPrompt: systemPrompt,
                    timeout: timeout
                )
            default:
                guard let baseURL = URL(string: provider.baseURL) else {
                    throw EnhancementError.notConfigured
                }
                result = try await openAICompatibleChatCompletion(
                    baseURL: baseURL,
                    apiKey: apiKey,
                    model: modelName,
                    systemPrompt: systemPrompt,
                    userContent: userContent,
                    temperature: modelName.lowercased().hasPrefix("gpt-5") ? 1.0 : 0.3,
                    reasoningEffort: ReasoningConfig.getReasoningParameter(for: provider, modelName: modelName),
                    extraBody: ReasoningConfig.getExtraBodyParameters(for: provider, modelName: modelName),
                    extraHeaders: provider == .custom && !aiService.customHeaders.isEmpty ? aiService.customHeaders : nil,
                    timeout: timeout
                )
            }
            return AIEnhancementOutputFilter.filter(result)
        } catch let error as LLMKitError {
            throw mapLLMKitError(error)
        }
    }
```

The `AutoLearnProviderPolicy.isSupported` guard is dropped here: the policy is Auto Learn's, and `AutoLearnAIReviewer.resolvedProvider` already only returns supported providers.

- [ ] **Step 2: Update the Auto Learn call site**

In `AutoLearnAIReviewer.swift` replace the call (line 103):

```swift
        let responseText = try await enhancementService.chatCompletion(
            systemPrompt: Self.reviewPrompt,
            userContent: requestText,
            provider: provider,
            modelName: modelName,
            timeout: enhancementService.backgroundTimeout
        )
```

- [ ] **Step 3: Add `backgroundTimeout` and `editSelection`**

In `AIEnhancementService.swift`, next to `chatCompletion`:

```swift
    /// Background-grade timeout shared by Auto Learn review and selection edit;
    /// the short dictation timeout would fail long requests repeatedly.
    var backgroundTimeout: TimeInterval {
        max(baseTimeout, 30)
    }

    /// Applies a spoken instruction to (or replaces) the selected text, using the
    /// enhancement provider and model so a Power Mode per-app provider applies.
    func editSelection(selectedText: String, spokenText: String) async throws -> String {
        let systemMessage = AIPrompts.selectionEdit
        let userMessage = SelectionEditService.makeUserMessage(selectedText: selectedText, spokenText: spokenText)
        let result = try await chatCompletion(
            systemPrompt: systemMessage,
            userContent: userMessage,
            provider: aiService.selectedProvider,
            modelName: aiService.currentModel,
            timeout: backgroundTimeout
        )
        guard !result.isEmpty else {
            throw EnhancementError.enhancementFailed
        }
        lastSystemMessageSent = systemMessage
        lastUserMessageSent = userMessage
        return result
    }
```

- [ ] **Step 4: Run AutoLearnTests to verify the rename**

Run with `-only-testing:VoiceInkTests/AutoLearnTests`.
Expected: PASS (the reviewer compiles against the new signature).

- [ ] **Step 5: Commit**

```bash
git add VoiceInk/Services/AIEnhancement/AIEnhancementService.swift VoiceInk/Services/AutoLearn/AutoLearnAIReviewer.swift
git commit -m "refactor: shared chatCompletion transport and selection edit request"
```

---

### Task 3: Engine capture + pipeline wiring

**Files:**
- Modify: `VoiceInk/Transcription/Engine/VoiceInkEngine.swift` (property, capture, clear, pass-through)
- Modify: `VoiceInk/Transcription/Engine/TranscriptionPipeline.swift` (param, edit branch, paste verification)

**Interfaces:**
- Consumes: `SelectionEditService.capture/pasteDecision`, `AIEnhancementService.editSelection` (Tasks 1–2).
- Produces: `VoiceInkEngine.pendingSelectionEdit: SelectionEditContext?`; `TranscriptionPipeline.run(…, selectionEdit: SelectionEditContext?, …)`.
- New localized keys used here (ru added in Task 5, keys listed verbatim):
  - `"Selection edit failed: %@"`
  - `"Selection changed — result copied to clipboard"`

- [ ] **Step 1: Engine — capture and clear**

In `VoiceInkEngine.swift`:

Add the property near `var recordedFile` (line ~19):

```swift
    var pendingSelectionEdit: SelectionEditContext?
```

In `toggleRecord`, start branch, right after `KeyboardLayoutLanguageService.captureCurrentLayout()` (line 135):

```swift
            // Same reasoning as the layout capture: the target app still owns focus,
            // so the AX read sees the selection the user is about to have edited.
            pendingSelectionEdit = enhancementService.flatMap { service in
                SelectionEditService.capture(isProviderConfigured: service.isConfigured)
            }
```

In `runPipeline(on:audioURL:)` change the signature and the pipeline call:

```swift
    private func runPipeline(on transcription: Transcription, audioURL: URL, selectionEdit: SelectionEditContext?) async {
```

and pass `selectionEdit: selectionEdit` in the `pipeline.run(...)` call (after `session:`). Call site (line 115) becomes:

```swift
                    await runPipeline(on: transcription, audioURL: recordedFile, selectionEdit: pendingSelectionEdit)
```

In the `didFinishActivePipeline` block (line 307–314) add:

```swift
            pendingSelectionEdit = nil
```

In the stop-branch cancel path (line 116–122), before `finishActiveRecorderCancellation()` add:

```swift
                    pendingSelectionEdit = nil
```

- [ ] **Step 2: Pipeline — signature and edit branch**

In `TranscriptionPipeline.swift`, `run(...)` gains a parameter after `session`:

```swift
        session: TranscriptionSession?,
        selectionEdit: SelectionEditContext?,
```

After `finalPastedText = cleanedText` (line 125), gate the existing prompt-detection and enhancement blocks with `selectionEdit == nil`, and append the selection-edit branch after the existing enhancement block (both existing conditions change; new block added):

```swift
            if let enhancementService, enhancementService.isConfigured, selectionEdit == nil {
                let detectionResult = promptDetectionService.analyzeText(text, with: enhancementService)
                promptDetectionResult = detectionResult
                await promptDetectionService.applyDetectionResult(detectionResult, to: enhancementService)
            }
```

```swift
            if let enhancementService,
               enhancementService.isEnhancementEnabled,
               enhancementService.isConfigured,
               !shouldSkipEnhancement,
               selectionEdit == nil {
                … existing body unchanged …
            }
```

```swift
            if let selectionEdit, let enhancementService, enhancementService.isConfigured {
                if shouldCancel() { await finishCanceledTranscription(); return }

                onStateChange(.enhancing)
                do {
                    let editStart = Date()
                    let result = try await enhancementService.editSelection(
                        selectedText: selectionEdit.text,
                        spokenText: cleanedText
                    )
                    transcription.enhancedText = result
                    transcription.aiEnhancementModelName = enhancementService.getAIService()?.currentModel
                    transcription.promptName = "Selection Edit"
                    transcription.enhancementDuration = Date().timeIntervalSince(editStart)
                    transcription.aiRequestSystemMessage = enhancementService.lastSystemMessageSent
                    transcription.aiRequestUserMessage = enhancementService.lastUserMessageSent
                    finalPastedText = result
                } catch {
                    // Nothing pasted, selection intact; the dictated text stays in history.
                    finalPastedText = nil
                    let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    let shortReason = String(errorDescription.prefix(80))
                    await MainActor.run {
                        NotificationManager.shared.showNotification(
                            title: String.localizedStringWithFormat(String(localized: "Selection edit failed: %@"), shortReason),
                            type: .warning
                        )
                    }
                    if shouldCancel() { await finishCanceledTranscription(); return }
                }
            }
```

- [ ] **Step 3: Pipeline — verify before paste**

At the top of the paste block (before `if var textToPaste = finalPastedText,`), read the live selection once:

```swift
        let selectionPasteMode = selectionEdit.map { context in
            SelectionEditService.pasteDecision(
                context: context,
                frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                currentSelection: FocusedTextAccessibility.selectedText()
            )
        }
```

Inside the paste block, right after the trial-expired prefix, split the flow:

```swift
            if selectionPasteMode == .clipboard {
                // The selection moved on since capture — hand the result to the clipboard
                // instead of pasting over text we can no longer see.
                ClipboardManager.copyToClipboard(textToPaste)
                LastPasteTracker.shared.clear()
                SoundManager.shared.playStopSound()
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: String(localized: "Selection changed — result copied to clipboard"),
                        type: .info
                    )
                }
                await restorePromptDetectionSettingsAndDismiss()
            } else {
                let appendSpace = selectionPasteMode == nil && UserDefaults.standard.bool(forKey: "AppendTrailingSpace")
                let pastedText = textToPaste + (appendSpace ? " " : "")
                let pasteOutcome = await CursorPaster.startPasteAtCursor(pastedText).value
                let autoSendKey = PowerModeManager.shared.currentActiveConfiguration?.autoSendKey

                if autoSendKey?.isEnabled == true || selectionPasteMode != nil {
                    LastPasteTracker.shared.clear()
                } else {
                    LastPasteTracker.shared.record(
                        transcriptionID: transcription.id,
                        pastedText: pastedText,
                        targetBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                        posted: pasteOutcome.result.didPostPasteCommand
                    )
                }

                SoundManager.shared.playStopSound()
                await restorePromptDetectionSettingsAndDismiss {
                    … existing autoSend closure unchanged …
                }
            }
```

(Existing `restorePromptDetectionSettingsAndDismiss()` call in the nothing-pasted `else` branch stays unchanged.)

- [ ] **Step 4: Build and run SelectionEditTests**

Run with `-only-testing:VoiceInkTests/SelectionEditTests`.
Expected: PASS (regression gate for the pure logic the pipeline now uses).

- [ ] **Step 5: Commit**

```bash
git add VoiceInk/Transcription/Engine/VoiceInkEngine.swift VoiceInk/Transcription/Engine/TranscriptionPipeline.swift
git commit -m "feat: route dictation over a selection through the selection edit"
```

---

### Task 4: Settings toggle, defaults, backup

**Files:**
- Modify: `VoiceInk/Views/EnhancementSettingsView.swift:43-53` (toggle in the General section)
- Modify: `VoiceInk/AppDefaults.swift:52-56` (register default)
- Modify: `VoiceInk/Services/BackupTypes.swift` (`GeneralBackup` field)
- Modify: `VoiceInk/Services/ImportExportService.swift:194-197` (export)
- Modify: `VoiceInk/Services/BackupImporter.swift:225-248` (import)
- New localized keys (ru in Task 5): `"Edit selection by voice"`, `"Dictation over a selection is sent to the AI as an instruction; the result replaces the selection."`

**Interfaces:**
- Consumes: `SelectionEditService.isEnabledKey/isEnabled` (Task 1).
- Produces: `GeneralBackup.isSelectionVoiceEditEnabled: Bool?` (optional — old backups without the key still decode).

- [ ] **Step 1: Register the default**

In `AppDefaults.swift`, Enhancement section:

```swift
            "IsSelectionVoiceEditEnabled": true,
```

- [ ] **Step 2: Add the toggle**

In `EnhancementSettingsView.swift`, inside the first `Section` right after the existing `Toggle` (after line 53), add:

```swift
                Toggle(isOn: $isSelectionVoiceEditEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Edit selection by voice")
                        Text("Dictation over a selection is sent to the AI as an instruction; the result replaces the selection.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
```

and the property:

```swift
    @AppStorage(SelectionEditService.isEnabledKey) private var isSelectionVoiceEditEnabled = true
```

- [ ] **Step 3: Backup export and import**

`BackupTypes.swift` — last field of `GeneralBackup` (after `autoLearnModel`):

```swift
    let isSelectionVoiceEditEnabled: Bool?
```

`ImportExportService.swift` — last argument of the `GeneralBackup(` initializer (after `autoLearnModel:`):

```swift
            isSelectionVoiceEditEnabled: SelectionEditService.isEnabled
```

`BackupImporter.swift` — after the Auto Learn imports (after line 248's closing brace of that `if`), before `print("Successfully imported general settings.")`:

```swift
        if let selectionVoiceEditEnabled = general.isSelectionVoiceEditEnabled {
            UserDefaults.standard.set(selectionVoiceEditEnabled, forKey: SelectionEditService.isEnabledKey)
        }
```

- [ ] **Step 4: Run the backup test suite**

Run with `-only-testing:VoiceInkTests/DictionaryImportExportTests`.
Expected: PASS (old-format decode stays green).

- [ ] **Step 5: Commit**

```bash
git add VoiceInk/Views/EnhancementSettingsView.swift VoiceInk/AppDefaults.swift VoiceInk/Services/BackupTypes.swift VoiceInk/Services/ImportExportService.swift VoiceInk/Services/BackupImporter.swift
git commit -m "feat: Edit selection by voice toggle with backup support"
```

---

### Task 5: Localization, CHANGELOG, full test pass

**Files:**
- Modify: `VoiceInk/Resources/Localizable.xcstrings` (4 new keys, hand-added)
- Modify: `CHANGELOG.md` (entry under `## [1.80] - 2026-09-24` → `### Added`)

**Interfaces:**
- Consumes: the localized keys introduced in Tasks 3–4 (verbatim):
  - `Edit selection by voice` → `Правка выделения голосом`
  - `Dictation over a selection is sent to the AI as an instruction; the result replaces the selection.` → `Диктовка над выделением уходит в AI как инструкция; результат заменяет выделение.`
  - `Selection edit failed: %@` → `Не удалось отредактировать выделение: %@`
  - `Selection changed — result copied to clipboard` → `Выделение изменилось — результат скопирован в буфер обмена`

- [ ] **Step 1: Add the ru translations**

Edit `Localizable.xcstrings` with a python script that loads the JSON, adds the four keys with `{"localizations": {"ru": {"stringUnit": {"state": "translated", "value": …}}}}`, and writes back with `json.dumps(d, ensure_ascii=False, indent=2) + "\n"` so key order and formatting match the file.

- [ ] **Step 2: Verify in the built bundle**

After the test run of Step 3, check the strings landed in the app bundle:

```bash
plutil -p "$(find ~/Library/Developer/Xcode/DerivedData -name VoiceInk.app -path '*Debug*' -newer /tmp -maxdepth 6 2>/dev/null | head -1)/Contents/Resources/ru.lproj/Localizable.strings" 2>/dev/null | grep -c "Правка выделения"
```

Expected: the new ru values are present (or read the file with `plutil -p … | grep`). Alternative: build once with `xcodebuild build` using the same signing overrides and check `.app/Contents/Resources/ru.lproj/Localizable.strings`.

- [ ] **Step 3: Run the delivery test suites**

Run the command from Global Constraints for each suite: `SelectionEditTests`, `AutoLearnTests`, `DictionaryImportExportTests`, `QuickHistoryTests`, `ShortcutMonitorTests`, `DoubleTapShortcutTests`.
Expected: all PASS. Save the `Test run with …` lines for the final report.

- [ ] **Step 4: CHANGELOG**

Under `## [1.80] - 2026-09-24` → `### Added`, first line:

```markdown
- Правка выделенного голосом: если при старте записи во встроенном поле есть выделенный текст, диктовка уходит в AI как инструкция («переведи на английский», «сделай списком»), и результат заменяет выделение. Если приложение не отдало выделение через Accessibility или оно изменилось к моменту вставки, результат копируется в буфер обмена. Выключатель «Edit selection by voice» в настройках улучшения, по умолчанию включён; настройки сохраняются в бэкапе.
```

- [ ] **Step 5: Commit**

```bash
git add VoiceInk/Resources/Localizable.xcstrings CHANGELOG.md
git commit -m "docs: selection edit ru strings and changelog"
```
