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
        let restore: TISInputSource?   // layout active before it; nil when it didn't switch
    }

    private let settings = LayoutSwitcherSettings.shared
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "LayoutSwitcherEngine")
    private let resonance = AntiResonanceGuard()
    private var tap: KeystrokeTap?
    private var buffer = KeystrokeBuffer()
    private var lastConversion: Conversion?
    private var inFlight = false
    private var pendingAuto = false
    private var lastSeq: UInt64 = 0   // sequence number of the last tap event handled
    private var triggerShortcut: Shortcut?
    private var appObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    /// Grace period between the boundary keystroke and the first Backspace: lets the app finish
    /// the space and gives a fast typist's next key a chance to cancel the conversion.
    private static let boundaryGrace: TimeInterval = 0.03

    /// Focus on a list has no text before the caret to check, and there Backspace deletes items
    /// (Notes binds Edit › Delete to a bare ⌫).
    private static let itemListRoles: Set<String> = [
        kAXTableRole as String, kAXOutlineRole as String, kAXListRole as String,
        kAXBrowserRole as String, kAXGridRole as String,
    ]

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
        let tap = KeystrokeTap { [weak self] event, seq in
            MainActor.assumeIsolated { self?.handle(event, seq: seq) }
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

    private func handle(_ event: KeystrokeTap.Event, seq: UInt64) {
        lastSeq = seq
        switch event {
        case .mouseDown:
            resetContext()
        case let .keyDown(keyCode, flags):
            let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
            // The trigger's own key combo must not wipe the word it is about to convert.
            if let triggerShortcut, triggerShortcut.matchesKeyEvent(keyCode: keyCode, modifierFlags: modifierFlags) { return }
            // A key before the replacement cancels it (grace period, or the tap sees it before the
            // flush marker); either way the screen is untouched and the buffer still matches it.
            pendingAuto = false
            // ⌃Space / ⌘Space / ⌥⌫ don't type a space or delete one character.
            let combo = !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
            switch keyCode {
            case 49 where !combo:   // space
                lastConversion = nil
                if let word = buffer.space() {
                    scheduleAutoConversion(of: word, capsLock: flags.contains(.maskAlphaShift), seq: seq)
                }
            case 36, 76, 48, 53, 123...126:   // return, keypad enter, tab, escape, arrows
                resetContext()
            case 51 where !combo:   // delete
                lastConversion = nil
                buffer.backspace()
            default:
                guard !combo, LayoutMapper.typeableKeyCodes.contains(keyCode) else {
                    resetContext()
                    return
                }
                lastConversion = nil
                let shift = flags.contains(.maskShift), caps = flags.contains(.maskAlphaShift)
                let data = LayoutPair.currentLayoutData()
                // A dead key composes with the next one: fewer characters on screen than keys.
                if let data, LayoutMapper.isDeadKey(keyCode: keyCode, layout: data, shift: shift, caps: caps) {
                    buffer.skipWord()
                    return
                }
                let ch = data.flatMap { LayoutMapper.character(keyCode: keyCode, layout: $0, shift: shift, caps: caps) }
                buffer.append(TypedKey(keyCode: keyCode, shift: shift, caps: caps, char: ch))
            }
        }
    }

    private func resetContext() {
        buffer.reset()
        lastConversion = nil
        pendingAuto = false
        resonance.resetHistory()
    }

    // MARK: - Auto conversion

    private func scheduleAutoConversion(of word: [TypedKey], capsLock: Bool, seq: UInt64) {
        guard settings.autoConvert else { logger.notice("auto gate: autoConvert off"); return }
        guard !resonance.isFrozen else { logger.notice("auto gate: frozen"); return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard !LayoutPolicy.secureInputActive else { logger.notice("auto gate: secure input"); return }
        guard !secureFieldFocused else { logger.notice("auto gate: secure field"); return }
        guard !LayoutPolicy.isDeniedApp(front, deniedApps: settings.deniedApps) else {
            logger.notice("auto gate: denied app \(front ?? "nil", privacy: .public)"); return
        }
        guard let both = LayoutPair.resolveBoth(layout1ID: settings.layout1ID, layout2ID: settings.layout2ID) else {
            logger.notice("auto gate: pair unresolved (layout not in configured pair)"); return
        }
        let typed = String(word.compactMap(\.char))
        guard typed.count == word.count else {
            logger.notice("auto gate: unresolved characters in buffer"); return
        }
        let map = LayoutMapper.bidirectionalMap(both.aData, both.bData)
        let plan = LayoutConversion.plan(typed: typed, aLang: both.aLang, bLang: both.bLang,
                                         map: map, capsLock: capsLock, alwaysConvert: settings.alwaysWordsSet)
        guard !LayoutPolicy.isNeverWord(plan.typed, plan.converted, never: settings.neverWordsSet) else {
            logger.notice("auto gate: never-word"); return
        }
        guard plan.verdict == .switchToConverted else {
            logger.notice("auto gate: verdict \(String(describing: plan.verdict), privacy: .public) typed=\(plan.typed, privacy: .private) conv=\(plan.converted, privacy: .private)")
            return
        }
        let original = plan.typed + " "
        let produced = String(plan.converted.prefix(plan.convertedLength))
            + String(plan.typed.dropFirst(plan.convertedLength)) + " "
        let switchTarget = plan.switchToB ? both.bSource : both.aSource
        guard resonance.allow(word: original, produced: produced) else {
            buffer.reset()
            return
        }

        pendingAuto = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.boundaryGrace) { [weak self] in
            guard let self, self.pendingAuto else { return }
            self.pendingAuto = false
            // Verify against the screen only when the app actually exposes text before the caret.
            // An empty result means the app gives us nothing to check (some editors / web fields),
            // not that the buffer is wrong — treat it like nil and proceed. And on a real mismatch
            // do NOT reset the buffer: the manual trigger stays available as a fallback.
            if let onScreen = FocusedTextAccessibility.textBeforeCaret(),
               !onScreen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // A letter right before it means the buffer holds only the tail of a word
                // (typing resumed after a click or arrows mid-word).
                let before = onScreen.dropLast(original.count).last
                guard onScreen.lowercased().hasSuffix(original.lowercased()),
                      !(before?.isLetter ?? false), !(before?.isNumber ?? false) else {
                    self.logger.notice("auto skip: screen does not end with the buffered word")
                    return
                }
            }
            self.perform(deleteCount: original.count, text: produced, original: original,
                         wasAuto: true, bundleID: front, switchTo: switchTarget, afterSeq: seq)
        }
    }

    // MARK: - Manual trigger

    func handleManualTrigger() async {
        guard settings.enabled, !inFlight else { return }
        pendingAuto = false
        let seq = lastSeq   // anything typed after this point cancels the replacement
        guard !LayoutPolicy.secureInputActive,
              !secureFieldFocused else {
            logger.notice("manual trigger: secure input")
            NotificationManager.shared.showNotification(title: String(localized: "Secure input is active"), type: .warning)
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Tap again = undo. Any key, click or app switch clears lastConversion, so no new
        // selection can exist yet — skip the selection read and its clipboard fallback.
        // An undone auto-conversion teaches the never list.
        if let last = lastConversion, last.bundleID == front {
            logger.notice("manual trigger: undo")
            perform(deleteCount: last.produced.count, text: last.original, original: last.produced,
                    wasAuto: false, bundleID: front, switchTo: last.restore, afterSeq: seq)
            if last.wasAuto { learnNever(last.original) }
            return
        }

        // A real highlight, not a Cmd-C fallback: some editors (Sublime) copy the whole line when
        // nothing is selected, which would make us type over an empty selection and append instead
        // of replace. AXSelectedText is authoritative — non-empty only on a real highlight, "" when
        // there is none. Only when AX can't report it at all (nil: Electron/Telegram) and the user
        // is not mid-word do we fall back to the copy-based read.
        let axSelection = FocusedTextAccessibility.selectedText()
        let selection: String?
        if let axSelection {
            selection = axSelection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : axSelection
        } else if buffer.manualTarget == nil {
            let copied = await SelectedTextService.fetchSelectedText()
            let trimmed = copied?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            selection = trimmed.isEmpty ? nil : copied
        } else {
            selection = nil
        }
        if let selection {
            guard let pair = LayoutPair.resolve(layout1ID: settings.layout1ID, layout2ID: settings.layout2ID) else {
                logger.notice("manual trigger: pair unresolved")
                NotificationManager.shared.showNotification(title: String(localized: "Current keyboard layout is not in the configured pair"), type: .warning)
                return
            }
            logger.notice("manual trigger: selection")
            convertSelection(selection, pair: pair, bundleID: front, afterSeq: seq)
            return
        }

        guard let both = LayoutPair.resolveBoth(layout1ID: settings.layout1ID, layout2ID: settings.layout2ID) else {
            logger.notice("manual trigger: pair unresolved")
            NotificationManager.shared.showNotification(title: String(localized: "Current keyboard layout is not in the configured pair"), type: .warning)
            return
        }
        guard let target = buffer.manualTarget else {
            logger.notice("manual trigger: nothing")
            NotificationManager.shared.showNotification(title: String(localized: "Nothing to convert"), type: .info)
            return
        }
        let typed = LayoutMapper.reconstruct(target.keys, currentData: LayoutPair.currentLayoutData(),
                                             pairA: both.aData, pairB: both.bData)
        logger.notice("manual trigger: last word")
        let map = LayoutMapper.bidirectionalMap(both.aData, both.bData)
        let converted = LayoutMapper.convertText(typed, map: map)
        // By the result's script: «'[» has no letters but becomes «эх».
        let switchToB = LayoutConversion.scriptMatchesLang(converted, lang: both.bLang)
        let spaces = String(repeating: " ", count: target.trailingSpaces)
        perform(deleteCount: typed.count + target.trailingSpaces, text: converted + spaces,
                original: typed + spaces, wasAuto: false, bundleID: front,
                switchTo: switchToB ? both.bSource : both.aSource, afterSeq: seq)
    }

    private func convertSelection(_ selection: String, pair: LayoutPair.Resolved, bundleID: String?, afterSeq: UInt64) {
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
        perform(deleteCount: 0, text: result, original: selection, wasAuto: false, bundleID: bundleID,
                switchTo: nil, afterSeq: afterSeq)
    }

    private func learnNever(_ original: String) {
        let trimmed = original.trimmingCharacters(in: .whitespaces)
        let word = String(trimmed.prefix(LayoutDetector.splitTrailingPunctuation(trimmed).coreLength)).lowercased()
        guard !word.isEmpty, !settings.neverWordsSet.contains(word) else { return }
        settings.neverWords.append(word)
        NotificationManager.shared.showNotification(
            title: String.localizedStringWithFormat(String(localized: "“%@” added to Never convert"), word),
            type: .info
        )
    }

    // MARK: - Replacement

    private func perform(deleteCount: Int, text: String, original: String, wasAuto: Bool,
                         bundleID: String?, switchTo: TISInputSource?, afterSeq: UInt64) {
        guard let tap else { return }
        if deleteCount > 0, let role = FocusedTextAccessibility.focusedRole(), Self.itemListRoles.contains(role) {
            logger.notice("replacement skipped: focus is \(role, privacy: .public), Backspace would delete items")
            return
        }
        inFlight = true
        let restore = switchTo == nil ? nil : LayoutPair.current()
        tap.runAtomically(afterSeq: afterSeq, work: {
            DirectTyper.replace(deleteCount: deleteCount, with: text)
        }, done: { [weak self] typed in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inFlight = false
                guard typed else {
                    self.logger.notice("replacement skipped: input arrived before it")
                    return
                }
                if let switchTo { LayoutPair.select(switchTo) }
                self.buffer.reset()
                self.lastConversion = Conversion(original: original, produced: text, wasAuto: wasAuto,
                                                 bundleID: bundleID, restore: restore)
                self.logger.notice("\(wasAuto ? "auto" : "manual", privacy: .public): \(original, privacy: .private) -> \(text, privacy: .private)")
            }
        })
    }
}
