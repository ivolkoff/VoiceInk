# Layout Switcher (PuntoSwitcher analog) — design

Date: 2026-09-17. Sources studied: [RuSwitcher](https://github.com/rashn/RuSwitcher)
(MIT) and [keyboop](https://github.com/iffuno/keyboop) (MIT). VoiceInk is GPL-3;
ported code keeps the original copyright line in the file header and a
`THIRD_PARTY.md` entry.

## Problem

The user types `ghbdtn` on the wrong keyboard layout and wants it fixed to
`привет` — automatically at the word boundary, or by a hotkey for the last word
or the current selection — without the clipboard being touched. VoiceInk already
runs a global event tap, has Accessibility and Input Monitoring, and knows the
layout language, so the feature lives inside VoiceInk instead of a separate app.

## Decisions (locked)

- **Skeleton from RuSwitcher**: listen-only tap, key-code buffer, any layout
  pair via `UCKeyTranslate`, precision-first detector on `NSSpellChecker` +
  a short-word list. No bundled dictionaries or trigram data.
- **Guards from keyboop**: anti-resonance circuit breaker, AX screen-vs-model
  check before deleting, synthetic events posted on
  `.cgAnnotatedSessionEventTap` from a serial queue.
- **Not in v1**: mid-word live-fix, trigram plausibility, word groups / time
  window, typo rules, two-caps fix, numeric typo, snippets, caret flag, layout
  sound, per-app layout memory, remote desktop, Spotlight special path, Hebrew /
  RTL branch, Chromium ⌘C sacrifice key. Each is a separate follow-up if the
  measured miss rate of the dictionary detector justifies it.
- **Manual trigger** reuses `ShortcutStore` / `ShortcutRecorder`: one new
  `ShortcutAction`. Modifier-only single tap (e.g. Right Option) works today;
  double-tap does not and is not added.
- **Auto-conversion default: on** once the feature master toggle is on; the
  master toggle itself defaults to **off** (the tap and typing are invasive).

## Architecture

New folder `VoiceInk/LayoutSwitcher/`. Each unit has one purpose and is
testable without the others.

| Unit | Purpose | Depends on |
|---|---|---|
| `KeystrokeTap` | Listen-only `CGEventTap` (keyDown, flagsChanged, left/right mouseDown) at `.cgSessionEventTap`; re-enables itself on `tapDisabledByTimeout`; ignores events carrying our `eventSourceUserData` marker. Delivers raw events to the engine on the main run loop. | CoreGraphics |
| `KeystrokeBuffer` | Model of what the user typed since the last context reset: `[TypedKey(keyCode, shift, caps)]` for the current word, the previous completed word, and the boundary run (spaces) between them. Pure value type. | — |
| `LayoutPair` | Resolves the two `TISInputSource`s in play (settings or auto-detect when exactly two keyboard layouts are enabled), current/other, language codes, and `select(other)` via `TISSelectInputSource`. | Carbon TIS, `KeyboardLayoutLanguageService` |
| `LayoutMapper` | `TypedKey` → character in a given layout through `UCKeyTranslate` on `kTISPropertyUnicodeKeyLayoutData`, with shift/caps modifiers; dead-key detection (length 0 + non-zero dead state ⇒ buffer unreliable ⇒ abort). Cached per layout pair. | Carbon |
| `LayoutDetector` | Pure decision `decide(typed:converted:currentLang:otherLang:capsLock:) -> .switchToConverted / .keep / .undecided`. Port of RuSwitcher `AutoSwitch.swift:45-177` minus the Hebrew branch, plus `ShortWords` (ru/en two-letter lists) and `splitTrailingPunctuation`. | `NSSpellChecker` |
| `LayoutPolicy` | Hard gates evaluated before the detector: secure input (`IsSecureEventInputEnabled()` or focused AX role `AXSecureTextField`), denied app list (RuSwitcher defaults; password managers not removable), never-convert / always-convert word lists. | AX, `LayoutSwitcherSettings` |
| `AntiResonanceGuard` | Port of keyboop `AntiResonanceGuard.swift` verbatim (window 0.7 s, 6 flips, freeze 2.5 s). Auto path only. | — |
| `DirectTyper` | Backspace×N then Unicode chunks (≤12 UTF-16 units per event, virtualKey 0, marker set, flags cleared) posted on `.cgAnnotatedSessionEventTap` from a dedicated serial queue; completion on main. Also `type(_:)` without deletion for selection replacement. | CoreGraphics |
| `LayoutSwitcherEngine` | Orchestrator: feeds the buffer, runs boundary auto-conversion, handles the manual trigger, undo, learning, layout switch. Single `@MainActor` instance owned by `AppDelegate`. | all of the above |
| `LayoutSwitcherSettings` | `UserDefaults`-backed: enabled, autoConvert, layout1ID, layout2ID, deniedApps, neverWords, alwaysWords. | — |
| `LayoutSwitcherView` | Sidebar section "Layout Switcher" in `ContentView`: toggles, layout pair pickers, `ShortcutRecorder(action: .convertLayout)`, three editable lists. | SwiftUI |

## Data flow

```
physical key ──► KeystrokeTap ──► Engine.handle(event)
                                   │
        ┌──────────────────────────┴───────────────────────────┐
        │ keyDown letter/punct (no ⌘/⌃/⌥): buffer.append       │
        │ Backspace: buffer.dropLast                            │
        │ Space: buffer.completeWord ──► maybeAutoConvert()     │
        │ Enter/Tab/arrows/⌘-combo/mouseDown/app switch: reset  │
        └───────────────────────────────────────────────────────┘

maybeAutoConvert():
  gates  : settings.autoConvert, !policy.secureInput, !policy.deniedApp(front),
           !inFlight, pair resolved, no dead keys in word
  map    : (typed, converted) = LayoutMapper(word)          // exact, key-code based
  split  : core/suffix = splitTrailingPunctuation(typed)     // "ghbdtn," → "ghbdtn" + ","
  policy : neverWords → stop; alwaysWords → convert
  decide : LayoutDetector.decide(core, convertedCore, cur, other, capsLock)
  guard  : AntiResonanceGuard.allow(word, produced)
  verify : AX text before caret ends with typed+boundary (skip when AX gives nothing;
           mismatch ⇒ abort + buffer.reset)
  act    : DirectTyper.replace(deleteCount: typed.count + boundary.count,
                               with: converted + suffix + boundary)
           LayoutPair.select(other); remember lastConversion for undo;
           buffer.markConverted()
```

Manual trigger (`ShortcutAction.convertLayout`, dispatched from
`RecordingShortcutManager.handleGlobalShortcut`):

1. Secure input ⇒ notification, stop.
2. Selection via `FocusedTextAccessibility.selectedText()` non-empty ⇒
   per-word smart conversion (RuSwitcher `SmartConvert` pass 1 + pass 2: flip
   garbage words, keep valid ones, pull unresolved words in the direction of
   their neighbours) ⇒ `DirectTyper.type(result)` replaces the selection. No
   layout switch.
3. Else if `lastConversion` is fresh (same app, buffer untouched since) ⇒ undo:
   delete the produced text, retype the original, switch layout back; if it
   was an auto-conversion, add the typed word to `neverWords` and show a
   notification naming the word (editable in settings).
4. Else last word from the buffer (or previous completed word if the current
   one is empty, including its boundary spaces) ⇒ convert unconditionally
   (no detector), switch layout, remember for undo.
5. Buffer empty and no selection ⇒ notification "Nothing to convert". No
   clipboard fallback.

## Safety rules

- **Never delete blind.** Auto path deletes only after the AX check passes or
  AX is unavailable; manual path deletes only what the buffer says was typed
  in this app since the last reset.
- **Real key during a synthetic burst** ⇒ engine sets `contextLost`, clears the
  buffer, and does not auto-convert until the next completed word. Ponytail
  ceiling: no interleave repair; keyboop's Fence B is the upgrade path.
- **Enter never triggers auto-conversion.** In chat apps the message is already
  sent when a listen-only tap sees the key; deleting afterwards would hit the
  next message. Enter resets the buffer.
- **Denied apps** disable auto only; the manual trigger still works there.
  Secure input disables both.
- **Our own events** never re-enter the buffer: posted below the session tap
  and carrying the `eventSourceUserData` marker.
- **Tap failure** (no Input Monitoring) ⇒ feature reports "unavailable" in its
  settings view via the existing `PermissionsView` wording; no retries in a loop.
- **Dead-key layouts** (U.S. International): a word containing a dead key is
  never converted (buffer length ≠ screen length).

## Integration points (existing code touched)

- `Shortcuts/ShortcutAction.swift`: `case convertLayout`, display name,
  defaults key, add to `globalUtilityActions`.
- `Shortcuts/ShortcutMigration.swift`, `ShortcutValidator.swift`: list entries.
- `Shortcuts/RecordingShortcutManager.swift:306`: dispatch to
  `LayoutSwitcherEngine.shared.handleManualTrigger()`.
- `Services/BackupTypes.swift`, `BackupImporter.swift`,
  `ImportExportService.swift`: shortcut backup entry (same pattern as
  `retranscribeLastInLayoutLanguage`).
- `Views/ContentView.swift`: sidebar item + view.
- `AppDelegate.swift`: create engine, start/stop on the master toggle.
- `Localizable.xcstrings`: en + ru strings.

## Testing

Unit tests (`VoiceInkTests/LayoutSwitcher*Tests.swift`), no tap, no typing:

- `KeystrokeBuffer`: append / backspace / boundary / reset transitions, previous
  word retained with boundary count, `markConverted` behaviour.
- `LayoutDetector`: table of (typed, converted, langs) → verdict covering: valid
  in current ⇒ keep; valid only in other ⇒ convert; both valid ⇒ keep; digits /
  camelCase / ALL-CAPS ⇒ undecided; Caps Lock on ⇒ caps vetoes skipped;
  2-letter via `ShortWords` both directions; trailing punctuation split and the
  «думаю» vs «дума.» ambiguity ⇒ undecided. `NSSpellChecker` is real (macOS
  dictionaries exist on CI-less local runs); tests skip when `ru`/`en` are
  unavailable.
- `LayoutMapper`: en↔ru mapping of a known key-code sequence against the
  installed U.S. and Russian layouts; skipped if either is missing.
- `AntiResonanceGuard`: injected clock; oscillation and storm both freeze.
- `LayoutPolicy`: denied-app prefix matching, protected password managers,
  never/always lists case-insensitive.
- `SmartConvert`: mixed selection «iPhone ghbdtn» → «iPhone привет».

Manual acceptance (`make local-signed`, real apps): TextEdit, Safari text
field, VS Code (Electron), Telegram, Terminal (auto off, manual on), a password
field (nothing happens), Option-tap undo, settings lists round-trip.

## Metric

Before enabling auto by default for anyone else: log every auto-conversion and
every undo for a week of the author's own typing; false-positive rate = undos /
conversions. Trigram booster is considered only if misses (words the user had
to fix manually) exceed what the never/always lists absorb.
