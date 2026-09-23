import Foundation
import AppKit
import os

@MainActor
class RecordingShortcutManager: ObservableObject {
    @Published var primaryRecordingShortcut: ShortcutSelection {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcut.rawValue, forKey: "primaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var secondaryRecordingShortcut: ShortcutSelection {
        didSet {
            if secondaryRecordingShortcut == .none {
                ShortcutStore.setShortcut(nil, for: .secondaryRecording)
            }
            UserDefaults.standard.set(secondaryRecordingShortcut.rawValue, forKey: "secondaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var primaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcutMode.rawValue, forKey: "primaryRecordingShortcutMode")
            primaryRecordingShortcutModeSource.primaryMode = primaryRecordingShortcutMode
            shortcutModeHandler.resetShortcutState(for: .primaryRecording)
        }
    }
    @Published var secondaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(secondaryRecordingShortcutMode.rawValue, forKey: "secondaryRecordingShortcutMode")
            shortcutModeHandler.resetShortcutState(for: .secondaryRecording)
        }
    }
    @Published var isMiddleClickToggleEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMiddleClickToggleEnabled, forKey: "isMiddleClickToggleEnabled")
            refreshShortcutMonitoring()
        }
    }
    @Published var middleClickActivationDelay: Int {
        didSet {
            UserDefaults.standard.set(middleClickActivationDelay, forKey: "middleClickActivationDelay")
        }
    }
    
    private var engine: VoiceInkEngine
    private var recorderUIManager: RecorderUIManager
    private var miniRecorderShortcutManager: MiniRecorderShortcutManager
    private let powerModeShortcutManager: PowerModeShortcutManager
    private let shortcutMonitor = ShortcutMonitor()
    private var shortcutChangeObserver: NSObjectProtocol?
    private let shortcutModeHandler: RecordingShortcutModeHandler
    private let primaryRecordingShortcutModeSource: RecordingShortcutModeSource
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecordingShortcutManager")

    private lazy var selectedTextEnhancementService: SelectedTextEnhancementService? = {
        guard let enhancementService = engine.enhancementService else { return nil }
        return SelectedTextEnhancementService(enhancementService: enhancementService)
    }()

    // MARK: - Helper Properties
    private var canHandleShortcutAction: Bool {
        Self.canHandleShortcutAction(for: engine.recordingState)
    }
    
    // Middle-click event monitoring
    private var middleClickMonitors: [Any?] = []
    private var middleClickTask: Task<Void, Never>?

    enum Mode: String, CaseIterable {
        case toggle = "toggle"
        case pushToTalk = "pushToTalk"
        case hybrid = "hybrid"
        case doubleTap = "doubleTap"

        var displayName: String {
            switch self {
            case .toggle: return "Toggle"
            case .pushToTalk: return "Push to Talk"
            case .hybrid: return "Hybrid"
            case .doubleTap: return "Double Tap"
            }
        }
    }

    enum ShortcutSelection: String, CaseIterable {
        case none = "none"
        case custom = "custom"
        
        var displayName: String {
            switch self {
            case .none: return "None"
            case .custom: return "Custom"
            }
        }
    }

    private static func canHandleShortcutAction(for recordingState: RecordingState) -> Bool {
        recordingState != .transcribing &&
        recordingState != .enhancing &&
        recordingState != .busy
    }

    init(engine: VoiceInkEngine, recorderUIManager: RecorderUIManager) {
        ShortcutMigration.migrateLegacyShortcutsIfNeeded()

        self.primaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .primaryRecording,
            allowsNone: false
        )
        self.secondaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .secondaryRecording,
            allowsNone: true
        )

        let primaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .primaryRecording
        )
        self.primaryRecordingShortcutMode = primaryRecordingShortcutMode
        self.secondaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .secondaryRecording
        )

        self.isMiddleClickToggleEnabled = UserDefaults.standard.bool(forKey: "isMiddleClickToggleEnabled")
        self.middleClickActivationDelay = UserDefaults.standard.integer(forKey: "middleClickActivationDelay")

        let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecordingShortcutManager")
        let shortcutModeHandler = RecordingShortcutModeHandler(
            logger: logger,
            canHandleShortcutAction: {
                Self.canHandleShortcutAction(for: engine.recordingState)
            },
            isRecorderVisible: {
                recorderUIManager.isMiniRecorderVisible
            },
            recordingState: {
                engine.recordingState
            },
            toggleMiniRecorder: { powerModeId in
                await recorderUIManager.toggleMiniRecorder(powerModeId: powerModeId)
            },
            cancelRecording: {
                await recorderUIManager.cancelRecording()
            }
        )

        let primaryRecordingShortcutModeSource = RecordingShortcutModeSource(
            primaryMode: primaryRecordingShortcutMode
        )

        self.engine = engine
        self.recorderUIManager = recorderUIManager
        self.miniRecorderShortcutManager = MiniRecorderShortcutManager(engine: engine, recorderUIManager: recorderUIManager)
        self.shortcutModeHandler = shortcutModeHandler
        self.primaryRecordingShortcutModeSource = primaryRecordingShortcutModeSource
        self.powerModeShortcutManager = PowerModeShortcutManager(
            modeProvider: {
                primaryRecordingShortcutModeSource.primaryMode
            },
            shortcutModeHandler: shortcutModeHandler
        )

        self.miniRecorderShortcutManager.onVisibleShortcutsRefreshed = { [weak self] in
            Task { @MainActor in
                self?.refreshShortcutMonitor()
            }
        }

        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.shortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshShortcutMonitoring()
            }
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.refreshShortcutMonitoring()
        }
    }
    
    private func refreshShortcutMonitoring() {
        removeAllMonitoring()
        
        refreshShortcutMonitor()
        setupMiddleClickMonitoring()
    }
    
    private func setupMiddleClickMonitoring() {
        guard isMiddleClickToggleEnabled else { return }

        // Mouse Down
        let downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self = self, event.buttonNumber == 2 else { return }

            Task { @MainActor in
                self.middleClickTask?.cancel()
                self.middleClickTask = Task {
                    do {
                        let delay = UInt64(self.middleClickActivationDelay) * 1_000_000 // ms to ns
                        try await Task.sleep(nanoseconds: delay)
                        
                        guard self.isMiddleClickToggleEnabled, !Task.isCancelled else { return }
                        guard self.canHandleShortcutAction else { return }
                        
                        await self.recorderUIManager.toggleMiniRecorder()
                    } catch {
                        // Cancelled
                    }
                }
            }
        }

        // Mouse Up
        let upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            guard let self = self, event.buttonNumber == 2 else { return }
            Task { @MainActor in
                self.middleClickTask?.cancel()
            }
        }

        middleClickMonitors = [downMonitor, upMonitor]
    }
    
    func refreshShortcutMonitor() {
        let primaryShortcut = primaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .primaryRecording) : nil
        let secondaryShortcut = secondaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .secondaryRecording) : nil
        var shortcuts = ShortcutStore.shortcuts(for: ShortcutAction.globalUtilityActions)
        var interruptibleRecordingActions = Set<ShortcutAction>()

        if let primaryShortcut {
            shortcuts[.primaryRecording] = primaryShortcut
            interruptibleRecordingActions.insert(.primaryRecording)
        }

        if let secondaryShortcut {
            shortcuts[.secondaryRecording] = secondaryShortcut
            interruptibleRecordingActions.insert(.secondaryRecording)
        }

        shortcutMonitor.start(
            shortcuts: shortcuts,
            interruptibleActions: interruptibleRecordingActions,
            onKeyDown: { [weak self] action, eventTime in
                Task { @MainActor in
                    guard let self else { return }
                    self.logger.notice("onKeyDown: action=\(action.storageName, privacy: .public), eventTime=\(eventTime, privacy: .public), state=\(String(describing: self.engine.recordingState), privacy: .public), visible=\(self.recorderUIManager.isMiniRecorderVisible, privacy: .public)")
                    guard let mode = self.recordingMode(for: action) else { return }
                    await self.shortcutModeHandler.handleKeyDown(
                        action: action,
                        eventTime: eventTime,
                        mode: mode
                    )
                }
            },
            onKeyUp: { [weak self] action, eventTime in
                Task { @MainActor in
                    guard let self else { return }
                    self.logger.notice("onKeyUp: action=\(action.storageName, privacy: .public), eventTime=\(eventTime, privacy: .public), state=\(String(describing: self.engine.recordingState), privacy: .public), visible=\(self.recorderUIManager.isMiniRecorderVisible, privacy: .public)")
                    if let mode = self.recordingMode(for: action) {
                        await self.shortcutModeHandler.handleKeyUp(
                            action: action,
                            eventTime: eventTime,
                            mode: mode
                        )
                    } else {
                        await self.handleGlobalShortcut(action)
                    }
                }
            },
            onShortcutPressed: { [weak self] action, eventTime in
                Task { @MainActor in
                    guard let self else { return }
                    self.logger.notice("onShortcutPressed: action=\(action.storageName, privacy: .public), eventTime=\(eventTime, privacy: .public), state=\(String(describing: self.engine.recordingState), privacy: .public), visible=\(self.recorderUIManager.isMiniRecorderVisible, privacy: .public)")
                    if let mode = self.recordingMode(for: action) {
                        await self.shortcutModeHandler.handleDiscretePress(
                            action: action,
                            eventTime: eventTime,
                            mode: mode
                        )
                    } else {
                        await self.handleGlobalShortcut(action)
                    }
                }
            },
            onShortcutInterrupted: { [weak self] action, _ in
                Task { @MainActor in
                    guard let self, self.recordingMode(for: action) != nil else { return }
                    await self.shortcutModeHandler.handleInterruption(action: action)
                }
            },
            onOtherKeyDown: { [weak self] in
                MainActor.assumeIsolated { self?.shortcutModeHandler.clearPendingDoubleTaps(powerMode: false) }
            }
        )
    }

    private func recordingMode(for action: ShortcutAction) -> Mode? {
        switch action {
        case .primaryRecording:
            return primaryRecordingShortcutMode
        case .secondaryRecording:
            return secondaryRecordingShortcutMode
        default:
            return nil
        }
    }

    private func handleGlobalShortcut(_ action: ShortcutAction) async {
        switch action {
        case .pasteLastTranscription:
            LastTranscriptionService.pasteLastTranscription(from: engine.modelContext)
        case .pasteLastEnhancement:
            LastTranscriptionService.pasteLastEnhancement(from: engine.modelContext)
        case .retryLastTranscription:
            LastTranscriptionService.retryLastTranscription(
                from: engine.modelContext,
                transcriptionModelManager: engine.transcriptionModelManager,
                serviceRegistry: engine.serviceRegistry,
                enhancementService: engine.enhancementService
            )
        case .retranscribeLastInLayoutLanguage:
            await RetranscribeLastInLayoutLanguageService.run(
                modelContext: engine.modelContext,
                transcriptionModelManager: engine.transcriptionModelManager,
                engine: engine
            )
        case .convertLayout:
            await LayoutSwitcherEngine.shared.handleManualTrigger()
        case .openHistoryWindow:
            HistoryWindowController.shared.showHistoryWindow(
                modelContainer: engine.modelContext.container,
                engine: engine
            )
        case .openQuickHistory:
            QuickHistoryController.shared.show(modelContext: engine.modelContext, engine: engine)
        case .quickAddToDictionary:
            DictionaryQuickAddManager.shared.toggle(modelContainer: engine.modelContext.container)
        case .enhanceSelectedText:
            await enhanceSelectedText()
        default:
            break
        }
    }

    /// Runs the enhance-selected-text action. Shared by the global shortcut and the menu bar item.
    /// - Parameter focusSettleDelay: pass a small delay for menu-bar triggers so focus returns to
    ///   the source app before the selection is captured; the global shortcut passes `0`.
    func enhanceSelectedText(focusSettleDelay: TimeInterval = 0) async {
        if let selectedTextEnhancementService {
            await selectedTextEnhancementService.run(focusSettleDelay: focusSettleDelay)
        } else {
            NotificationManager.shared.showNotification(title: String(localized: "AI Enhancement is not available"), type: .error)
        }
    }

    private func removeAllMonitoring() {
        shortcutMonitor.stop()
        
        for monitor in middleClickMonitors {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        middleClickMonitors = []
        middleClickTask?.cancel()
        
        shortcutModeHandler.reset()
    }
    
    var isShortcutConfigured: Bool {
        let isPrimaryShortcutConfigured = primaryRecordingShortcut != .none && ShortcutStore.shortcut(for: .primaryRecording) != nil
        let isSecondaryShortcutConfigured = secondaryRecordingShortcut == .none || ShortcutStore.shortcut(for: .secondaryRecording) != nil
        return isPrimaryShortcutConfigured && isSecondaryShortcutConfigured
    }
    
    func updateShortcutStatus() {
        // Called when a shortcut changes
        refreshShortcutMonitoring()
    }
    
    deinit {
        if let shortcutChangeObserver {
            NotificationCenter.default.removeObserver(shortcutChangeObserver)
        }

        MainActor.assumeIsolated {
            removeAllMonitoring()
        }
    }
}

@MainActor
private final class RecordingShortcutModeSource {
    var primaryMode: RecordingShortcutManager.Mode

    init(primaryMode: RecordingShortcutManager.Mode) {
        self.primaryMode = primaryMode
    }
}

@MainActor
final class RecordingShortcutModeHandler {
    private let logger: Logger
    private let canHandleShortcutAction: @MainActor () -> Bool
    private let isRecorderVisible: @MainActor () -> Bool
    private let recordingState: @MainActor () -> RecordingState
    private let toggleMiniRecorder: @MainActor (UUID?) async -> Void
    private let cancelRecording: @MainActor () async -> Void

    private var shortcutPressStartTime: TimeInterval?
    private var isHandsFreeRecording = false
    private var isShortcutPressed = false
    private var activeRecordingShortcutAction: ShortcutAction?
    private var interruptedRecordingActions = Set<ShortcutAction>()
    private var activeShortcutCanCancelAccidentalStart = false
    private var activeShortcutIsDoubleTap = false
    private var lastShortcutPressTime: Date?
    /// First short tap of a pending double tap, per action.
    private var pendingDoubleTapTimes: [ShortcutAction: TimeInterval] = [:]

    private let shortcutPressCooldown: TimeInterval = 0.5
    private let hybridPressThreshold: TimeInterval = 0.5
    private let doubleTapThreshold: TimeInterval = 0.7

    init(
        logger: Logger,
        canHandleShortcutAction: @escaping @MainActor () -> Bool,
        isRecorderVisible: @escaping @MainActor () -> Bool,
        recordingState: @escaping @MainActor () -> RecordingState,
        toggleMiniRecorder: @escaping @MainActor (UUID?) async -> Void,
        cancelRecording: @escaping @MainActor () async -> Void
    ) {
        self.logger = logger
        self.canHandleShortcutAction = canHandleShortcutAction
        self.isRecorderVisible = isRecorderVisible
        self.recordingState = recordingState
        self.toggleMiniRecorder = toggleMiniRecorder
        self.cancelRecording = cancelRecording
    }

    func reset() {
        isShortcutPressed = false
        shortcutPressStartTime = nil
        isHandsFreeRecording = false
        activeRecordingShortcutAction = nil
        interruptedRecordingActions.removeAll()
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false
        clearPendingDoubleTaps()
    }

    /// Any other key between the taps means it wasn't a double tap.
    func clearPendingDoubleTaps() {
        pendingDoubleTapTimes.removeAll()
    }

    /// Each monitor sees the other monitor's shortcut as "another key", so it clears only its own taps.
    func clearPendingDoubleTaps(powerMode: Bool) {
        pendingDoubleTapTimes = pendingDoubleTapTimes.filter { action, _ in
            if case .powerMode = action { return !powerMode }
            return powerMode
        }
    }

    func resetShortcutState(for action: ShortcutAction) {
        pendingDoubleTapTimes.removeValue(forKey: action)
        guard activeRecordingShortcutAction == action else { return }
        isShortcutPressed = false
        shortcutPressStartTime = nil
        activeRecordingShortcutAction = nil
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false
    }

    /// Second short tap within the threshold → true; otherwise remembers this tap as the first.
    private func completesDoubleTap(_ action: ShortcutAction, at eventTime: TimeInterval) -> Bool {
        if let first = pendingDoubleTapTimes.removeValue(forKey: action),
           eventTime - first >= 0, eventTime - first <= doubleTapThreshold {
            return true
        }
        pendingDoubleTapTimes[action] = eventTime
        return false
    }

    func handleKeyDown(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        powerModeId: UUID? = nil
    ) async {
        logger.notice("handleKeyDown enter: action=\(action.storageName, privacy: .public), mode=\(mode.rawValue, privacy: .public), eventTime=\(eventTime, privacy: .public), isShortcutPressed=\(self.isShortcutPressed, privacy: .public), active=\(self.activeRecordingShortcutAction?.storageName ?? "nil", privacy: .public), handsFree=\(self.isHandsFreeRecording, privacy: .public), visible=\(self.isRecorderVisible(), privacy: .public), state=\(String(describing: self.recordingState()), privacy: .public)")
        if interruptedRecordingActions.remove(action) != nil {
            logger.notice("handleKeyDown ignored: interrupted action=\(action.storageName, privacy: .public)")
            return
        }

        if mode == .doubleTap && (!canHandleShortcutAction() || recordingState() == .starting) {
            pendingDoubleTapTimes.removeValue(forKey: action)
            return
        }

        // The cooldown would swallow the second tap of a double tap.
        if mode != .doubleTap, let lastTrigger = lastShortcutPressTime,
           Date().timeIntervalSince(lastTrigger) < shortcutPressCooldown {
            logger.notice("handleKeyDown ignored: cooldown action=\(action.storageName, privacy: .public)")
            return
        }

        guard !isShortcutPressed else {
            logger.notice("handleKeyDown ignored: already pressed action=\(action.storageName, privacy: .public)")
            return
        }
        isShortcutPressed = true
        activeRecordingShortcutAction = action
        activeShortcutIsDoubleTap = mode == .doubleTap
        activeShortcutCanCancelAccidentalStart = mode != .doubleTap && canCurrentShortcutPressCancelAccidentalStart
        if mode != .doubleTap {
            lastShortcutPressTime = Date()
        }
        shortcutPressStartTime = eventTime

        switch mode {
        case .toggle, .hybrid:
            if isHandsFreeRecording {
                isHandsFreeRecording = false
                guard canHandleShortcutAction() else { return }
                logger.notice("handleShortcutKeyDown: toggling mini recorder (hands-free toggle)")
                await toggleMiniRecorder(powerModeId)
                return
            }

            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                logger.notice("handleShortcutKeyDown: toggling mini recorder (key down while not visible)")
                await toggleMiniRecorder(powerModeId)
            }

        case .pushToTalk:
            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                logger.notice("handleShortcutKeyDown: starting recording (push-to-talk key down)")
                await toggleMiniRecorder(powerModeId)
            }

        case .doubleTap:
            break   // decided on release
        }
    }

    func handleKeyUp(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        powerModeId: UUID? = nil
    ) async {
        logger.notice("handleKeyUp enter: action=\(action.storageName, privacy: .public), mode=\(mode.rawValue, privacy: .public), eventTime=\(eventTime, privacy: .public), isShortcutPressed=\(self.isShortcutPressed, privacy: .public), active=\(self.activeRecordingShortcutAction?.storageName ?? "nil", privacy: .public), handsFree=\(self.isHandsFreeRecording, privacy: .public), visible=\(self.isRecorderVisible(), privacy: .public), state=\(String(describing: self.recordingState()), privacy: .public)")
        guard isShortcutPressed, activeRecordingShortcutAction == action else {
            logger.notice("handleKeyUp ignored: state mismatch action=\(action.storageName, privacy: .public)")
            return
        }
        isShortcutPressed = false
        activeRecordingShortcutAction = nil
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false

        switch mode {
        case .toggle:
            isHandsFreeRecording = true

        case .pushToTalk:
            if isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                logger.notice("handleShortcutKeyUp: stopping recording (push-to-talk key up)")
                await toggleMiniRecorder(powerModeId)
            }

        case .hybrid:
            let pressDuration = shortcutPressStartTime.map { eventTime - $0 } ?? 0
            if pressDuration >= hybridPressThreshold && recordingState() == .recording {
                guard canHandleShortcutAction() else { return }
                logger.notice("handleShortcutKeyUp: stopping recording (hybrid push-to-talk, duration=\(pressDuration, privacy: .public)s)")
                await toggleMiniRecorder(powerModeId)
            } else {
                isHandsFreeRecording = true
            }

        case .doubleTap:
            guard canHandleShortcutAction(), recordingState() != .starting else {
                pendingDoubleTapTimes.removeValue(forKey: action)
                break
            }
            let pressDuration = shortcutPressStartTime.map { eventTime - $0 } ?? 0
            if pressDuration < 0 || pressDuration > doubleTapThreshold {
                pendingDoubleTapTimes.removeValue(forKey: action)   // a hold is not a tap
            } else if completesDoubleTap(action, at: eventTime) {
                logger.notice("handleShortcutKeyUp: toggling mini recorder (double tap)")
                await toggleMiniRecorder(powerModeId)
                isHandsFreeRecording = isRecorderVisible()
            }
        }

        shortcutPressStartTime = nil
    }

    func handleDiscretePress(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        powerModeId: UUID? = nil
    ) async {
        logger.notice("handleDiscretePress enter: action=\(action.storageName, privacy: .public), mode=\(mode.rawValue, privacy: .public), eventTime=\(eventTime, privacy: .public), isShortcutPressed=\(self.isShortcutPressed, privacy: .public), active=\(self.activeRecordingShortcutAction?.storageName ?? "nil", privacy: .public), handsFree=\(self.isHandsFreeRecording, privacy: .public), visible=\(self.isRecorderVisible(), privacy: .public), state=\(String(describing: self.recordingState()), privacy: .public)")
        if interruptedRecordingActions.remove(action) != nil {
            logger.notice("handleDiscretePress ignored: interrupted action=\(action.storageName, privacy: .public)")
            return
        }

        isShortcutPressed = false
        activeRecordingShortcutAction = nil
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false
        shortcutPressStartTime = nil
        isHandsFreeRecording = isRecorderVisible()

        guard canHandleShortcutAction() else {
            pendingDoubleTapTimes.removeValue(forKey: action)
            return
        }

        // Carbon hot keys arrive as a single press, so a double tap is two presses.
        if mode == .doubleTap {
            guard recordingState() != .starting, completesDoubleTap(action, at: eventTime) else { return }
        }

        switch mode {
        case .toggle, .hybrid, .pushToTalk, .doubleTap:
            logger.notice("handleDiscreteShortcutPress: toggling mini recorder (eventTime=\(eventTime, privacy: .public)s)")
            await toggleMiniRecorder(powerModeId)
        }
    }

    func handleInterruption(action: ShortcutAction) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else {
            if canCurrentShortcutPressCancelAccidentalStart {
                interruptedRecordingActions.insert(action)
            }
            return
        }

        if activeShortcutIsDoubleTap {
            resetShortcutState(for: action)   // part of a chord: neither tap counts
            return
        }

        guard activeShortcutCanCancelAccidentalStart else { return }

        logger.notice("handleShortcutInterruption: cancelling recording shortcut that became part of a larger key chord")
        reset()
        await cancelRecording()
    }

    private var canCurrentShortcutPressCancelAccidentalStart: Bool {
        !isRecorderVisible() && recordingState() == .idle
    }
}
