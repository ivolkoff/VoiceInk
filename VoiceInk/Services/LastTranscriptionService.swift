import Foundation
import SwiftData

class LastTranscriptionService: ObservableObject {
    
    static func getLastTranscription(from modelContext: ModelContext) -> Transcription? {
        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        
        do {
            let transcriptions = try modelContext.fetch(descriptor)
            return transcriptions.first
        } catch {
            print("Error fetching last transcription: \(error)")
            return nil
        }
    }
    
    static func copyLastTranscription(from modelContext: ModelContext) {
        guard let lastTranscription = getLastTranscription(from: modelContext) else {
            Task { @MainActor in
                NotificationManager.shared.showNotification(
                    title: String(localized: "No transcription available"),
                    type: .error
                )
            }
            return
        }
        
        let textToCopy = lastTranscription.successfulEnhancedText ?? lastTranscription.text

        let success = ClipboardManager.copyToClipboard(textToCopy)
        
        Task { @MainActor in
            if success {
                NotificationManager.shared.showNotification(
                    title: String(localized: "Last transcription copied"),
                    type: .success
                )
            } else {
                NotificationManager.shared.showNotification(
                    title: String(localized: "Failed to copy transcription"),
                    type: .error
                )
            }
        }
    }

    static func pasteLastTranscription(from modelContext: ModelContext) {
        guard let lastTranscription = getLastTranscription(from: modelContext) else {
            Task { @MainActor in
                NotificationManager.shared.showNotification(
                    title: String(localized: "No transcription available"),
                    type: .error
                )
            }
            return
        }
        
        let textToPaste = lastTranscription.text

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            CursorPaster.pasteAtCursor(textToPaste)
        }
    }
    
    static func pasteLastEnhancement(from modelContext: ModelContext) {
        guard let lastTranscription = getLastTranscription(from: modelContext) else {
            Task { @MainActor in
                NotificationManager.shared.showNotification(
                    title: String(localized: "No transcription available"),
                    type: .error
                )
            }
            return
        }
        
        let textToPaste = lastTranscription.successfulEnhancedText ?? lastTranscription.text

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            CursorPaster.pasteAtCursor(textToPaste)
        }
    }
    
    @MainActor private static var isRetryInFlight = false

    static func retryLastTranscription(from modelContext: ModelContext, engine: VoiceInkEngine) {
        Task { @MainActor in
            // Same guards as RetranscribeLastInLayoutLanguageService: no re-entrancy (double
            // press would duplicate records and WAV copies), and never while a recording is
            // in flight — retranscribeAudio must not share services with a live recording.
            guard !isRetryInFlight else { return }
            guard engine.recordingState == .idle else {
                NotificationManager.shared.showNotification(
                    title: String(localized: "Finish recording before re-transcribing"),
                    type: .error
                )
                return
            }

            guard let lastTranscription = getLastTranscription(from: modelContext),
                  let audioURLString = lastTranscription.audioFileURL,
                  let audioURL = URL(string: audioURLString),
                  FileManager.default.fileExists(atPath: audioURL.path) else {
                NotificationManager.shared.showNotification(
                    title: String(localized: "Cannot retry: Audio file not found"),
                    type: .error
                )
                return
            }

            guard let currentModel = engine.transcriptionModelManager.currentTranscriptionModel else {
                NotificationManager.shared.showNotification(
                    title: String(localized: "No transcription model selected"),
                    type: .error
                )
                return
            }

            isRetryInFlight = true
            defer { isRetryInFlight = false }

            // Own registry, not the shared engine one: the shared instances are not
            // isolated and would race a live dictation's whisper/fluidAudio context.
            let serviceRegistry = TranscriptionServiceRegistry(
                modelProvider: engine.whisperModelManager,
                modelsDirectory: engine.whisperModelManager.modelsDirectory,
                modelContext: modelContext
            )
            let transcriptionService = AudioTranscriptionService(
                modelContext: modelContext,
                serviceRegistry: serviceRegistry,
                enhancementService: engine.enhancementService
            )
            do {
                let newTranscription = try await transcriptionService.retranscribeAudio(from: audioURL, using: currentModel)

                let textToCopy = newTranscription.successfulEnhancedText ?? newTranscription.text
                ClipboardManager.copyToClipboard(textToCopy)

                NotificationManager.shared.showNotification(
                    title: String(localized: "Copied to clipboard"),
                    type: .success
                )
            } catch {
                NotificationManager.shared.showNotification(
                    title: String.localizedStringWithFormat(String(localized: "Retry failed: %@"), error.localizedDescription),
                    type: .error
                )
            }
            await serviceRegistry.cleanup()
        }
    }
}