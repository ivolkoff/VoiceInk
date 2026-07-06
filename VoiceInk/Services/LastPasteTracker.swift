import Foundation

/// Records the exact text VoiceInk last pasted into a target app, so the
/// "re-transcribe last recording in the keyboard-layout language" hotkey can
/// verify — before deleting anything — that the selection it is about to replace
/// is exactly what we pasted.
///
/// In-memory only: the hotkey targets a paste that just happened in the same
/// session, so there is no need to survive an app restart.
@MainActor
final class LastPasteTracker {
    static let shared = LastPasteTracker()
    private init() {}

    struct LastPaste {
        /// The transcription whose text was pasted; ties this context to a specific record.
        let transcriptionID: UUID
        /// The exact string sent to the field, including any trailing space / banner.
        let pastedText: String
        /// The frontmost app's bundle identifier at paste time.
        let targetBundleID: String?
        /// Whether the paste command was issued. `false` ⇒ nothing landed; `true` ⇒ the paste was
        /// posted but not a guarantee the field accepted it — the caller must still verify.
        let posted: Bool
    }

    private(set) var context: LastPaste?

    func record(transcriptionID: UUID, pastedText: String, targetBundleID: String?, posted: Bool) {
        context = LastPaste(
            transcriptionID: transcriptionID,
            pastedText: pastedText,
            targetBundleID: targetBundleID,
            posted: posted
        )
    }

    func clear() {
        context = nil
    }
}
