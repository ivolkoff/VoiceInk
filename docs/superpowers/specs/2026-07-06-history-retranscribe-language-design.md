# Re-transcribe History Recording in a Different Language

## Problem

A user sometimes forgets to switch the keyboard layout before dictating. With
"Match transcription language to keyboard layout" on (default), or with a
mismatched manual `SelectedLanguage`, the recording is transcribed in the wrong
language and the result is garbage. The audio is already saved, so the user
should be able to re-run recognition on that saved audio in the correct
language, directly from History.

## Decisions (locked)

- **Result:** overwrite the existing `Transcription` record in place (one record
  per audio). The old text is replaced.
- **Language selection:** a menu listing the languages supported by the current
  active transcription model.
- **Model:** the current active model (`currentTranscriptionModel`).
- **Enhancement:** raw text only. The enhancement fields are cleared; the user
  can re-run enhancement afterward with the existing "Re-enhance" button.

## Existing infrastructure reused

- `AudioPlayerView` (rendered inside `TranscriptionDetailView` only when the
  record has an audio file) already holds `@EnvironmentObject engine`,
  `@Environment(\.modelContext)`, `transcription`, `bannerState`,
  `isOperationInProgress`, and an `arrow.clockwise` re-transcribe button. This is
  the home for the new control.
- `AudioTranscriptionService` already builds its **own**
  `TranscriptionServiceRegistry` (not `engine.serviceRegistry`) and already has
  the post-processing pipeline (`TranscriptionOutputFilter.filter`, trim,
  `WhisperTextFormatter`, `WordReplacementService`,
  `applyUserCleanupPreferences`). We add an in-place variant next to
  `retranscribeAudio`.
- `reEnhanceOnly` is the reference pattern for mutating a `Transcription`
  `@Model` in place and saving on the main context.

## Architecture

### 1. Thread an explicit language through the transcribe stack

Today every transcription service reads the language itself from
`TranscriptionLanguagePreference.layoutOverride(for:) ?? UserDefaults
"SelectedLanguage"`. There is no per-call override, so a re-transcribe has
nothing to pass the chosen language to. Add one:

- `TranscriptionService.transcribe(audioURL:model:language:)` — add
  `language: String? = nil`.
- `TranscriptionServiceRegistry.transcribe(audioURL:model:language:)` — pass
  through.
- Each of the 4 file services (whisper, cloud/`CloudTranscriptionService`,
  `OpenAICompatibleTranscriptionService`, native Apple, fluidAudio): resolve as
  `language ?? (layoutOverride(for: model) ?? existing default)`. When
  `language != nil`, `layoutOverride` is bypassed — otherwise the keyboard-layout
  language would silently win over the user's pick.

Live dictation and the existing `retranscribeAudio` pass `nil` → behaviour
unchanged.

**Whisper priming prompt (critical).** The whisper initial prompt is read from
`UserDefaults "TranscriptionPrompt"`, which `WhisperPrompt` derives from
`SelectedLanguage` (a full sample sentence in that language). Feeding a
Japanese sample sentence into a Russian decode corrupts output — exactly the
failure this feature exists to fix. So in `WhisperTranscriptionService`, when
`language != nil`, use an empty prompt (`""`) instead of the
`SelectedLanguage`-derived one. (Cloud/OpenAI prompt is a soft vocabulary hint,
not a hard conditioning input — left as-is to keep the change minimal. Native
Apple and fluidAudio have no prompt.)

### 2. In-place re-transcription: `AudioTranscriptionService.retranscribeInPlace`

```
func retranscribeInPlace(
    _ transcription: Transcription,
    language: String,
    model: any TranscriptionModel
) async throws
```

Flow:

1. Guard the audio file exists (`transcription.audioFileURL` → `URL` →
   `FileManager.fileExists`); else throw `noAudioFile`.
2. Transcribe via the service's own `serviceRegistry.transcribe(audioURL:model:
   language: language)`.
3. Post-process identically to `retranscribeAudio` (filter, trim, optional
   `WhisperTextFormatter`, `WordReplacementService`,
   `applyUserCleanupPreferences`).
4. On `MainActor`, before mutating:
   `guard !transcription.isDeleted, transcription.modelContext != nil else {
   return }` — the record may have been deleted (user delete, auto-cleanup
   sweep) during the async transcription.
5. Snapshot the fields about to change, then overwrite:
   - `text = cleanedText`
   - `enhancedText = nil`, `aiEnhancementModelName = nil`, `promptName = nil`,
     `enhancementDuration = nil`, `aiRequestSystemMessage = nil`,
     `aiRequestUserMessage = nil`
   - `transcriptionModelName = model.displayName`
   - `transcriptionDuration = <measured>`
   - `transcriptionStatus = TranscriptionStatus.completed.rawValue` (in case the
     record was `failed`/`canceled`/`pending`)
   - `timestamp = Date()` — otherwise `TranscriptionAutoCleanupService`'s sweep
     deletes the record (and its audio) on the next completion or app launch
     because its timestamp is old.
6. `try modelContext.save()`. On throw, restore the snapshot and rethrow so the
   UI shows an error and no half-state persists.
7. **Do not** post `.transcriptionCompleted` — that notification drives
   `TranscriptionAutoCleanupService`, which would delete the record we just
   overwrote (immediate-delete mode) and trigger a sweep. No notification is
   needed for UI refresh: the record is the same `@Model` instance shown in the
   detail pane and the history list, so SwiftData observation updates both.

No new audio file is written; the existing `audioFileURL` is reused (the
playing `AVAudioPlayer` is undisturbed).

### 3. UI control in `AudioPlayerView`

A compact icon `Menu` button (`character.bubble`) placed next to the existing
`arrow.clockwise` button.

- **Visibility** — shown only when all hold:
  - `transcription != nil` (audio-file presence is already guaranteed here)
  - `engine.transcriptionModelManager.currentTranscriptionModel != nil`
  - `model.isMultilingualModel` (english-only models: a 1-item menu is useless)
  - `model.provider != .gemini` (Gemini ignores the language argument and always
    autodetects — the menu would be a no-op)

  Otherwise the button is hidden.
- **Items** — `TranscriptionLanguageSupport.languages(for: model)` minus the
  `"auto"` entry, sorted by display name. Built as a bare `Menu` — do **not**
  reuse `LanguageSelectionView.menuItemView`, which mutates `SelectedLanguage`
  and posts notifications as a side effect of rendering.
- **Model capture** — capture the model at menu-build time and pass it into
  `retranscribeInPlace` with the chosen language, so a mid-flight model switch
  can't run a language the executing model doesn't support.
- **Gating** — `.disabled(isOperationInProgress || engine.recordingState !=
  .idle)`. Re-transcription while a live recording holds the shared
  whisper/fluidAudio context would tear that context down mid-run; refuse until
  idle. Help text when disabled: recording in progress.
- **Confirmation** — selecting a language shows a confirm dialog ("Replaces the
  transcription text and discards any enhancement. This can't be undone.")
  before running, because it destroys `enhancedText`.
- **State/feedback** — a dedicated `@State isReTranscribingLanguage` (added to
  `isOperationInProgress`); reuse `bannerState` for success/error banners. Store
  the `Task` and cancel it in `onDisappear`.

## Data flow

language pick → confirm → `retranscribeInPlace(transcription, language, model)`
→ service's own registry → service (explicit language; whisper empty prompt) →
post-process → guard not-deleted → snapshot + overwrite `@Model` + `save()` →
SwiftData observation refreshes detail pane and list item. No notification.

## Error handling

- No model / not multilingual / gemini → control hidden.
- Recording in progress → control disabled.
- No audio file → throw `noAudioFile` → error banner; record untouched.
- Transcription/network failure → throw → error banner; record untouched.
- `save()` failure → snapshot rollback + error banner.
- Record deleted during the async run → silent no-op (guard).

## Testing

Unit tests on `retranscribeInPlace` with a fake `TranscriptionServiceRegistry`:

1. The `language` argument reaches the registry/service.
2. On success: `text` overwritten, `enhancedText == nil`, `transcriptionStatus
   == completed`, `timestamp` bumped, `transcriptionModelName` updated.
3. `save()` failure → fields rolled back to snapshot, error rethrown.
4. Deleted record (`isDeleted`/`modelContext == nil`) → no mutation, no throw.

Whisper empty-prompt behaviour (language override → prompt `""`) is covered by a
focused assertion at the seam if one exists, else noted as a manual check.

## Out of scope

- Re-running AI enhancement automatically after re-transcription.
- Re-transcribing with a model other than the current active one.
- Creating a separate history entry (the existing `arrow.clockwise` button
  already covers new-record re-transcription in the current language).
