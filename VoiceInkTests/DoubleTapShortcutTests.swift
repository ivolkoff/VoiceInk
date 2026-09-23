import os
import Testing
@testable import VoiceInk

@MainActor
struct DoubleTapShortcutTests {
    private final class Recorder {
        var toggles = 0
        var visible = false
    }

    private func makeHandler(_ recorder: Recorder) -> RecordingShortcutModeHandler {
        RecordingShortcutModeHandler(
            logger: Logger(subsystem: "tests", category: "DoubleTap"),
            canHandleShortcutAction: { true },
            isRecorderVisible: { recorder.visible },
            recordingState: { .idle },
            toggleMiniRecorder: { _ in recorder.toggles += 1; recorder.visible.toggle() },
            cancelRecording: {}
        )
    }

    private func tap(_ handler: RecordingShortcutModeHandler, down: Double, up: Double) async {
        await handler.handleKeyDown(action: .primaryRecording, eventTime: down, mode: .doubleTap)
        await handler.handleKeyUp(action: .primaryRecording, eventTime: up, mode: .doubleTap)
    }

    @Test func twoQuickTapsToggleOnce() async {
        let recorder = Recorder()
        let handler = makeHandler(recorder)
        await tap(handler, down: 0, up: 0.1)
        #expect(recorder.toggles == 0)
        await tap(handler, down: 0.3, up: 0.4)
        #expect(recorder.toggles == 1)
    }

    @Test func slowSecondTapHoldOrKeyInBetweenDoNotToggle() async {
        let recorder = Recorder()
        let handler = makeHandler(recorder)

        await tap(handler, down: 0, up: 0.1)
        await tap(handler, down: 1.5, up: 1.6)      // too late: becomes a new first tap

        await tap(handler, down: 3, up: 4)          // a hold is not a tap
        await tap(handler, down: 4.2, up: 4.3)      // first tap again

        handler.clearPendingDoubleTaps()            // another key typed in between
        await tap(handler, down: 4.5, up: 4.6)

        #expect(recorder.toggles == 0)
    }

    @Test func twoCarbonPressesToggleOnce() async {
        let recorder = Recorder()
        let handler = makeHandler(recorder)
        await handler.handleDiscretePress(action: .primaryRecording, eventTime: 0, mode: .doubleTap)
        await handler.handleDiscretePress(action: .primaryRecording, eventTime: 0.4, mode: .doubleTap)
        #expect(recorder.toggles == 1)
    }
}
