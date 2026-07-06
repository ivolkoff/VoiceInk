import Foundation
import ApplicationServices

/// Reads the current text selection of the system-wide focused UI element via Accessibility.
/// Used by the re-transcribe-last hotkey to verify — before replacing — that the text it is about
/// to overwrite is exactly what VoiceInk pasted.
enum FocusedTextAccessibility {
    /// The selected text of the focused element, or `nil` when there is no focus or the element
    /// does not expose `AXSelectedText` (common for web / Electron fields). A `nil` result must be
    /// treated as "can't verify" and the caller must fall back to a non-destructive path.
    @MainActor
    static func selectedText() -> String? {
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

        let element = focusedValue as! AXUIElement
        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selection) == .success,
              let text = selection as? String else {
            return nil
        }
        return text
    }
}
