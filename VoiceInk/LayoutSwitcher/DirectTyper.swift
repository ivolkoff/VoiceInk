import CoreGraphics
import Foundation

/// Clipboard-free replacement: synthetic Backspaces, then the text as Unicode key events.
/// Posted on `.cgAnnotatedSessionEventTap` — below every session-level tap, ours included —
/// so no other layout switcher (or our own monitors) sees them. The µs pauses run on a private
/// serial queue: the main thread hosts active event taps and must never sleep.
enum DirectTyper {
    /// `eventSourceUserData` on every event we post; KeystrokeTap drops events carrying it.
    static let marker: Int64 = 0x564B_4C53

    private static let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.layout-typer", qos: .userInteractive)
    private static let backspace: CGKeyCode = 51
    /// A CGEvent carries ~20 UTF-16 units; 12 leaves headroom for surrogate pairs.
    private static let chunkSize = 12

    static func replace(deleteCount: Int, with text: String, completion: @escaping () -> Void) {
        queue.async {
            let source = CGEventSource(stateID: .privateState)
            usleep(9_000)   // let the app finish the keystroke that triggered us
            for _ in 0..<deleteCount {
                post(virtualKey: backspace, source: source)
                usleep(500)
            }
            if deleteCount > 0 { usleep(8_000) }
            typeUnicode(text, source: source)
            DispatchQueue.main.async(execute: completion)
        }
    }

    static func type(_ text: String, completion: @escaping () -> Void) {
        replace(deleteCount: 0, with: text, completion: completion)
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
            let chunk = Array(units[i..<min(i + chunkSize, units.count)])
            post(virtualKey: 0, source: source, unicode: chunk)
            i += chunkSize
            usleep(800)
        }
    }
}
