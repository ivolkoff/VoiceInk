import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

final class ShortcutMonitor {
    fileprivate enum EventKind {
        case keyDown
        case keyUp
        case flagsChanged
    }

    private struct ShortcutState {
        var shortcut: Shortcut
        var isDown = false
        var pressedAt: TimeInterval?
        var isInterrupted = false
    }

    private var shortcuts: [ShortcutAction: ShortcutState] = [:]
    private var interruptibleActions: Set<ShortcutAction> = []
    private var onKeyDown: ((ShortcutAction, TimeInterval) -> Void)?
    private var onKeyUp: ((ShortcutAction, TimeInterval) -> Void)?
    private var onShortcutPressed: ((ShortcutAction, TimeInterval) -> Void)?
    private var onShortcutInterrupted: ((ShortcutAction, TimeInterval) -> Void)?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var carbonEventHandler: EventHandlerRef?
    private var carbonHotKeys: [EventHotKeyRef] = []
    private var carbonHotKeyActions: [UInt32: ShortcutAction] = [:]
    private var eventTapActions: Set<ShortcutAction>?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ShortcutMonitor")

    private static var hasRequestedListenEventAccess = false
    private static let shortcutInterruptionWindow: TimeInterval = 1.0

    deinit {
        stop()
    }

    @discardableResult
    func start(
        shortcuts: [ShortcutAction: Shortcut],
        interruptibleActions: Set<ShortcutAction> = [],
        onKeyDown: @escaping (ShortcutAction, TimeInterval) -> Void,
        onKeyUp: @escaping (ShortcutAction, TimeInterval) -> Void,
        onShortcutPressed: ((ShortcutAction, TimeInterval) -> Void)? = nil,
        onShortcutInterrupted: ((ShortcutAction, TimeInterval) -> Void)? = nil
    ) -> Bool {
        stop()

        for (action, shortcut) in shortcuts {
            self.shortcuts[action] = ShortcutState(shortcut: shortcut)
            logger.notice("start: action=\(action.storageName, privacy: .public), shortcut=\(shortcut.displayString, privacy: .public), kind=\(shortcut.kind.rawValue, privacy: .public)")
        }

        guard !self.shortcuts.isEmpty else {
            return true
        }

        self.interruptibleActions = interruptibleActions
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
        self.onShortcutPressed = onShortcutPressed
        self.onShortcutInterrupted = onShortcutInterrupted

        return installEventTap()
    }

    func stop() {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        unregisterCarbonHotKeys()

        shortcuts = [:]
        interruptibleActions = []
        eventTapActions = nil
        onKeyDown = nil
        onKeyUp = nil
        onShortcutPressed = nil
        onShortcutInterrupted = nil
    }

    private func installEventTap() -> Bool {
        #if DEBUG || LOCAL_BUILD
        let tapShortcuts = shortcuts.filter { _, state in
            state.shortcut.isModifierOnly
        }
        let carbonShortcuts = shortcuts.filter { _, state in
            state.shortcut.canRegisterWithCarbonHotKey
        }

        logger.notice("install: carbon=\(carbonShortcuts.count, privacy: .public), eventTap=\(tapShortcuts.count, privacy: .public), interruptible=\(self.interruptibleActions.map { $0.storageName }.joined(separator: ","), privacy: .public)")
        let didInstallCarbonHotKeys = installCarbonHotKeys(for: carbonShortcuts)
        eventTapActions = Set(tapShortcuts.keys)
        guard !tapShortcuts.isEmpty else {
            return didInstallCarbonHotKeys || carbonShortcuts.isEmpty
        }
        #endif

        guard Self.hasListenEventAccess() else {
            #if DEBUG || LOCAL_BUILD
            return didInstallCarbonHotKeys
            #else
            return false
            #endif
        }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                monitor.resetPressedShortcutsAfterTapInterruption()
                if let eventTap = monitor.eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let shouldSuppress = monitor.handleCGEvent(type: type, event: event)
            return shouldSuppress ? nil : Unmanaged.passUnretained(event)
        }

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            #if DEBUG || LOCAL_BUILD
            return didInstallCarbonHotKeys
            #else
            return false
            #endif
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            return false
        }

        self.eventTap = eventTap
        eventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    #if DEBUG || LOCAL_BUILD
    private func installCarbonHotKeys(for shortcuts: [ShortcutAction: ShortcutState]) -> Bool {
        guard !shortcuts.isEmpty else {
            return false
        }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.carbonHotKeyHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &carbonEventHandler
        )

        guard installStatus == noErr else {
            logger.error("carbon install handler failed status=\(installStatus, privacy: .public)")
            return false
        }

        var nextID: UInt32 = 1

        for (action, state) in shortcuts {
            let hotKeyID = EventHotKeyID(signature: Self.carbonHotKeySignature, id: nextID)
            var hotKeyRef: EventHotKeyRef?
            let registerStatus = RegisterEventHotKey(
                UInt32(state.shortcut.keyCode),
                state.shortcut.carbonModifierFlags,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            guard registerStatus == noErr, let hotKeyRef else {
                logger.error("carbon register failed: id=\(nextID, privacy: .public), action=\(action.storageName, privacy: .public), shortcut=\(state.shortcut.displayString, privacy: .public), status=\(registerStatus, privacy: .public)")
                nextID += 1
                continue
            }

            carbonHotKeys.append(hotKeyRef)
            carbonHotKeyActions[nextID] = action
            logger.notice("carbon registered: id=\(nextID, privacy: .public), action=\(action.storageName, privacy: .public), shortcut=\(state.shortcut.displayString, privacy: .public), interruptible=\(self.interruptibleActions.contains(action), privacy: .public)")
            nextID += 1
        }

        if carbonHotKeys.isEmpty {
            unregisterCarbonHotKeys()
            return false
        }

        return true
    }

    private func unregisterCarbonHotKeys() {
        for hotKey in carbonHotKeys {
            UnregisterEventHotKey(hotKey)
        }

        carbonHotKeys = []
        carbonHotKeyActions = [:]

        if let carbonEventHandler {
            RemoveEventHandler(carbonEventHandler)
            self.carbonEventHandler = nil
        }
    }

    private func handleCarbonHotKey(event: EventRef?) -> OSStatus {
        guard let event else {
            logger.notice("carbon event: missing event")
            return Self.carbonEventNotHandled
        }

        var hotKeyID = EventHotKeyID()
        let parameterStatus = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard parameterStatus == noErr,
              hotKeyID.signature == Self.carbonHotKeySignature,
              let action = carbonHotKeyActions[hotKeyID.id]
        else {
            logger.notice("carbon event not handled: status=\(parameterStatus, privacy: .public), signature=\(hotKeyID.signature, privacy: .public), id=\(hotKeyID.id, privacy: .public), kind=\(Int(GetEventKind(event)), privacy: .public)")
            return Self.carbonEventNotHandled
        }

        guard var state = shortcuts[action] else {
            logger.notice("carbon event no state: id=\(hotKeyID.id, privacy: .public), action=\(action.storageName, privacy: .public), kind=\(Int(GetEventKind(event)), privacy: .public)")
            return Self.carbonEventNotHandled
        }

        let eventTime = ProcessInfo.processInfo.systemUptime
        logger.notice("carbon event handled: id=\(hotKeyID.id, privacy: .public), action=\(action.storageName, privacy: .public), kind=\(Int(GetEventKind(event)), privacy: .public), isDown=\(state.isDown, privacy: .public), hasDiscrete=\(self.onShortcutPressed != nil, privacy: .public), interruptible=\(self.interruptibleActions.contains(action), privacy: .public)")

        switch Int(GetEventKind(event)) {
        case kEventHotKeyPressed:
            if onShortcutPressed != nil {
                state.isDown = true
                state.pressedAt = eventTime
                state.isInterrupted = false
                shortcuts[action] = state
                dispatchShortcutPressed(for: action, eventTime: eventTime)
                return noErr
            }

            if state.isDown {
                state.isDown = false
                state.pressedAt = nil
                state.isInterrupted = false
                shortcuts[action] = state
                dispatchKeyUp(for: action, eventTime: eventTime)
            }

            state.isDown = true
            state.pressedAt = eventTime
            state.isInterrupted = false
            shortcuts[action] = state
            dispatchKeyDown(for: action, eventTime: eventTime)

            if !interruptibleActions.contains(action) {
                state.isDown = false
                state.pressedAt = nil
                state.isInterrupted = false
                shortcuts[action] = state
                dispatchKeyUp(for: action, eventTime: eventTime)
            }

        case kEventHotKeyReleased:
            guard interruptibleActions.contains(action) else { return noErr }
            guard state.isDown else { return noErr }
            state.isDown = false
            state.pressedAt = nil
            state.isInterrupted = false
            shortcuts[action] = state
            dispatchKeyUp(for: action, eventTime: eventTime)

        default:
            break
        }

        return noErr
    }

    private static let carbonHotKeySignature: OSType = 0x56494B48 // VIKH
    private static let carbonEventNotHandled = OSStatus(eventNotHandledErr)

    private static let carbonHotKeyHandler: EventHandlerUPP = { _, event, userData in
        guard let userData else {
            return noErr
        }

        let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userData).takeUnretainedValue()
        return monitor.handleCarbonHotKey(event: event)
    }
    #else
    private func unregisterCarbonHotKeys() {}
    #endif

    private static func hasListenEventAccess() -> Bool {
        if CGPreflightListenEventAccess() {
            return true
        }

        guard !hasRequestedListenEventAccess else {
            return false
        }

        hasRequestedListenEventAccess = true
        return CGRequestListenEventAccess()
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard let eventKind = EventKind(type) else {
            return false
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        if type == .keyDown || type == .keyUp || type == .flagsChanged {
            logger.notice("cg event: type=\(type.rawValue, privacy: .public), keyCode=\(keyCode, privacy: .public), flags=\(modifierFlags.rawValue, privacy: .public)")
        }
        return handleEvent(
            kind: eventKind,
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            eventTime: ProcessInfo.processInfo.systemUptime
        )
    }

    private func resetPressedShortcutsAfterTapInterruption() {
        let eventTime = ProcessInfo.processInfo.systemUptime
        let pressedActions = shortcuts.compactMap { action, state in
            state.isDown ? action : nil
        }

        guard !pressedActions.isEmpty else {
            return
        }

        for action in pressedActions {
            if var state = shortcuts[action] {
                state.isDown = false
                state.pressedAt = nil
                state.isInterrupted = false
                shortcuts[action] = state
            }
            dispatchKeyUp(for: action, eventTime: eventTime)
        }
    }

    private func handleEvent(
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventTime: TimeInterval
    ) -> Bool {
        var shouldSuppress = false

        if kind == .keyDown {
            handleShortcutInterruptions(keyCode: keyCode, eventTime: eventTime)
        }

        let actions = eventTapActions ?? Set(shortcuts.keys)

        for action in Array(actions) {
            guard var state = shortcuts[action] else {
                continue
            }

            if state.shortcut.isModifierOnly {
                handleModifierOnlyShortcut(
                    action: action,
                    state: state,
                    kind: kind,
                    keyCode: keyCode,
                    modifierFlags: modifierFlags,
                    eventTime: eventTime
                )
                continue
            }

            let transition = transitionForKeyShortcut(
                state.shortcut,
                isDown: state.isDown,
                kind: kind,
                keyCode: keyCode,
                modifierFlags: modifierFlags
            )

            switch transition {
            case .none:
                break
            case .suppress:
                shouldSuppress = true
            case .keyDown:
                logger.notice("dispatch keyDown: action=\(action.storageName, privacy: .public), eventTime=\(eventTime, privacy: .public)")
                state.isDown = true
                state.pressedAt = eventTime
                state.isInterrupted = false
                shortcuts[action] = state
                shouldSuppress = true
                dispatchKeyDown(for: action, eventTime: eventTime)
            case .keyUp:
                logger.notice("dispatch keyUp: action=\(action.storageName, privacy: .public), eventTime=\(eventTime, privacy: .public)")
                state.isDown = false
                state.pressedAt = nil
                state.isInterrupted = false
                shortcuts[action] = state
                shouldSuppress = true
                dispatchKeyUp(for: action, eventTime: eventTime)
            }
        }

        return shouldSuppress
    }

    private enum ShortcutTransition {
        case none
        case suppress
        case keyDown
        case keyUp
    }

    private func transitionForKeyShortcut(
        _ shortcut: Shortcut,
        isDown: Bool,
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ShortcutTransition {
        switch kind {
        case .keyDown:
            guard shortcut.matchesKeyEvent(keyCode: keyCode, modifierFlags: modifierFlags) else {
                return .none
            }

            return isDown ? .suppress : .keyDown
        case .keyUp:
            return isDown && keyCode == shortcut.keyCode ? .keyUp : .none
        case .flagsChanged:
            guard isDown else {
                return .none
            }

            let currentFlags = Shortcut.normalizedModifierFlags(
                modifierFlags,
                forKeyCode: shortcut.keyCode
            )
            return currentFlags.isSuperset(of: shortcut.modifierFlags) ? .suppress : .keyUp
        }
    }

    private func handleModifierOnlyShortcut(
        action: ShortcutAction,
        state: ShortcutState,
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventTime: TimeInterval
    ) {
        var state = state

        guard kind == .flagsChanged else {
            return
        }

        if state.isDown {
            if state.shortcut.shouldReleaseModifierEvent(keyCode: keyCode, modifierFlags: modifierFlags) {
                state.isDown = false
                state.pressedAt = nil
                state.isInterrupted = false
                shortcuts[action] = state
                dispatchKeyUp(for: action, eventTime: eventTime)
            }

            return
        }

        if state.shortcut.matchesModifierEvent(keyCode: keyCode, modifierFlags: modifierFlags) {
            state.isDown = true
            state.pressedAt = eventTime
            state.isInterrupted = false
            shortcuts[action] = state
            dispatchKeyDown(for: action, eventTime: eventTime)
        }
    }

    private func handleShortcutInterruptions(keyCode: UInt16, eventTime: TimeInterval) {
        guard !Shortcut.isModifierKeyCode(keyCode) else {
            return
        }

        for action in interruptibleActions {
            guard var state = shortcuts[action],
                  state.isDown,
                  !state.isInterrupted,
                  let pressedAt = state.pressedAt,
                  eventTime - pressedAt <= Self.shortcutInterruptionWindow,
                  state.shortcut.isInterruptedByAdditionalKeyDown(keyCode: keyCode)
            else {
                continue
            }

            state.isInterrupted = true
            shortcuts[action] = state
            dispatchShortcutInterrupted(for: action, eventTime: eventTime)
        }
    }

    private func dispatchKeyDown(for action: ShortcutAction, eventTime: TimeInterval) {
        logger.notice("queue keyDown: action=\(action.storageName, privacy: .public), eventTime=\(eventTime, privacy: .public)")
        DispatchQueue.main.async { [onKeyDown] in
            onKeyDown?(action, eventTime)
        }
    }

    private func dispatchKeyUp(for action: ShortcutAction, eventTime: TimeInterval) {
        logger.notice("queue keyUp: action=\(action.storageName, privacy: .public), eventTime=\(eventTime, privacy: .public)")
        DispatchQueue.main.async { [onKeyUp] in
            onKeyUp?(action, eventTime)
        }
    }

    private func dispatchShortcutInterrupted(for action: ShortcutAction, eventTime: TimeInterval) {
        logger.notice("queue interrupted: action=\(action.storageName, privacy: .public), eventTime=\(eventTime, privacy: .public)")
        DispatchQueue.main.async { [onShortcutInterrupted] in
            onShortcutInterrupted?(action, eventTime)
        }
    }

    private func dispatchShortcutPressed(for action: ShortcutAction, eventTime: TimeInterval) {
        logger.notice("queue pressed: action=\(action.storageName, privacy: .public), eventTime=\(eventTime, privacy: .public)")
        DispatchQueue.main.async { [onShortcutPressed] in
            onShortcutPressed?(action, eventTime)
        }
    }

    private static let eventMask: CGEventMask = [
        CGEventType.keyDown,
        CGEventType.keyUp,
        CGEventType.flagsChanged
    ].reduce(CGEventMask(0)) { mask, type in
        mask | (CGEventMask(1) << Int(type.rawValue))
    }
}

private extension ShortcutMonitor.EventKind {
    init?(_ type: CGEventType) {
        switch type {
        case .keyDown:
            self = .keyDown
        case .keyUp:
            self = .keyUp
        case .flagsChanged:
            self = .flagsChanged
        default:
            return nil
        }
    }
}
