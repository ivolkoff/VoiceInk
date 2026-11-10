import Testing
@testable import VoiceInk

struct ReleaseTailPolicyTests {
    private func q(_ n: Int) -> [Bool] { Array(repeating: false, count: n) }
    private func s(_ n: Int) -> [Bool] { Array(repeating: true, count: n) }

    @Test func baseTailAlwaysRecorded() {
        #expect(ReleaseTailPolicy.shouldKeepRecording([]))
        #expect(ReleaseTailPolicy.shouldKeepRecording(q(9)))
    }

    @Test func quietAfterReleaseStopsAtBase() {
        #expect(!ReleaseTailPolicy.shouldKeepRecording(q(10)))
    }

    @Test func wordThroughBaseKeepsGoingUntilQuiet() {
        #expect(ReleaseTailPolicy.shouldKeepRecording(s(10)))
        #expect(ReleaseTailPolicy.shouldKeepRecording(s(10) + q(7)))
        #expect(!ReleaseTailPolicy.shouldKeepRecording(s(10) + q(8)))
    }

    @Test func capStopsAt600ms() {
        #expect(!ReleaseTailPolicy.shouldKeepRecording(s(30)))
    }

    @Test func keyClickDoesNotExtend() {
        #expect(!ReleaseTailPolicy.shouldKeepRecording(s(1) + q(9)))
        #expect(!ReleaseTailPolicy.shouldKeepRecording(q(7) + s(3)))
    }

    @Test func syllableGapsStillCountAsTalking() {
        #expect(ReleaseTailPolicy.shouldKeepRecording([true, true, false, true, true, false, true, true, true, true]))
    }

    @Test func wordEndingInsideBaseStopsAtBase() {
        #expect(!ReleaseTailPolicy.shouldKeepRecording(s(6) + q(4)))
    }
}
