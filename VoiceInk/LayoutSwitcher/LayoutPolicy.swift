import Carbon

/// Hard gates checked before the detector ever runs.
enum LayoutPolicy {
    /// Terminals, IDEs and password managers: auto-conversion is off there by default.
    /// A trailing "*" matches a bundle-id prefix.
    static let defaultDeniedApps: [String] = [
        "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
        "io.alacritty", "com.github.wez.wezterm", "dev.warp.Warp-Stable", "co.zeit.hyper",
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.sublimetext.4", "com.todesktop.230313mzl4w4u92", "com.google.android.studio",
        "com.jetbrains.*",
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "org.keepassxc.keepassxc",
    ]

    /// Password managers can't be un-denied, whatever the user list says.
    static let protectedApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "org.keepassxc.keepassxc",
    ]

    static func isDeniedApp(_ bundleID: String?, deniedApps: [String]) -> Bool {
        guard let id = bundleID else { return false }
        if protectedApps.contains(id) { return true }
        return deniedApps.contains { entry in
            entry.hasSuffix("*") ? id.hasPrefix(String(entry.dropLast())) : entry == id
        }
    }

    /// Session-wide secure input (password field, Secure Keyboard Entry in a terminal).
    static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Also matches without trailing punctuation: «ghbdtn,» is vetoed by a learned «ghbdtn».
    static func isNeverWord(_ typed: String, _ converted: String, never: Set<String>) -> Bool {
        guard !never.isEmpty else { return false }
        let core = LayoutDetector.splitTrailingPunctuation(typed).coreLength
        return [typed, converted, String(typed.prefix(core)), String(converted.prefix(core))]
            .contains { never.contains($0.lowercased()) }
    }
}
