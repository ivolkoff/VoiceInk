import CoreGraphics
import Foundation
import os

/// Listen-only tap for the switcher. Kept separate from ShortcutMonitor: that tap is active,
/// exists only while modifier-only shortcuts are configured, and restarts on every shortcut
/// change; this one lives and dies with the feature toggle.
final class KeystrokeTap {
    enum Event {
        case keyDown(keyCode: UInt16, flags: CGEventFlags)
        case mouseDown
    }

    private let handler: (Event) -> Void
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "KeystrokeTap")

    init(handler: @escaping (Event) -> Void) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// false when the tap can't be created — Input Monitoring is missing.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if let userInfo {
                Unmanaged<KeystrokeTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            logger.error("tap create failed — Input Monitoring not granted?")
            return false
        }
        self.tap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            guard event.getIntegerValueField(.eventSourceUserData) != DirectTyper.marker else { return }
            handler(.keyDown(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags))
        case .leftMouseDown, .rightMouseDown:
            handler(.mouseDown)
        default:
            break
        }
    }
}
