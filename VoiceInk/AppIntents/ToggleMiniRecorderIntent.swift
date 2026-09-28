import AppIntents
import Foundation
import AppKit

struct ToggleMiniRecorderIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle VoiceInk Recorder"
    static var description = IntentDescription("Start or stop the VoiceInk mini recorder for voice transcription.")
    
    static var openAppWhenRun: Bool = false
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Intents bypass ShortcutMonitor, which gates every hotkey path on the session
        // state: an automation must not touch the microphone on a locked screen.
        guard UserSessionInputPolicy.allowsShortcutHandling else {
            return .result(dialog: IntentDialog(stringLiteral: "VoiceInk ignored the request: the session is locked"))
        }
        NotificationCenter.default.post(name: .toggleMiniRecorder, object: nil)
        
        let dialog = IntentDialog(stringLiteral: "VoiceInk recorder toggled")
        return .result(dialog: dialog)
    }
}

enum IntentError: Error, LocalizedError {
    case appNotAvailable
    case serviceNotAvailable
    
    var errorDescription: String? {
        switch self {
        case .appNotAvailable:
            return "VoiceInk app is not available"
        case .serviceNotAvailable:
            return "VoiceInk recording service is not available"
        }
    }
}
