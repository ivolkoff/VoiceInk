import CoreAudio
import Foundation
import Testing
@testable import VoiceInk

struct RecorderErrorTests {
    @Test func hardwareNotRunningFromAnyStartStepMeansAudioSystemIsStuck() {
        let failures: [CoreAudioRecorderError] = [
            .failedToStart(status: kAudioHardwareNotRunningError),
            .failedToInitialize(status: kAudioHardwareNotRunningError),
            .failedToSetDevice(status: kAudioHardwareNotRunningError),
        ]

        for failure in failures {
            #expect(Recorder.RecorderError(startFailure: failure) == .audioSystemNotRunning)
        }
    }

    @Test func otherFailuresStayGeneric() {
        let failures: [Error] = [
            CoreAudioRecorderError.failedToStart(status: -1),
            CoreAudioRecorderError.deviceNotAvailable,
            URLError(.unknown),
        ]

        for failure in failures {
            #expect(Recorder.RecorderError(startFailure: failure) == .couldNotStartRecording)
        }
    }
}
