import Foundation

enum ShortcutStore {
    static let shortcutDidChange = Notification.Name("ShortcutStoreShortcutDidChange")

    static func rawShortcut(for action: ShortcutAction) -> Shortcut? {
        shortcutData(for: action)
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
    }

    static func shortcut(for action: ShortcutAction) -> Shortcut? {
        guard action.isStored else {
            return nil
        }

        guard !isShortcutCleared(for: action) else {
            return nil
        }

        return rawShortcut(for: action)
    }

    static func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) {
        guard action.isStored else {
            return
        }

        if let shortcut, ShortcutValidator.validationError(for: shortcut, action: action) != nil {
            return
        }

        if let shortcut,
           let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: action.userDefaultsKey)
            UserDefaults.standard.removeObject(forKey: clearedUserDefaultsKey(for: action))
            ShortcutMigration.removeLegacyCustomRecordingShortcut(for: action)
            ShortcutMigration.removeLegacyKeyboardShortcut(for: action)
        } else {
            UserDefaults.standard.removeObject(forKey: action.userDefaultsKey)
            UserDefaults.standard.set(true, forKey: clearedUserDefaultsKey(for: action))
            ShortcutMigration.removeLegacyCustomRecordingShortcut(for: action)
            ShortcutMigration.removeLegacyKeyboardShortcut(for: action)
        }

        NotificationCenter.default.post(
            name: shortcutDidChange,
            object: action
        )
    }

    /// Temporarily disables a shortcut (so the global monitor stops firing it) while
    /// preserving its stored definition — unlike setShortcut(nil), which erases it and
    /// marks it explicitly cleared. Used while interactively re-recording so the binding
    /// survives an app crash mid-recording; recoverInterruptedRecording restores it.
    static func pauseShortcut(for action: ShortcutAction) {
        guard action.isStored else {
            return
        }

        UserDefaults.standard.set(true, forKey: clearedUserDefaultsKey(for: action))
        NotificationCenter.default.post(
            name: shortcutDidChange,
            object: action
        )
    }

    /// If a shortcut is marked cleared but its definition is still stored, the app was
    /// killed after pauseShortcut but before recording finished (a real removal erases
    /// the raw data too). Clear the flag to restore the previous binding.
    static func recoverInterruptedRecording(for action: ShortcutAction) {
        guard action.isStored else {
            return
        }
        guard isShortcutCleared(for: action), let shortcut = rawShortcut(for: action) else {
            return
        }

        // While paused, this binding was invisible to the conflict validator, so another action may
        // have taken the same shortcut in the meantime. Re-validate before un-pausing — restoring
        // unconditionally would reinstate a duplicate the validator would have rejected. If it now
        // conflicts, drop the stale binding rather than creating two actions on one key.
        if ShortcutValidator.validationError(for: shortcut, action: action) != nil {
            UserDefaults.standard.removeObject(forKey: action.userDefaultsKey)
            NotificationCenter.default.post(name: shortcutDidChange, object: action)
            return
        }

        UserDefaults.standard.removeObject(forKey: clearedUserDefaultsKey(for: action))
        NotificationCenter.default.post(
            name: shortcutDidChange,
            object: action
        )
    }

    static func removeShortcutStorage(for action: ShortcutAction) {
        guard action.isStored else {
            return
        }

        UserDefaults.standard.removeObject(forKey: action.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: clearedUserDefaultsKey(for: action))
        ShortcutMigration.removeLegacyCustomRecordingShortcut(for: action)
        ShortcutMigration.removeLegacyKeyboardShortcut(for: action)
        NotificationCenter.default.post(
            name: shortcutDidChange,
            object: action
        )
    }

    static func shortcuts(for actions: [ShortcutAction]) -> [ShortcutAction: Shortcut] {
        actions.reduce(into: [:]) { result, action in
            if let shortcut = shortcut(for: action) {
                result[action] = shortcut
            }
        }
    }

    private static func shortcutData(for action: ShortcutAction) -> Data? {
        UserDefaults.standard.data(forKey: action.userDefaultsKey)
    }

    static func isShortcutCleared(for action: ShortcutAction) -> Bool {
        UserDefaults.standard.bool(forKey: clearedUserDefaultsKey(for: action))
    }

    private static func clearedUserDefaultsKey(for action: ShortcutAction) -> String {
        "\(action.userDefaultsKey)_cleared"
    }
}
