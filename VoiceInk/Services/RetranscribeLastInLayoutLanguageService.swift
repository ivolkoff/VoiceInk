import Foundation
import SwiftData
import AppKit
import ApplicationServices

/// Drives the "re-transcribe last recording in the keyboard-layout language and replace the pasted
/// text" hotkey. Every guard is checked BEFORE any destructive keystroke, and the on-screen text is
/// only deleted once the selection is verified to be exactly what we pasted — otherwise the new
/// text is left on the clipboard and nothing is destroyed.
enum RetranscribeLastInLayoutLanguageService {
    @MainActor private static var isInFlight = false

    @MainActor
    static func run(
        modelContext: ModelContext,
        transcriptionModelManager: TranscriptionModelManager,
        engine: VoiceInkEngine
    ) async {
        // 1. Re-entrancy: global-utility actions have no debounce, and two runs share the whisper
        //    model manager, which would tear the context down mid-transcription.
        guard !isInFlight else { return }

        // 2. Recorder must be idle — a run during recording tears down the shared whisper context.
        guard engine.recordingState == .idle else {
            notify("Finish recording before re-transcribing", .error)
            return
        }

        // 3. Current keyboard-layout language, read now (not the record-time cache).
        KeyboardLayoutLanguageService.captureCurrentLayout()
        guard let layoutLang = KeyboardLayoutLanguageService.currentLanguageCode() else {
            notify("Couldn't detect the keyboard layout language", .error)
            return
        }

        // 4. There must be a recent, actually-posted paste to replace.
        guard let paste = LastPasteTracker.shared.context, paste.posted else {
            notify("No recent dictation to re-transcribe", .error)
            return
        }

        // 5. The last record must be the one we pasted and be a completed transcription.
        guard let last = LastTranscriptionService.getLastTranscription(from: modelContext),
              last.id == paste.transcriptionID,
              last.transcriptionStatus == TranscriptionStatus.completed.rawValue else {
            notify("No matching transcription to re-transcribe", .error)
            return
        }

        // 6. Its audio file must still exist (auto-cleanup may have removed it).
        guard let audioURLString = last.audioFileURL,
              let audioURL = URL(string: audioURLString),
              FileManager.default.fileExists(atPath: audioURL.path) else {
            notify("Audio file not found — can't re-transcribe", .error)
            return
        }

        // 7. Resolve the layout language to a concrete code the current model supports.
        guard let model = transcriptionModelManager.currentTranscriptionModel else {
            notify("No transcription model selected", .error)
            return
        }
        guard let resolvedCode = TranscriptionLanguagePreference.supportedCode(forLayoutLanguage: layoutLang, model: model) else {
            notify("Keyboard layout language isn't supported by this model", .error)
            return
        }

        // 8. Accessibility is required for the select-back keystrokes.
        guard AXIsProcessTrusted() else {
            notify("Grant Accessibility permission to replace text", .error)
            return
        }

        // 9. The app we pasted into must still be frontmost.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == paste.targetBundleID else {
            notify("Switch back to the app where you dictated", .error)
            return
        }

        // Invariant: no `await` may exist between the `isInFlight` guard above and this line — the
        // guards run synchronously on the MainActor so a second press can't slip through before the
        // flag is set. Keep any new async work below this point.
        isInFlight = true
        defer { isInFlight = false }

        // 10. Re-transcribe BEFORE touching the field; a failure aborts with nothing destroyed.
        notify("Re-transcribing…", .info, isLoading: true)
        let service = AudioTranscriptionService(modelContext: modelContext, engine: engine)
        let newText: String
        do {
            newText = try await service.retranscribeInPlace(last, language: resolvedCode, using: model)
        } catch {
            notify("Re-transcription failed: \(error.localizedDescription)", .error)
            return
        }

        // Focus can change during the seconds-long re-transcription — re-check before any keystroke
        // so we don't select-back in the wrong app. (The AX verify below is the final backstop.)
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == paste.targetBundleID else {
            fallBackToClipboard(newText)
            return
        }

        // 11. Verify-before-destroy: select the pasted text, confirm it's exactly what we pasted,
        //     and only then replace it. Any mismatch → non-destructive clipboard fallback.
        let expected = paste.pastedText
        guard await CursorPaster.selectBackward(count: expected.count) else {
            fallBackToClipboard(newText)
            return
        }
        // Let the selection register before reading it back.
        try? await Task.sleep(nanoseconds: 40_000_000)

        if FocusedTextAccessibility.selectedText() == expected {
            let pasteResult = await CursorPaster.pasteAtCursorAndWaitUntilPosted(newText)
            guard pasteResult.didPostPasteCommand else {
                // Paste didn't post — leave the (still-selected) original intact and fall back.
                CursorPaster.collapseSelectionForward()
                fallBackToClipboard(newText)
                return
            }
            // The field now holds newText — track it so a further layout switch can replace again.
            LastPasteTracker.shared.record(
                transcriptionID: last.id,
                pastedText: newText,
                targetBundleID: paste.targetBundleID,
                posted: true
            )
            notify("Re-transcribed in \(layoutLang)", .success)
        } else {
            // The selection isn't our text (user edited, caret moved, AutoSend submitted, or the
            // field doesn't expose AX selection). Don't delete anything.
            CursorPaster.collapseSelectionForward()
            fallBackToClipboard(newText)
        }
    }

    @MainActor
    private static func fallBackToClipboard(_ text: String) {
        ClipboardManager.copyToClipboard(text)
        notify("Couldn't safely replace — re-transcription copied to clipboard", .info)
    }

    @MainActor
    private static func notify(_ title: String, _ type: AppNotificationView.NotificationType, isLoading: Bool = false) {
        NotificationManager.shared.showNotification(title: title, type: type, isLoading: isLoading)
    }
}
