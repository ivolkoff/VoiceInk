import Foundation

/// Result of capturing text for the enhance-selected-text action.
///
/// Distinguishes a real user selection from a select-all fallback (so callers can
/// reason about how aggressive the capture was) and from the "nothing usable" case.
enum SelectedTextCaptureResult: Equatable {
    /// Text the user had actively selected.
    case selection(String)
    /// Text obtained by selecting all content in the focused editable field.
    case selectedAll(String)
    /// No usable text could be captured.
    case noText

    /// The captured text, or `nil` when nothing usable was found.
    var text: String? {
        switch self {
        case .selection(let text), .selectedAll(let text):
            return text
        case .noText:
            return nil
        }
    }
}

/// The decision made before running (or skipping) AI enhancement on captured text.
///
/// Encodes the no-text and max-length guards so they can be unit-tested without
/// touching accessibility, the network, or the pasteboard.
enum SelectedTextEnhancementDecision: Equatable {
    /// Captured text is usable and within the limit; enhancement should run.
    case proceed(text: String)
    /// No usable text was captured; abort and notify.
    case abortNoText
    /// Captured text exceeds the configured limit; abort before any AI call and notify.
    case abortTooLong(length: Int, limit: Int)

    static func decide(capture: SelectedTextCaptureResult, maxInputLength: Int) -> SelectedTextEnhancementDecision {
        guard let text = capture.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .abortNoText
        }

        let length = text.count
        if length > maxInputLength {
            return .abortTooLong(length: length, limit: maxInputLength)
        }

        return .proceed(text: text)
    }
}

/// Settings for the enhance-selected-text action.
enum SelectedTextEnhancementSettings {
    static let maxInputLengthKey = "selectedTextEnhancementMaxInputLength"

    /// Default character limit. Comfortably covers normal paragraphs/emails while
    /// blocking whole-document accidents from the select-all fallback.
    static let defaultMaxInputLength = 4000

    static func maxInputLength(defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: maxInputLengthKey)
        return stored > 0 ? stored : defaultMaxInputLength
    }
}
