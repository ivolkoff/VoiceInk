import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import SelectedTextKit

class SelectedTextService {
    static func fetchSelectedText() async -> String? {
        let strategies: [TextStrategy] = [.accessibility, .menuAction]
        do {
            let selectedText = try await SelectedTextManager.shared.getSelectedText(strategies: strategies)
            return selectedText
        } catch {
            print("Failed to get selected text: \(error)")
            return nil
        }
    }

    /// Capture text for the enhance-selected-text action.
    ///
    /// Prefers the user's active selection. When nothing is selected and an editable
    /// text element is focused, falls back to selecting all text in that field. The
    /// result distinguishes a real selection, a select-all fallback, and "no usable text"
    /// so the select-all side effect is never triggered in non-text contexts.
    static func captureForEnhancement() async -> SelectedTextCaptureResult {
        if let selected = await nonEmptySelectedText() {
            return .selection(selected)
        }

        let hasEditableField = await MainActor.run { focusedEditableElement() != nil }
        guard hasEditableField else {
            return .noText
        }

        await selectAllInFocusedField()

        if let selectedAll = await nonEmptySelectedText() {
            return .selectedAll(selectedAll)
        }

        return .noText
    }

    private static func nonEmptySelectedText() async -> String? {
        guard let text = await fetchSelectedText(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }

    // MARK: - Focused editable element detection

    private static func focusedEditableElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focused = focusedValue,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return nil
        }

        let element = focused as! AXUIElement
        guard isEditableTextRole(element) || isSelectedTextSettable(element) else {
            return nil
        }
        return element
    }

    private static func isEditableTextRole(_ element: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else {
            return false
        }

        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]
        return editableRoles.contains(role)
    }

    private static func isSelectedTextSettable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    // MARK: - Select-all fallback

    @MainActor
    private static func selectAllInFocusedField() async {
        guard AXIsProcessTrusted() else { return }

        let source = CGEventSource(stateID: .privateState)
        let commandKey: CGKeyCode = 0x37
        let aKey: CGKeyCode = 0x00

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: true),
              let aDown = CGEvent(keyboardEventSource: source, virtualKey: aKey, keyDown: true),
              let aUp = CGEvent(keyboardEventSource: source, virtualKey: aKey, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: false) else {
            return
        }

        aDown.flags = .maskCommand
        aUp.flags = .maskCommand

        cmdDown.post(tap: .cghidEventTap)
        await wait(0.01)
        aDown.post(tap: .cghidEventTap)
        await wait(0.01)
        aUp.post(tap: .cghidEventTap)
        await wait(0.01)
        cmdUp.post(tap: .cghidEventTap)

        // Give the focused app a moment to apply the selection before re-capturing.
        await wait(0.05)
    }

    private static func wait(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
