import CoreGraphics
import Foundation
import Testing
@testable import VoiceInk

struct UserSessionInputPolicyTests {
    private let active: [String: Any] = [
        kCGSessionOnConsoleKey as String: true,
        kCGSessionLoginDoneKey as String: NSNumber(value: true),
    ]

    @Test func activeSessionAllowsShortcuts() {
        #expect(UserSessionInputPolicy.allowsShortcutHandling(sessionProperties: active))
    }

    @Test func lockedSwitchedAwayOrLoggingInBlocksShortcuts() {
        var locked = active
        locked["CGSSessionScreenIsLocked"] = NSNumber(value: true)
        var switchedAway = active
        switchedAway[kCGSessionOnConsoleKey as String] = false
        var loggingIn = active
        loggingIn.removeValue(forKey: kCGSessionLoginDoneKey as String)

        #expect(!UserSessionInputPolicy.allowsShortcutHandling(sessionProperties: locked))
        #expect(!UserSessionInputPolicy.allowsShortcutHandling(sessionProperties: switchedAway))
        #expect(!UserSessionInputPolicy.allowsShortcutHandling(sessionProperties: loggingIn))
    }
}
