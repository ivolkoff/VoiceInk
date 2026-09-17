import Foundation
import Testing
@testable import VoiceInk

struct LayoutPolicyTests {
    @Test func deniedAppsMatchExactAndPrefix() {
        let list = ["com.apple.Terminal", "com.jetbrains.*"]
        #expect(LayoutPolicy.isDeniedApp("com.apple.Terminal", deniedApps: list))
        #expect(LayoutPolicy.isDeniedApp("com.jetbrains.intellij", deniedApps: list))
        #expect(!LayoutPolicy.isDeniedApp("com.apple.TextEdit", deniedApps: list))
        #expect(!LayoutPolicy.isDeniedApp(nil, deniedApps: list))
    }

    @Test func passwordManagersAreDeniedEvenWhenRemovedFromTheList() {
        #expect(LayoutPolicy.isDeniedApp("com.1password.1password", deniedApps: []))
    }

    @Test func neverWordsMatchEitherSideCaseInsensitively() {
        let never: Set<String> = ["ghbdtn"]
        #expect(LayoutPolicy.isNeverWord("GHBDTN", "ПРИВЕТ", never: never))
        #expect(LayoutPolicy.isNeverWord("привет", "ghbdtn", never: never))
        #expect(!LayoutPolicy.isNeverWord("vbh", "мир", never: never))
    }

    @Test func settingsRoundTripAndDefaults() {
        let suite = "LayoutPolicyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let fresh = LayoutSwitcherSettings(defaults: defaults)
        #expect(fresh.enabled == false)
        #expect(fresh.autoConvert == true)
        #expect(fresh.deniedApps == LayoutPolicy.defaultDeniedApps)

        fresh.enabled = true
        fresh.neverWords = ["Ghbdtn"]
        fresh.layout1ID = "com.apple.keylayout.US"

        let reloaded = LayoutSwitcherSettings(defaults: defaults)
        #expect(reloaded.enabled == true)
        #expect(reloaded.neverWordsSet == ["ghbdtn"])
        #expect(reloaded.layout1ID == "com.apple.keylayout.US")
    }
}
