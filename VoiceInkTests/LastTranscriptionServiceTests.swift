import Foundation
import SwiftData
import Testing
@testable import VoiceInk

@MainActor
struct LastTranscriptionServiceTests {
    private let container: ModelContainer

    init() throws {
        container = try ModelContainer(
            for: Transcription.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func insert(_ items: [(text: String, status: TranscriptionStatus?)]) throws -> ModelContext {
        let context = ModelContext(container)
        let now = Date()
        for (index, item) in items.enumerated() {
            let transcription = Transcription(text: item.text, duration: 1)
            transcription.transcriptionStatus = item.status?.rawValue
            transcription.timestamp = now.addingTimeInterval(TimeInterval(index))
            context.insert(transcription)
        }
        try context.save()
        return context
    }

    @Test func pasteSkipsFailedCanceledAndPendingEntries() throws {
        let context = try insert([
            ("real dictation", .completed),
            ("Transcription Failed: No speech detected", .failed),
            (Transcription.canceledTranscriptionText, .canceled),
            ("", .pending),
        ])
        #expect(LastTranscriptionService.getLastPasteableTranscription(from: context)?.text == "real dictation")
    }

    @Test func legacyEntriesWithoutStatusArePasteable() throws {
        let context = try insert([("old", .completed), ("legacy", nil)])
        #expect(LastTranscriptionService.getLastPasteableTranscription(from: context)?.text == "legacy")
    }

    @Test func retryStillSeesTheNewestFailedEntry() throws {
        let context = try insert([("real dictation", .completed), ("Transcription Failed: x", .failed)])
        #expect(LastTranscriptionService.getLastTranscription(from: context)?.text == "Transcription Failed: x")
    }
}
