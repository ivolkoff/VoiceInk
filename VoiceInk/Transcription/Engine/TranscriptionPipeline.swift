import Foundation
import SwiftData
import AppKit
import os

/// Handles the full post-recording pipeline:
/// transcribe → filter → format → word-replace → prompt-detect → AI enhance → start paste + dismiss → save
@MainActor
class TranscriptionPipeline {
    private let modelContext: ModelContext
    private let serviceRegistry: TranscriptionServiceRegistry
    private let enhancementService: AIEnhancementService?
    private let promptDetectionService = PromptDetectionService()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionPipeline")

    var licenseViewModel: LicenseViewModel

    init(
        modelContext: ModelContext,
        serviceRegistry: TranscriptionServiceRegistry,
        enhancementService: AIEnhancementService?
    ) {
        self.modelContext = modelContext
        self.serviceRegistry = serviceRegistry
        self.enhancementService = enhancementService
        self.licenseViewModel = LicenseViewModel()
    }

    /// Run the full pipeline for a given transcription record.
    /// - Parameters:
    ///   - transcription: The pending Transcription SwiftData object to populate and save.
    ///   - audioURL: The recorded audio file.
    ///   - model: The transcription model to use.
    ///   - session: An active streaming session if one was prepared, otherwise nil.
    ///   - onStateChange: Called when the pipeline moves to a new recording state (e.g. `.enhancing`).
    ///   - shouldCancel: Returns true if the user requested cancellation.
    ///   - onCancel: Called when cancellation is detected to cancel active session state.
    ///   - onDismiss: Called as soon as paste is initiated to dismiss the recorder panel.
    func run(
        transcription: Transcription,
        audioURL: URL,
        model: any TranscriptionModel,
        session: TranscriptionSession?,
        selectionEdit: SelectionEditCapture?,
        onStateChange: @escaping (RecordingState) -> Void,
        shouldCancel: () -> Bool,
        onCancel: @escaping () async -> Void,
        onDismiss: @escaping () async -> Void
    ) async {
        var finalPastedText: String?
        var promptDetectionResult: PromptDetectionService.PromptDetectionResult?
        var didInsertSessionMetric = false

        func restorePromptDetectionSettingsIfNeeded() async {
            if let result = promptDetectionResult,
               let enhancementService,
               result.shouldEnableAI {
                await promptDetectionService.restoreOriginalSettings(result, to: enhancementService)
            }
        }

        func restorePromptDetectionSettingsAndDismiss(afterRestore: () -> Void = {}) async {
            await restorePromptDetectionSettingsIfNeeded()
            afterRestore()
            await onDismiss()
        }

        func finishCanceledTranscription() async {
            await onCancel()
            await restorePromptDetectionSettingsIfNeeded()

            let canceledDuration: TimeInterval?
            if transcription.duration > 0 {
                canceledDuration = nil
            } else {
                let duration = await AudioFileMetadata.duration(for: audioURL)
                canceledDuration = duration > 0 ? duration : nil
            }

            transcription.markAsCanceledTranscription(
                duration: canceledDuration,
                modelName: transcription.transcriptionModelName ?? model.displayName
            )

            do {
                try modelContext.save()
            } catch {
                logger.error("Failed to save canceled transcription: \(error.localizedDescription, privacy: .public)")
            }
        }

        if shouldCancel() {
            await finishCanceledTranscription()
            return
        }

        do {
            let transcriptionStart = Date()
            var text: String
            if let session {
                text = try await session.transcribe(audioURL: audioURL)
            } else {
                text = try await serviceRegistry.transcribe(audioURL: audioURL, model: model)
            }
            text = TranscriptionOutputFilter.filter(text)
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)

            if shouldCancel() { await finishCanceledTranscription(); return }

            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if UserDefaults.standard.bool(forKey: "IsTextFormattingEnabled") {
                text = WhisperTextFormatter.format(text)
            }

            text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            let cleanedText = TranscriptionOutputFilter.applyUserCleanupPreferences(text)

            let actualDuration = await AudioFileMetadata.duration(for: audioURL)

            transcription.text = cleanedText
            transcription.duration = actualDuration
            transcription.transcriptionModelName = model.displayName
            transcription.transcriptionDuration = transcriptionDuration
            transcription.language = TranscriptionLanguagePreference.resolvedLanguage(for: model)
            finalPastedText = cleanedText

            if let enhancementService, enhancementService.isConfigured, selectionEdit == nil {
                let detectionResult = promptDetectionService.analyzeText(text, with: enhancementService)
                promptDetectionResult = detectionResult
                await promptDetectionService.applyDetectionResult(detectionResult, to: enhancementService)
            }

            let isSkipShortEnhancementEnabled = UserDefaults.standard.bool(forKey: "SkipShortEnhancement")
            let savedThreshold = UserDefaults.standard.integer(forKey: "ShortEnhancementWordThreshold")
            let shortEnhancementWordThreshold = savedThreshold > 0 ? savedThreshold : 3
            let shouldSkipEnhancement = isSkipShortEnhancementEnabled && WordCounter.count(in: text) <= shortEnhancementWordThreshold && !(promptDetectionResult?.shouldEnableAI == true)

            if let enhancementService,
               enhancementService.isEnhancementEnabled,
               enhancementService.isConfigured,
               !shouldSkipEnhancement,
               selectionEdit == nil {
                if shouldCancel() { await finishCanceledTranscription(); return }

                onStateChange(.enhancing)
                let textForAI = promptDetectionResult?.processedText ?? text

                do {
                    let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(textForAI)
                    transcription.enhancedText = enhancedText
                    transcription.aiEnhancementModelName = enhancementService.getAIService()?.currentModel
                    transcription.promptName = promptName
                    transcription.enhancementDuration = enhancementDuration
                    transcription.aiRequestSystemMessage = enhancementService.lastSystemMessageSent
                    transcription.aiRequestUserMessage = enhancementService.lastUserMessageSent
                    finalPastedText = enhancedText
                } catch {
                    let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    transcription.enhancedText = "Enhancement failed: \(errorDescription)"
                    let shortReason = String(errorDescription.prefix(80))
                    await MainActor.run {
                        NotificationManager.shared.showNotification(
                            title: String.localizedStringWithFormat(String(localized: "Enhancement failed: %@"), shortReason),
                            type: .warning
                        )
                    }
                    if shouldCancel() { await finishCanceledTranscription(); return }
                }
            }

            if let selectionEdit {
                switch selectionEdit {
                case .edit(let selectionEditContext):
                    if let enhancementService, enhancementService.isConfigured {
                        if shouldCancel() { await finishCanceledTranscription(); return }

                        onStateChange(.enhancing)
                        do {
                            let editStart = Date()
                            let result = try await enhancementService.editSelection(
                                selectedText: selectionEditContext.text,
                                spokenText: cleanedText
                            )
                            transcription.enhancedText = result
                            transcription.aiEnhancementModelName = enhancementService.getAIService()?.currentModel
                            transcription.promptName = "Selection Edit"
                            transcription.enhancementDuration = Date().timeIntervalSince(editStart)
                            transcription.aiRequestSystemMessage = enhancementService.lastSystemMessageSent
                            transcription.aiRequestUserMessage = enhancementService.lastUserMessageSent
                            finalPastedText = result
                        } catch {
                            // Nothing pasted, selection intact; the dictated text stays in history.
                            finalPastedText = nil
                            let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                            let shortReason = String(errorDescription.prefix(80))
                            await MainActor.run {
                                NotificationManager.shared.showNotification(
                                    title: String.localizedStringWithFormat(String(localized: "Selection edit failed: %@"), shortReason),
                                    type: .warning
                                )
                            }
                            if shouldCancel() { await finishCanceledTranscription(); return }
                        }
                    }
                case .tooLarge(let selectionLength, let maxLength):
                    // The selection is too big to edit; pasting ordinary dictation over it
                    // would destroy it, so the dictated text goes to the clipboard instead.
                    finalPastedText = nil
                    let copied = ClipboardManager.copyToClipboard(cleanedText)
                    await MainActor.run {
                        NotificationManager.shared.showNotification(
                            title: String.localizedStringWithFormat(
                                String(localized: "Selection is too large to edit (%lld/%lld characters)"),
                                selectionLength, maxLength
                            ),
                            type: copied ? .info : .warning
                        )
                    }
                }
            }

            transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue
        } catch {
            let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

            if let nativeAppleError = error as? NativeAppleTranscriptionService.ServiceError,
               case .assetDownloadRequired = nativeAppleError {
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: errorDescription,
                        type: .error,
                        duration: 5.0
                    )
                }
            }

            transcription.text = "Transcription Failed: \(errorDescription)"
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
        }

        func saveTranscriptionAndPostCompletion() {
            if transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
                do {
                    didInsertSessionMetric = try SessionMetricRecorder.recordRecorderSession(
                        transcription: transcription,
                        model: model,
                        in: modelContext
                    )
                } catch {
                    logger.error("Failed to record session metric: \(error.localizedDescription, privacy: .public)")
                }
            }

            do {
                try modelContext.save()
                if didInsertSessionMetric {
                    NotificationCenter.default.post(name: .sessionMetricsDidChange, object: nil)
                }
                NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
            } catch {
                logger.error("Failed to save transcription: \(error.localizedDescription, privacy: .public)")
            }
        }

        if shouldCancel() {
            await finishCanceledTranscription()
            return
        }

        let selectionPasteMode = selectionEdit.flatMap { capture -> SelectionEditService.PasteDecision? in
            guard case .edit(let context) = capture else { return nil }
            return SelectionEditService.pasteDecision(
                context: context,
                frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                currentSelection: FocusedTextAccessibility.selectedText()
            )
        }

        if var textToPaste = finalPastedText,
           transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
            if case .trialExpired = licenseViewModel.licenseState {
                textToPaste = """
                    Your trial has expired. Upgrade to VoiceInk Pro at tryvoiceink.com/buy
                    \n\(textToPaste)
                    """
            }

            if selectionPasteMode == .clipboard {
                // The selection moved on since capture — hand the result to the clipboard
                // instead of pasting over text we can no longer see.
                ClipboardManager.copyToClipboard(textToPaste)
                LastPasteTracker.shared.clear()
                SoundManager.shared.playStopSound()
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: String(localized: "Selection changed — result copied to clipboard"),
                        type: .info
                    )
                }
                await restorePromptDetectionSettingsAndDismiss()
            } else {
                let appendSpace = selectionPasteMode == nil && UserDefaults.standard.bool(forKey: "AppendTrailingSpace")
                let pastedText = textToPaste + (appendSpace ? " " : "")
                let pasteOutcome = await CursorPaster.startPasteAtCursor(pastedText).value
                let autoSendKey = PowerModeManager.shared.currentActiveConfiguration?.autoSendKey

                // Record the exact paste so the re-transcribe-last hotkey can safely replace it.
                // Skip when AutoSend fired: the text was submitted, so it can't be replaced in place.
                // A selection edit is never tracked: re-transcribing the spoken instruction
                // must not replace the edit result.
                if autoSendKey?.isEnabled == true || selectionPasteMode != nil {
                    LastPasteTracker.shared.clear()
                } else {
                    LastPasteTracker.shared.record(
                        transcriptionID: transcription.id,
                        pastedText: pastedText,
                        targetBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                        posted: pasteOutcome.result.didPostPasteCommand
                    )
                }

                SoundManager.shared.playStopSound()
                await restorePromptDetectionSettingsAndDismiss {
                    if let autoSendKey, autoSendKey.isEnabled {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            // Return submits and clears the field; that is not a correction to learn.
                            if let generation = pasteOutcome.autoLearnGeneration {
                                await AutoLearnService.shared.cancelForAutoSend(generation: generation)
                            }
                            CursorPaster.performAutoSend(autoSendKey)
                        }
                    }
                }
            }
        } else {
            // Nothing pasted this run — drop any prior paste context so the hotkey can't act on it.
            LastPasteTracker.shared.clear()
            await restorePromptDetectionSettingsAndDismiss()
        }

        saveTranscriptionAndPostCompletion()
    }
}
