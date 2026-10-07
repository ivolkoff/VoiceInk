import Cocoa
import SwiftUI
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var menuBarManager: MenuBarManager?
    weak var meetingRecorder: MeetingRecorder?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarManager?.applyActivationPolicy()
        KeyboardLayoutLanguageService.captureCurrentLayout()
        _ = LayoutSwitcherEngine.shared   // subscribes to the enabled toggle and starts when on
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let menuBarManager = menuBarManager, !menuBarManager.isMenuBarOnly {
            if WindowManager.shared.showMainWindow() != nil {
                return false
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let meetingRecorder else { return .terminateNow }
        let mustWait = meetingRecorder.prepareForTermination {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return mustWait ? .terminateLater : .terminateNow
    }

    // Stash URL when app cold-starts to avoid spawning a new window/tab
    var pendingOpenFileURL: URL?
    
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { SupportedMedia.isSupported(url: $0) }) else {
            return
        }
        
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        if WindowManager.shared.currentMainWindow() == nil {
            // Cold start: do NOT create a window here to avoid extra window/tab.
            // Defer to SwiftUI’s WindowGroup-created ContentView and let it process this later.
            pendingOpenFileURL = url
        } else {
            // Running: focus current window and route in-place to Transcribe Audio
            menuBarManager?.focusMainWindow()
            NotificationCenter.default.post(name: .navigateToDestination, object: nil, userInfo: ["destination": "Transcribe Audio"])
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openFileForTranscription, object: nil, userInfo: ["url": url])
            }
        }
    }
}
