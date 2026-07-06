import Foundation
import Carbon

/// Reads the language of the current macOS keyboard input source (layout).
enum KeyboardLayoutLanguageService {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedLanguage: String?

    /// Base, lowercased language code of the layout captured by the most recent
    /// `captureCurrentLayout()` call (e.g. "en", "ru"), or `nil` if it has not been
    /// captured yet.
    ///
    /// Reads only the cache, so it is safe to call from any thread. The Text Input Source
    /// API it would otherwise use asserts it runs on the main dispatch queue and crashes
    /// the process when called from the Swift concurrency cooperative pool, which is where
    /// the transcription engines resolve the language.
    static func currentLanguageCode() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedLanguage
    }

    /// Captures the active keyboard layout language into the cache. Must run on the main
    /// thread. Call this the moment recording starts, while the target app still owns the
    /// input source, so transcription reflects the layout the user was actually typing in.
    ///
    /// Capturing at record time — rather than reacting to input-source-change
    /// notifications — keeps the value correct even while VoiceInk sits in the background
    /// and never receives those notifications.
    @MainActor
    static func captureCurrentLayout() {
        updateCachedLanguage(readCurrentLayoutLanguage())
    }

    /// Stores a layout language code in the thread-safe cache.
    static func updateCachedLanguage(_ code: String?) {
        lock.lock()
        cachedLanguage = code
        lock.unlock()
    }

    /// Normalizes an ISO code to its base, lowercased language (e.g. "en-US" -> "en").
    /// Returns `nil` for empty input.
    static func normalize(_ code: String) -> String? {
        let base = code.split(separator: "-").first.map(String.init) ?? code
        let trimmed = base.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Reads the active layout language via TIS. MUST run on the main thread — TIS
    /// asserts its dispatch queue.
    @MainActor
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
