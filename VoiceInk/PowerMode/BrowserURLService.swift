import Foundation
import AppKit
import os

enum BrowserType {
    case safari
    case arc
    case chrome
    case edge
    case firefox
    case brave
    case opera
    case vivaldi
    case orion
    case zen
    case yandex
    
    var scriptName: String {
        switch self {
        case .safari: return "safariURL"
        case .arc: return "arcURL"
        case .chrome: return "chromeURL"
        case .edge: return "edgeURL"
        case .firefox: return "firefoxURL"
        case .brave: return "braveURL"
        case .opera: return "operaURL"
        case .vivaldi: return "vivaldiURL"
        case .orion: return "orionURL"
        case .zen: return "zenURL"
        case .yandex: return "yandexURL"
        }
    }
    
    var bundleIdentifier: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .arc: return "company.thebrowser.Browser"
        case .chrome: return "com.google.Chrome"
        case .edge: return "com.microsoft.edgemac"
        case .firefox: return "org.mozilla.firefox"
        case .brave: return "com.brave.Browser"
        case .opera: return "com.operasoftware.Opera"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        case .orion: return "com.kagi.kagimacOS"
        case .zen: return "app.zen-browser.zen"
        case .yandex: return "ru.yandex.desktop.yandex-browser"
        }
    }
    
    var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .arc: return "Arc"
        case .chrome: return "Google Chrome"
        case .edge: return "Microsoft Edge"
        case .firefox: return "Firefox"
        case .brave: return "Brave"
        case .opera: return "Opera"
        case .vivaldi: return "Vivaldi"
        case .orion: return "Orion"
        case .zen: return "Zen Browser"
        case .yandex: return "Yandex Browser"
        }
    }
    
    static var allCases: [BrowserType] {
        [.safari, .arc, .chrome, .edge, .firefox, .brave, .opera, .vivaldi, .orion, .zen, .yandex]
    }
    
    static var installedBrowsers: [BrowserType] {
        allCases.filter { browser in
            let workspace = NSWorkspace.shared
            return workspace.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) != nil
        }
    }
}

enum BrowserURLError: Error {
    case scriptNotFound
    case executionFailed
    case browserNotRunning
    case noActiveWindow
    case noActiveTab
}

class BrowserURLService {
    static let shared = BrowserURLService()
    
    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "browser.applescript"
    )
    
    private init() {}
    
    func getCurrentURL(from browser: BrowserType) async throws -> String {
        guard let scriptURL = Bundle.main.url(forResource: browser.scriptName, withExtension: "scpt") else {
            logger.error("❌ AppleScript file not found: \(browser.scriptName, privacy: .public).scpt")
            throw BrowserURLError.scriptNotFound
        }
        
        logger.debug("🔍 Attempting to execute AppleScript for \(browser.displayName, privacy: .public)")
        
        // Check if browser is running
        if !isRunning(browser) {
            logger.error("❌ Browser not running: \(browser.displayName, privacy: .public)")
            throw BrowserURLError.browserNotRunning
        }
        
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = [scriptURL.path]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        // The synchronous waitUntilExit blocks for as long as osascript runs — on the
        // first browser recording that includes a TCC dialog the user must answer.
        // Run it on the global queue instead of pinning a cooperative thread.
        let result: (status: Int32, output: String) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try task.run()
                    task.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(returning: (task.terminationStatus, output))
                } catch {
                    continuation.resume(returning: (-1, ""))
                }
            }
        }

        // Two failure conventions: Chrome/Safari let errors propagate so osascript
        // exits non-zero, while the Firefox/Zen scripts catch internally and return
        // an "ERROR: ..." sentinel with exit 0. Check both. A real URL never starts
        // with "ERROR:", so this avoids a contains("error") false-positive on
        // legitimate URLs.
        if result.status != 0 || result.output.hasPrefix("ERROR:") {
            logger.error("❌ AppleScript error for \(browser.displayName, privacy: .public): \(result.output, privacy: .public)")
            throw BrowserURLError.executionFailed
        }

        if result.output.isEmpty {
            logger.error("❌ Empty output from AppleScript for \(browser.displayName, privacy: .public)")
            throw BrowserURLError.noActiveTab
        }

        logger.debug("✅ Successfully retrieved URL from \(browser.displayName, privacy: .public): \(result.output, privacy: .public)")
        return result.output
    }
    
    func isRunning(_ browser: BrowserType) -> Bool {
        let workspace = NSWorkspace.shared
        let runningApps = workspace.runningApplications
        let isRunning = runningApps.contains { $0.bundleIdentifier == browser.bundleIdentifier }
        logger.debug("\(browser.displayName, privacy: .public) running status: \(isRunning, privacy: .public)")
        return isRunning
    }
} 
