import AppKit
import Testing
@testable import VoiceInk

struct ShortcutMonitorTests {
    private final class Releases {
        var actions: [ShortcutAction] = []
    }

    private let rightOption = Shortcut.modifierOnly(keyCode: 61, modifierFlags: [.option])

    private func drainMain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func press(_ monitor: ShortcutMonitor, chordKey: UInt16?, at time: TimeInterval) {
        _ = monitor.handleEvent(kind: .flagsChanged, keyCode: 61, mouseButton: 0, modifierFlags: [.option], eventTime: time)
        if let chordKey {
            _ = monitor.handleEvent(kind: .keyDown, keyCode: chordKey, mouseButton: 0, modifierFlags: [.option], eventTime: time + 0.1)
        }
        _ = monitor.handleEvent(kind: .flagsChanged, keyCode: 61, mouseButton: 0, modifierFlags: [], eventTime: time + 0.2)
    }

    @Test func modifierTapFiresADiscreteActionButAChordDoesNot() async {
        let monitor = ShortcutMonitor()
        let releases = Releases()
        monitor.configure(shortcuts: [.convertLayout: rightOption],
                          onKeyDown: { _, _ in }, onKeyUp: { action, _ in releases.actions.append(action) })

        press(monitor, chordKey: nil, at: 1)
        press(monitor, chordKey: 123, at: 2)   // ⌥←
        press(monitor, chordKey: 27, at: 3)    // ⌥⇧- for «—»
        await drainMain()

        #expect(releases.actions == [.convertLayout])
    }

    @Test func holdActionsStillGetTheirReleaseAfterAChord() async {
        let monitor = ShortcutMonitor()
        let releases = Releases()
        monitor.configure(shortcuts: [.primaryRecording: rightOption], interruptibleActions: [.primaryRecording],
                          onKeyDown: { _, _ in }, onKeyUp: { action, _ in releases.actions.append(action) })

        press(monitor, chordKey: 123, at: 1)
        await drainMain()

        #expect(releases.actions == [.primaryRecording])
    }
}
