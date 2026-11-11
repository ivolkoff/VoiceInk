import Foundation
import IOKit.pwr_mgt
import Testing
@testable import VoiceInk

@MainActor
struct ScreenSleepPreventerTests {
    /// Display-sleep assertions this process holds right now, as the system reports them.
    private func heldAssertions() -> Int {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return -1 }

        let own = all[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? []
        return own.filter {
            $0[kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypePreventUserIdleDisplaySleep
                && $0[kIOPMAssertionNameKey] as? String == "VoiceInk Recording Activity"
        }.count
    }

    @Test func holdsOneAssertionBetweenStartAndStop() {
        let preventer = ScreenSleepPreventer.shared
        #expect(heldAssertions() == 0)

        preventer.startPreventingSleep()
        preventer.startPreventingSleep()
        #expect(heldAssertions() == 1)

        preventer.stopPreventingSleep()
        #expect(heldAssertions() == 0)

        preventer.stopPreventingSleep()
        preventer.startPreventingSleep()
        #expect(heldAssertions() == 1)
        preventer.stopPreventingSleep()
        #expect(heldAssertions() == 0)
    }
}
