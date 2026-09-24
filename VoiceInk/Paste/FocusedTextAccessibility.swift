import Foundation
import ApplicationServices

/// Reads the current text selection of the system-wide focused UI element via Accessibility.
/// Used by the re-transcribe-last hotkey to verify — before replacing — that the text it is about
/// to overwrite is exactly what VoiceInk pasted, and by the layout switcher for the same reason.
enum FocusedTextAccessibility {
    /// The selected text of the focused element, or `nil` when there is no focus or the element
    /// does not expose `AXSelectedText` (common for web / Electron fields). A `nil` result must be
    /// treated as "can't verify" and the caller must fall back to a non-destructive path.
    @MainActor
    static func selectedText() -> String? {
        guard let element = focusedElement() else { return nil }
        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selection) == .success,
              let text = selection as? String else {
            return nil
        }
        return text
    }

    /// Text of the focused element up to the caret (or the start of the selection). nil when the
    /// element exposes no value or range — then the screen can't be checked against the buffer.
    @MainActor
    static func textBeforeCaret() -> String? {
        guard let element = focusedElement() else { return nil }
        var value: CFTypeRef?
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        let nsText = text as NSString
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location <= nsText.length else { return nil }
        return nsText.substring(to: range.location)
    }

    /// Role of the focused element (`AXSecureTextField` for password fields); nil when unknown.
    @MainActor
    static func focusedRole() -> String? {
        guard let element = focusedElement() else { return nil }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success else { return nil }
        return role as? String
    }

    /// Focused element plus its role/subrole from a single lookup. `selectedText` reads
    /// lazily so a caller can gate on editability before pulling the value across the
    /// process boundary; separate focused-element lookups would each pay the 0.5 s
    /// messaging timeout.
    struct SelectionSnapshot {
        let element: AXUIElement
        let role: String?
        let subrole: String?

        var selectedText: String? {
            var selection: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selection) == .success else {
                return nil
            }
            return selection as? String
        }
    }

    @MainActor
    static func selectionSnapshot() -> SelectionSnapshot? {
        guard let element = focusedElement() else { return nil }
        var role: CFTypeRef?
        let roleValue = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success ? role as? String : nil
        var subrole: CFTypeRef?
        let subroleValue = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success ? subrole as? String : nil
        return SelectionSnapshot(element: element, role: roleValue, subrole: subroleValue)
    }

    /// Subrole of the focused element. Secure text fields carry role `AXTextField` and this
    /// subrole `AXSecureTextField`, so the password-field gate must check both.
    @MainActor
    static func focusedSubrole() -> String? {
        guard let element = focusedElement() else { return nil }
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success else { return nil }
        return subrole as? String
    }

    @MainActor
    private static func focusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        // Bound the synchronous cross-process AX read so an unresponsive focused app can't hang the UI.
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedValue = focused,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (focusedValue as! AXUIElement)
    }
}
