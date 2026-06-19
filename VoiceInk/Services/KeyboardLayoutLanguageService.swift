import Foundation
import Carbon

/// Reads the language of the current macOS keyboard input source (layout).
enum KeyboardLayoutLanguageService {
    /// Base, lowercased language code of the active keyboard layout (e.g. "en", "ru"),
    /// or `nil` if it cannot be determined.
    ///
    /// Reading the current keyboard input source is thread-safe, so this runs on the
    /// calling thread directly. It must NOT hop to the main thread with a blocking
    /// `DispatchQueue.main.sync`: transcription engines call this from the Swift
    /// concurrency cooperative pool, and blocking that on main causes a hang.
    static func currentLanguageCode() -> String? {
        readCurrentLayoutLanguage()
    }

    /// Normalizes an ISO code to its base, lowercased language (e.g. "en-US" -> "en").
    /// Returns `nil` for empty input.
    static func normalize(_ code: String) -> String? {
        let base = code.split(separator: "-").first.map(String.init) ?? code
        let trimmed = base.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func readCurrentLayoutLanguage() -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return nil
        }
        let languages = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String]
        guard let first = languages?.first else { return nil }
        return normalize(first)
    }
}
