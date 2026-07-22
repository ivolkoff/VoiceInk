import Foundation
import AppKit
import os

class ActiveWindowService: ObservableObject {
    static let shared = ActiveWindowService()
    @Published var currentApplication: NSRunningApplication?
    private var enhancementService: AIEnhancementService?
    private let browserURLService = BrowserURLService.shared

    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "browser.detection"
    )

    private init() {}

    func configure(with enhancementService: AIEnhancementService) {
        self.enhancementService = enhancementService
    }
    
    // This method is nonisolated async (runs off the caller's actor), so every read
    // of main-owned state — NSWorkspace and PowerModeManager's @Published
    // configurations — is hopped onto the main actor to avoid a data race.
    func applyConfiguration(powerModeId: UUID? = nil) async {
        if let powerModeId = powerModeId {
            let config = await MainActor.run { PowerModeManager.shared.getConfiguration(with: powerModeId) }
            if let config {
                await MainActor.run {
                    PowerModeManager.shared.setActiveConfiguration(config)
                }
                await PowerModeSessionManager.shared.beginSession(with: config)
                return
            }
        }

        guard let frontmostApp = await MainActor.run(resultType: NSRunningApplication?.self, body: { NSWorkspace.shared.frontmostApplication }),
              let bundleIdentifier = frontmostApp.bundleIdentifier else {
            return
        }

        await MainActor.run {
            currentApplication = frontmostApp
        }

        var configToApply: PowerModeConfig?

        if let browserType = BrowserType.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            do {
                let currentURL = try await browserURLService.getCurrentURL(from: browserType)
                configToApply = await MainActor.run { PowerModeManager.shared.getConfigurationForURL(currentURL) }
            } catch {
                logger.error("❌ Failed to get URL from \(browserType.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if configToApply == nil {
            configToApply = await MainActor.run { PowerModeManager.shared.getConfigurationForApp(bundleIdentifier) }
        }

        if configToApply == nil {
            configToApply = await MainActor.run { PowerModeManager.shared.getDefaultConfiguration() }
        }

        if let config = configToApply {
            await MainActor.run {
                PowerModeManager.shared.setActiveConfiguration(config)
            }
            await PowerModeSessionManager.shared.beginSession(with: config)
        }
    }
} 
