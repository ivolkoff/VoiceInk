import Foundation
import os

@MainActor
final class MeetingSummarizer {
    enum Failure: LocalizedError {
        case server(Int, String)
        case empty

        var errorDescription: String? {
            switch self {
            case .server(let status, let body): return String(localized: "Ollama returned \(status): \(body)")
            case .empty: return String(localized: "The model returned an empty summary.")
            }
        }
    }

    static let timeout: TimeInterval = 300

    private let aiService: AIService
    private let enhancementService: AIEnhancementService
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingSummarizer")

    init(aiService: AIService, enhancementService: AIEnhancementService) {
        self.aiService = aiService
        self.enhancementService = enhancementService
    }

    var canSummarize: Bool { enhancementService.isConfigured }

    // Without the toggle a saved cloud key would send every call transcript out with enhancement switched off.
    var shouldAutoSummarize: Bool { enhancementService.isEnhancementEnabled && enhancementService.isConfigured }

    func summarize(_ transcript: String, languageCode: String?) async throws -> String {
        let provider = aiService.selectedProvider
        let model = aiService.currentModel
        let system = Self.instructions(language: Self.languageName(languageCode ?? MeetingLanguage.detect(transcript)?.code))
        let summary: String
        if provider == .ollama {
            summary = AIEnhancementOutputFilter.filter(try await ollamaChat(system: system, transcript: transcript, model: model))
        } else {
            summary = try await enhancementService.chatCompletion(
                systemPrompt: system, userContent: transcript, provider: provider, modelName: model, timeout: Self.timeout
            )
        }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.empty }
        return trimmed + "\n"
    }

    nonisolated static func languageName(_ code: String?) -> String {
        guard let code, code != MeetingLanguage.auto,
              let languageCode = Locale(identifier: code).language.languageCode?.identifier,
              let name = Locale(identifier: "en").localizedString(forLanguageCode: languageCode) else {
            return "the same language as the transcript"
        }
        return name
    }

    nonisolated static func ollamaContextSize(characters: Int) -> Int {
        min(max(characters / 3 + 2_048, 4_096), 32_768)
    }

    private static func instructions(language: String) -> String {
        """
        You summarize recording transcripts. Write everything in \(language), including the section headings. \
        Reply in Markdown. Start with a title line "# <short descriptive title, 3 to 6 words>", then exactly these sections:
        ## TL;DR
        One or two sentences, no list.
        ## Key points
        Bullets with the facts, decisions and numbers discussed. Start each bullet with the [mm:ss] time from the transcript line where it was said.
        ## Action items
        Bullets of tasks only, as "Name: task". Write "None" if there are none.
        Never repeat the same point in two sections. Do not invent details. Reply with the summary only.
        """
    }

    // LLMkit's OllamaClient sends no num_ctx, so Ollama would silently cut a long transcript to its default context.
    private func ollamaChat(system: String, transcript: String, model: String) async throws -> String {
        guard let base = URL(string: AIProvider.ollama.baseURL) else { throw Failure.server(0, "Invalid Ollama URL") }
        let contextSize = Self.ollamaContextSize(characters: transcript.count)
        if transcript.count / 3 + 2_048 > contextSize {
            logger.warning("Transcript exceeds the Ollama context cap; its beginning may be cut")
        }
        var request = URLRequest(url: base.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "think": false,
            "messages": [["role": "system", "content": system], ["role": "user", "content": transcript]],
            "options": ["num_ctx": contextSize],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.server(status, String(decoding: data.prefix(200), as: UTF8.self))
        }
        struct Reply: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        return try JSONDecoder().decode(Reply.self, from: data).message.content
    }
}
