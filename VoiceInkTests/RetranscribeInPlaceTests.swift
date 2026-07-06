//
//  RetranscribeInPlaceTests.swift
//  VoiceInkTests
//

import Foundation
import SwiftData
import Testing
@testable import VoiceInk

@MainActor
private final class FakeTranscriber: AudioTranscribing {
    let returnText: String
    var capturedLanguage: String?
    var callCount = 0

    init(returnText: String) { self.returnText = returnText }

    func transcribe(audioURL: URL, model: any TranscriptionModel, language: String?) async throws -> String {
        callCount += 1
        capturedLanguage = language
        return returnText
    }
}

@MainActor
struct RetranscribeInPlaceTests {

    private func makeModel() -> CloudModel {
        CloudModel(
            name: "fake",
            displayName: "Fake Model",
            description: "",
            provider: .whisper,
            speed: 0,
            accuracy: 0,
            isMultilingual: true,
            supportedLanguages: ["en": "English", "ru": "Russian"]
        )
    }

    private func makeTempAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data([0, 1, 2, 3]).write(to: url)
        return url
    }

    private func inMemoryContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Transcription.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return container.mainContext
    }

    @Test func overwritesRecordAndPassesChosenLanguage() async throws {
        let context = try inMemoryContext()
        let audioURL = try makeTempAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let transcription = Transcription(
            text: "old text",
            duration: 1,
            enhancedText: "old enhanced",
            audioFileURL: audioURL.absoluteString,
            transcriptionModelName: "Old Model",
            transcriptionStatus: .pending
        )
        let oldTimestamp = Date(timeIntervalSince1970: 0)
        transcription.timestamp = oldTimestamp
        context.insert(transcription)
        try context.save()

        let fake = FakeTranscriber(returnText: "hello world")
        let service = AudioTranscriptionService(modelContext: context, serviceRegistry: fake, enhancementService: nil)

        let returned = try await service.retranscribeInPlace(transcription, language: "ru", using: makeModel())

        #expect(returned == "hello world")
        #expect(fake.capturedLanguage == "ru")
        #expect(transcription.text == "hello world")
        #expect(transcription.enhancedText == nil)
        #expect(transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue)
        #expect(transcription.transcriptionModelName == "Fake Model")
        #expect(transcription.timestamp > oldTimestamp)
    }

    @Test func missingAudioFileThrowsAndLeavesRecordUntouched() async throws {
        let context = try inMemoryContext()

        let transcription = Transcription(
            text: "old text",
            duration: 1,
            audioFileURL: "file:///nonexistent/\(UUID().uuidString).wav"
        )
        context.insert(transcription)
        try context.save()

        let fake = FakeTranscriber(returnText: "new")
        let service = AudioTranscriptionService(modelContext: context, serviceRegistry: fake, enhancementService: nil)

        await #expect(throws: (any Error).self) {
            try await service.retranscribeInPlace(transcription, language: "ru", using: makeModel())
        }
        #expect(fake.callCount == 0)
        #expect(transcription.text == "old text")
    }

    @Test func skipsOverwriteWhenRecordNotInAContext() async throws {
        let context = try inMemoryContext()
        let audioURL = try makeTempAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        // Never inserted → modelContext == nil, mirroring a record deleted mid-flight.
        let transcription = Transcription(
            text: "old text",
            duration: 1,
            audioFileURL: audioURL.absoluteString
        )

        let fake = FakeTranscriber(returnText: "new text")
        let service = AudioTranscriptionService(modelContext: context, serviceRegistry: fake, enhancementService: nil)

        try await service.retranscribeInPlace(transcription, language: "ru", using: makeModel())

        #expect(fake.callCount == 1)          // transcription ran
        #expect(transcription.text == "old text") // but the record was not overwritten
    }
}
