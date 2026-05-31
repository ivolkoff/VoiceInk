import Foundation
import AppKit
import os

/// Orchestrates the enhance-selected-text action: capture → length-guard → enhance → paste.
///
/// Reuses the same leaf services as the post-transcription pipeline
/// (`SelectedTextService`, `AIEnhancementService`, `CursorPaster`) without recording audio.
/// The action overwrites user content in third-party apps, so it is strictly non-destructive:
/// it only pastes on success and never touches the original text on any abort or failure.
@MainActor
final class SelectedTextEnhancementService {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SelectedTextEnhancementService")
    private let enhancementService: AIEnhancementService
    private var isRunning = false

    init(enhancementService: AIEnhancementService) {
        self.enhancementService = enhancementService
    }

    /// - Parameter focusSettleDelay: time to wait before capturing the selection. Menu-bar
    ///   triggers need a brief delay so keyboard focus returns to the source app after the
    ///   menu closes; the global shortcut leaves focus untouched and passes `0`.
    func run(focusSettleDelay: TimeInterval = 0) async {
        guard !isRunning else {
            logger.notice("Ignoring enhance-selected-text trigger: a run is already in progress")
            return
        }
        isRunning = true
        defer { isRunning = false }

        // Guard: enhancement must be enabled and configured (before any capture side effects).
        guard enhancementService.isConfigured else {
            notify(String(localized: "Configure AI Enhancement to use this shortcut"), type: .error)
            return
        }

        if focusSettleDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(focusSettleDelay * 1_000_000_000))
        }

        // Capture the selection (with select-all fallback when an editable field is focused).
        let capture = await SelectedTextService.captureForEnhancement()
        let maxInputLength = SelectedTextEnhancementSettings.maxInputLength()
        let decision = SelectedTextEnhancementDecision.decide(capture: capture, maxInputLength: maxInputLength)

        let inputText: String
        switch decision {
        case .abortNoText:
            notify(String(localized: "No text found to enhance"), type: .warning)
            return
        case .abortTooLong(let length, let limit):
            notify(String.localizedStringWithFormat(String(localized: "Selected text is too large (%lld/%lld characters)"), length, limit), type: .warning)
            return
        case .proceed(let text):
            inputText = text
        }

        // Persistent in-flight indicator: stays on screen (with a spinner) until the
        // AI responds, so the user always knows the request is still running.
        NotificationManager.shared.showNotification(
            title: String(localized: "Enhancing selected text…"),
            type: .info,
            isLoading: true
        )

        do {
            let (enhanced, _, _) = try await enhancementService.enhance(inputText)

            guard !enhanced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                logger.error("Enhancement returned empty text; leaving original selection untouched")
                notify(String(localized: "Enhancement returned no text"), type: .error)
                return
            }

            // Response arrived: replace the loading indicator, then paste over the selection.
            // CursorPaster preserves the clipboard.
            notify(String(localized: "Selected text enhanced"), type: .success, duration: 2.0)
            CursorPaster.startPasteAtCursor(enhanced)
        } catch {
            logger.error("Enhancement failed: \(error.localizedDescription, privacy: .public)")
            notify(String.localizedStringWithFormat(String(localized: "Enhancement failed: %@"), error.localizedDescription), type: .error)
        }
    }

    private func notify(
        _ title: String,
        type: AppNotificationView.NotificationType,
        duration: TimeInterval = 3.0
    ) {
        NotificationManager.shared.showNotification(title: title, type: type, duration: duration)
    }
}
