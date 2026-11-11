import Foundation
import IOKit.pwr_mgt
import os

@MainActor
final class ScreenSleepPreventer {
    static let shared = ScreenSleepPreventer()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ScreenSleepPreventer")
    private var assertionID: IOPMAssertionID = 0

    private init() {}

    func startPreventingSleep() {
        guard assertionID == 0 else { return }

        var newAssertionID: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "VoiceInk Recording Activity" as CFString,
            &newAssertionID
        )

        if status == kIOReturnSuccess {
            assertionID = newAssertionID
        } else {
            logger.error("Failed to create display sleep assertion: \(status, privacy: .public)")
        }
    }

    func stopPreventingSleep() {
        guard assertionID != 0 else { return }

        // Clear before releasing: after a failed release the ID is no longer valid, and
        // keeping it would block every later recording from taking a new assertion.
        let releasingID = assertionID
        assertionID = 0

        let status = IOPMAssertionRelease(releasingID)
        if status != kIOReturnSuccess {
            logger.error("Failed to release display sleep assertion: \(status, privacy: .public)")
        }
    }
}
