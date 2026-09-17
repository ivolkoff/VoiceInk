import AppKit
import ApplicationServices
import Carbon
import Combine
import os

/// Orchestrates the layout switcher: feeds the keystroke buffer from the tap, converts at word
/// boundaries, handles the manual trigger and its undo. One instance, main actor.
@MainActor
final class LayoutSwitcherEngine {
    static let shared = LayoutSwitcherEngine()

    private struct Conversion {
        let original: String   // what was on screen before we touched it
        let produced: String   // what we typed instead
        let wasAuto: Bool
        let bundleID: String?
    }

    private let settings = LayoutSwitcherSettings.shared
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "LayoutSwitcherEngine")
    private let resonance = AntiResonanceGuard()
    private var tap: KeystrokeTap?
    private var buffer = KeystrokeBuffer()
    private var lastConversion: Conversion?
    private var inFlight = false
    private var interrupted = false
    private var triggerShortcut: Shortcut?
    private var appObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    /// Grace period between the boundary keystroke and the first Backspace: lets the app finish
    /// the space and gives a fast typist's next key a chance to cancel the conversion.
    private static let boundaryGrace: TimeInterval = 0.03

    /// Secure fields report role `AXTextField` + subrole `AXSecureTextField`; some apps put the
    /// name straight into the role, so both are checked.
    private var secureFieldFocused: Bool {
        FocusedTextAccessibility.focusedRole() == (kAXSecureTextFieldSubrole as String)
            || FocusedTextAccessibility.focusedSubrole() == (kAXSecureTextFieldSubrole as String)
    }

    private init() {
        triggerShortcut = ShortcutStore.shortcut(for: .convertLayout)
        NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)
            .sink { [weak self] _ in self?.triggerShortcut = ShortcutStore.shortcut(for: .convertLayout) }
            .store(in: &cancellables)
        settings.$enabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                Task { @MainActor in enabled ? self?.start() : self?.stop() }
            }
            .store(in: &cancellables)
    }

    func start() {
        guard tap == nil else { return }
        let tap = KeystrokeTap { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        guard tap.start() else {
            logger.error("start: tap unavailable")
            return
        }
        self.tap = tap
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resetContext() }
        }
        SystemDictionary.warmUp()
        logger.notice("started")
    }

    func stop() {
        tap?.stop()
        tap = nil
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        resetContext()
        logger.notice("stopped")
    }

    // MARK: - Tap events

    private func handle(_ event: KeystrokeTap.Event) {
        switch event {
        case .mouseDown:
            resetContext()
        case let .keyDown(keyCode, flags):
            let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
            // The trigger's own key combo must not wipe the word it is about to convert.
            if let triggerShortcut, triggerShortcut.matchesKeyEvent(keyCode: keyCode, modifierFlags: modifierFlags) { return }
            if inFlight {
                interrupted = true
                resetContext()
                return
            }
            switch keyCode {
            case 49:   // space
                lastConversion = nil
                if let word = buffer.space() {
                    scheduleAutoConversion(of: word, capsLock: flags.contains(.maskAlphaShift))
                }
            case 36, 76, 48, 53, 123...126:   // return, keypad enter, tab, escape, arrows
                resetContext()
            case 51:   // delete
                lastConversion = nil
                buffer.backspace()
            default:
                let combo = !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
                guard !combo, LayoutMapper.typeableKeyCodes.contains(keyCode) else {
                    resetContext()
                    return
                }
                lastConversion = nil
                buffer.append(TypedKey(keyCode: keyCode, shift: flags.contains(.maskShift), caps: flags.contains(.maskAlphaShift)))
            }
        }
    }

    private func resetContext() {
        buffer.reset()
        lastConversion = nil
        resonance.resetHistory()
    }

    // MARK: - Auto conversion

    private func scheduleAutoConversion(of word: [TypedKey], capsLock: Bool) {
        guard settings.autoConvert else { logger.notice("auto gate: autoConvert off"); return }
        guard !resonance.isFrozen else { logger.notice("auto gate: frozen"); return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard !LayoutPolicy.secureInputActive else { logger.notice("auto gate: secure input"); return }
        guard !secureFieldFocused else { logger.notice("auto gate: secure field"); return }
        guard !LayoutPolicy.isDeniedApp(front, deniedApps: settings.deniedApps) else {
            logger.notice("auto gate: denied app \(front ?? "nil", privacy: .public)"); return
        }
        guard let pair = LayoutPair.resolve(layout1ID: settings.layout1ID, layout2ID: settings.layout2ID) else {
            logger.notice("auto gate: pair unresolved (layout not in configured pair)"); return
        }
        guard let pairs = LayoutMapper.convert(word, from: pair.currentData, to: pair.otherData) else {
            logger.notice("auto gate: mapping failed (dead key or unmapped)"); return
        }

        let typed = String(pairs.map(\.original))
        let converted = String(pairs.map(\.converted))
        guard !LayoutPolicy.isNeverWord(typed, converted, never: settings.neverWordsSet) else {
            logger.notice("auto gate: never-word"); return
        }

        let decision = LayoutDetector.decideWord(pairs: pairs, currentLang: pair.currentLang, otherLang: pair.otherLang,
                                                 capsLock: capsLock, alwaysConvert: settings.alwaysWordsSet)
        guard decision.verdict == .switchToConverted else {
            logger.notice("auto gate: verdict \(String(describing: decision.verdict), privacy: .public) typed=\(typed, privacy: .public) conv=\(converted, privacy: .public) langs=\(pair.currentLang, privacy: .public)/\(pair.otherLang, privacy: .public)")
            return
        }

        let original = typed + " "
        let produced = String(pairs.prefix(decision.convertedLength).map(\.converted))
            + String(pairs.dropFirst(decision.convertedLength).map(\.original)) + " "
        guard resonance.allow(word: original, produced: produced) else {
            buffer.reset()
            return
        }

        inFlight = true
        interrupted = false
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.boundaryGrace) { [weak self] in
            guard let self else { return }
            guard !self.interrupted else {
                self.inFlight = false
                return
            }
            if let onScreen = FocusedTextAccessibility.textBeforeCaret(), !onScreen.hasSuffix(original) {
                let tail = String(onScreen.suffix(max(original.count + 4, 12)))
                self.logger.notice("auto skip: expected suffix \(original, privacy: .public) but screen tail is \(tail, privacy: .public)")
                self.inFlight = false
                self.buffer.reset()
                return
            }
            self.perform(deleteCount: original.count, text: produced, original: original,
                         wasAuto: true, bundleID: front, switchTo: pair.other)
        }
    }

    // MARK: - Manual trigger

    func handleManualTrigger() async {
        guard settings.enabled, !inFlight else { return }
        guard !LayoutPolicy.secureInputActive,
              !secureFieldFocused else {
            logger.notice("manual trigger: secure input")
            NotificationManager.shared.showNotification(title: String(localized: "Secure input is active"), type: .warning)
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let pair = LayoutPair.resolve(layout1ID: settings.layout1ID, layout2ID: settings.layout2ID) else {
            logger.notice("manual trigger: pair unresolved")
            NotificationManager.shared.showNotification(title: String(localized: "Current keyboard layout is not in the configured pair"), type: .warning)
            return
        }

        let selection = await SelectedTextService.fetchSelectedText()
        if let selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.notice("manual trigger: selection")
            convertSelection(selection, pair: pair, bundleID: front)
            return
        }

        if let last = lastConversion, last.bundleID == front {
            logger.notice("manual trigger: undo")
            // Tap again = undo. An undone auto-conversion teaches the never list.
            perform(deleteCount: last.produced.count, text: last.original, original: last.produced,
                    wasAuto: false, bundleID: front, switchTo: pair.other)
            if last.wasAuto { learnNever(last.original) }
            return
        }

        guard let target = buffer.manualTarget,
              let pairs = LayoutMapper.convert(target.keys, from: pair.currentData, to: pair.otherData) else {
            logger.notice("manual trigger: nothing")
            NotificationManager.shared.showNotification(title: String(localized: "Nothing to convert"), type: .info)
            return
        }
        logger.notice("manual trigger: last word")
        let spaces = String(repeating: " ", count: target.trailingSpaces)
        let original = String(pairs.map(\.original)) + spaces
        let produced = String(pairs.map(\.converted)) + spaces
        perform(deleteCount: original.count, text: produced, original: original,
                wasAuto: false, bundleID: front, switchTo: pair.other)
    }

    private func convertSelection(_ selection: String, pair: LayoutPair.Resolved, bundleID: String?) {
        let result: String
        if SmartConvert.isLatinLang(pair.currentLang), SmartConvert.isCyrillicLang(pair.otherLang),
           SystemDictionary.isAvailable(pair.currentLang), SystemDictionary.isAvailable(pair.otherLang) {
            result = SmartConvert.selection(selection, latLang: pair.currentLang, cyrLang: pair.otherLang,
                                            map: LayoutMapper.bidirectionalMap(pair.currentData, pair.otherData))
        } else if SmartConvert.isCyrillicLang(pair.currentLang), SmartConvert.isLatinLang(pair.otherLang),
                  SystemDictionary.isAvailable(pair.currentLang), SystemDictionary.isAvailable(pair.otherLang) {
            result = SmartConvert.selection(selection, latLang: pair.otherLang, cyrLang: pair.currentLang,
                                            map: LayoutMapper.bidirectionalMap(pair.currentData, pair.otherData))
        } else {
            result = LayoutMapper.convertText(selection, map: LayoutMapper.characterMap(from: pair.currentData, to: pair.otherData))
        }
        guard result != selection else {
            NotificationManager.shared.showNotification(title: String(localized: "Nothing to convert"), type: .info)
            return
        }
        // Typing over a selection replaces it; no Backspaces, no layout switch.
        perform(deleteCount: 0, text: result, original: selection, wasAuto: false, bundleID: bundleID, switchTo: nil)
    }

    private func learnNever(_ original: String) {
        let word = original.trimmingCharacters(in: .whitespaces).lowercased()
        guard !word.isEmpty, !settings.neverWordsSet.contains(word) else { return }
        settings.neverWords.append(word)
        NotificationManager.shared.showNotification(
            title: String.localizedStringWithFormat(String(localized: "“%@” added to Never convert"), word),
            type: .info
        )
    }

    // MARK: - Replacement

    private func perform(deleteCount: Int, text: String, original: String, wasAuto: Bool,
                         bundleID: String?, switchTo: TISInputSource?) {
        inFlight = true
        interrupted = false
        DirectTyper.replace(deleteCount: deleteCount, with: text) { [weak self] in
            guard let self else { return }
            self.inFlight = false
            if let switchTo { LayoutPair.select(switchTo) }
            self.buffer.reset()
            self.lastConversion = Conversion(original: original, produced: text, wasAuto: wasAuto, bundleID: bundleID)
            self.logger.notice("\(wasAuto ? "auto" : "manual", privacy: .public): \(original, privacy: .private) -> \(text, privacy: .private)")
        }
    }
}
