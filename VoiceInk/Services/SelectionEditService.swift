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
        isEditable: Bool,
        maxInputLength: Int,
        frontmostBundleID: String?
    ) -> SelectionEditCapture? {
        // A read-only selection (web page, PDF, terminal output) has nowhere for the
        // result to land — treating it as an edit would paste into whatever is focused.
        guard isEnabled, isProviderConfigured, isEditable else { return nil }
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
        // One focused-element lookup for all attributes; gate on editability and the
        // secure subrole before reading the value so protected text is never read.
        guard let snapshot = FocusedTextAccessibility.selectionSnapshot(),
              SelectedTextService.isEditableText(snapshot.element) else { return nil }
        let secure = kAXSecureTextFieldSubrole as String
        guard snapshot.role != secure, snapshot.subrole != secure else { return nil }
        return captureDecision(
            isEnabled: isEnabled,
            isProviderConfigured: isProviderConfigured,
            selection: snapshot.selectedText,
            focusedRole: snapshot.role,
            focusedSubrole: snapshot.subrole,
            isEditable: true,
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
