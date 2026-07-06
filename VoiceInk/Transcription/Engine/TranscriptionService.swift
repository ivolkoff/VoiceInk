import Foundation

/// A protocol defining the interface for a transcription service.
/// This allows for a unified way to handle both local and cloud-based transcription models.
protocol TranscriptionService {
    /// Transcribes the audio from a given file URL.
    ///
    /// - Parameters:
    ///   - audioURL: The URL of the audio file to transcribe.
    ///   - model: The `TranscriptionModel` to use for transcription. This provides context about the provider (local, OpenAI, etc.).
    ///   - language: An explicit language code that overrides the layout/`SelectedLanguage` resolution.
    ///     Pass `nil` to keep the normal behaviour. Used when re-transcribing an existing recording
    ///     in a language the user picks manually.
    /// - Returns: The transcribed text as a `String`.
    /// - Throws: An error if the transcription fails.
    func transcribe(audioURL: URL, model: any TranscriptionModel, language: String?) async throws -> String
}

extension TranscriptionService {
    /// Convenience overload for the common case with no explicit language override.
    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        try await transcribe(audioURL: audioURL, model: model, language: nil)
    }
}