import SwiftUI
import AppKit

@MainActor
final class NotchRecorderScreenMetrics: ObservableObject {
    @Published var notchSize = NSSize(width: 180, height: 37)
}

class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class NotchRecorderPanel: KeyablePanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    let screenMetrics = NotchRecorderScreenMetrics()
    private var displayID: CGDirectDisplayID?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .hudWindow],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .statusBar + 3
        self.backgroundColor = .clear
        self.isOpaque = false
        self.alphaValue = 1.0
        self.hasShadow = false
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.appearance = NSAppearance(named: .darkAqua)
        self.styleMask.remove(.titled)
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.standardWindowButton(.closeButton)?.isHidden = true
        self.isMovable = false

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    static func calculateWindowMetrics(on screen: NSScreen?) -> (frame: NSRect, notchWidth: CGFloat, notchHeight: CGFloat) {
        guard let screen else {
            return (NSRect(x: 0, y: 0, width: 280, height: 24), 180, 37)
        }

        let safeAreaInsets = screen.safeAreaInsets
        let notchHeight: CGFloat = safeAreaInsets.top > 0
            ? safeAreaInsets.top
            : NSApplication.shared.mainMenu?.menuBarHeight ?? NSStatusBar.system.thickness

        let notchWidth: CGFloat = {
            if let left = screen.auxiliaryTopLeftArea?.width,
               let right = screen.auxiliaryTopRightArea?.width {
                return screen.frame.width - left - right
            }
            return 180
        }()

        let maxSideExpansion: CGFloat = 110
        let sideMargin: CGFloat = 10
        let totalWidth = notchWidth + (maxSideExpansion + sideMargin) * 2

        let maxContentHeight: CGFloat = 200
        let xPosition = screen.frame.midX - (totalWidth / 2)
        let yPosition = screen.frame.maxY - maxContentHeight

        let frame = NSRect(x: xPosition, y: yPosition, width: totalWidth, height: maxContentHeight)
        return (frame, notchWidth, notchHeight)
    }

    func show() {
        place(on: RecorderScreenResolver.resolve())
        orderFrontRegardless()
    }

    private func place(on screen: NSScreen?) {
        displayID = screen.flatMap(RecorderScreenResolver.displayID(for:))
        let metrics = NotchRecorderPanel.calculateWindowMetrics(on: screen)
        screenMetrics.notchSize = NSSize(width: metrics.notchWidth, height: metrics.notchHeight)
        setFrame(metrics.frame, display: true)
    }

    func hide(completion: @escaping () -> Void) {
        completion()
    }

    @objc private func handleScreenParametersChange() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            // Stay on the display the recorder opened on; the cursor may be elsewhere by now.
            self.place(on: RecorderScreenResolver.resolve(preferredDisplayID: self.displayID))
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

class NotchRecorderHostingController<Content: View>: NSHostingController<Content> {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }
}
