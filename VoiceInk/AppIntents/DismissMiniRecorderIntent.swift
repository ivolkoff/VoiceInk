import AppIntents
import Foundation
import AppKit

struct DismissMiniRecorderIntent: AppIntent {
    static var title: LocalizedStringResource = "Dismiss VoiceInk Recorder"
    static var description = IntentDescription("Dismiss the VoiceInk mini recorder and cancel any active recording.")
    
    static var openAppWhenRun: Bool = false
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Intents bypass ShortcutMonitor, which gates every hotkey path on the session
        // state: an automation must not touch the microphone on a locked screen.
        guard UserSessionInputPolicy.allowsShortcutHandling else {
            return .result(dialog: IntentDialog(stringLiteral: "VoiceInk ignored the request: the session is locked"))
        }
        NotificationCenter.default.post(name: .dismissMiniRecorder, object: nil)
        
        let dialog = IntentDialog(stringLiteral: "VoiceInk recorder dismissed")
        return .result(dialog: dialog)
    }
}
