import Foundation
import FluidAudio
import os

@MainActor
final class MeetingTranscriber {
    struct Result {
        let transcript: String
        let language: String?
    }

    enum Failure: LocalizedError {
        case noModel
        case streamingOnly(String)

        var errorDescription: String? {
            switch self {
            case .noModel:
                return String(localized: "No transcription model selected")
            case .streamingOnly(let name):
                return String(localized: "\(name) works only in streaming mode and can't transcribe recordings. Pick another model.")
            }
        }
    }

    private static let sampleRate = 16_000.0
    private static let retryDelays: [UInt64] = [5, 20, 60]

    private let engine: VoiceInkEngine
    private let audioProcessor = AudioProcessor()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingTranscriber")

    init(engine: VoiceInkEngine) {
        self.engine = engine
    }

    func transcribe(audioURL: URL, languageChoice: String, onStatus: @escaping (String) -> Void) async throws -> Result {
        guard let model = engine.transcriptionModelManager.currentTranscriptionModel else { throw Failure.noModel }
        if let cloud = CloudProviderRegistry.provider(for: model.provider), cloud.isStreamingOnly {
            throw Failure.streamingOnly(model.displayName)
        }
        let supported = TranscriptionLanguageSupport.languages(for: model)
        let fixedLanguage = Self.fixedLanguage(choice: languageChoice, model: model, supported: supported)

        onStatus(String(localized: "Preparing audio…"))
        let samples = try await audioProcessor.processAudioToSamples(audioURL)
        let chunks = await speechChunks(samples)

        let registry = TranscriptionServiceRegistry(
            modelProvider: engine.whisperModelManager,
            modelsDirectory: engine.whisperModelManager.modelsDirectory,
            modelContext: engine.modelContext
        )
        registry.localTranscriptionService.retainsOwnContext = true
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        do {
            let result = try await run(chunks: chunks, samples: samples, model: model, supported: supported,
                                       fixedLanguage: fixedLanguage, registry: registry, tempDirectory: tempDirectory, onStatus: onStatus)
            await registry.cleanup()
            return result
        } catch {
            await registry.cleanup()
            throw error
        }
    }

    nonisolated static func isRetryable(_ error: Error) -> Bool {
        switch error as? CloudTranscriptionError {
        case .apiRequestFailed(let statusCode, _): return statusCode == 429 || statusCode >= 500
        case .networkError: return true
        default: return false
        }
    }

    // nil means Auto with detect-then-correct; models without "auto" get a concrete language up front.
    private static func fixedLanguage(choice: String, model: any TranscriptionModel, supported: [String: String]) -> String? {
        if choice != MeetingLanguage.auto {
            return TranscriptionLanguageSupport.validLanguageOrFallback(choice, for: model)
        }
        if supported[MeetingLanguage.auto] != nil { return nil }
        if let selected = UserDefaults.standard.string(forKey: "SelectedLanguage"), supported[selected] != nil {
            return selected
        }
        return TranscriptionLanguageSupport.validLanguageOrFallback(nil, for: model)
    }

    private func run(
        chunks: [MeetingText.Chunk], samples: [Float], model: any TranscriptionModel, supported: [String: String],
        fixedLanguage: String?, registry: TranscriptionServiceRegistry, tempDirectory: URL, onStatus: (String) -> Void
    ) async throws -> Result {
        let languageLabel = fixedLanguage.map(Self.displayName) ?? String(localized: "Auto-detect")
        var texts: [String] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            onStatus(String(localized: "Transcribing \(index + 1) of \(chunks.count) · \(languageLabel)…"))
            texts.append(try await transcribeChunk(chunk, samples: samples, language: fixedLanguage ?? MeetingLanguage.auto,
                                                   model: model, registry: registry, tempDirectory: tempDirectory))
        }

        var language = fixedLanguage
        if fixedLanguage == nil {
            let allText = texts.joined(separator: " ")
            let detection = MeetingLanguage.detect(allText)
            if let dominant = MeetingLanguage.dominantLanguage(detection: detection, characterCount: allText.count, supported: Set(supported.keys)) {
                language = dominant
                let redo = MeetingLanguage.pass2Indices(chunkTexts: texts, language: dominant)
                for (step, index) in redo.enumerated() {
                    try Task.checkCancellation()
                    onStatus(String(localized: "Correcting to \(Self.displayName(dominant)): \(step + 1) of \(redo.count)…"))
                    texts[index] = try await transcribeChunk(chunks[index], samples: samples, language: dominant,
                                                             model: model, registry: registry, tempDirectory: tempDirectory)
                }
            } else {
                language = detection?.code
            }
        }
        logger.notice("Meeting transcribed: \(chunks.count) chunks, language \(language ?? "unknown", privacy: .public)")
        let transcript = MeetingText.assembleTranscript(zip(chunks, texts).map { (start: $0.start, text: $1) })
        return Result(transcript: transcript, language: language)
    }

    private func transcribeChunk(
        _ chunk: MeetingText.Chunk, samples: [Float], language: String, model: any TranscriptionModel,
        registry: TranscriptionServiceRegistry, tempDirectory: URL
    ) async throws -> String {
        let from = max(0, min(samples.count, Int(chunk.start * Self.sampleRate)))
        let to = max(from, min(samples.count, Int(chunk.end * Self.sampleRate)))
        guard to - from >= Int(Self.sampleRate / 10) else { return "" }
        let url = tempDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try audioProcessor.saveSamplesAsWav(samples: Array(samples[from..<to]), to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var attempt = 0
        while true {
            do {
                let raw = try await registry.transcribe(audioURL: url, model: model, language: language)
                let filtered = TranscriptionOutputFilter.filter(raw)
                return WordReplacementService.shared.applyReplacements(to: filtered, using: engine.modelContext)
            } catch let error where attempt < Self.retryDelays.count && Self.isRetryable(error) {
                logger.notice("Chunk failed, retrying: \(error.localizedDescription, privacy: .public)")
                try await Task.sleep(nanoseconds: Self.retryDelays[attempt] * 1_000_000_000)
                attempt += 1
            }
        }
    }

    private static func displayName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    private func speechChunks(_ samples: [Float]) async -> [MeetingText.Chunk] {
        do {
            let vad = try await VadManager(config: VadConfig(defaultThreshold: 0.7))
            var config = VadSegmentationConfig.default
            config.minSpeechDuration = 0.5
            // The default 14 s cap force-splits continuous speech mid-word; the engines window long input themselves.
            config.maxSpeechDuration = 28
            let segments = try await vad.segmentSpeech(samples, config: config)
            return MeetingText.mergeSegments(segments.map { MeetingText.Chunk(start: $0.startTime, end: $0.endTime) })
        } catch {
            logger.notice("VAD unavailable, using fixed 30 s chunks: \(error.localizedDescription, privacy: .public)")
            return MeetingText.fixedChunks(duration: Double(samples.count) / Self.sampleRate)
        }
    }
}
