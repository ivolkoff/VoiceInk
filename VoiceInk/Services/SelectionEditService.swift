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
