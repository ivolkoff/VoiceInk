import AppKit
import Testing
@testable import VoiceInk

@MainActor
struct RecorderScreenResolverTests {
    private static func center(of screen: NSScreen) -> NSPoint {
        NSPoint(x: screen.frame.midX, y: screen.frame.midY)
    }

    private static func id(_ screen: NSScreen?) -> CGDirectDisplayID? {
        screen.flatMap(RecorderScreenResolver.displayID(for:))
    }

    @Test func picksTheScreenUnderTheCursor() {
        for screen in NSScreen.screens {
            let resolved = RecorderScreenResolver.resolve(mouseLocation: Self.center(of: screen))
            #expect(Self.id(resolved) == Self.id(screen))
        }
    }

    @Test func retainedDisplayWinsOverTheCursor() {
        for retained in NSScreen.screens {
            for cursorScreen in NSScreen.screens {
                let resolved = RecorderScreenResolver.resolve(
                    preferredDisplayID: Self.id(retained),
                    mouseLocation: Self.center(of: cursorScreen)
                )
                #expect(Self.id(resolved) == Self.id(retained))
            }
        }
    }

    @Test func detachedRetainedDisplayFallsBackToTheCursor() {
        let detached = CGDirectDisplayID.max
        for screen in NSScreen.screens {
            let resolved = RecorderScreenResolver.resolve(
                preferredDisplayID: detached,
                mouseLocation: Self.center(of: screen)
            )
            #expect(Self.id(resolved) == Self.id(screen))
        }
    }

    @Test func notchPanelIsCenteredAtTheTopOfItsScreen() {
        for screen in NSScreen.screens {
            let metrics = NotchRecorderPanel.calculateWindowMetrics(on: screen)
            #expect(metrics.frame.midX == screen.frame.midX)
            #expect(metrics.frame.maxY == screen.frame.maxY)
            #expect(metrics.notchWidth > 0 && metrics.notchHeight > 0)
        }
        let fallback = NotchRecorderPanel.calculateWindowMetrics(on: nil)
        #expect(fallback.notchWidth == 180 && fallback.notchHeight == 37)
    }

    /// Moves the real cursor, so it only runs on request:
    /// `TEST_RUNNER_VOICEINK_CURSOR_TESTS=1 xcodebuild test …`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOICEINK_CURSOR_TESTS"] == "1"))
    func panelsOpenOnTheCursorDisplayAndStayThere() async throws {
        let screens = NSScreen.screens
        guard let primaryHeight = screens.first?.frame.height else { return }
        let original = NSEvent.mouseLocation
        func warp(to screen: NSScreen) async throws {
            let point = Self.center(of: screen)
            // CoreGraphics counts Y from the top of the primary display.
            CGWarpMouseCursorPosition(CGPoint(x: point.x, y: primaryHeight - point.y))
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        defer { CGWarpMouseCursorPosition(CGPoint(x: original.x, y: primaryHeight - original.y)) }

        let notch = NotchRecorderPanel(contentRect: .zero)
        let mini = MiniRecorderPanel(contentRect: .zero)
        defer {
            notch.orderOut(nil)
            mini.orderOut(nil)
        }

        for (index, screen) in screens.enumerated() {
            try await warp(to: screen)
            notch.show()
            mini.show()
            #expect(screen.frame.contains(NSPoint(x: notch.frame.midX, y: notch.frame.midY)))
            #expect(screen.frame.contains(NSPoint(x: mini.frame.midX, y: mini.frame.midY)))
            #expect(notch.screenMetrics.notchSize.width == NotchRecorderPanel.calculateWindowMetrics(on: screen).notchWidth)

            // A display reconfiguration while the cursor is elsewhere must not move the panel.
            let other = screens[(index + 1) % screens.count]
            try await warp(to: other)
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            try await Task.sleep(nanoseconds: 400_000_000)
            #expect(screen.frame.contains(NSPoint(x: notch.frame.midX, y: notch.frame.midY)))
        }
    }
}
