# Layout Switcher (PuntoSwitcher analog) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix words typed in the wrong keyboard layout (`ghbdtn` → `привет`) inside VoiceInk — automatically at the word boundary and by a hotkey for the last word or the selection — without touching the clipboard.

**Architecture:** A listen-only `CGEventTap` feeds a key-code buffer; at a space the word is rendered in both layouts of the pair through `UCKeyTranslate`, judged by `NSSpellChecker` (precision first), and, when it is garbage in the current layout but a real word in the other, deleted with synthetic Backspaces and retyped as Unicode key events posted below every session-level tap. The system layout is then switched with `TISSelectInputSource`. The manual trigger is one new `ShortcutAction` handled by the existing shortcut stack. Everything lives in `VoiceInk/LayoutSwitcher/` plus one settings view.

**Tech Stack:** Swift 5 (Xcode 16 project, synchronized folders — new files under `VoiceInk/` and `VoiceInkTests/` are picked up without editing the pbxproj), SwiftUI, Combine, Carbon TIS/`UCKeyTranslate`, CoreGraphics event taps, `NSSpellChecker`, swift-testing (`import Testing`, `@Test`, `#expect`).

**Spec:** `docs/superpowers/specs/2026-09-17-layout-switcher-design.md`

## Global Constraints

- Ported code is MIT from RuSwitcher (© Rashns) and keyboop (© Keyboop contributors); each ported file keeps a one-line origin comment and `THIRD_PARTY.md` (Task 10) carries the licence texts. VoiceInk is GPL-3; MIT inside GPL is fine with attribution.
- No new SPM dependencies. No bundled dictionaries or trigram data.
- New source files go in `VoiceInk/LayoutSwitcher/` (logic) and `VoiceInk/Views/LayoutSwitcher/` (UI); tests are flat files in `VoiceInkTests/`.
- Logger subsystem is `"com.prakashjoshipax.voiceink"`; categories are the type name.
- Comments explain *why* only, ≤3 lines, no headers restating the next line.
- Feature master toggle defaults **off**; auto-conversion inside it defaults **on**.
- Enter/Tab/arrows/mouse click/⌘-⌃-⌥ combos reset the buffer and never trigger a conversion.
- Synthetic events: `virtualKey 0` Unicode chunks of ≤12 UTF-16 units, `eventSourceUserData == DirectTyper.marker`, posted on `.cgAnnotatedSessionEventTap` from a private serial queue — never sleep on the main thread.

**Build and test commands.** The target cannot be built with a bare `xcodebuild`; use ad-hoc signing exactly as `make local` does.

Build:

```bash
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  -xcconfig LocalBuild.xcconfig \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" \
  CODE_SIGN_ENTITLEMENTS="$PWD/VoiceInk/VoiceInk.local.entitlements" \
  build 2>&1 | grep -E 'error:|warning: unre|BUILD (SUCCEEDED|FAILED)'
```

Test one suite (substitute the suite name):

```bash
xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  -destination 'platform=macOS' -xcconfig LocalBuild.xcconfig \
  -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" \
  CODE_SIGN_ENTITLEMENTS="$PWD/VoiceInk/VoiceInk.local.entitlements" \
  -only-testing:VoiceInkTests/<SuiteName> 2>&1 | grep -E '✔|✘|error:|TEST (SUCCEEDED|FAILED)'
```

Always scope with `-only-testing`. Known-red baseline unrelated to this plan: `RetranscribeInPlaceTests` crashes the test host. Do not run the whole target.

---

## File structure

| File | Responsibility |
|---|---|
| `VoiceInk/LayoutSwitcher/KeystrokeBuffer.swift` | `TypedKey`, `KeystrokeBuffer` — pure model of what was typed since the last reset |
| `VoiceInk/LayoutSwitcher/ShortWords.swift` | Frequent two-letter words (ru/en) — positive signal where the dictionary is unreliable |
| `VoiceInk/LayoutSwitcher/LayoutDetector.swift` | `SystemDictionary`, `LayoutVerdict`, `LayoutDetector` — pure decision, incl. trailing punctuation |
| `VoiceInk/LayoutSwitcher/LayoutPair.swift` | TIS: enabled layouts, IDs, names, language codes, current, select, pair resolution |
| `VoiceInk/LayoutSwitcher/LayoutMapper.swift` | `KeyChars`, key code ↔ character via `UCKeyTranslate`, character maps, text flip |
| `VoiceInk/LayoutSwitcher/SmartConvert.swift` | Per-word conversion of a selection (garbage flips, valid words stay) |
| `VoiceInk/LayoutSwitcher/LayoutSwitcherSettings.swift` | `UserDefaults`-backed `ObservableObject` |
| `VoiceInk/LayoutSwitcher/LayoutPolicy.swift` | Secure input, denied apps, never/always words |
| `VoiceInk/LayoutSwitcher/AntiResonanceGuard.swift` | Circuit breaker for A→B→A auto flips |
| `VoiceInk/LayoutSwitcher/DirectTyper.swift` | Backspace×N + Unicode typing, clipboard-free |
| `VoiceInk/LayoutSwitcher/KeystrokeTap.swift` | Listen-only `CGEventTap` |
| `VoiceInk/LayoutSwitcher/LayoutSwitcherEngine.swift` | Orchestration: auto path, manual trigger, undo, learning |
| `VoiceInk/Paste/FocusedTextAccessibility.swift` (modify) | `textBeforeCaret()`, `focusedRole()` |
| `VoiceInk/Views/LayoutSwitcher/LayoutSwitcherView.swift` | Settings UI + `StringListEditor` |
| `VoiceInk/Shortcuts/ShortcutAction.swift`, `ShortcutMigration.swift`, `ShortcutValidator.swift`, `RecordingShortcutManager.swift` (modify) | `.convertLayout` action |
| `VoiceInk/Services/BackupTypes.swift`, `BackupImporter.swift`, `ImportExportService.swift` (modify) | shortcut in backups |
| `VoiceInk/Views/ContentView.swift`, `VoiceInk/AppDelegate.swift` (modify) | sidebar item, engine start |
| `VoiceInk/Resources/Localizable.xcstrings` (modify) | ru strings |
| `THIRD_PARTY.md` (create) | MIT notices |

---

## Task 0: Restore the build prerequisite

`VoiceInk.xcodeproj` links `whisper.xcframework` from `$(HOME)/VoiceInk-Dependencies/whisper.cpp/build-apple/whisper.xcframework`; on 2026-09-17 that directory does not exist, so nothing compiles.

**Files:** none.

- [ ] **Step 1: Confirm the dependency is missing**

Run: `ls -d ~/VoiceInk-Dependencies/whisper.cpp/build-apple/whisper.xcframework`
Expected: `No such file or directory`. If it exists, skip to Step 3.

- [ ] **Step 2: Build the whisper XCFramework**

```bash
make whisper
```

Takes several minutes; needs `cmake`. On a missing tool run `make check`, install it (`brew install cmake`), re-run.

- [ ] **Step 3: Verify the toolchain**

Run the "Test one suite" command with `-only-testing:VoiceInkTests/KeyboardLayoutLanguageServiceTests`.
Expected: `** TEST SUCCEEDED **`. Nothing to commit.

---

## Task 1: KeystrokeBuffer

**Files:**
- Create: `VoiceInk/LayoutSwitcher/KeystrokeBuffer.swift`
- Test: `VoiceInkTests/KeystrokeBufferTests.swift`

**Interfaces:**
- Produces: `struct TypedKey: Equatable { let keyCode: UInt16; let shift: Bool; let caps: Bool }`, `struct KeystrokeBuffer` with `append(_:)`, `space() -> [TypedKey]?`, `backspace() -> Bool`, `reset()`, `currentWord`, `previousWord`, `boundaryCount`, `manualTarget: (keys: [TypedKey], trailingSpaces: Int)?`.

- [ ] **Step 1: Write the failing tests**

`VoiceInkTests/KeystrokeBufferTests.swift`:

```swift
import Testing
@testable import VoiceInk

struct KeystrokeBufferTests {
    private func key(_ code: UInt16) -> TypedKey { TypedKey(keyCode: code, shift: false, caps: false) }

    @Test func spaceCompletesCurrentWord() {
        var b = KeystrokeBuffer()
        b.append(key(5)); b.append(key(4))
        #expect(b.space() == [key(5), key(4)])
        #expect(b.currentWord.isEmpty)
        #expect(b.previousWord == [key(5), key(4)])
        #expect(b.boundaryCount == 1)
    }

    @Test func extraSpacesExtendTheBoundary() {
        var b = KeystrokeBuffer()
        b.append(key(5)); _ = b.space()
        #expect(b.space() == nil)
        #expect(b.boundaryCount == 2)
        #expect(b.manualTarget?.keys == [key(5)])
        #expect(b.manualTarget?.trailingSpaces == 2)
    }

    @Test func newLetterForgetsPreviousWord() {
        var b = KeystrokeBuffer()
        b.append(key(5)); _ = b.space(); b.append(key(4))
        #expect(b.previousWord.isEmpty)
        #expect(b.boundaryCount == 0)
        #expect(b.manualTarget?.keys == [key(4)])
        #expect(b.manualTarget?.trailingSpaces == 0)
    }

    @Test func backspaceInsideWordDropsLastKey() {
        var b = KeystrokeBuffer()
        b.append(key(5)); b.append(key(4))
        #expect(b.backspace())
        #expect(b.currentWord == [key(5)])
    }

    @Test func backspaceAcrossBoundaryResets() {
        var b = KeystrokeBuffer()
        b.append(key(5)); _ = b.space()
        #expect(!b.backspace())
        #expect(b.manualTarget == nil)
    }

    @Test func leadingSpacesAreNotABoundary() {
        var b = KeystrokeBuffer()
        #expect(b.space() == nil)
        #expect(b.boundaryCount == 0)
        #expect(b.manualTarget == nil)
    }
}
```

- [ ] **Step 2: Run the suite, expect a compile failure**

Run the test command with `-only-testing:VoiceInkTests/KeystrokeBufferTests`.
Expected: `error: cannot find 'KeystrokeBuffer' in scope`.

- [ ] **Step 3: Implement**

`VoiceInk/LayoutSwitcher/KeystrokeBuffer.swift`:

```swift
import Foundation

/// One physical key press, kept as a key code so the same word can be rendered in either
/// layout of the pair through UCKeyTranslate.
struct TypedKey: Equatable {
    let keyCode: UInt16
    let shift: Bool
    let caps: Bool
}

/// What the user typed since the last context reset. The engine feeds it from the event tap
/// and asks it for the last word; it never touches the screen itself.
struct KeystrokeBuffer: Equatable {
    private(set) var currentWord: [TypedKey] = []
    private(set) var previousWord: [TypedKey] = []
    /// Spaces typed after `previousWord`; 0 while `currentWord` is being typed.
    private(set) var boundaryCount = 0

    mutating func append(_ key: TypedKey) {
        currentWord.append(key)
        previousWord = []
        boundaryCount = 0
    }

    /// The word the space just completed, or nil when the space only widens an existing gap.
    mutating func space() -> [TypedKey]? {
        defer { currentWord = [] }
        guard !currentWord.isEmpty else {
            if !previousWord.isEmpty { boundaryCount += 1 }
            return nil
        }
        previousWord = currentWord
        boundaryCount = 1
        return currentWord
    }

    /// Backspace inside the current word drops its last key. Backspace across a word boundary
    /// makes the model unreliable, so it resets and returns false.
    @discardableResult
    mutating func backspace() -> Bool {
        guard !currentWord.isEmpty else {
            reset()
            return false
        }
        currentWord.removeLast()
        return true
    }

    mutating func reset() {
        currentWord = []
        previousWord = []
        boundaryCount = 0
    }

    /// What the manual trigger converts: the word being typed, else the last completed word
    /// together with the spaces after it (they are deleted and retyped as-is).
    var manualTarget: (keys: [TypedKey], trailingSpaces: Int)? {
        if !currentWord.isEmpty { return (currentWord, 0) }
        if !previousWord.isEmpty { return (previousWord, boundaryCount) }
        return nil
    }
}
```

- [ ] **Step 4: Run the suite, expect green**

Expected: 6 tests passed, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add VoiceInk/LayoutSwitcher/KeystrokeBuffer.swift VoiceInkTests/KeystrokeBufferTests.swift
git commit -m "feat(layout): keystroke buffer model"
```

---

## Task 2: ShortWords, SystemDictionary, LayoutDetector

**Files:**
- Create: `VoiceInk/LayoutSwitcher/ShortWords.swift`, `VoiceInk/LayoutSwitcher/LayoutDetector.swift`, `VoiceInk/LayoutSwitcher/LayoutMapper.swift` (only the `KeyChars` struct here; the rest of the mapper comes in Task 3)
- Test: `VoiceInkTests/LayoutDetectorTests.swift`

**Interfaces:**
- Produces: `struct KeyChars: Equatable { let original: Character; let converted: Character }`; `enum LayoutVerdict { case switchToConverted, keep, undecided }`; `enum SystemDictionary { @MainActor static func isAvailable(_ lang: String) -> Bool; @MainActor static func isValidWord(_ word: String, lang: String) -> Bool; @MainActor static func warmUp() }`; `enum ShortWords { static func common(_ lang: String) -> Set<String>? }`; `enum LayoutDetector { @MainActor static func decide(typed:converted:currentLang:otherLang:capsLock:alwaysConvert:) -> LayoutVerdict; @MainActor static func decideWord(pairs:currentLang:otherLang:capsLock:alwaysConvert:) -> (verdict: LayoutVerdict, convertedLength: Int); static func splitTrailingPunctuation(_:) -> (coreLength: Int, suffix: String); static func isAllCaps(_:) -> Bool; static func looksLikeCodeIdentifier(_:) -> Bool }`.

- [ ] **Step 1: Write the failing tests**

`VoiceInkTests/LayoutDetectorTests.swift`:

```swift
import Testing
@testable import VoiceInk

@MainActor
struct LayoutDetectorTests {
    /// Both dictionaries must exist on the machine; otherwise the dictionary tests are no-ops.
    private var dictionariesAvailable: Bool {
        SystemDictionary.isAvailable("ru") && SystemDictionary.isAvailable("en")
    }

    private func pairs(_ typed: String, _ converted: String) -> [KeyChars] {
        zip(typed, converted).map { KeyChars(original: $0, converted: $1) }
    }

    private func decide(_ typed: String, _ converted: String, cur: String = "en", oth: String = "ru",
                        caps: Bool = false, always: Set<String> = []) -> LayoutVerdict {
        LayoutDetector.decide(typed: typed, converted: converted, currentLang: cur, otherLang: oth,
                              capsLock: caps, alwaysConvert: always)
    }

    @Test func garbageThatIsARealWordInTheOtherLayoutConverts() {
        guard dictionariesAvailable else { return }
        #expect(decide("ghbdtn", "привет") == .switchToConverted)
        #expect(decide("привет", "ghbdtn", cur: "ru", oth: "en") == .keep)
    }

    @Test func realWordInCurrentLayoutIsKept() {
        guard dictionariesAvailable else { return }
        #expect(decide("hello", "руддщ") == .keep)
    }

    @Test func wordValidInBothLayoutsIsKept() {
        guard dictionariesAvailable else { return }
        // "vs" reads as «мы»; both are listed as frequent, so neither direction fires.
        #expect(decide("vs", "мы") == .keep)
    }

    @Test func digitsCodeAndAcronymsAreUndecided() {
        #expect(decide("gh1", "пр1") == .undecided)
        #expect(decide("ghbDtn", "привет") == .undecided)
        #expect(decide("GHBDTN", "ПРИВЕТ") == .undecided)
        #expect(decide("ghbвет", "привет") == .undecided)
    }

    @Test func capsLockDisablesTheCapsVetoes() {
        guard dictionariesAvailable else { return }
        #expect(decide("GHBDTN", "ПРИВЕТ", caps: true) == .switchToConverted)
    }

    @Test func singleLetterIsUndecided() {
        #expect(decide("z", "я") == .undecided)
    }

    @Test func twoLetterWordsUseTheFrequencyList() {
        #expect(decide("yt", "не") == .switchToConverted)
        #expect(decide("не", "yt", cur: "ru", oth: "en") == .switchToConverted)
        #expect(decide("qq", "йй") == .undecided)
        #expect(decide("to", "ещ") == .keep)
    }

    @Test func alwaysConvertOverridesEverything() {
        #expect(decide("GH1", "ПР1", always: ["пр1"]) == .switchToConverted)
    }

    @Test func splitsTrailingPunctuation() {
        #expect(LayoutDetector.splitTrailingPunctuation("ghbdtn,").coreLength == 6)
        #expect(LayoutDetector.splitTrailingPunctuation("ghbdtn,").suffix == ",")
        #expect(LayoutDetector.splitTrailingPunctuation("ghbdtn").suffix == "")
        #expect(LayoutDetector.splitTrailingPunctuation("a,b").suffix == "")
        #expect(LayoutDetector.splitTrailingPunctuation("x?!").suffix == "?!")
    }

    @Test func trailingCommaIsKeptLiteral() {
        guard dictionariesAvailable else { return }
        // ',' is «б» on ЙЦУКЕН: «приветб» is not a word, so only the core converts.
        let r = LayoutDetector.decideWord(pairs: pairs("ghbdtn,", "приветб"),
                                          currentLang: "en", otherLang: "ru", capsLock: false)
        #expect(r.verdict == .switchToConverted)
        #expect(r.convertedLength == 6)
    }

    @Test func ambiguousTrailingPeriodIsUndecided() {
        guard dictionariesAvailable else { return }
        // «levf.» is both «думаю» and «дума.» — leave it to the manual trigger.
        let r = LayoutDetector.decideWord(pairs: pairs("levf.", "думаю"),
                                          currentLang: "en", otherLang: "ru", capsLock: false)
        #expect(r.verdict == .undecided)
    }

    @Test func realWordWithTrailingPeriodIsKept() {
        guard dictionariesAvailable else { return }
        let r = LayoutDetector.decideWord(pairs: pairs("hello.", "руддщю"),
                                          currentLang: "en", otherLang: "ru", capsLock: false)
        #expect(r.verdict == .keep)
    }
}
```

- [ ] **Step 2: Run the suite, expect a compile failure**

`-only-testing:VoiceInkTests/LayoutDetectorTests` → `error: cannot find 'LayoutDetector' in scope`.

- [ ] **Step 3: Implement ShortWords**

`VoiceInk/LayoutSwitcher/ShortWords.swift` (port of RuSwitcher `ShortWords.swift`, MIT © Rashns):

```swift
import Foundation

/// Frequent two-letter words. NSSpellChecker accepts almost any two letters as a word, so at
/// this length conversion needs a positive signal: the converted form must be listed here and
/// the typed form must not be. Real English tokens whose ЙЦУКЕН image is a frequent Russian word
/// (vs→«мы», dj→«во», …) sit in both lists, which vetoes them in both directions.
/// Port of RuSwitcher ShortWords.swift (MIT, © Rashns).
enum ShortWords {
    private static let ru: Set<String> = [
        "не", "ты", "на", "он", "мы", "вы", "да", "но", "за", "бы", "же", "из",
        "ну", "по", "то", "от", "их", "ее", "её", "со", "ли", "ни", "об", "ей",
        "во", "им", "ко", "те", "та", "уж", "ок", "эй",
    ]
    private static let en: Set<String> = [
        "to", "it", "of", "is", "in", "we", "me", "he", "my", "on", "do", "no",
        "be", "so", "go", "if", "up", "at", "as", "an", "us", "or", "by", "am",
        "ok", "hi", "oh", "ah", "um", "mr", "ya",
        "vs", "dj", "kb", "jr", "bp", "ye", "ds",
    ]

    static func common(_ lang: String) -> Set<String>? {
        switch String(lang.prefix(2)) {
        case "ru": return ru
        case "en": return en
        default: return nil
        }
    }
}
```

- [ ] **Step 4: Add `KeyChars`**

`VoiceInk/LayoutSwitcher/LayoutMapper.swift` (Task 3 extends this file):

```swift
import Foundation

/// One typed key rendered in both layouts of the pair.
struct KeyChars: Equatable {
    let original: Character
    let converted: Character
}
```

- [ ] **Step 5: Implement SystemDictionary and LayoutDetector**

`VoiceInk/LayoutSwitcher/LayoutDetector.swift` (port of RuSwitcher `AutoSwitch.swift:7-177`, MIT © Rashns, without the Hebrew branch):

```swift
import AppKit

/// System-dictionary lookups through NSSpellChecker: local, no bundled data, ~0.1 ms per word.
/// The first call spins up the AppleSpell XPC service (hundreds of ms on main), hence `warmUp()`.
enum SystemDictionary {
    @MainActor private static let checker = NSSpellChecker.shared
    @MainActor private static var cachedLanguages: [String]?

    @MainActor static func isAvailable(_ lang: String) -> Bool {
        let two = String(lang.prefix(2))
        return languages().contains { String($0.prefix(2)) == two }
    }

    @MainActor static func isValidWord(_ word: String, lang: String) -> Bool {
        let range = checker.checkSpelling(of: word, startingAt: 0, language: lang,
                                          wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }

    @MainActor static func warmUp() {
        _ = languages()
        _ = isValidWord("test", lang: "en")
    }

    @MainActor private static func languages() -> [String] {
        if let cachedLanguages { return cachedLanguages }
        let langs = checker.availableLanguages
        cachedLanguages = langs
        return langs
    }
}

enum LayoutVerdict: Equatable {
    case switchToConverted, keep, undecided
}

/// Decides whether a word was typed in the wrong layout. Precision over recall: any doubt is
/// `.undecided` and nothing happens — the manual trigger still works.
/// Port of RuSwitcher AutoSwitch.swift (MIT, © Rashns) without the Hebrew branch.
enum LayoutDetector {
    @MainActor
    static func decide(typed: String, converted: String, currentLang: String, otherLang: String,
                       capsLock: Bool, alwaysConvert: Set<String> = []) -> LayoutVerdict {
        // always-convert matches the target form so a correctly typed word can't ping-pong.
        if alwaysConvert.contains(converted.lowercased()) { return .switchToConverted }
        guard typed.count >= 2 else { return .undecided }
        // ё/х/ъ/ж/э/б/ю live on punctuation keys, so `typed` may contain punctuation while
        // the conversion is all letters; the dictionary decides that case.
        guard typed.allSatisfy({ $0.isLetter }) || converted.allSatisfy({ $0.isLetter }) else {
            return .undecided
        }
        if !capsLock {
            if isAllCaps(typed) { return .undecided }
            if looksLikeCodeIdentifier(typed) { return .undecided }
        }

        let cur = String(currentLang.prefix(2))
        let oth = String(otherLang.prefix(2))

        if typed.count == 2 {
            guard let othShort = ShortWords.common(oth) else { return .undecided }
            if let curShort = ShortWords.common(cur), curShort.contains(typed.lowercased()) { return .keep }
            return othShort.contains(converted.lowercased()) ? .switchToConverted : .undecided
        }

        guard SystemDictionary.isAvailable(oth) else { return .undecided }
        guard SystemDictionary.isValidWord(converted.lowercased(), lang: oth) else { return .keep }
        if SystemDictionary.isAvailable(cur), SystemDictionary.isValidWord(typed.lowercased(), lang: cur) {
            return .keep
        }
        return .switchToConverted
    }

    /// Decision for a whole typed word including trailing punctuation («ghbdtn,» → «привет,»).
    /// `. , ; :` are letters on ЙЦУКЕН, so «levf.» reads both as «думаю» and as «дума.»; when
    /// both readings are real words the verdict is `.undecided`. `convertedLength` says how many
    /// leading pairs to convert; the rest is retyped literally.
    @MainActor
    static func decideWord(pairs: [KeyChars], currentLang: String, otherLang: String,
                           capsLock: Bool, alwaysConvert: Set<String> = []) -> (verdict: LayoutVerdict, convertedLength: Int) {
        let typed = String(pairs.map(\.original))
        let converted = String(pairs.map(\.converted))
        let (coreLength, suffix) = splitTrailingPunctuation(typed)
        guard !suffix.isEmpty, coreLength > 0 else {
            let v = decide(typed: typed, converted: converted, currentLang: currentLang,
                           otherLang: otherLang, capsLock: capsLock, alwaysConvert: alwaysConvert)
            return (v, pairs.count)
        }
        let core = String(pairs.prefix(coreLength).map(\.original))
        let convertedCore = String(pairs.prefix(coreLength).map(\.converted))
        let coreVerdict = decide(typed: core, converted: convertedCore, currentLang: currentLang,
                                 otherLang: otherLang, capsLock: capsLock, alwaysConvert: alwaysConvert)
        let oth = String(otherLang.prefix(2))
        let fullReading = converted.allSatisfy { $0.isLetter }
            && SystemDictionary.isAvailable(oth)
            && SystemDictionary.isValidWord(converted.lowercased(), lang: oth)
        guard fullReading else { return (coreVerdict, coreLength) }
        switch coreVerdict {
        case .switchToConverted:
            return (.undecided, pairs.count)
        case .keep:
            return (.keep, pairs.count)
        case .undecided:
            let v = decide(typed: typed, converted: converted, currentLang: currentLang,
                           otherLang: otherLang, capsLock: capsLock, alwaysConvert: alwaysConvert)
            return (v, pairs.count)
        }
    }

    /// Splits punctuation stuck to the end of a word. Digits, hyphen, @ and # are not split so
    /// URLs and code keep tripping the detector's vetoes; quotes are skipped because smart
    /// punctuation and dead-key layouts change them under our feet.
    static func splitTrailingPunctuation(_ s: String) -> (coreLength: Int, suffix: String) {
        let punct: Set<Character> = [",", ".", "!", "?", ";", ":", ")", "`", "[", "]"]
        var core = s[...]
        while let last = core.last, punct.contains(last) { core = core.dropLast() }
        return (core.count, String(s.dropFirst(core.count)))
    }

    static func isAllCaps(_ s: String) -> Bool {
        s == s.uppercased() && s != s.lowercased()
    }

    /// Inner capital (camelCase) or Latin and Cyrillic in one token — code, not a word.
    static func looksLikeCodeIdentifier(_ s: String) -> Bool {
        for (i, c) in s.enumerated() where i > 0 && c.isUppercase { return true }
        var hasLatin = false, hasCyrillic = false
        for u in s.unicodeScalars {
            switch u.value {
            case 0x41...0x5A, 0x61...0x7A: hasLatin = true
            case 0x0400...0x04FF: hasCyrillic = true
            default: break
            }
        }
        return hasLatin && hasCyrillic
    }
}
```

- [ ] **Step 6: Run the suite, expect green**

Expected: 12 tests passed. If `twoLetterWordsUseTheFrequencyList` fails on `decide("to", "ещ")`, the machine's spell checker is not involved (2-letter path) — re-check the ShortWords lists were copied exactly.

- [ ] **Step 7: Commit**

```bash
git add VoiceInk/LayoutSwitcher/ShortWords.swift VoiceInk/LayoutSwitcher/LayoutDetector.swift VoiceInk/LayoutSwitcher/LayoutMapper.swift VoiceInkTests/LayoutDetectorTests.swift
git commit -m "feat(layout): dictionary-based wrong-layout detector"
```

---

## Task 3: LayoutPair and LayoutMapper

**Files:**
- Create: `VoiceInk/LayoutSwitcher/LayoutPair.swift`
- Modify: `VoiceInk/LayoutSwitcher/LayoutMapper.swift`
- Test: `VoiceInkTests/LayoutMapperTests.swift`

**Interfaces:**
- Consumes: `TypedKey`, `KeyChars`.
- Produces:
  - `enum LayoutPair` — `struct Resolved { current, other: TISInputSource; currentLang, otherLang: String; currentData, otherData: Data }`; `static func enabledLayouts() -> [TISInputSource]`; `static func allLayouts() -> [TISInputSource]`; `static func sourceID(_:) -> String`; `static func localizedName(_:) -> String`; `static func languageCode(_:) -> String?`; `static func layoutData(_:) -> Data?`; `@MainActor static func current() -> TISInputSource?`; `static func select(_:)`; `static func autoDetectIDs(from:) -> (String, String)?`; `@MainActor static func resolve(layout1ID:layout2ID:) -> Resolved?`.
  - `enum LayoutMapper` — `static let typeableKeyCodes: ClosedRange<UInt16>`; `static func character(keyCode:layout:shift:caps:) -> Character?`; `static func isDeadKey(keyCode:layout:shift:caps:) -> Bool`; `static func convert(_ keys: [TypedKey], from: Data, to: Data) -> [KeyChars]?`; `static func characterMap(from:to:) -> [Character: Character]`; `static func bidirectionalMap(_:_:) -> [Character: Character]`; `static func convertText(_:map:) -> String`.

- [ ] **Step 1: Write the failing tests**

`VoiceInkTests/LayoutMapperTests.swift`:

```swift
import Testing
@testable import VoiceInk

/// Runs only where the U.S. (or ABC) and Russian layouts are installed (enabled or not).
enum TestLayouts {
    static func usAndRussian() -> (us: Data, ru: Data)? {
        let all = LayoutPair.allLayouts()
        let us = all.first { ["com.apple.keylayout.US", "com.apple.keylayout.ABC"].contains(LayoutPair.sourceID($0)) }
        let ru = all.first { LayoutPair.sourceID($0) == "com.apple.keylayout.Russian" }
        guard let us, let ru, let usData = LayoutPair.layoutData(us), let ruData = LayoutPair.layoutData(ru) else { return nil }
        return (usData, ruData)
    }
}

struct LayoutMapperTests {
    // g h b d t n on ANSI: kVK_ANSI_G … kVK_ANSI_N
    private let ghbdtn: [TypedKey] = [5, 4, 11, 2, 17, 45].map { TypedKey(keyCode: $0, shift: false, caps: false) }

    @Test func rendersTheSameKeysInBothLayouts() {
        guard let l = TestLayouts.usAndRussian() else { return }
        let pairs = LayoutMapper.convert(ghbdtn, from: l.us, to: l.ru)
        #expect(pairs.map { String($0.map(\.original)) } == "ghbdtn")
        #expect(pairs.map { String($0.map(\.converted)) } == "привет")
    }

    @Test func shiftAndCapsProduceUppercase() {
        guard let l = TestLayouts.usAndRussian() else { return }
        #expect(LayoutMapper.character(keyCode: 5, layout: l.us, shift: true, caps: false) == "G")
        #expect(LayoutMapper.character(keyCode: 5, layout: l.ru, shift: false, caps: true) == "П")
    }

    @Test func punctuationKeysBecomeLetters() {
        guard let l = TestLayouts.usAndRussian() else { return }
        // ';' is «ж», ',' is «б»
        #expect(LayoutMapper.character(keyCode: 41, layout: l.ru, shift: false, caps: false) == "ж")
        #expect(LayoutMapper.character(keyCode: 43, layout: l.ru, shift: false, caps: false) == "б")
    }

    @Test func characterMapFlipsText() {
        guard let l = TestLayouts.usAndRussian() else { return }
        let map = LayoutMapper.bidirectionalMap(l.us, l.ru)
        #expect(LayoutMapper.convertText("ghbdtn vbh", map: map) == "привет мир")
        #expect(LayoutMapper.convertText("руддщ", map: map) == "hello")
    }

    @Test func combiningMarksAreLeftAlone() {
        guard let l = TestLayouts.usAndRussian() else { return }
        let map = LayoutMapper.bidirectionalMap(l.us, l.ru)
        let withMark = "a\u{0301}b"
        #expect(LayoutMapper.convertText(withMark, map: map) == withMark)
    }

    @Test func autoDetectPicksLatinFirst() {
        let all = LayoutPair.allLayouts()
        guard let ids = LayoutPair.autoDetectIDs(from: all) else { return }
        #expect(ids.0 != ids.1)
        let first = all.first { LayoutPair.sourceID($0) == ids.0 }
        #expect(first.flatMap(LayoutPair.languageCode) == "en")
    }
}
```

- [ ] **Step 2: Run the suite, expect a compile failure**

`-only-testing:VoiceInkTests/LayoutMapperTests` → `error: cannot find 'LayoutPair' in scope`.

- [ ] **Step 3: Implement LayoutPair**

`VoiceInk/LayoutSwitcher/LayoutPair.swift` (port of RuSwitcher `LayoutSwitcher.swift`, MIT © Rashns, without caching):

```swift
import Carbon

/// The two keyboard layouts the switcher converts between. TIS calls that read the current
/// source are main-thread-only (see KeyboardLayoutLanguageService), hence the @MainActor marks.
/// Port of RuSwitcher LayoutSwitcher.swift (MIT, © Rashns).
enum LayoutPair {
    struct Resolved {
        let current: TISInputSource
        let other: TISInputSource
        let currentLang: String
        let otherLang: String
        let currentData: Data
        let otherData: Data
    }

    /// Enabled keyboard layouts (input methods like Japanese/Chinese are excluded: nothing to convert).
    static func enabledLayouts() -> [TISInputSource] {
        list(includeAllInstalled: false)
    }

    /// Every installed layout, enabled or not. Tests use it so they don't depend on the user's set.
    static func allLayouts() -> [TISInputSource] {
        list(includeAllInstalled: true)
    }

    private static func list(includeAllInstalled: Bool) -> [TISInputSource] {
        let conditions: CFDictionary = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as Any,
        ] as CFDictionary
        return TISCreateInputSourceList(conditions, includeAllInstalled)?.takeRetainedValue() as? [TISInputSource] ?? []
    }

    static func sourceID(_ source: TISInputSource) -> String {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    static func localizedName(_ source: TISInputSource) -> String {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return sourceID(source) }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    static func layoutData(_ source: TISInputSource) -> Data? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    }

    /// BCP-47 language of a layout. Third-party `.keylayout` files often declare no language
    /// (macOS then returns "" first), so fall back to the script of what the home row types.
    static func languageCode(_ source: TISInputSource) -> String? {
        if let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
           let langs = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String],
           let first = langs.first, !first.isEmpty {
            return first
        }
        guard let data = layoutData(source) else { return nil }
        for keyCode: UInt16 in [0, 1, 2, 3, 38, 40, 37] {
            guard let scalar = LayoutMapper.character(keyCode: keyCode, layout: data, shift: false, caps: false)?
                .unicodeScalars.first, scalar.properties.isAlphabetic else { continue }
            switch scalar.value {
            case 0x0400...0x04FF: return "ru"
            case 0x0041...0x005A, 0x0061...0x007A: return "en"
            case 0x0370...0x03FF: return "el"
            case 0x0530...0x058F: return "hy"
            case 0x10A0...0x10FF: return "ka"
            default: continue
            }
        }
        return nil
    }

    @MainActor
    static func current() -> TISInputSource? {
        TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }

    /// Enable only when actually disabled: enabling an already-enabled third-party layout
    /// triggers a system security prompt on every switch.
    static func select(_ source: TISInputSource) {
        if let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled),
           Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue() != kCFBooleanTrue {
            TISEnableInputSource(source)
        }
        TISSelectInputSource(source)
    }

    /// The Latin layout and the first other one. nil when fewer than two layouts are available.
    static func autoDetectIDs(from layouts: [TISInputSource]) -> (String, String)? {
        let first = layouts.first { languageCode($0) == "en" }
            ?? layouts.first { ["ABC", "US", "British"].contains { sourceID($0).contains($1) } }
            ?? layouts.first
        guard let first else { return nil }
        let firstID = sourceID(first)
        guard let second = layouts.first(where: { sourceID($0) != firstID }) else { return nil }
        return (firstID, sourceID(second))
    }

    /// nil when the current layout is not one of the pair — then nothing is converted.
    @MainActor
    static func resolve(layout1ID: String, layout2ID: String) -> Resolved? {
        let layouts = enabledLayouts()
        var id1 = layout1ID, id2 = layout2ID
        if id1.isEmpty || id2.isEmpty {
            guard let auto = autoDetectIDs(from: layouts) else { return nil }
            if id1.isEmpty { id1 = auto.0 == id2 ? auto.1 : auto.0 }
            if id2.isEmpty { id2 = auto.1 == id1 ? auto.0 : auto.1 }
        }
        guard let current = current() else { return nil }
        let currentID = sourceID(current)
        let otherID: String
        if currentID == id1 { otherID = id2 } else if currentID == id2 { otherID = id1 } else { return nil }
        guard let other = layouts.first(where: { sourceID($0) == otherID }),
              let currentLang = languageCode(current), let otherLang = languageCode(other),
              let currentData = layoutData(current), let otherData = layoutData(other) else { return nil }
        return Resolved(current: current, other: other, currentLang: currentLang, otherLang: otherLang,
                        currentData: currentData, otherData: otherData)
    }
}
```

- [ ] **Step 4: Implement LayoutMapper**

Replace `VoiceInk/LayoutSwitcher/LayoutMapper.swift` with (port of RuSwitcher `DynamicKeyMapping.swift`, MIT © Rashns):

```swift
import Carbon

/// One typed key rendered in both layouts of the pair.
struct KeyChars: Equatable {
    let original: Character
    let converted: Character
}

/// Key code → character in a given layout through UCKeyTranslate. Pure over the layout's
/// `uchr` data, so it can be tested against any installed layout.
/// Port of RuSwitcher DynamicKeyMapping.swift (MIT, © Rashns).
enum LayoutMapper {
    /// Main key block (letters, digits, punctuation). Space/Return/Tab are inside this range;
    /// the engine handles them before asking the mapper.
    static let typeableKeyCodes: ClosedRange<UInt16> = 0...50

    static func character(keyCode: UInt16, layout: Data, shift: Bool, caps: Bool) -> Character? {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layout.withUnsafeBytes { raw -> OSStatus in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(ptr, keyCode, UInt16(kUCKeyActionDown), modifiers(shift: shift, caps: caps),
                                  UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysMask),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        guard s.count == 1, let c = s.first, c.isLetter || c.isNumber || c.isPunctuation || c.isSymbol else { return nil }
        return c
    }

    /// Dead key: UCKeyTranslate with dead keys enabled returns no character and a pending state.
    /// A word containing one has more keys than screen characters, so it is never converted.
    static func isDeadKey(keyCode: UInt16, layout: Data, shift: Bool, caps: Bool) -> Bool {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layout.withUnsafeBytes { raw -> OSStatus in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(ptr, keyCode, UInt16(kUCKeyActionDown), modifiers(shift: shift, caps: caps),
                                  UInt32(LMGetKbdType()), 0, &deadKeyState, chars.count, &length, &chars)
        }
        return status == noErr && length == 0 && deadKeyState != 0
    }

    /// Per-key characters in both layouts; nil when a key has no character in either layout or
    /// is a dead key in the source layout.
    static func convert(_ keys: [TypedKey], from source: Data, to target: Data) -> [KeyChars]? {
        var out: [KeyChars] = []
        out.reserveCapacity(keys.count)
        for k in keys {
            if isDeadKey(keyCode: k.keyCode, layout: source, shift: k.shift, caps: k.caps) { return nil }
            guard let o = character(keyCode: k.keyCode, layout: source, shift: k.shift, caps: k.caps),
                  let c = character(keyCode: k.keyCode, layout: target, shift: k.shift, caps: k.caps) else { return nil }
            out.append(KeyChars(original: o, converted: c))
        }
        return out
    }

    /// source→target over the main block. Unshifted first: on layouts without case the shifted
    /// character equals the plain one and must not overwrite the lowercase mapping.
    static func characterMap(from source: Data, to target: Data) -> [Character: Character] {
        var map: [Character: Character] = [:]
        for keyCode in typeableKeyCodes {
            for shift in [false, true] {
                guard let s = character(keyCode: keyCode, layout: source, shift: shift, caps: false),
                      let t = character(keyCode: keyCode, layout: target, shift: shift, caps: false),
                      s != t, map[s] == nil else { continue }
                map[s] = t
            }
        }
        return map
    }

    /// Both directions merged. On shared punctuation keys («.» is «ю» one way and «/» the other)
    /// a letter wins: flipping script matters more than flipping a symbol.
    static func bidirectionalMap(_ a: Data, _ b: Data) -> [Character: Character] {
        var map = characterMap(from: a, to: b)
        for (k, v) in characterMap(from: b, to: a) {
            if let existing = map[k] {
                if !existing.isLetter && v.isLetter { map[k] = v }
            } else {
                map[k] = v
            }
        }
        return map
    }

    /// Flips every mapped character. Decomposed input is precomposed first; text with combining
    /// marks is returned untouched — a half-converted mix is worse than nothing.
    static func convertText(_ input: String, map: [Character: Character]) -> String {
        let text = input.precomposedStringWithCanonicalMapping
        if text.unicodeScalars.contains(where: { $0.properties.generalCategory == .nonspacingMark }) { return input }
        return String(text.map { map[$0] ?? $0 })
    }

    private static func modifiers(shift: Bool, caps: Bool) -> UInt32 {
        var mods: UInt32 = shift ? (UInt32(shiftKey >> 8) & 0xFF) : 0
        if caps { mods |= UInt32(alphaLock >> 8) & 0xFF }
        return mods
    }
}
```

- [ ] **Step 5: Run the suite, expect green**

Expected: 6 tests passed. If `combiningMarksAreLeftAlone` fails, check `precomposedStringWithCanonicalMapping` turned `a\u{0301}` into `á` — then the guard must run on the *input*, not the precomposed text; fix by checking `input` too.

- [ ] **Step 6: Commit**

```bash
git add VoiceInk/LayoutSwitcher/LayoutPair.swift VoiceInk/LayoutSwitcher/LayoutMapper.swift VoiceInkTests/LayoutMapperTests.swift
git commit -m "feat(layout): TIS layout pair and UCKeyTranslate mapper"
```

---

## Task 4: SmartConvert (selection)

**Files:**
- Create: `VoiceInk/LayoutSwitcher/SmartConvert.swift`
- Test: `VoiceInkTests/SmartConvertTests.swift`

**Interfaces:**
- Consumes: `SystemDictionary`, `ShortWords`, `LayoutDetector.isAllCaps/looksLikeCodeIdentifier`, `LayoutMapper.convertText(_:map:)`.
- Produces: `enum SmartConvert { @MainActor static func selection(_ text: String, latLang: String, cyrLang: String, map: [Character: Character]) -> String; static func isCyrillicLang(_:) -> Bool; static func isLatinLang(_:) -> Bool }`.

- [ ] **Step 1: Write the failing tests**

`VoiceInkTests/SmartConvertTests.swift`:

```swift
import Testing
@testable import VoiceInk

@MainActor
struct SmartConvertTests {
    private func run(_ text: String) -> String? {
        guard let l = TestLayouts.usAndRussian(),
              SystemDictionary.isAvailable("ru"), SystemDictionary.isAvailable("en") else { return nil }
        let map = LayoutMapper.bidirectionalMap(l.us, l.ru)
        return SmartConvert.selection(text, latLang: "en", cyrLang: "ru", map: map)
    }

    @Test func flipsGarbageAndKeepsValidWords() {
        guard let out = run("iPhone ghbdtn") else { return }
        #expect(out == "iPhone привет")
    }

    @Test func flipsBothDirectionsInMixedGarbage() {
        guard let out = run("ghbdtn ьшк") else { return }
        #expect(out == "привет мир")
    }

    @Test func pullsShortWordsInTheDirectionOfTheirNeighbours() {
        guard let out = run("z yt vjue") else { return }
        #expect(out == "я не могу")
    }

    @Test func scientificSingleLetterStaysWhenNeighboursAreValid() {
        guard let out = run("vitamin c") else { return }
        #expect(out == "vitamin c")
    }

    @Test func keepsTrailingPunctuationLiteral() {
        guard let out = run("ghbdtn,") else { return }
        #expect(out == "привет,")
    }

    @Test func languageClassification() {
        #expect(SmartConvert.isCyrillicLang("ru-RU"))
        #expect(SmartConvert.isLatinLang("en"))
        #expect(!SmartConvert.isLatinLang("he"))
    }
}
```

- [ ] **Step 2: Run the suite, expect a compile failure**

`-only-testing:VoiceInkTests/SmartConvertTests` → `error: cannot find 'SmartConvert' in scope`.

- [ ] **Step 3: Implement**

`VoiceInk/LayoutSwitcher/SmartConvert.swift` (port of RuSwitcher `SmartConvert.swift`, MIT © Rashns):

```swift
import Foundation

/// Per-word conversion of a selection between a Latin-script and a Cyrillic-script layout: a
/// word flips only when it is garbage in its own script and a real word after the flip, so
/// «iPhone стоит» survives while «ghbdtn ьшк» is fixed in both directions. Unresolved short
/// tokens follow the direction their neighbours flipped in.
/// Port of RuSwitcher SmartConvert.swift (MIT, © Rashns).
enum SmartConvert {
    private enum Script { case cyr, lat, other, mixed }
    private enum WordDecision { case keep, flip(String, Script), unresolved }

    private static let cyr1: Set<Character> = ["я", "в", "с", "к", "о", "у", "а", "и"]
    private static let lat1: Set<Character> = ["a", "i"]

    @MainActor
    static func selection(_ text: String, latLang: String, cyrLang: String, map: [Character: Character]) -> String {
        let toks = tokenize(text)
        var results = [String?](repeating: nil, count: toks.count)
        var pending: [Int] = []
        var flippedCyr = 0, flippedLat = 0

        for (i, tok) in toks.enumerated() {
            guard tok.isWord else { results[i] = tok.str; continue }
            switch decideWord(tok.str, latLang: latLang, cyrLang: cyrLang, map: map) {
            case .keep:
                results[i] = tok.str
            case let .flip(s, toScript):
                results[i] = s
                if toScript == .cyr { flippedCyr += 1 } else if toScript == .lat { flippedLat += 1 }
            case .unresolved:
                pending.append(i)
            }
        }

        // Signal = direction of the words that actually flipped. Both directions or none ⇒ no signal.
        let target: Script? = (flippedCyr > 0 && flippedLat == 0) ? .cyr
            : (flippedLat > 0 && flippedCyr == 0) ? .lat : nil
        for i in pending { results[i] = signalFlip(toks[i].str, target: target, map: map) }
        return results.map { $0 ?? "" }.joined()
    }

    @MainActor
    private static func decideWord(_ w: String, latLang: String, cyrLang: String, map: [Character: Character]) -> WordDecision {
        let core = letterCore(w)
        let script = dominantScript(core)
        guard core.count >= 1, script == .cyr || script == .lat else { return .keep }
        if LayoutDetector.isAllCaps(core) || LayoutDetector.looksLikeCodeIdentifier(core) { return .keep }

        let wordLang = (script == .cyr) ? cyrLang : latLang
        let flipLang = (script == .cyr) ? latLang : cyrLang
        let flippedScript: Script = (script == .cyr) ? .lat : .cyr

        if core.count == 1 { return .unresolved }
        if core.count == 2 {
            if let cur = ShortWords.common(wordLang), cur.contains(core.lowercased()) { return .keep }
            let whole = LayoutMapper.convertText(w, map: map)
            let wc = letterCore(whole)
            if wc.count == 2, let oth = ShortWords.common(flipLang), oth.contains(wc.lowercased()) {
                return .flip(whole, flippedScript)
            }
            return .unresolved
        }

        if SystemDictionary.isValidWord(core.lowercased(), lang: wordLang) { return .keep }
        let whole = LayoutMapper.convertText(w, map: map)
        let wc = letterCore(whole)
        if wc.count >= 2, wc.allSatisfy({ $0.isLetter }), SystemDictionary.isValidWord(wc.lowercased(), lang: flipLang) {
            return .flip(whole, flippedScript)
        }
        let (body, suffix) = splitTrailingNonLetters(w)
        if !suffix.isEmpty, !body.isEmpty {
            let bflip = LayoutMapper.convertText(body, map: map)
            let bc = letterCore(bflip)
            if bc.count >= 2, bc.allSatisfy({ $0.isLetter }), SystemDictionary.isValidWord(bc.lowercased(), lang: flipLang) {
                return .flip(bflip + suffix, flippedScript)
            }
        }
        return .unresolved
    }

    /// Only 1–2 letter tokens follow the signal: longer unresolved words are brands/terms the
    /// dictionary didn't confirm, not garbage. Single letters must also be frequent words.
    private static func signalFlip(_ orig: String, target: Script?, map: [Character: Character]) -> String {
        guard let target else { return orig }
        var lead = "", trail = ""
        var chars = Array(orig)
        while let f = chars.first, !f.isLetter { lead.append(f); chars.removeFirst() }
        while let l = chars.last, !l.isLetter { trail = String(l) + trail; chars.removeLast() }
        let core = String(chars)
        guard !core.isEmpty, core.count <= 2, dominantScript(core) != target else { return orig }
        let flipped = LayoutMapper.convertText(core, map: map)
        if core.count == 1 {
            guard let fch = letterCore(flipped).first,
                  (target == .cyr ? cyr1 : lat1).contains(Character(fch.lowercased())) else { return orig }
        }
        return lead + flipped + trail
    }

    private static let cyrillicLangs: Set<String> = ["ru", "uk", "be", "bg", "sr", "mk", "kk", "ky", "mn", "tg"]
    private static let nonLatinLangs: Set<String> = ["he", "iw", "el", "hy", "ka", "ar", "fa", "yi"]

    static func isCyrillicLang(_ lang: String) -> Bool {
        cyrillicLangs.contains(String(lang.lowercased().prefix(2)))
    }

    static func isLatinLang(_ lang: String) -> Bool {
        let two = String(lang.lowercased().prefix(2))
        return !cyrillicLangs.contains(two) && !nonLatinLangs.contains(two)
    }

    private static func dominantScript(_ s: String) -> Script {
        var cyr = 0, lat = 0
        for u in s.unicodeScalars {
            if u.value >= 0x0400 && u.value <= 0x04FF { cyr += 1 }
            else if (u.value >= 0x41 && u.value <= 0x5A) || (u.value >= 0x61 && u.value <= 0x7A) { lat += 1 }
        }
        if cyr > 0 && lat > 0 { return .mixed }
        if cyr > 0 { return .cyr }
        if lat > 0 { return .lat }
        return .other
    }

    private static func letterCore(_ s: String) -> String {
        var chars = Array(s)
        while let f = chars.first, !f.isLetter { chars.removeFirst() }
        while let l = chars.last, !l.isLetter { chars.removeLast() }
        return String(chars)
    }

    private static func splitTrailingNonLetters(_ s: String) -> (body: String, suffix: String) {
        var body = Array(s); var suffix = ""
        while let l = body.last, !l.isLetter { suffix = String(l) + suffix; body.removeLast() }
        return (String(body), suffix)
    }

    /// Alternating word / whitespace runs; joining them back gives the input unchanged.
    private static func tokenize(_ s: String) -> [(isWord: Bool, str: String)] {
        var out: [(Bool, String)] = []
        var cur = ""
        var curWS: Bool?
        for ch in s {
            let ws = ch.isWhitespace
            if let w = curWS {
                if ws == w { cur.append(ch) } else { out.append((!w, cur)); cur = String(ch); curWS = ws }
            } else {
                curWS = ws; cur = String(ch)
            }
        }
        if let w = curWS, !cur.isEmpty { out.append((!w, cur)) }
        return out
    }
}
```

- [ ] **Step 4: Run the suite, expect green**

Expected: 6 tests passed.

- [ ] **Step 5: Commit**

```bash
git add VoiceInk/LayoutSwitcher/SmartConvert.swift VoiceInkTests/SmartConvertTests.swift
git commit -m "feat(layout): per-word smart conversion of selections"
```

---

## Task 5: Settings and policy

**Files:**
- Create: `VoiceInk/LayoutSwitcher/LayoutSwitcherSettings.swift`, `VoiceInk/LayoutSwitcher/LayoutPolicy.swift`
- Test: `VoiceInkTests/LayoutPolicyTests.swift`

**Interfaces:**
- Produces: `final class LayoutSwitcherSettings: ObservableObject` (`static let shared`, `init(defaults:)`, `@Published enabled, autoConvert: Bool`, `layout1ID, layout2ID: String`, `deniedApps, neverWords, alwaysWords: [String]`, `neverWordsSet, alwaysWordsSet: Set<String>`); `enum LayoutPolicy` (`defaultDeniedApps: [String]`, `protectedApps: Set<String>`, `isDeniedApp(_:deniedApps:) -> Bool`, `secureInputActive: Bool`, `isNeverWord(_:_:never:) -> Bool`).

- [ ] **Step 1: Write the failing tests**

`VoiceInkTests/LayoutPolicyTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the suite, expect a compile failure**

`-only-testing:VoiceInkTests/LayoutPolicyTests` → `error: cannot find 'LayoutPolicy' in scope`.

- [ ] **Step 3: Implement LayoutPolicy**

`VoiceInk/LayoutSwitcher/LayoutPolicy.swift` (denied-app defaults from RuSwitcher `AutoSwitch.swift:217-231`, MIT © Rashns):

```swift
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

    static func isNeverWord(_ typed: String, _ converted: String, never: Set<String>) -> Bool {
        guard !never.isEmpty else { return false }
        return never.contains(typed.lowercased()) || never.contains(converted.lowercased())
    }
}
```

- [ ] **Step 4: Implement LayoutSwitcherSettings**

`VoiceInk/LayoutSwitcher/LayoutSwitcherSettings.swift`:

```swift
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
```

- [ ] **Step 5: Run the suite, expect green**

Expected: 4 tests passed.

- [ ] **Step 6: Commit**

```bash
git add VoiceInk/LayoutSwitcher/LayoutPolicy.swift VoiceInk/LayoutSwitcher/LayoutSwitcherSettings.swift VoiceInkTests/LayoutPolicyTests.swift
git commit -m "feat(layout): settings store and safety policy"
```

---

## Task 6: AntiResonanceGuard

**Files:**
- Create: `VoiceInk/LayoutSwitcher/AntiResonanceGuard.swift`
- Test: `VoiceInkTests/AntiResonanceGuardTests.swift`

**Interfaces:**
- Produces: `final class AntiResonanceGuard { init(window: TimeInterval = 0.7, maxFlips: Int = 6, freezeFor: TimeInterval = 2.5); var clock: () -> TimeInterval; func allow(word: String, produced: String) -> Bool; var isFrozen: Bool; func resetHistory() }`.

- [ ] **Step 1: Write the failing tests**

`VoiceInkTests/AntiResonanceGuardTests.swift`:

```swift
import Testing
@testable import VoiceInk

struct AntiResonanceGuardTests {
    @Test func normalTypingIsAllowed() {
        let g = AntiResonanceGuard()
        var now = 0.0
        g.clock = { now }
        #expect(g.allow(word: "ghbdtn", produced: "привет"))
        now += 1
        #expect(g.allow(word: "vbh", produced: "мир"))
    }

    @Test func oscillationFreezes() {
        let g = AntiResonanceGuard()
        var now = 0.0
        g.clock = { now }
        #expect(g.allow(word: "ghbdtn", produced: "привет"))
        now += 0.1
        #expect(!g.allow(word: "привет", produced: "ghbdtn"))
        #expect(g.isFrozen)
        now += 0.1
        #expect(!g.allow(word: "vbh", produced: "мир"))
        now += 3
        #expect(!g.isFrozen)
        #expect(g.allow(word: "vbh", produced: "мир"))
    }

    @Test func stormFreezes() {
        let g = AntiResonanceGuard(window: 1, maxFlips: 3, freezeFor: 5)
        var now = 0.0
        g.clock = { now }
        for i in 0..<3 {
            #expect(g.allow(word: "w\(i)", produced: "p\(i)"))
            now += 0.1
        }
        #expect(!g.allow(word: "w9", produced: "p9"))
    }
}
```

- [ ] **Step 2: Run the suite, expect a compile failure**

`-only-testing:VoiceInkTests/AntiResonanceGuardTests` → `error: cannot find 'AntiResonanceGuard' in scope`.

- [ ] **Step 3: Implement**

`VoiceInk/LayoutSwitcher/AntiResonanceGuard.swift` (port of keyboop `AntiResonanceGuard.swift`, MIT © Keyboop contributors):

```swift
import Foundation
import os

/// Circuit breaker against A→B→A auto flips: if one synthetic event ever leaks back into the
/// buffer, the detector would re-convert its own output in a µs-paced loop. Applies to the
/// auto path only; the manual trigger is the user's decision.
/// Port of keyboop AntiResonanceGuard.swift (MIT, © Keyboop contributors).
final class AntiResonanceGuard {
    private let window: TimeInterval
    private let maxFlips: Int
    private let freezeFor: TimeInterval
    private var recent: [(produced: String, at: TimeInterval)] = []
    private var frozenUntil: TimeInterval = 0
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AntiResonanceGuard")

    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    init(window: TimeInterval = 0.7, maxFlips: Int = 6, freezeFor: TimeInterval = 2.5) {
        self.window = window
        self.maxFlips = maxFlips
        self.freezeFor = freezeFor
    }

    /// Ask before an auto-conversion `word` → `produced`. false ⇒ skip it and reset the buffer.
    func allow(word: String, produced: String) -> Bool {
        let now = clock()
        if now < frozenUntil { return false }
        recent.removeAll { now - $0.at > window }
        let oscillation = recent.contains { $0.produced == word }
        recent.append((produced: produced, at: now))
        if oscillation || recent.count > maxFlips {
            frozenUntil = now + freezeFor
            recent.removeAll()
            logger.notice("auto-conversion frozen for \(self.freezeFor, privacy: .public)s (\(oscillation ? "oscillation" : "storm", privacy: .public))")
            return false
        }
        return true
    }

    var isFrozen: Bool { clock() < frozenUntil }

    func resetHistory() { recent.removeAll() }
}
```

- [ ] **Step 4: Run the suite, expect green**

Expected: 3 tests passed.

- [ ] **Step 5: Commit**

```bash
git add VoiceInk/LayoutSwitcher/AntiResonanceGuard.swift VoiceInkTests/AntiResonanceGuardTests.swift
git commit -m "feat(layout): anti-resonance guard for auto conversion"
```

---

## Task 7: DirectTyper, KeystrokeTap, Accessibility helpers

No unit tests: these post and read real system events. The check is the build plus the manual acceptance in Task 11.

**Files:**
- Create: `VoiceInk/LayoutSwitcher/DirectTyper.swift`, `VoiceInk/LayoutSwitcher/KeystrokeTap.swift`
- Modify: `VoiceInk/Paste/FocusedTextAccessibility.swift`

**Interfaces:**
- Produces: `enum DirectTyper { static let marker: Int64; static func replace(deleteCount: Int, with text: String, completion: @escaping () -> Void); static func type(_ text: String, completion: @escaping () -> Void) }` (completion is delivered on the main actor); `final class KeystrokeTap { enum Event { case keyDown(keyCode: UInt16, flags: CGEventFlags), mouseDown }; init(handler: @escaping (Event) -> Void); @discardableResult func start() -> Bool; func stop() }`; `FocusedTextAccessibility.textBeforeCaret() -> String?`, `FocusedTextAccessibility.focusedRole() -> String?` (both `@MainActor`).

- [ ] **Step 1: DirectTyper**

`VoiceInk/LayoutSwitcher/DirectTyper.swift` (posting location and chunking from keyboop `TextReplacer.swift`, MIT © Keyboop contributors):

```swift
import CoreGraphics
import Foundation

/// Clipboard-free replacement: synthetic Backspaces, then the text as Unicode key events.
/// Posted on `.cgAnnotatedSessionEventTap` — below every session-level tap, ours included —
/// so no other layout switcher (or our own monitors) sees them. The µs pauses run on a private
/// serial queue: the main thread hosts active event taps and must never sleep.
enum DirectTyper {
    /// `eventSourceUserData` on every event we post; KeystrokeTap drops events carrying it.
    static let marker: Int64 = 0x564B_4C53

    private static let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.layout-typer", qos: .userInteractive)
    private static let backspace: CGKeyCode = 51
    /// A CGEvent carries ~20 UTF-16 units; 12 leaves headroom for surrogate pairs.
    private static let chunkSize = 12

    static func replace(deleteCount: Int, with text: String, completion: @escaping () -> Void) {
        queue.async {
            let source = CGEventSource(stateID: .privateState)
            usleep(9_000)   // let the app finish the keystroke that triggered us
            for _ in 0..<deleteCount {
                post(virtualKey: backspace, source: source)
                usleep(500)
            }
            if deleteCount > 0 { usleep(8_000) }
            typeUnicode(text, source: source)
            DispatchQueue.main.async(execute: completion)
        }
    }

    static func type(_ text: String, completion: @escaping () -> Void) {
        replace(deleteCount: 0, with: text, completion: completion)
    }

    private static func post(virtualKey: CGKeyCode, source: CGEventSource?, unicode: [UniChar]? = nil) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: down) else { continue }
            e.flags = []
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            if let unicode {
                unicode.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            }
            e.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private static func typeUnicode(_ text: String, source: CGEventSource?) {
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + chunkSize, units.count)])
            post(virtualKey: 0, source: source, unicode: chunk)
            i += chunkSize
            usleep(800)
        }
    }
}
```

- [ ] **Step 2: KeystrokeTap**

`VoiceInk/LayoutSwitcher/KeystrokeTap.swift`:

```swift
import CoreGraphics
import Foundation
import os

/// Listen-only tap for the switcher. Kept separate from ShortcutMonitor: that tap is active,
/// exists only while modifier-only shortcuts are configured, and restarts on every shortcut
/// change; this one lives and dies with the feature toggle.
final class KeystrokeTap {
    enum Event {
        case keyDown(keyCode: UInt16, flags: CGEventFlags)
        case mouseDown
    }

    private let handler: (Event) -> Void
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "KeystrokeTap")

    init(handler: @escaping (Event) -> Void) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// false when the tap can't be created — Input Monitoring is missing.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if let userInfo {
                Unmanaged<KeystrokeTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            logger.error("tap create failed — Input Monitoring not granted?")
            return false
        }
        self.tap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            guard event.getIntegerValueField(.eventSourceUserData) != DirectTyper.marker else { return }
            handler(.keyDown(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags))
        case .leftMouseDown, .rightMouseDown:
            handler(.mouseDown)
        default:
            break
        }
    }
}
```

- [ ] **Step 3: Accessibility helpers**

Replace the body of `VoiceInk/Paste/FocusedTextAccessibility.swift` so the three readers share one focused-element lookup:

```swift
import Foundation
import ApplicationServices

/// Reads the current text selection of the system-wide focused UI element via Accessibility.
/// Used by the re-transcribe-last hotkey to verify — before replacing — that the text it is about
/// to overwrite is exactly what VoiceInk pasted, and by the layout switcher for the same reason.
enum FocusedTextAccessibility {
    /// The selected text of the focused element, or `nil` when there is no focus or the element
    /// does not expose `AXSelectedText` (common for web / Electron fields). A `nil` result must be
    /// treated as "can't verify" and the caller must fall back to a non-destructive path.
    @MainActor
    static func selectedText() -> String? {
        guard let element = focusedElement() else { return nil }
        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selection) == .success,
              let text = selection as? String else {
            return nil
        }
        return text
    }

    /// Text of the focused element up to the caret (or the start of the selection). nil when the
    /// element exposes no value or range — then the screen can't be checked against the buffer.
    @MainActor
    static func textBeforeCaret() -> String? {
        guard let element = focusedElement() else { return nil }
        var value: CFTypeRef?
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        let nsText = text as NSString
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location <= nsText.length else { return nil }
        return nsText.substring(to: range.location)
    }

    /// Role of the focused element (`AXSecureTextField` for password fields); nil when unknown.
    @MainActor
    static func focusedRole() -> String? {
        guard let element = focusedElement() else { return nil }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success else { return nil }
        return role as? String
    }

    @MainActor
    private static func focusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        // Bound the synchronous cross-process AX read so an unresponsive focused app can't hang the UI.
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedValue = focused,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (focusedValue as! AXUIElement)
    }
}
```

- [ ] **Step 4: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`, no new warnings mentioning these files.

- [ ] **Step 5: Re-run the retranscribe tests that use `selectedText()`**

`-only-testing:VoiceInkTests/RetranscribeHotkeyTests`. Expected: `** TEST SUCCEEDED **` (the refactor must not change `selectedText()` behaviour).

- [ ] **Step 6: Commit**

```bash
git add VoiceInk/LayoutSwitcher/DirectTyper.swift VoiceInk/LayoutSwitcher/KeystrokeTap.swift VoiceInk/Paste/FocusedTextAccessibility.swift
git commit -m "feat(layout): direct typer, listen-only tap, AX caret helpers"
```

---

## Task 8: `ShortcutAction.convertLayout`

**Files:**
- Modify: `VoiceInk/Shortcuts/ShortcutAction.swift`, `VoiceInk/Shortcuts/ShortcutMigration.swift:283-299`, `VoiceInk/Shortcuts/ShortcutValidator.swift:96-100`, `VoiceInk/Services/BackupTypes.swift:69-79`, `VoiceInk/Services/BackupImporter.swift:118-120`, `VoiceInk/Services/ImportExportService.swift:161`, `VoiceInk/Shortcuts/RecordingShortcutManager.swift:319-324`

**Interfaces:**
- Produces: `ShortcutAction.convertLayout` stored under `Shortcut_convertLayout`, listed in `globalUtilityActions`, dispatched to `LayoutSwitcherEngine.shared.handleManualTrigger()` (implemented in Task 9 — this task adds the dispatch line, so the build stays red until Task 9's engine exists; do Task 8 and Task 9 back to back and build once at the end of Task 9).

- [ ] **Step 1: Add the case**

In `VoiceInk/Shortcuts/ShortcutAction.swift`:

After `case enhanceSelectedText` (line 14) add:

```swift
    case convertLayout
```

In `storageName`, after the `.enhanceSelectedText` case (line 56) add:

```swift
        case .convertLayout:
            return "convertLayout"
```

In `displayName`, after the `.enhanceSelectedText` case (line 91) add:

```swift
        case .convertLayout:
            return String(localized: "Convert Last Word Layout")
```

In `globalUtilityActions` append `.convertLayout` after `.enhanceSelectedText`:

```swift
    static let globalUtilityActions: [Self] = [
        .pasteLastTranscription,
        .pasteLastEnhancement,
        .retryLastTranscription,
        .retranscribeLastInLayoutLanguage,
        .openHistoryWindow,
        .quickAddToDictionary,
        .enhanceSelectedText,
        .convertLayout
    ]
```

- [ ] **Step 2: Migration and validator**

`VoiceInk/Shortcuts/ShortcutMigration.swift` line 297 — add `.convertLayout` to the `nil` group:

```swift
        case .retranscribeLastInLayoutLanguage, .enhanceSelectedText, .convertLayout, .miniRecorderEscape, .miniRecorderPrompt, .miniRecorderPowerMode:
            return nil
```

`VoiceInk/Shortcuts/ShortcutValidator.swift` line 98:

```swift
            [.retranscribeLastInLayoutLanguage, .enhanceSelectedText, .convertLayout] +
```

- [ ] **Step 3: Backup round-trip**

`VoiceInk/Services/BackupTypes.swift` — after `let retranscribeLastInLayoutLanguageShortcut: ShortcutBackup?` (line 75) add:

```swift
    let convertLayoutShortcut: ShortcutBackup?
```

`GeneralBackup` uses synthesized `Codable`, which decodes a missing key of an `Optional` property as `nil`, so backups made before this field exist keep importing.

`VoiceInk/Services/BackupImporter.swift` — after the `retranscribeLayoutShortcut` block (lines 118-120) add:

```swift
        if let convertLayoutShortcut = general.convertLayoutShortcut {
            ShortcutStore.setShortcut(convertLayoutShortcut.shortcut, for: .convertLayout)
        }
```

`VoiceInk/Services/ImportExportService.swift` — after line 161 add:

```swift
            convertLayoutShortcut: ShortcutStore.shortcut(for: .convertLayout).map(ShortcutBackup.init),
```

- [ ] **Step 4: Dispatch**

`VoiceInk/Shortcuts/RecordingShortcutManager.swift` — in `handleGlobalShortcut`, after the `.retranscribeLastInLayoutLanguage` case (line 324) add:

```swift
        case .convertLayout:
            LayoutSwitcherEngine.shared.handleManualTrigger()
```

- [ ] **Step 5: Commit (build verified at the end of Task 9)**

```bash
git add VoiceInk/Shortcuts/ShortcutAction.swift VoiceInk/Shortcuts/ShortcutMigration.swift VoiceInk/Shortcuts/ShortcutValidator.swift VoiceInk/Services/BackupTypes.swift VoiceInk/Services/BackupImporter.swift VoiceInk/Services/ImportExportService.swift VoiceInk/Shortcuts/RecordingShortcutManager.swift
git commit -m "feat(shortcuts): convertLayout global action"
```

---

## Task 9: LayoutSwitcherEngine

**Files:**
- Create: `VoiceInk/LayoutSwitcher/LayoutSwitcherEngine.swift`
- Modify: `VoiceInk/AppDelegate.swift:8-11`

**Interfaces:**
- Consumes: everything from Tasks 1–8, `NotificationManager.shared.showNotification(title:type:)`, `ShortcutStore.shortcut(for:)`, `ShortcutStore.shortcutDidChange`, `Shortcut.matchesKeyEvent(keyCode:modifierFlags:)`.
- Produces: `@MainActor final class LayoutSwitcherEngine { static let shared; func start(); func stop(); func handleManualTrigger() }`.

- [ ] **Step 1: Implement the engine**

`VoiceInk/LayoutSwitcher/LayoutSwitcherEngine.swift`:

```swift
import AppKit
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
        guard settings.autoConvert, !resonance.isFrozen else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard !LayoutPolicy.secureInputActive,
              FocusedTextAccessibility.focusedRole() != (kAXSecureTextFieldRole as String),
              !LayoutPolicy.isDeniedApp(front, deniedApps: settings.deniedApps),
              let pair = LayoutPair.resolve(layout1ID: settings.layout1ID, layout2ID: settings.layout2ID),
              let pairs = LayoutMapper.convert(word, from: pair.currentData, to: pair.otherData) else { return }

        let typed = String(pairs.map(\.original))
        let converted = String(pairs.map(\.converted))
        guard !LayoutPolicy.isNeverWord(typed, converted, never: settings.neverWordsSet) else { return }

        let decision = LayoutDetector.decideWord(pairs: pairs, currentLang: pair.currentLang, otherLang: pair.otherLang,
                                                 capsLock: capsLock, alwaysConvert: settings.alwaysWordsSet)
        guard decision.verdict == .switchToConverted else { return }

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
                self.logger.notice("auto: screen does not end with the buffered word, skipping")
                self.inFlight = false
                self.buffer.reset()
                return
            }
            self.perform(deleteCount: original.count, text: produced, original: original,
                         wasAuto: true, bundleID: front, switchTo: pair.other)
        }
    }

    // MARK: - Manual trigger

    func handleManualTrigger() {
        guard settings.enabled, !inFlight else { return }
        guard !LayoutPolicy.secureInputActive,
              FocusedTextAccessibility.focusedRole() != (kAXSecureTextFieldRole as String) else {
            NotificationManager.shared.showNotification(title: String(localized: "Secure input is active"), type: .warning)
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let pair = LayoutPair.resolve(layout1ID: settings.layout1ID, layout2ID: settings.layout2ID) else {
            NotificationManager.shared.showNotification(title: String(localized: "Current keyboard layout is not in the configured pair"), type: .warning)
            return
        }

        if let selection = FocusedTextAccessibility.selectedText(), !selection.isEmpty {
            convertSelection(selection, pair: pair, bundleID: front)
            return
        }

        if let last = lastConversion, last.bundleID == front {
            // Tap again = undo. An undone auto-conversion teaches the never list.
            perform(deleteCount: last.produced.count, text: last.original, original: last.produced,
                    wasAuto: false, bundleID: front, switchTo: pair.other)
            if last.wasAuto { learnNever(last.original) }
            return
        }

        guard let target = buffer.manualTarget,
              let pairs = LayoutMapper.convert(target.keys, from: pair.currentData, to: pair.otherData) else {
            NotificationManager.shared.showNotification(title: String(localized: "Nothing to convert"), type: .info)
            return
        }
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
```

- [ ] **Step 2: Start the engine at launch**

`VoiceInk/AppDelegate.swift` `applicationDidFinishLaunching` — after `KeyboardLayoutLanguageService.captureCurrentLayout()` (line 10) add:

```swift
        _ = LayoutSwitcherEngine.shared   // subscribes to the enabled toggle and starts when on
```

- [ ] **Step 3: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`. Typical fixes if it fails:
- `kAXSecureTextFieldRole` needs `import ApplicationServices` (add it to the engine imports).
- `Shortcut.matchesKeyEvent` argument label mismatch — check `VoiceInk/Shortcuts/Shortcut.swift:103` and match it exactly.
- `DirectTyper.replace` completion runs on the main queue but is not `@MainActor`-typed; the engine's closure touching `@MainActor` state compiles in Swift 5 language mode (warning at most). If the compiler errors, wrap the closure body in `Task { @MainActor in ... }`.

- [ ] **Step 4: Run the unit suites once more**

Run each of: `KeystrokeBufferTests`, `LayoutDetectorTests`, `LayoutMapperTests`, `SmartConvertTests`, `LayoutPolicyTests`, `AntiResonanceGuardTests`. Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add VoiceInk/LayoutSwitcher/LayoutSwitcherEngine.swift VoiceInk/AppDelegate.swift
git commit -m "feat(layout): engine — auto conversion at word boundary, manual trigger, undo"
```

---

## Task 10: Settings view, sidebar, localization, attribution

**Files:**
- Create: `VoiceInk/Views/LayoutSwitcher/LayoutSwitcherView.swift`, `THIRD_PARTY.md`
- Modify: `VoiceInk/Views/ContentView.swift:6-35, 169-195`, `VoiceInk/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `LayoutSwitcherSettings.shared`, `LayoutPair.enabledLayouts()/sourceID/localizedName`, `LayoutPolicy.protectedApps`, `ShortcutRecorder(action:onShortcutChanged:)`, `recordingShortcutManager.updateShortcutStatus()`.

- [ ] **Step 1: The view**

`VoiceInk/Views/LayoutSwitcher/LayoutSwitcherView.swift`:

```swift
import SwiftUI

struct LayoutSwitcherView: View {
    @ObservedObject private var settings = LayoutSwitcherSettings.shared
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager
    @State private var layouts: [(id: String, name: String)] = []

    var body: some View {
        Form {
            Section {
                Toggle("Enable Layout Switcher", isOn: $settings.enabled)
                Toggle("Convert automatically at word boundaries", isOn: $settings.autoConvert)
                    .disabled(!settings.enabled)
                LabeledContent {
                    ShortcutRecorder(action: .convertLayout) {
                        recordingShortcutManager.updateShortcutStatus()
                    }
                    .controlSize(.small)
                } label: {
                    HStack(spacing: 4) {
                        Text("Convert Last Word Layout")
                        InfoTip("Converts the last typed word (or the selection) to the other layout. Press again to undo. A single modifier tap such as Right Option works well.")
                    }
                }
            } footer: {
                Text("Fixes words typed in the wrong keyboard layout: ghbdtn → привет. Needs Accessibility and Input Monitoring.")
            }

            Section("Layout Pair") {
                layoutPicker("First layout", selection: $settings.layout1ID)
                layoutPicker("Second layout", selection: $settings.layout2ID)
            }

            Section {
                StringListEditor(items: $settings.neverWords, prompt: "word")
            } header: {
                Text("Never convert")
            } footer: {
                Text("Nicknames, logins, brands. Undoing an automatic conversion adds the word here.")
            }

            Section {
                StringListEditor(items: $settings.alwaysWords, prompt: "target word")
            } header: {
                Text("Always convert")
            } footer: {
                Text("Add the word you want to get, e.g. привет — not the garbage that produced it.")
            }

            Section {
                StringListEditor(items: $settings.deniedApps, prompt: "bundle id or prefix*", locked: LayoutPolicy.protectedApps)
            } header: {
                Text("Apps without automatic conversion")
            } footer: {
                Text("The manual shortcut still works in these apps. Password managers can't be removed.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            layouts = LayoutPair.enabledLayouts().map { (LayoutPair.sourceID($0), LayoutPair.localizedName($0)) }
        }
    }

    private func layoutPicker(_ title: LocalizedStringKey, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Automatic").tag("")
            ForEach(layouts, id: \.id) { layout in
                Text(layout.name).tag(layout.id)
            }
        }
    }
}

/// Add/remove editor for a list of strings. `locked` entries have no remove button.
struct StringListEditor: View {
    @Binding var items: [String]
    let prompt: LocalizedStringKey
    var locked: Set<String> = []
    @State private var draft = ""

    var body: some View {
        ForEach(items, id: \.self) { item in
            HStack {
                Text(item)
                Spacer()
                if !locked.contains(item) {
                    Button {
                        items.removeAll { $0 == item }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        HStack {
            TextField(prompt, text: $draft)
                .onSubmit(add)
            Button("Add", action: add)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !items.contains(value) else { return }
        items.append(value)
        draft = ""
    }
}
```

- [ ] **Step 2: Sidebar item**

`VoiceInk/Views/ContentView.swift`:

In `enum ViewType`, after `case dictionary = "Dictionary"` (line 15) add:

```swift
    case layoutSwitcher = "Layout Switcher"
```

In `icon`, after the `.dictionary` line (line 31) add:

```swift
        case .layoutSwitcher: return "keyboard.badge.ellipsis"
```

In `detailView(for:)`, after the `.dictionary` case (lines 184-185) add:

```swift
        case .layoutSwitcher:
            LayoutSwitcherView()
```

- [ ] **Step 3: Build and open the view**

Build with the build command, then `make local-signed` (keeps Accessibility/Input Monitoring across rebuilds) and open VoiceInk → sidebar "Layout Switcher". Expected: the form renders; pickers list the enabled layouts; adding/removing list entries persists across relaunch; the shortcut recorder records a modifier-only shortcut (e.g. Right Option).

- [ ] **Step 4: Russian strings**

Build once so Xcode extracts the new keys into `VoiceInk/Resources/Localizable.xcstrings`. Then add translations with this script (run from the repo root; it appends `ru` entries and leaves existing keys untouched):

```bash
python3 - <<'PY'
import json
path = "VoiceInk/Resources/Localizable.xcstrings"
d = json.load(open(path, encoding="utf-8"))
ru = {
    "Layout Switcher": "Переключатель раскладки",
    "Enable Layout Switcher": "Включить переключатель раскладки",
    "Convert automatically at word boundaries": "Исправлять автоматически на границе слова",
    "Convert Last Word Layout": "Исправить раскладку последнего слова",
    "Converts the last typed word (or the selection) to the other layout. Press again to undo. A single modifier tap such as Right Option works well.": "Переводит последнее набранное слово (или выделение) в другую раскладку. Повторное нажатие — отмена. Удобно назначить одиночный модификатор, например правый Option.",
    "Fixes words typed in the wrong keyboard layout: ghbdtn → привет. Needs Accessibility and Input Monitoring.": "Исправляет слова, набранные не в той раскладке: ghbdtn → привет. Нужны разрешения «Универсальный доступ» и «Мониторинг ввода».",
    "Layout Pair": "Пара раскладок",
    "First layout": "Первая раскладка",
    "Second layout": "Вторая раскладка",
    "Automatic": "Автоматически",
    "Never convert": "Никогда не исправлять",
    "Nicknames, logins, brands. Undoing an automatic conversion adds the word here.": "Ники, логины, бренды. Отмена автоматического исправления добавляет слово сюда.",
    "Always convert": "Всегда исправлять",
    "Add the word you want to get, e.g. привет — not the garbage that produced it.": "Добавляйте слово, которое должно получиться, например «привет», а не набор букв, из которого оно вышло.",
    "Apps without automatic conversion": "Приложения без автоматического исправления",
    "The manual shortcut still works in these apps. Password managers can't be removed.": "Ручной хоткей в этих приложениях работает. Менеджеры паролей удалить нельзя.",
    "word": "слово",
    "target word": "целевое слово",
    "bundle id or prefix*": "bundle id или префикс*",
    "Add": "Добавить",
    "Secure input is active": "Включён защищённый ввод",
    "Current keyboard layout is not in the configured pair": "Текущая раскладка не входит в настроенную пару",
    "Nothing to convert": "Нечего исправлять",
    "“%@” added to Never convert": "«%@» добавлено в «Никогда не исправлять»",
}
added = 0
for key, value in ru.items():
    entry = d["strings"].setdefault(key, {})
    loc = entry.setdefault("localizations", {})
    if "ru" not in loc:
        loc["ru"] = {"stringUnit": {"state": "translated", "value": value}}
        added += 1
with open(path, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
    f.write("\n")
print("added", added)
PY
git diff --stat VoiceInk/Resources/Localizable.xcstrings
```

Expected: `added 24` (fewer if some keys already existed), and the diff stat shows only insertions plus at most a one-line change at the file end. If the diff rewrites the whole file, the catalog's formatting differs from `json.dump(indent=2)` — revert with `git checkout VoiceInk/Resources/Localizable.xcstrings` and add the entries in Xcode's String Catalog editor instead.

Rebuild and run with `defaults write com.prakashjoshipax.VoiceInk AppleLanguages -array ru` (or the app's interface-language setting) to confirm the Russian strings show; reset with `defaults delete com.prakashjoshipax.VoiceInk AppleLanguages`.

- [ ] **Step 5: Attribution**

Create `THIRD_PARTY.md` at the repo root:

```markdown
# Third-party notices

## RuSwitcher — layout detection, key mapping, selection conversion

Files `VoiceInk/LayoutSwitcher/{ShortWords,LayoutDetector,LayoutPair,LayoutMapper,SmartConvert,LayoutPolicy}.swift`
are ports from <https://github.com/rashn/RuSwitcher>, MIT License.

MIT License

Copyright (c) 2025 Rashns

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Keyboop — anti-resonance guard, synthetic event posting

`VoiceInk/LayoutSwitcher/AntiResonanceGuard.swift` and the posting strategy in
`VoiceInk/LayoutSwitcher/DirectTyper.swift` come from <https://github.com/iffuno/keyboop>, MIT License.

MIT License

Copyright (c) 2026 Keyboop contributors

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

Copyright lines are copied verbatim from the two repositories' `LICENSE` files (RuSwitcher: `Copyright (c) 2025 Rashns`; keyboop: `Copyright (c) 2026 Keyboop contributors`).

- [ ] **Step 6: Commit**

```bash
git add VoiceInk/Views/LayoutSwitcher/LayoutSwitcherView.swift VoiceInk/Views/ContentView.swift VoiceInk/Resources/Localizable.xcstrings THIRD_PARTY.md
git commit -m "feat(layout): settings view, sidebar entry, ru strings, third-party notices"
```

---

## Task 11: Manual acceptance and metric

**Files:** none (verification only). Fix anything that fails in the task that owns the code, with a commit per fix.

- [ ] **Step 1: Install a signed local build**

```bash
make local-signed
```

Open VoiceInk, grant Accessibility and Input Monitoring if prompted (Settings → Permissions), enable the switcher in the sidebar view, record Right Option as the trigger.

- [ ] **Step 2: Auto path in TextEdit**

With the U.S. layout active, type `ghbdtn ` in TextEdit. Expected: the word becomes `привет `, the menu-bar layout flag switches to Russian. Type `vbh ` on Russian — «мир» is what you meant, so it stays. Type `hello ` on Russian (`руддщ `): expected `hello ` and the flag back to U.S.

- [ ] **Step 3: Trailing punctuation and ambiguity**

Type `ghbdtn, ` → `привет, `. Type `levf. ` → unchanged (ambiguous). Tap Right Option: the manual trigger converts every buffered key, so the dot becomes «ю» — expect `думаю `. Tap again → back to `levf. `.

- [ ] **Step 4: Undo learns**

Type `ghbdtn ` (auto-converted), immediately tap Right Option. Expected: `ghbdtn ` restored, layout back to U.S., notification "“ghbdtn” added to Never convert", and the word listed in Settings. Type `ghbdtn ` again → stays. Remove it from the list.

- [ ] **Step 5: Selection**

Select `iPhone ghbdtn ьшк` (type it with auto off, or paste) and tap Right Option. Expected: `iPhone привет мир`, layout unchanged.

- [ ] **Step 6: Guards**

- Terminal.app: type `ghbdtn ` → unchanged (denied app); tap Right Option → converted (manual still works).
- Safari address bar and a web `<textarea>`: auto conversion works; if the AX check logs "screen does not end with the buffered word" in Console (`log stream --predicate 'subsystem == "com.prakashjoshipax.voiceink" AND category == "LayoutSwitcherEngine"'`), note the app — it is a candidate for the denied list, not a bug to fix now.
- VS Code / Telegram (Electron): auto conversion works via the no-AX path.
- A password field (System Settings → Users, or Safari login): nothing happens; Right Option shows "Secure input is active".
- Press Enter after `ghbdtn` in Messages/Telegram: the message is sent as typed, nothing is deleted afterwards.
- Click into the middle of an existing word and type a letter + space: no conversion (buffer reset by the click).

- [ ] **Step 7: Metric**

Keep the feature on for a week of your own typing. Count from the log:

```bash
log show --last 7d --predicate 'subsystem == "com.prakashjoshipax.voiceink" AND category == "LayoutSwitcherEngine"' \
  | grep -c 'auto:'
log show --last 7d --predicate 'subsystem == "com.prakashjoshipax.voiceink" AND category == "LayoutSwitcherEngine"' \
  | grep -c 'added to Never convert'
```

False-positive rate = second / first. Words you had to fix by hand (misses) are the input for deciding whether keyboop's trigram booster is worth porting — record them in `docs/superpowers/specs/2026-09-17-layout-switcher-design.md` under "Metric" before proposing it.

---

## Self-review

- Spec coverage: buffer (T1), detector + ShortWords + trailing punctuation (T2), any-pair mapping + TIS (T3), SmartConvert (T4), policy + settings (T5), anti-resonance (T6), tap + direct typing + AX checks (T7), ShortcutAction + backup (T8), engine incl. Enter-never-converts, denied-apps-auto-only, secure input both paths, undo → never list, interleaved-key abort (T9), UI + sidebar + ru + THIRD_PARTY (T10), acceptance + metric (T11). Dead-key layouts: `LayoutMapper.convert` returns nil (T3), the engine skips (T9). Tap failure reporting: the engine logs; the settings footer names the permissions (T10) — the spec's "reports unavailable in its settings view" is covered by the footer text plus the existing Permissions page, no live status indicator.
- Type consistency: `LayoutDetector.decideWord(pairs:currentLang:otherLang:capsLock:alwaysConvert:)` returns `(verdict:, convertedLength:)` in T2 and is consumed as such in T9; `LayoutPair.Resolved` fields `currentData/otherData/currentLang/otherLang/other` in T3 and T9; `DirectTyper.replace(deleteCount:with:completion:)` in T7 and T9; `KeystrokeTap.Event.keyDown(keyCode:flags:)` in T7 and T9; `LayoutSwitcherSettings` property names in T5, T9, T10.
- Placeholders: none; licence copyright lines were taken from the cloned repositories.
