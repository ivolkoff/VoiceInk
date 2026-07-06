# Hotkey: Re-transcribe Last Recording in Keyboard-Layout Language and Replace

## Problem

A user dictates, forgets the keyboard layout was on the wrong language, and the
just-pasted text is garbage. They want to: switch the keyboard layout to the
correct language, press one global hotkey, and have the pasted text replaced
in place with a re-transcription in that language — without touching History or
re-dictating.

## Decisions (locked)

- **Trigger:** a new global-utility hotkey (`ShortcutAction`), like the existing
  "Retry Last Transcription".
- **Language:** the current keyboard-layout language, read at hotkey time.
- **Text:** raw re-transcription (no AI enhancement re-run).
- **Replacement:** replace the previously-pasted text in place — but **safely**:
  never destroy content unless we can prove the selection about to be deleted is
  exactly the text we pasted. Otherwise abort and fall back to the clipboard.
- **History:** the last record is overwritten in place (reuses
  `retranscribeInPlace` from the History re-transcribe feature).

## Why the naive version was rejected

Reconstructing the pasted length as `enhancedText ?? text` and blindly sending
`Shift+Left ×N` then `Cmd+V` loses user data in common cases: the pasted string
is not what's stored (trailing space is on by default; trial/enhancement-failure
banners; enhancement-failure writes an error string into `enhancedText`); the
focused app can change during the seconds-long re-transcription; AutoSend may
have already submitted the text; the last record may be canceled/failed/no-audio
so there is nothing to re-transcribe after the delete; or the user typed more
after dictating. The design below eliminates each by **verifying before
destroying** and by **recording the exact paste** instead of reconstructing it.

## Core safety principle

> Do not delete anything until we have (a) the new text in hand and (b) proof
> that the text currently selected is exactly what we pasted.

Re-transcription runs *first*; a failure aborts before any keystroke. The delete
only happens through a select-back whose selection is read back via
Accessibility and compared to the known pasted string. Any mismatch → no delete,
clipboard fallback.

## Component 1 — record the exact paste (`LastPasteTracker`)

A `@MainActor final class LastPasteTracker` singleton holding one optional
value:

```
struct LastPaste {
    let transcriptionID: UUID
    let pastedText: String      // the EXACT string sent to the field
    let targetBundleID: String? // NSWorkspace.frontmostApplication at paste time
    let posted: Bool            // CursorPaster returned .commandPosted
}
```

`TranscriptionPipeline`, at the point it pastes (after banner/trailing-space are
applied, using the real `finalPastedText` and the awaited `PasteResult`), sets
`LastPasteTracker.shared.context = LastPaste(...)`. In-memory only — the feature
targets a paste that just happened in the same session, so no SwiftData schema
change/migration is needed. Cleared is fine on restart.

This replaces the fragile `enhancedText ?? text` reconstruction with the ground
truth of what was actually typed.

## Component 2 — hotkey handler (`retranscribeLastInLayoutLanguage`)

Added to `handleGlobalShortcut`. Ordered guards (each maps to a review finding);
any failed guard → notification and return, **before** any destructive action:

1. **Re-entrancy:** a `@MainActor` bool on the manager; if a run is in flight,
   ignore the press. Global-utility actions bypass the recorder's 0.5s
   debounce, and two runs share `engine.whisperModelManager` → context torn down
   mid-transcription. (One flag.)
2. **Recorder idle:** `guard engine.recordingState == .idle` — a run during a
   live recording tears down the shared whisper context. This is *not* inherited
   from the retry action; it is explicit.
3. **Layout language:** `captureCurrentLayout()` then
   `guard let layoutLang = currentLanguageCode()` — nil when the input source
   exposes no language → "couldn't detect keyboard layout".
4. **Paste context present & posted:** `guard let lp = LastPasteTracker.shared.context, lp.posted`.
5. **Record identity & status:** `guard let last = getLastTranscription(...),
   last.id == lp.transcriptionID, last.transcriptionStatus == completed` — rejects
   canceled/failed/older records and the zero-retention case where the completed
   record was deleted and an unrelated older one would be returned.
6. **Audio exists on disk:** `guard audioFileURL` resolves and
   `FileManager.fileExists` — auto-cleanup may have removed the file; abort
   before touching the field.
7. **Model + language support:** `guard let model = currentTranscriptionModel`,
   then resolve the concrete code for the layout language using the same
   base→BCP-47 variant rules as `TranscriptionLanguagePreference.layoutOverride`
   (base match; else a `layout` / `layout-*` variant, `.sorted().first`); no
   variant → "language not supported by this model". Do **not** call
   `layoutOverride` directly — it is gated on the `MatchLanguageToKeyboardLayout`
   default and returns nil to mean "defer", which this always-on hotkey must not
   inherit. Factor the resolver into a shared function.
8. **Accessibility:** `guard AXIsProcessTrusted()` — the `Shift+Left` events need
   it; without it the arrows are dropped but the AppleScript paste still fires →
   duplication.
9. **Frontmost app unchanged:** `guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == lp.targetBundleID`.

Then:

10. **Re-transcribe (before any delete):** `let newText = try await service.retranscribeInPlace(last, language: resolvedCode, using: model)`.
    Build the service with the engine initializer (its own registry). A throw
    here (transcription or save failure) → error notification, **no keystrokes
    sent, nothing destroyed.**
11. **Verify-before-destroy:** post `Shift+Left ×lp.pastedText.count` (paced), read
    the focused element's selected text via
    `AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute)`:
    - **Selection == `lp.pastedText`** → paste `newText` (replaces selection).
      Update `LastPasteTracker` to the new text so a second layout switch can
      re-replace.
    - **Mismatch or AX read nil** (user edited, AutoSend submitted, focus/caret
      moved, web/Electron field without AX selection) → collapse the selection
      (post `Right` arrow), copy `newText` to the clipboard, notify "Couldn't
      safely replace — re-transcription copied to clipboard."

The `Shift+Left` and paste reuse the existing CGEvent pattern in
`CursorPaster.pasteFromClipboard` (private-state source, `.maskShift`, virtual
key `0x7B` for Left), paced with the same `pasteShortcutEventDelay` so events
aren't coalesced/dropped, and the paste only starts after the arrows are posted.

## Component 3 — `retranscribeInPlace` returns the text

Change its return type from `Void` to `String` (the cleaned text), so the
hotkey can paste it. `@discardableResult` for the existing History caller.
Policy (coherent across callers):

- Transcription success → returns the cleaned text.
- Deleted-record guard hit → return the freshly cleaned text anyway (persistence
  skipped; the hotkey can still replace what's on screen).
- `save()` failure → roll back the record and **throw** (History shows an error;
  the hotkey aborts before any delete, since step 10 precedes step 11).

## Wiring (required, else the feature is dead/unbindable)

- Add the case to `ShortcutAction` with `storageName`/`displayName` and to
  `ShortcutAction.globalUtilityActions` (registration/monitoring).
- Add a `ShortcutRecorder(action:)` row in `SettingsView` so it is bindable.
- Omit from `legacyKeyboardShortcutActions` (new action).
- Backup/export: add a field in `BackupTypes`/`ImportExportService`/
  `BackupImporter` so the shortcut survives export/import. (Low severity;
  runtime persistence works without it — include for completeness.)

## Error handling & fallback

Every guard failure and the verify-mismatch case are non-destructive: they emit
a notification and, where a re-transcription was produced, leave it on the
clipboard. The only paths that touch the field are (a) a verified match (replace)
and (b) never on an unverified selection.

## Testing

- Unit: the shared **language resolver** (base `en` → `en` for whisper, → `en-US`
  for an Apple model; `ru` → nil/unsupported for Apple; base match preferred).
- Unit: `retranscribeInPlace` returns the cleaned text; deleted-guard returns
  text without persisting; save-failure rolls back and throws.
- Unit: `LastPasteTracker` identity gate — mismatched `transcriptionID` ⇒ handler
  aborts (guard 5).
- The keystroke/AX select-verify path is integration-tested manually (native
  field: replace; edited field: aborts to clipboard; different app: aborts).

## Known limitations (documented, not fixed)

- AX `kAXSelectedTextAttribute` is unavailable or unreliable in some web/Electron
  fields → those always fall back to clipboard (safe, never destructive).
- `String.count` (grapheme clusters) vs a field's caret stops can differ for ZWJ
  emoji; the verify step catches the resulting mismatch → clipboard fallback.
- Autocorrect/substitutions between paste and hotkey change the on-screen text →
  verify mismatch → clipboard fallback.
- The `.idle` gate has a small tail race with the prior pipeline's async paste;
  accepted (`// ponytail:` note), the verify step still protects correctness.

## Out of scope

- Persisting paste context across app restarts (SwiftData fields/migration).
- Re-running AI enhancement.
- Replacing when AutoSend already submitted the text (unrecoverable in place →
  clipboard fallback).
