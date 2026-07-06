import Foundation
import SwiftUI
import AVFoundation
import SwiftData
import os

/// The subset of `TranscriptionServiceRegistry` that `AudioTranscriptionService` depends on.
/// Exists so re-transcription can be unit-tested with a fake transcriber.
@MainActor
protocol AudioTranscribing {
    func transcribe(audioURL: URL, model: any TranscriptionModel, language: String?) async throws -> String
}

extension TranscriptionServiceRegistry: AudioTranscribing {}

@MainActor
class AudioTranscriptionService: ObservableObject {
    @Published var isTranscribing = false
    @Published var currentError: TranscriptionError?

    private let modelContext: ModelContext
    private let enhancementService: AIEnhancementService?
    private let promptDetectionService = PromptDetectionService()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioTranscriptionService")
    private let serviceRegistry: AudioTranscribing

    enum TranscriptionError: Error {
        case noAudioFile
        case transcriptionFailed
        case modelNotLoaded
        case invalidAudioFormat
    }

    init(modelContext: ModelContext, engine: VoiceInkEngine) {
        self.modelContext = modelContext
        self.enhancementService = engine.enhancementService
        self.serviceRegistry = TranscriptionServiceRegistry(modelProvider: engine.whisperModelManager, modelsDirectory: engine.whisperModelManager.modelsDirectory, modelContext: modelContext)
    }

    init(modelContext: ModelContext, serviceRegistry: AudioTranscribing, enhancementService: AIEnhancementService?) {
        self.modelContext = modelContext
        self.enhancementService = enhancementService
        self.serviceRegistry = serviceRegistry
    }
    
    /// Re-transcribes an existing recording's saved audio in an explicitly chosen language and
    /// overwrites the given record in place (raw text only — enhancement fields are cleared).
    ///
    /// Uses this service's own `serviceRegistry`, never the shared engine one, so it cannot tear
    /// down a live recording's whisper/fluidAudio context. Callers must additionally refuse to run
    /// while a recording is in progress. Does NOT post `.transcriptionCompleted`: that notification
    /// drives auto-cleanup, which would delete the record we just overwrote.
    ///
    /// Returns the cleaned re-transcription text. Transcription success always returns the text —
    /// even if the record was deleted mid-flight and persistence was skipped — so the hotkey caller
    /// can still replace the on-screen text. A `save()` failure rolls back and throws.
    @discardableResult
    func retranscribeInPlace(_ transcription: Transcription, language: String, using model: any TranscriptionModel) async throws -> String {
        guard let urlString = transcription.audioFileURL,
              let url = URL(string: urlString),
              FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.noAudioFile
        }

        await MainActor.run { isTranscribing = true }
        defer { Task { @MainActor in isTranscribing = false } }

        let transcriptionStart = Date()
        var text = try await serviceRegistry.transcribe(audioURL: url, model: model, language: language)
        let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)
        text = TranscriptionOutputFilter.filter(text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if UserDefaults.standard.bool(forKey: "IsTextFormattingEnabled") {
            text = WhisperTextFormatter.format(text)
        }

        text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
        let cleanedText = TranscriptionOutputFilter.applyUserCleanupPreferences(text)

        try await MainActor.run {
            // The record may have been deleted (user delete, auto-cleanup sweep) during the await.
            guard !transcription.isDeleted, transcription.modelContext != nil else { return }

            // Snapshot fields we overwrite so we can roll back on a save failure.
            let old = (
                text: transcription.text,
                enhancedText: transcription.enhancedText,
                aiEnhancementModelName: transcription.aiEnhancementModelName,
                promptName: transcription.promptName,
                enhancementDuration: transcription.enhancementDuration,
                aiRequestSystemMessage: transcription.aiRequestSystemMessage,
                aiRequestUserMessage: transcription.aiRequestUserMessage,
                transcriptionModelName: transcription.transcriptionModelName,
                transcriptionDuration: transcription.transcriptionDuration,
                transcriptionStatus: transcription.transcriptionStatus,
                timestamp: transcription.timestamp,
                language: transcription.language
            )

            transcription.text = cleanedText
            transcription.enhancedText = nil
            transcription.aiEnhancementModelName = nil
            transcription.promptName = nil
            transcription.enhancementDuration = nil
            transcription.aiRequestSystemMessage = nil
            transcription.aiRequestUserMessage = nil
            transcription.transcriptionModelName = model.displayName
            transcription.transcriptionDuration = transcriptionDuration
            transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue
            transcription.language = language
            // Bump so the auto-cleanup sweep treats it as fresh instead of deleting it.
            transcription.timestamp = Date()

            do {
                try modelContext.save()
            } catch {
                transcription.text = old.text
                transcription.enhancedText = old.enhancedText
                transcription.aiEnhancementModelName = old.aiEnhancementModelName
                transcription.promptName = old.promptName
                transcription.enhancementDuration = old.enhancementDuration
                transcription.aiRequestSystemMessage = old.aiRequestSystemMessage
                transcription.aiRequestUserMessage = old.aiRequestUserMessage
                transcription.transcriptionModelName = old.transcriptionModelName
                transcription.transcriptionDuration = old.transcriptionDuration
                transcription.transcriptionStatus = old.transcriptionStatus
                transcription.timestamp = old.timestamp
                transcription.language = old.language
                logger.error("❌ Failed to save re-transcription: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }

        return cleanedText
    }

    func retranscribeAudio(from url: URL, using model: any TranscriptionModel) async throws -> Transcription {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.noAudioFile
        }
        
        await MainActor.run {
            isTranscribing = true
        }
        
        do {
            let transcriptionStart = Date()
            var text = try await serviceRegistry.transcribe(audioURL: url, model: model, language: nil)
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)
            text = TranscriptionOutputFilter.filter(text)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            let powerModeManager = PowerModeManager.shared
            let activePowerModeConfig = powerModeManager.currentActiveConfiguration
            let powerModeName = (activePowerModeConfig?.isEnabled == true) ? activePowerModeConfig?.name : nil
            let powerModeEmoji = (activePowerModeConfig?.isEnabled == true) ? activePowerModeConfig?.emoji : nil

            if UserDefaults.standard.bool(forKey: "IsTextFormattingEnabled") {
                text = WhisperTextFormatter.format(text)
            }

            text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            logger.notice("✅ Word replacements applied")
            let cleanedText = TranscriptionOutputFilter.applyUserCleanupPreferences(text)

            let audioAsset = AVURLAsset(url: url)
            let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))
            let recordingsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.prakashjoshipax.VoiceInk")
                .appendingPathComponent("Recordings")
            
            let fileName = "retranscribed_\(UUID().uuidString).wav"
            let permanentURL = recordingsDirectory.appendingPathComponent(fileName)
            
            do {
                try FileManager.default.copyItem(at: url, to: permanentURL)
            } catch {
                logger.error("❌ Failed to create permanent copy of audio: \(error.localizedDescription, privacy: .public)")
                isTranscribing = false
                throw error
            }
            
            let permanentURLString = permanentURL.absoluteString

            // Apply prompt detection for trigger words
            let originalText = cleanedText
            var promptDetectionResult: PromptDetectionService.PromptDetectionResult? = nil

            if let enhancementService = enhancementService, enhancementService.isConfigured {
                let detectionResult = await promptDetectionService.analyzeText(text, with: enhancementService)
                promptDetectionResult = detectionResult
                await promptDetectionService.applyDetectionResult(detectionResult, to: enhancementService)
            }

            // Apply AI enhancement if enabled
            if let enhancementService = enhancementService,
               enhancementService.isEnhancementEnabled,
               enhancementService.isConfigured {
                do {
                    let textForAI = promptDetectionResult?.processedText ?? text
                    let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(textForAI)
                    let newTranscription = Transcription(
                        text: originalText,
                        duration: duration,
                        enhancedText: enhancedText,
                        audioFileURL: permanentURLString,
                        transcriptionModelName: model.displayName,
                        aiEnhancementModelName: enhancementService.getAIService()?.currentModel,
                        promptName: promptName,
                        transcriptionDuration: transcriptionDuration,
                        enhancementDuration: enhancementDuration,
                        aiRequestSystemMessage: enhancementService.lastSystemMessageSent,
                        aiRequestUserMessage: enhancementService.lastUserMessageSent,
                        powerModeName: powerModeName,
                        powerModeEmoji: powerModeEmoji
                    )
                    modelContext.insert(newTranscription)
                    do {
                        try modelContext.save()
                        NotificationCenter.default.post(name: .transcriptionCreated, object: newTranscription)
                        NotificationCenter.default.post(name: .transcriptionCompleted, object: newTranscription)
                    } catch {
                        logger.error("❌ Failed to save transcription: \(error.localizedDescription, privacy: .public)")
                    }

                    // Restore original prompt settings if AI was temporarily enabled
                    if let result = promptDetectionResult,
                       result.shouldEnableAI {
                        await promptDetectionService.restoreOriginalSettings(result, to: enhancementService)
                    }

                    await MainActor.run {
                        isTranscribing = false
                    }

                    return newTranscription
                } catch {
                    let newTranscription = Transcription(
                        text: originalText,
                        duration: duration,
                        audioFileURL: permanentURLString,
                        transcriptionModelName: model.displayName,
                        promptName: nil,
                        transcriptionDuration: transcriptionDuration,
                        powerModeName: powerModeName,
                        powerModeEmoji: powerModeEmoji
                    )
                    modelContext.insert(newTranscription)
                    do {
                        try modelContext.save()
                        NotificationCenter.default.post(name: .transcriptionCreated, object: newTranscription)
                        NotificationCenter.default.post(name: .transcriptionCompleted, object: newTranscription)
                    } catch {
                        logger.error("❌ Failed to save transcription: \(error.localizedDescription, privacy: .public)")
                    }

                    await MainActor.run {
                        isTranscribing = false
                    }

                    return newTranscription
                }
            } else {
                let newTranscription = Transcription(
                    text: originalText,
                    duration: duration,
                    audioFileURL: permanentURLString,
                    transcriptionModelName: model.displayName,
                    promptName: nil,
                    transcriptionDuration: transcriptionDuration,
                    powerModeName: powerModeName,
                    powerModeEmoji: powerModeEmoji
                )
                modelContext.insert(newTranscription)
                do {
                    try modelContext.save()
                    NotificationCenter.default.post(name: .transcriptionCompleted, object: newTranscription)
                } catch {
                    logger.error("❌ Failed to save transcription: \(error.localizedDescription, privacy: .public)")
                }

                await MainActor.run {
                    isTranscribing = false
                }

                return newTranscription
            }
        } catch {
            logger.error("❌ Transcription failed: \(error.localizedDescription, privacy: .public)")
            currentError = .transcriptionFailed
            isTranscribing = false
            throw error
        }
    }
}
