import Testing
@testable import VoiceInk

struct ReturnToAppTests {
    @Test func noTargetPastesInPlace() {
        #expect(ReturnToApp.decision(targetPID: nil, targetIsTerminated: false, frontmostPID: 20, ownPID: 1) == .paste)
    }

    @Test func ownAppPastesInPlace() {
        #expect(ReturnToApp.decision(targetPID: 1, targetIsTerminated: false, frontmostPID: 20, ownPID: 1) == .paste)
    }

    @Test func targetAlreadyFrontPastesInPlace() {
        #expect(ReturnToApp.decision(targetPID: 20, targetIsTerminated: false, frontmostPID: 20, ownPID: 1) == .paste)
    }

    @Test func otherAppInFrontReturnsToTarget() {
        #expect(ReturnToApp.decision(targetPID: 20, targetIsTerminated: false, frontmostPID: 30, ownPID: 1) == .returnTo(20))
    }

    @Test func terminatedTargetCannotReturn() {
        #expect(ReturnToApp.decision(targetPID: 20, targetIsTerminated: true, frontmostPID: 30, ownPID: 1) == .cannotReturn)
    }
}
