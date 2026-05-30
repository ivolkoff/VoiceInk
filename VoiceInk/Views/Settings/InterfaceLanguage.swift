import Foundation
import SwiftUI
import AppKit

/// The app's interface (UI) language, independent of the macOS system language and of
/// the transcription language. Selecting a value overrides `AppleLanguages` so the next
/// launch renders the UI in that locale; `.system` removes the override and follows macOS.
enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case russian

    var id: String { rawValue }

    /// The macOS language code written to `AppleLanguages`. `nil` for `.system` (no override).
    var localeCode: String? {
        switch self {
        case .system: return nil
        case .english: return "en"
        case .russian: return "ru"
        }
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .system: return "System Language"
        case .english: return "English"
        case .russian: return "Russian"
        }
    }

    // UserDefaults key that records the user's explicit picker choice.
    private static let overrideKey = "VoiceInkInterfaceLanguage"
    private static let appleLanguagesKey = "AppleLanguages"

    /// The currently selected interface language (defaults to `.system`).
    static var current: InterfaceLanguage {
        guard let raw = UserDefaults.standard.string(forKey: overrideKey),
              let value = InterfaceLanguage(rawValue: raw) else {
            return .system
        }
        return value
    }

    /// Persists the choice and updates `AppleLanguages`. Returns `true` if a relaunch is
    /// needed for the change to take effect (i.e. the effective language changed).
    @discardableResult
    func apply() -> Bool {
        let defaults = UserDefaults.standard
        let previous = InterfaceLanguage.current
        defaults.set(rawValue, forKey: InterfaceLanguage.overrideKey)

        switch localeCode {
        case nil:
            defaults.removeObject(forKey: InterfaceLanguage.appleLanguagesKey)
        case let code?:
            defaults.set([code], forKey: InterfaceLanguage.appleLanguagesKey)
        }
        defaults.synchronize()
        return previous != self
    }

    /// Relaunches the app so the new interface language is applied on next launch.
    static func relaunchApp() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}
