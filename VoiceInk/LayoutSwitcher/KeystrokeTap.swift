import CoreGraphics
import Foundation
import os

/// The switcher's tap. Kept separate from ShortcutMonitor: that tap lives on main, exists only while
/// modifier-only shortcuts are configured and restarts on every shortcut change; this one lives and
/// dies with the feature toggle. Active and on its own thread, so a replacement can run inside the
/// callback (`runAtomically`) and a busy main thread never stalls anyone's input.
final class KeystrokeTap {
    enum Event {
        case keyDown(keyCode: UInt16, flags: CGEventFlags)
        case mouseDown
    }

    /// `eventSourceUserData` of the flagsChanged event that makes the callback run the pending job.
    static let flushMarker: Int64 = 0x564B_4C46

    private struct Job {
        let id: Int
        let afterSeq: UInt64
        let work: () -> Void
        let done: (Bool) -> Void
    }

    private let handler: (Event, UInt64) -> Void
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private let lock = NSLock()
    private var seq: UInt64 = 0   // real key and mouse downs seen; guarded by lock
    private var job: Job?         // guarded by lock
    private var nextJobID = 0
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "KeystrokeTap")

    /// `handler` runs on main with each event's sequence number, in tap order.
    init(handler: @escaping (Event, UInt64) -> Void) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// false when the tap can't be created — Accessibility or Input Monitoring is missing.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            return Unmanaged<KeystrokeTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            logger.error("tap create failed — Accessibility or Input Monitoring not granted?")
            return false
        }
        self.tap = tap
        var loop: CFRunLoop?
        let ready = DispatchSemaphore(value: 0)
        // The callback reaches self unretained; keep it alive until this loop exits after stop().
        let thread = Thread { [self] in
            withExtendedLifetime(self) {
                loop = CFRunLoopGetCurrent()
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
                ready.signal()
                CFRunLoopRun()
            }
        }
        thread.name = "LayoutSwitcher.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        runLoop = loop
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
        runLoop = nil
        lock.lock()
        let pending = job
        job = nil
        lock.unlock()
        pending?.done(false)
    }

    /// Runs `work` inside the callback, where WindowServer holds every later event, so nothing typed
    /// meanwhile can land inside the replacement. Skipped — `done(false)` — when a key or click
    /// arrived after `afterSeq` (the screen may no longer match) or the marker never came back.
    /// `done` runs on main, ordered before the handler call for any event that followed.
    // ponytail: holds all input for the whole replacement; a huge selection could trip the tap
    // timeout — chunk the job across several markers if that ever shows in the logs.
    func runAtomically(afterSeq: UInt64, work: @escaping () -> Void, done: @escaping (Bool) -> Void) {
        lock.lock()
        nextJobID += 1
        let id = nextJobID
        job = Job(id: id, afterSeq: afterSeq, work: work, done: done)
        lock.unlock()
        // flagsChanged with the current flags: harmless if it ever slips past us.
        let marker = CGEvent(source: nil)
        marker?.type = .flagsChanged
        marker?.flags = CGEventSource.flagsState(.combinedSessionState)
        marker?.setIntegerValueField(.eventSourceUserData, value: Self.flushMarker)
        marker?.post(tap: .cgSessionEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let lost = self.job?.id == id ? self.job : nil
            if lost != nil { self.job = nil }
            self.lock.unlock()
            lost?.done(false)
        }
    }

    // MARK: - Tap thread

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            if event.getIntegerValueField(.eventSourceUserData) == Self.flushMarker {
                flush()
                return nil
            }
        case .keyDown:
            if event.getIntegerValueField(.eventSourceUserData) != DirectTyper.marker {
                forward(.keyDown(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags))
            }
        case .leftMouseDown, .rightMouseDown:
            forward(.mouseDown)
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func forward(_ event: Event) {
        lock.lock()
        seq += 1
        let n = seq
        lock.unlock()
        let handler = handler
        DispatchQueue.main.async { handler(event, n) }
    }

    private func flush() {
        lock.lock()
        let pending = job
        job = nil
        let fresh = pending?.afterSeq == seq
        lock.unlock()
        guard let pending else { return }
        if fresh { pending.work() }
        DispatchQueue.main.async { pending.done(fresh) }
    }
}
