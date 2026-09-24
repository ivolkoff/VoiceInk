import Foundation
import AppKit

/// Context captured at recording start for a "voice edit of the selection" run.
struct SelectionEditContext: Equatable {
    let text: String
    let bundleID: String?
}

/// Outcome of the capture: an editable selection within the length limit, or an
/// over-limit selection the edit must not touch.
enum SelectionEditCapture: Equatable {
    case edit(SelectionEditContext)
    case tooLarge(length: Int, limit: Int)
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
    ) -> SelectionEditCapture? {
        guard isEnabled, isProviderConfigured else { return nil }
        guard let selection,
              !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Secure fields report role `AXTextField` + this subrole; some apps put the
        // name straight into the role, so both are checked.
        let secure = kAXSecureTextFieldSubrole as String
        guard focusedRole != secure, focusedSubrole != secure else { return nil }
        let length = selection.count
        if length > maxInputLength {
            // An over-limit selection must not fall through to ordinary dictation:
            // a short spoken command would replace the whole document.
            return .tooLarge(length: length, limit: maxInputLength)
        }
        return .edit(SelectionEditContext(text: selection, bundleID: frontmostBundleID))
    }

    /// Reads the live selection while the target app still owns focus. Call at
    /// recording start, next to `KeyboardLayoutLanguageService.captureCurrentLayout()`.
    /// `nil` ⇒ ordinary dictation (no AX selection, disabled, unconfigured, secure field…).
    @MainActor
    static func capture(isProviderConfigured: Bool) -> SelectionEditCapture? {
        // Check the role before reading the value so a secure field's content is
        // never read at all; `captureDecision` re-checks for direct callers.
        let role = FocusedTextAccessibility.focusedRole()
        let subrole = FocusedTextAccessibility.focusedSubrole()
        let secure = kAXSecureTextFieldSubrole as String
        guard role != secure, subrole != secure else { return nil }
        return captureDecision(
            isEnabled: isEnabled,
            isProviderConfigured: isProviderConfigured,
            selection: FocusedTextAccessibility.selectedText(),
            focusedRole: role,
            focusedSubrole: subrole,
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
