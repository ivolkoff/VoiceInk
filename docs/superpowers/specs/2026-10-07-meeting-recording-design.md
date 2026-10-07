# Meeting recording — design

Date: 2026-10-07. Revised the same day after review.

## Problem

The user records calls (Zoom, Teams, Google Meet in a browser, Discord) with a
separate app, AppRec (`~/WebDev/apprec`): it captures one app's audio plus the
microphone, writes a timestamped transcript and a summary, and names the
recording folder after the summary title. The user wants this inside VoiceInk.

VoiceInk already has everything after capture: transcription models
(`TranscriptionServiceRegistry`), audio decoding (`AudioProcessor`), VAD
(FluidAudio `VadManager`), AI providers including Ollama
(`AIEnhancementService.chatCompletion`). The missing part is capturing a chosen
app's audio and the microphone, and a place to list the recordings.

## Decisions (locked)

- **Scenario: whole calls.** Tens of minutes, transcript and summary after
  stop. Not a dictation source, nothing is pasted.
- **Storage: folders on disk, AppRec layout.** `~/Music/Recordings/<name>/`
  with `audio.m4a`, `transcript.txt`, `summary.md`. The same folder AppRec uses,
  so existing AppRec recordings show up. Not in the SwiftData history. The app
  is not sandboxed (`VoiceInk.entitlements`), no new entitlements or Info.plist
  keys are needed.
- **Capture: ScreenCaptureKit, ported from AppRec** (`apprec/Sources/Recorder.swift`).
  App audio and microphone from one `SCStream`. `SCStreamConfiguration.captureMicrophone`
  needs macOS 15; the app target is 14.4. No type carries `@available` (a
  stored property of a potentially unavailable type does not compile):
  `MeetingCapture` wraps only the macOS 15 calls (`captureMicrophone`,
  `microphoneCaptureDeviceID`, the `.microphone` output, `export(to:as:)`) in
  `if #available(macOS 15, *)`, and the UI is hidden behind the same check.
  Core Audio process taps were rejected: no code to port, 2–3× the code.
- **Transcription: the current VoiceInk model**, not WhisperKit. Language from
  a **picker on the Meetings screen**: Auto (default) or a fixed language,
  persisted. Auto means *detect, then correct* (see `MeetingTranscriber`). Model
  and language choice are captured once at the start of the step and passed
  explicitly, so the keyboard-layout override, `SelectedLanguage` and a Power
  Mode switch during the run do not apply. Timestamps are model-agnostic: VAD
  segments merged into chunks of up to 30 s, each transcribed separately,
  stamped with the chunk start.
- **Summary: the AI enhancement provider.** Automatic after transcription only
  when `isEnhancementEnabled && isConfigured`; the manual Create button needs
  only `isConfigured`. Without the toggle check a saved cloud API key would send
  every call transcript to the cloud with enhancement switched off.
- **UI: a sidebar section plus menu bar items.** No global hotkey.
- **Discord** is a regular app (`com.hnc.Discord`, helpers
  `com.hnc.Discord.helper[.Renderer|.GPU|.Plugin]`); the bundle-ID prefix filter
  covers all of them. Chrome helpers (`com.google.Chrome.helper*`) are covered
  the same way.

## Out of scope

- Speaker labels ("me / others") from the separate mic and app tracks.
- Recording several apps at once, or the whole system audio.
- Recovering a recording after a crash (an unfinished `.mov` is unreadable).
- Chunked summarization of transcripts longer than the model context.
- Porting AppRec's WhisperKit, Ollama model management, or Apple Intelligence summarizer.
- An in-app player: Play opens `audio.m4a` in the default app.

## Components

New folder `VoiceInk/Meetings/`.

- **`MeetingCapture`** — ported `SCStream` setup
  and `TrackWriter`. Start takes a bundle ID, the microphone flag and an
  optional microphone UID. The UID comes from
  `AudioDeviceManager.availableDevices` matched by `getCurrentDevice()`
  (`getDeviceUID` is private); a `0` device or no match leaves
  `microphoneCaptureDeviceID` unset (system default). Filter:
  `content.applications` whose bundle ID equals the chosen one or starts with
  `<id>.`. Config as in AppRec: 48 kHz, stereo app track, mono mic track, AAC,
  `excludesCurrentProcessAudio = true`, 2×2 px video at 1 fps. Stop finishes
  the writer and returns the temp `.mov`.
- **`MeetingStore`** — the recordings folder: list (folders containing
  `audio.m4a`, with flags for transcript and summary, duration from the asset,
  sorted by creation date), create a folder for a new recording, move a folder
  to the Trash, rename a folder to `yyyy-MM-dd HH.mm <title>` with `2`, `3`…
  suffix on collision. Folder names use the recording **start** time and a
  `DateFormatter` with `en_US_POSIX`. After the mixdown the folder's
  `creationDate` is set to `startedAt` (`FileManager.setAttributes`); a later
  rename takes the date from the folder's `creationDate` (for AppRec folders,
  their own creation time). Ported from AppRec's `Recorder`, minus
  `moveFlatRecordingsIntoFolders`.
- **`MeetingTranscriber`** — one transcription at a time across the app (a
  second registry would load a second model copy); further requests wait in a
  FIFO queue.
  1. `m4a` → 16 kHz samples (`AudioProcessor.processAudioToSamples`).
  2. `VadManager.segmentSpeech` with threshold 0.7 (as
     `FluidAudioTranscriptionService`) and `minSpeechDuration` 0.5 s; adjacent
     segments merged while the merged span stays ≤ 30 s; the chunk keeps the
     first segment's start. VAD alone closes a segment on every 0.75 s pause,
     which would give hundreds of 2–10 s pieces per hour.
  3. Each chunk → temp WAV (`AudioProcessor.saveSamplesAsWav`) → one
     `TranscriptionServiceRegistry` for the whole run →
     `transcribe(audioURL:model:language:)` with the captured model and the
     current language (below) → temp WAV deleted at once. A chunk transcribed
     again gets its WAV re-created from the samples, still in memory; its text
     replaces the old one by chunk index.
     - **Fixed language:** run through
       `TranscriptionLanguageSupport.validLanguageOrFallback` for the captured
       model at the start of the step (the saved choice may not fit a model
       switched since), then passed for every chunk. The picker lists
       `TranscriptionLanguageSupport.languages(for:)` of the current model.
     - **Auto, detect then correct** (models whose list has `auto`):
       1. Pass 1: every chunk with `auto`. Engines already accept it:
          whisper.cpp detects the language itself (`LibWhisper.swift:39-46`),
          Parakeet V3/Ultra decode without a hint (the hint only replaces
          tokens in the wrong script, `TdtDecoderV3.tokenLanguageFilter`),
          cloud providers get no language field
          (`CloudTranscriptionService.swift:102-107`).
       2. Dominant language `L`: `NLLanguageRecognizer.languageHypotheses(withMaximum:)`
          over the whole filtered pass-1 text. Needs ≥ 200 characters,
          probability ≥ 0.8, and `L` in the model's list; otherwise pass 1 is
          final (short or bilingual call).
       3. Pass 2 with `L`: chunks whose own detected language is not `L`; for
          Parakeet every chunk, since stray wrong-script tokens do not change
          a chunk's detected language and a pass is cheap. A chunk that is
          *confidently another language* (≥ 100 characters, probability ≥ 0.8)
          is kept: a real switch, e.g. a guest speaking English.
       Deciding on the whole pass rather than the first chunks keeps an
       English greeting or music at the start from setting the language of
       the whole call.
     - **Code mapping NL → VoiceInk:** `zh-Hans`/`zh-Hant` → `zh`, `nb` → `no`,
       otherwise the part before `-`. A language NL cannot name is never `L`.
     - **Models without `auto`:** English-only models get `en` from
       `validLanguageOrFallback`; Apple Native gets `SelectedLanguage` if it is
       in the model's list (stored as BCP-47 for it), else the fallback.
     - **Run language:** fixed, `L`, or for a final pass 1,
       `NLLanguageRecognizer` on the whole transcript. The status line shows
       the language used.
  4. Text per chunk: `TranscriptionOutputFilter.filter`, then
     `WordReplacementService.applyReplacements` (needs a `ModelContext`), then
     newlines collapsed to spaces and trimmed. `WhisperTextFormatter` and
     `applyUserCleanupPreferences` are not applied: the formatter inserts line
     breaks and breaks one-line-per-chunk; punctuation removal and lowercase are
     dictation preferences.
  5. Output: one line per non-empty chunk, `[mm:ss] text` (`[h:mm:ss]` past one
     hour) → `transcript.txt`.
  - **Whisper keeps one context per run.** Today `WhisperTranscriptionService`
    releases a context it created itself after every call
    (`WhisperTranscriptionService.swift:92-96`), and the shared context is
    unloaded after each dictation. The service gets a flag that keeps its own
    context loaded; `TranscriptionServiceRegistry.cleanup()` (FluidAudio only
    today) also releases it, but only a context the service created itself:
    the same `!==` check against the shared context as
    `WhisperTranscriptionService.swift:93`, so a running dictation keeps its
    model.
  - **Cloud models:** a streaming-only provider (Cartesia,
    `CloudTranscriptionService.swift:64-65`) fails the step up front with a
    clear message. A chunk failing with `apiRequestFailed` or `networkError` is
    retried after 5, 20 and 60 s; after that the step fails and no partial
    `transcript.txt` is written. `networkError` also covers decoding and
    timeout errors (`CloudTranscriptionService.swift:81-82, 156-157`); retrying
    those is accepted, the retries are bounded.
  - The engines' own VAD still runs inside each chunk: FluidAudio on chunks
    ≥ 20 s when `IsVADEnabled` (`FluidAudioTranscriptionService.swift:131`),
    Whisper always (`LibWhisper.swift:72-85`). It only trims silence and is
    left as is.
- **`MeetingSummarizer`** — skipped when the transcript is empty. System prompt
  ported from AppRec (`apprec/Sources/Ollama.swift:108-120`): title line
  `# <3–6 words>`, then `## TL;DR`, `## Key points` (each bullet starts with the
  `[mm:ss]` of its transcript line), `## Action items`; everything in the run's
  language from `MeetingTranscriber`; for a transcript made earlier (manual
  Create), `NLLanguageRecognizer` on `transcript.txt`. The code (base or
  BCP-47) becomes an English language name through `Locale`, as AppRec does.
  Provider and
  model are captured at the start of the step. Transport:
  - **Ollama:** direct `POST <AIProvider.ollama.baseURL>/api/chat` with model
    `aiService.currentModel` (as `editSelection` does), `"think": false`,
    `stream: false`, `options.num_ctx = min(max(chars / 3 + 2048, 4096), 32768)`
    as AppRec does. The existing path, LLMkit `OllamaClient.generate`, sends no
    `num_ctx`, so a long transcript would be cut to Ollama's default context
    without an error. Above the 32768 cap (~90k characters) the transcript is
    still cut; this is logged.
  - **Others:** `AIEnhancementService.chatCompletion` with the captured
    provider and model.
  - The reply goes through `AIEnhancementOutputFilter.filter`.
  - Timeout ≈ 300 s; the final value is set after the manual long-recording test.
- **`MeetingRecorder`** — `@MainActor ObservableObject`, created in
  `VoiceInkApp.init` as a `@StateObject` next to the other services, handed to
  `AppDelegate` like them and to `ContentView` and `MenuBarView` through the
  environment. Holds: running apps for the picker (refreshed when the section
  appears and on `NSWorkspace` launch/terminate notifications), selected bundle
  ID, microphone flag and language (persisted in `UserDefaults`), state
  (`idle` / `recording(startedAt)` / `saving`), recordings list, per-folder
  step state (queued / transcribing / summarizing), last error. Runs the chain
  after stop.
- **UI.**
  - `ViewType.meetings`, wired into `visibleViewTypes`, `detailView` and
    `navigateToDestination` in `ContentView.swift`, visible on macOS 15+: app
    picker with icons, microphone toggle, language picker, Record / Stop with
    elapsed time, error line, list of recordings. Row: name, duration, buttons
    Transcript (opens `transcript.txt`), Summary (opens `summary.md`), Play
    (opens `audio.m4a`), Move to Trash; a missing step shows a Create button, a
    queued transcription shows "Queued", a running step shows a spinner.
    Context menu: Show in Finder.
  - `MenuBarView`: "Record call" submenu listing running apps, and
    "Stop recording — <App>" in its place while recording. No menu bar icon
    change.
- **`AppDelegate.applicationShouldTerminate`** — while the state is
  `recording` or `saving`, returns `.terminateLater`, stops the recording if
  needed, awaits the save (writer finish and mixdown), and calls
  `reply(toApplicationShouldTerminate: true)` in a `defer`, so an export error
  does not block quitting. All quit paths go through `NSApp.terminate`.
  Transcription is left for later (the row offers Create).

## Flow

1. **Start.** `MeetingRecorder.start()` → `MeetingCapture.start(...)` → state
   `recording(startedAt)`. One recording at a time.
2. **Stop.** State `saving` → writer finished → `AVAssetExportSession`
   (`AppleM4A`) mixes both tracks into
   `~/Music/Recordings/<App> yyyy-MM-dd HH.mm.ss/audio.m4a` (start time) → temp
   `.mov` removed → state `idle` → list refreshed.
3. **Transcribe.** `MeetingTranscriber` → `transcript.txt` → list refreshed.
4. **Summarize** (automatic only if `isEnhancementEnabled && isConfigured`).
   `MeetingSummarizer` → `summary.md` → title from the first line that starts
   with `# ` (`/ : \` and control characters replaced by spaces, trimmed of
   spaces and dots, ≤ 60 characters) → folder renamed → list refreshed.

Steps 3 and 4 can be re-run from the row at any time.

## Errors

| Case | Behavior |
|---|---|
| Screen & System Audio Recording not granted | Error text and a button opening that Privacy pane (the URL already used in `PermissionsView.swift`). |
| Chosen app not running at start | Error; no folder created. |
| Stream fails or the app quits mid-recording | `didStopWithError` → `stop()`: what was captured is saved. |
| No samples captured | "No audio was captured"; no folder. |
| Streaming-only transcription model | Step fails up front with a message naming the model. |
| Chunk fails after 3 retries, or any other transcription error | Step fails; no partial `transcript.txt`; row offers Create. |
| Summary fails | Transcript kept; error shown; row offers Create. |
| Enhancement off or not configured | Automatic summary skipped silently. |
| Empty transcript | Summary not requested; folder not renamed. |
| VoiceInk quits while recording or saving | Recording saved via `applicationShouldTerminate`. |
| Crash mid-recording | Recording lost (accepted). |

## Testing

Unit tests in `VoiceInkTests`, no ScreenCaptureKit, VAD or models:

- timestamp format: `[00:05]`, `[59:59]`, `[1:02:03]`;
- chunk merging: segments `[(start, end)]` → chunks ≤ 30 s, chunk start = first
  segment start, a single segment longer than 30 s stays alone;
- dominant language as a pure function (pass-1 text, model's language list →
  `L` or `nil`): under 200 characters → `nil`; Russian text → `ru`; mixed
  Russian/English below 0.8 → `nil`; a language the model lacks → `nil`;
- pass-2 selection as a pure function (chunk texts, `L`, Parakeet or not →
  chunk indices): a short English chunk in Russian text is selected; a long
  confident English chunk is kept; Parakeet selects all but confident others;
- NL code mapping: `zh-Hans` → `zh`, `nb` → `no`, `pt-BR` → `pt`;
- transcript assembly as a pure function `[(start, text)] → String`: empty
  texts dropped, newlines collapsed, lines ordered by start;
- title from summary: first `# ` line, forbidden characters, 60-character cap,
  no heading → `nil`;
- folder rename with collision suffix, and listing with and without
  transcript/summary, on a temp directory.

Manual, built app (only macOS 27 is available here; the macOS 15 path is not
tested):

- Discord call: other participants and the microphone audible in `audio.m4a`;
  transcript with timestamps;
- Google Meet in Chrome and in Safari, or Zoom;
- microphone off → only app audio; a non-default microphone selected in
  VoiceInk → that microphone is recorded;
- dictation during a recording still works;
- language on Auto: a Russian call after an English dictation → Russian; a
  Russian call opening with English greetings or music → Russian throughout;
  an English call → English; a call switching between Russian and English →
  pass 1 kept;
- language fixed to Russian → every chunk in Russian; the saved language not
  supported by a newly selected model → fallback used and shown in the status
  line;
- target app quits mid-recording → recording saved;
- VoiceInk quits mid-recording, and right after Stop → `audio.m4a` present;
- recording longer than 30 minutes with Parakeet and with a local Whisper model
  → transcript, summary, rename; time the summary on Ollama and set the
  timeout;
- enhancement switched off with a cloud key saved → no automatic summary;
- permission denied → clear error and the Settings button.

New UI strings get Russian translations in `Localizable.xcstrings`.
`CHANGELOG.md` gets `## [1.82.0]` with an `### Added` entry, and
`MARKETING_VERSION` goes to 1.82.0.

## Unverified, checked during implementation

- Which Discord process plays call audio (the prefix filter covers all of them).
- Safari: page audio is played by `com.apple.WebKit.GPU`, which the
  `com.apple.Safari.` prefix does not match; Safari may record silence. If so,
  the filter adds WebKit processes for Safari.
- `microphoneCaptureDeviceID`: AppRec never sets it.
- Whether `SCStream` with `captureMicrophone` and VoiceInk's dictation capture
  share the microphone without either failing.
- What `SCStream` does when the captured app quits (error vs. silence).
- Peak memory for a one-hour recording (estimate ~1.1 GB during sample
  conversion).
- Language thresholds (200 characters and 0.8 for `L`; 100 characters and 0.8
  for a confident other chunk): tuned on real calls.
- Deepgram on Auto: VoiceInk sends no `language` and no `detect_language`
  (LLMkit `DeepgramClient.swift:42-44`); if Deepgram then assumes English,
  pass 1 of a Russian call is English garbage and `L` becomes `en`. If
  confirmed, Deepgram on Auto sends `detect_language=true`, or the Meetings
  screen asks for a fixed language with Deepgram.
