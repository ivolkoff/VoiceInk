import AppKit
import SwiftData
import SwiftUI

@MainActor
final class QuickHistoryController: NSObject {
    static let shared = QuickHistoryController()

    private var panel: QuickHistoryPanel?
    private var viewModel: QuickHistoryViewModel?
    private var targetApplication: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    private override init() {
        super.init()

        rememberExternalApplication(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                self?.rememberExternalApplication(application)
            }
        }
    }

    func show(modelContext: ModelContext, engine: VoiceInkEngine) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            viewModel?.reload()
            return
        }

        targetApplication = resolvedTargetApplication()

        guard let enhancementService = engine.enhancementService else { return }

        let viewModel = QuickHistoryViewModel(modelContext: modelContext)
        let rootView = QuickHistoryView(
            viewModel: viewModel,
            onPaste: { [weak self] transcription in
                self?.paste(transcription)
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )
        .modelContainer(modelContext.container)
        .environmentObject(engine)
        .environmentObject(enhancementService)

        let panel = QuickHistoryPanel(size: NSSize(width: 680, height: 470))
        panel.onEscape = { [weak self] in
            self?.handleEscape()
        }
        panel.onKeyDown = { [weak self] event in
            self?.handlePanelKeyDown(event) ?? false
        }
        panel.onDismissRequest = { [weak self] in
            self?.dismiss()
        }
        panel.contentViewController = NSHostingController(rootView: rootView)

        self.panel = panel
        self.viewModel = viewModel
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard let panel else { return }

        panel.persistPosition()
        panel.onEscape = nil
        panel.onKeyDown = nil
        panel.onDismissRequest = nil
        self.panel = nil
        viewModel = nil
        panel.orderOut(nil)
        panel.close()
    }

    private func handlePanelKeyDown(_ event: NSEvent) -> Bool {
        guard let viewModel else { return false }

        switch event.keyCode {
        case 125 where !viewModel.isShowingDetail: // down arrow
            viewModel.moveSelection(by: 1)
            return true
        case 126 where !viewModel.isShowingDetail: // up arrow
            viewModel.moveSelection(by: -1)
            return true
        case 36, 76: // Return, keypad Enter
            if event.modifierFlags.contains(.command) {
                viewModel.showDetail()
            } else if let transcription = viewModel.transcriptionForPaste() {
                performPaste(transcription)
            }
            return true
        default:
            return false
        }
    }

    private func paste(_ requestedTranscription: Transcription) {
        guard let transcription = viewModel?.transcriptionForPaste(preferredID: requestedTranscription.id) else {
            return
        }
        performPaste(transcription)
    }

    private func performPaste(_ transcription: Transcription) {
        let text = transcription.preferredHistoryText
        let targetApplication = resolvedTargetApplication() ?? targetApplication
        self.targetApplication = nil
        dismiss()

        targetApplication?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            CursorPaster.pasteAtCursor(text)
        }
    }

    private func resolvedTargetApplication() -> NSRunningApplication? {
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           isExternalApplication(frontmostApplication) {
            rememberExternalApplication(frontmostApplication)
            return frontmostApplication
        }

        if let lastExternalApplication, !lastExternalApplication.isTerminated {
            return lastExternalApplication
        }
        return nil
    }

    private func rememberExternalApplication(_ application: NSRunningApplication?) {
        guard let application, isExternalApplication(application), !application.isTerminated else { return }
        lastExternalApplication = application
    }

    private func isExternalApplication(_ application: NSRunningApplication) -> Bool {
        application.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }

    private func handleEscape() {
        if viewModel?.closeInnermostLevel() != true {
            dismiss()
        }
    }
}

final class QuickHistoryPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onKeyDown: ((NSEvent) -> Bool)?
    var onDismissRequest: (() -> Void)?

    private static let positionDefaultsKey = "VoiceInkQuickHistoryOrigin"

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = true
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        restorePosition()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidMove),
            name: NSWindow.didMoveNotification,
            object: self
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // Arrows and Return must reach the controller before the focused search field consumes them.
    override func sendEvent(_ event: NSEvent) {
        // While an input method is composing, Return/arrows/Escape belong to its candidate window.
        guard event.type == .keyDown,
              (firstResponder as? NSTextInputClient)?.hasMarkedText() != true else {
            super.sendEvent(event)
            return
        }

        if event.keyCode == 53 {
            performEscapeAction()
            return
        }
        if onKeyDown?(event) == true {
            return
        }
        super.sendEvent(event)
    }

    private func performEscapeAction() {
        if let onEscape {
            onEscape()
        } else {
            onDismissRequest?()
        }
    }

    override func resignKey() {
        super.resignKey()

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isKeyWindow, !self.isHostingFocusedAuxiliaryWindow else { return }
            self.onDismissRequest?()
        }
    }

    func persistPosition() {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.positionDefaultsKey)
    }

    @objc private func panelDidMove() {
        persistPosition()
    }

    private var isHostingFocusedAuxiliaryWindow: Bool {
        guard let keyWindow = NSApp.keyWindow else { return false }
        return keyWindow.parent == self
            || childWindows?.contains(keyWindow) == true
            || keyWindow.sheetParent == self
            || attachedSheet == keyWindow
    }

    private func restorePosition() {
        if let storedOrigin = UserDefaults.standard.string(forKey: Self.positionDefaultsKey) {
            let origin = NSPointFromString(storedOrigin)
            let proposedFrame = NSRect(origin: origin, size: frame.size)
            // A saved origin on a since-disconnected display would open the panel off screen.
            if NSScreen.screens.contains(where: {
                let visible = $0.visibleFrame.intersection(proposedFrame)
                return visible.width >= 120 && visible.height >= 80
            }) {
                setFrameOrigin(origin)
                return
            }
        }

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            center()
            return
        }
        setFrameOrigin(NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2 + 48
        ))
    }
}
