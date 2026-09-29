import Foundation
import SwiftData
import LLMkit

enum CloudTranscriptionError: Error, LocalizedError {
    case unsupportedProvider
    case streamingOnlyProvider
    case missingAPIKey
    case invalidAPIKey
    case audioFileNotFound
    case apiRequestFailed(statusCode: Int, message: String)
    case networkError(Error)
    case noTranscriptionReturned
    case dataEncodingError

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return String(localized: "The model provider is not supported by this service.")
        case .streamingOnlyProvider:
            return String(localized: "This model only supports live dictation; it can't transcribe files or re-transcribe.")
        case .missingAPIKey:
            return String(localized: "API key for this service is missing. Please configure it in the settings.")
        case .invalidAPIKey:
            return String(localized: "The provided API key is invalid.")
        case .audioFileNotFound:
            return String(localized: "The audio file to transcribe could not be found.")
        case .apiRequestFailed(let statusCode, let message):
            return String(localized: "The API request failed with status code \(statusCode): \(message)")
        case .networkError(let error):
            return String(localized: "A network error occurred: \(error.localizedDescription)")
        case .noTranscriptionReturned:
            return String(localized: "The API returned an empty or invalid response.")
        case .dataEncodingError:
            return String(localized: "Failed to encode the request body.")
        }
    }
}

class CloudTranscriptionService: TranscriptionService {
    private let modelContext: ModelContext
    private lazy var openAICompatibleService = OpenAICompatibleTranscriptionService()

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel, language languageOverride: String?) async throws -> String {
        let audioData = try loadAudioData(from: audioURL)
        let fileName = audioURL.lastPathComponent
        let (language, languageMatchesSelected) = selectedLanguage(for: model, override: languageOverride)

        do {
            if model.provider == .custom {
                guard let customModel = model as? CustomCloudModel else {
                    throw CloudTranscriptionError.unsupportedProvider
                }
                return try await openAICompatibleService.transcribe(audioURL: audioURL, model: customModel, language: languageOverride)
            }

            guard let cloudProvider = CloudProviderRegistry.provider(for: model.provider) else {
                throw CloudTranscriptionError.unsupportedProvider
            }
            if cloudProvider.isStreamingOnly {
                throw CloudTranscriptionError.streamingOnlyProvider
            }
            let apiKey = try requireAPIKey(forProvider: cloudProvider.providerKey)
            return try await cloudProvider.transcribe(
                audioData: audioData,
                fileName: fileName,
                apiKey: apiKey,
                model: model.name,
                language: language,
                prompt: transcriptionPrompt(languageMatchesSelected: languageMatchesSelected),
                customVocabulary: getCustomDictionaryTerms()
            )
        } catch let error as CloudTranscriptionError {
            throw error
        } catch let error as LLMKitError {
            throw mapLLMKitError(error)
        } catch {
            throw CloudTranscriptionError.networkError(error)
        }
    }

    // MARK: - Helpers

    private func loadAudioData(from url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CloudTranscriptionError.audioFileNotFound
        }
        return try Data(contentsOf: url)
    }

    private func requireAPIKey(forProvider provider: String) throws -> String {
        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: provider), !apiKey.isEmpty else {
            throw CloudTranscriptionError.missingAPIKey
        }
        return apiKey
    }

    private func selectedLanguage(for model: any TranscriptionModel, override: String? = nil) -> (language: String?, matchesSelected: Bool) {
        let selected = UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "auto"
        let resolved = override
            ?? TranscriptionLanguagePreference.layoutOverride(for: model)
            ?? selected
        let language = (resolved == "auto" || resolved.isEmpty) ? nil : resolved
        return (language, resolved == selected)
    }

    private func transcriptionPrompt(languageMatchesSelected: Bool) -> String? {
        // The stored "TranscriptionPrompt" is a Whisper bootstrap sentence derived from
        // SelectedLanguage; feeding it into a request pinned to a different language
        // (explicit or keyboard-layout override) corrupts the output — same guard as
        // WhisperTranscriptionService.
        guard languageMatchesSelected else { return nil }
        let prompt = UserDefaults.standard.string(forKey: "TranscriptionPrompt") ?? ""
        return prompt.isEmpty ? nil : prompt
    }

    private func getCustomDictionaryTerms() -> [String] {
        // `transcribe` is a nonisolated async method, so this runs off the main
        // thread. `modelContext` is the main context (not thread-safe); read
        // vocabulary through a fresh context bound to the same container.
        let context = ModelContext(modelContext.container)
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\.word)])
        guard let vocabularyWords = try? context.fetch(descriptor) else {
            return []
        }
        var seen = Set<String>()
        var unique: [String] = []
        for word in vocabularyWords {
            let trimmed = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(trimmed)
            }
        }
        return unique
    }

    private func mapLLMKitError(_ error: LLMKitError) -> CloudTranscriptionError {
        switch error {
        case .missingAPIKey:
            return .missingAPIKey
        case .httpError(let statusCode, let message):
            return .apiRequestFailed(statusCode: statusCode, message: message)
        case .noResultReturned:
            return .noTranscriptionReturned
        case .encodingError:
            return .dataEncodingError
        case .networkError(let detail):
            return .networkError(NSError(domain: "LLMkit", code: -1, userInfo: [NSLocalizedDescriptionKey: detail]))
        case .invalidURL, .decodingError, .timeout:
            return .networkError(error)
        }
    }
}
