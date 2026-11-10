import AppKit

enum ReturnToApp {
    static let userDefaultsKey = "returnToAppBeforePaste"

    enum Decision: Equatable {
        case paste
        case returnTo(pid_t)
        case cannotReturn
    }

    static func decision(targetPID: pid_t?, targetIsTerminated: Bool, frontmostPID: pid_t?, ownPID: pid_t) -> Decision {
        guard let targetPID, targetPID != ownPID else { return .paste }
        if targetIsTerminated { return .cannotReturn }
        return targetPID == frontmostPID ? .paste : .returnTo(targetPID)
    }

    @MainActor
    static func bringToFront(_ app: NSRunningApplication, timeout: TimeInterval = 0.5) async -> Bool {
        app.activate()
        let deadline = Date().addingTimeInterval(timeout)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // Give the app's key window a moment to take focus before Cmd+V is posted.
        try? await Task.sleep(nanoseconds: 50_000_000)
        return true
    }
}
