import Combine
import Foundation

final class LayoutSwitcherSettings: ObservableObject {
    static let shared = LayoutSwitcherSettings()

    enum Keys {
        static let enabled = "layoutSwitcher.enabled"
        static let autoConvert = "layoutSwitcher.autoConvert"
        static let layout1ID = "layoutSwitcher.layout1ID"
        static let layout2ID = "layoutSwitcher.layout2ID"
        static let deniedApps = "layoutSwitcher.deniedApps"
        static let neverWords = "layoutSwitcher.neverWords"
        static let alwaysWords = "layoutSwitcher.alwaysWords"
    }

    private let defaults: UserDefaults

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Keys.enabled) } }
    @Published var autoConvert: Bool { didSet { defaults.set(autoConvert, forKey: Keys.autoConvert) } }
    /// Empty = auto-detect.
    @Published var layout1ID: String { didSet { defaults.set(layout1ID, forKey: Keys.layout1ID) } }
    @Published var layout2ID: String { didSet { defaults.set(layout2ID, forKey: Keys.layout2ID) } }
    @Published var deniedApps: [String] { didSet { defaults.set(deniedApps, forKey: Keys.deniedApps) } }
    @Published var neverWords: [String] { didSet { defaults.set(neverWords, forKey: Keys.neverWords) } }
    /// Target forms («привет»), not the garbage that produced them.
    @Published var alwaysWords: [String] { didSet { defaults.set(alwaysWords, forKey: Keys.alwaysWords) } }

    var neverWordsSet: Set<String> { Set(neverWords.map { $0.lowercased() }) }
    var alwaysWordsSet: Set<String> { Set(alwaysWords.map { $0.lowercased() }) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Keys.enabled)
        autoConvert = defaults.object(forKey: Keys.autoConvert) as? Bool ?? true
        layout1ID = defaults.string(forKey: Keys.layout1ID) ?? ""
        layout2ID = defaults.string(forKey: Keys.layout2ID) ?? ""
        deniedApps = defaults.stringArray(forKey: Keys.deniedApps) ?? LayoutPolicy.defaultDeniedApps
        neverWords = defaults.stringArray(forKey: Keys.neverWords) ?? []
        alwaysWords = defaults.stringArray(forKey: Keys.alwaysWords) ?? []
    }
}
