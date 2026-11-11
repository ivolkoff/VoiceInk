import AppKit

@MainActor
enum RecorderScreenResolver {
    /// The retained display if it is still attached, then the cursor's screen, the active
    /// screen, and any screen.
    static func resolve(preferredDisplayID: CGDirectDisplayID? = nil, mouseLocation: NSPoint? = nil) -> NSScreen? {
        let screens = NSScreen.screens
        if let preferredDisplayID,
           let retained = screens.first(where: { displayID(for: $0) == preferredDisplayID }) {
            return retained
        }

        let mouseLocation = mouseLocation ?? NSEvent.mouseLocation
        return screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main ?? screens.first
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
