import CoreGraphics
import Foundation

/// Whether the current macOS user session may receive global shortcuts: not while the screen is
/// locked, the session is switched away (fast user switching) or login hasn't finished.
enum UserSessionInputPolicy {
    // CGSession has no public constant for this long-standing WindowServer property.
    private static let screenIsLockedKey = "CGSSessionScreenIsLocked"

    static var allowsShortcutHandling: Bool {
        guard let properties = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return allowsShortcutHandling(sessionProperties: properties)
    }

    static func allowsShortcutHandling(sessionProperties: [String: Any]) -> Bool {
        booleanValue(sessionProperties[kCGSessionOnConsoleKey as String]) == true
            && booleanValue(sessionProperties[kCGSessionLoginDoneKey as String]) == true
            && booleanValue(sessionProperties[screenIsLockedKey]) != true
    }

    private static func booleanValue(_ value: Any?) -> Bool? {
        (value as? Bool) ?? (value as? NSNumber)?.boolValue
    }
}
