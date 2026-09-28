import CoreGraphics
import Foundation

/// Clipboard-free replacement: synthetic Backspaces, then the text as Unicode key events.
/// Posted on `.cgAnnotatedSessionEventTap` — below every session-level tap, ours included —
/// so no other layout switcher (or our own monitors) sees them. Blocks for the µs pauses:
/// KeystrokeTap runs it inside its callback on the tap thread, never on main.
enum DirectTyper {
    /// `eventSourceUserData` on every event we post; KeystrokeTap drops events carrying it.
    static let marker: Int64 = 0x564B_4C53

    private static let backspace: CGKeyCode = 51
    /// A CGEvent carries ~20 UTF-16 units; 12 leaves headroom.
    private static let chunkSize = 12

    static func replace(deleteCount: Int, with text: String) {
        let source = CGEventSource(stateID: .privateState)
        usleep(9_000)   // let the app finish the keystroke that triggered us
        for _ in 0..<deleteCount {
            post(virtualKey: backspace, source: source)
            usleep(500)
        }
        if deleteCount > 0 { usleep(8_000) }
        typeUnicode(text, source: source)
    }

    private static func post(virtualKey: CGKeyCode, source: CGEventSource?, unicode: [UniChar]? = nil) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: down) else { continue }
            e.flags = []
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            if let unicode {
                unicode.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            }
            e.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private static func typeUnicode(_ text: String, source: CGEventSource?) {
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            var end = min(i + chunkSize, units.count)
            // Never split a surrogate pair across events: a lone half inserts garbage.
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
            let chunk = Array(units[i..<end])
            post(virtualKey: 0, source: source, unicode: chunk)
            i = end
            usleep(800)
        }
    }
}
