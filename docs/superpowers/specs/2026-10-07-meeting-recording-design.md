# Meeting recording — design

Date: 2026-10-07.

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
  so existing AppRec recordings show up. Not in the SwiftData history.
- **Capture: ScreenCaptureKit, ported from AppRec** (`apprec/Sources/Recorder.swift`).
  App audio and microphone from one `SCStream`. `SCStreamConfiguration.captureMicrophone`
  needs macOS 15; the app target is 14.4, so the feature is `@available(macOS 15, *)`
  and hidden on 14.x. Core Audio process taps were rejected: no code to port,
  2–3× the code.
- **Transcription: the current VoiceInk model**, not WhisperKit. Timestamps are
  model-agnostic: VAD segments, each transcribed separately, stamped with the
  segment start.
- **Summary: the configured AI enhancement provider**, not AppRec's
  Ollama/Apple Intelligence selection. Skipped when enhancement is not
  configured.
- **UI: a sidebar section plus menu bar items.** No global hotkey.
- **Discord** is a regular app (`com.hnc.Discord`, helpers
  `com.hnc.Discord.helper[.Renderer|.GPU|.Plugin]`); the bundle-ID prefix filter
  covers all of them. Discord in a browser is recorded by picking the browser.

## Out of scope

- Speaker labels ("me / others") from the separate mic and app tracks.
- Recording several apps at once, or the whole system audio.
- Recovering a recording after a crash (an unfinished `.mov` is unreadable).
- Chunked summarization of transcripts longer than the model context.
- Porting AppRec's WhisperKit, Ollama model management, or Apple Intelligence summarizer.

## Components

New folder `VoiceInk/Meetings/`.

- **`MeetingCapture`** — ported `SCStream` setup and `TrackWriter`. Start takes
  a bundle ID, the microphone flag and the microphone device UID
  (`AudioDeviceManager.getCurrentDevice()` → UID, set as
  `microphoneCaptureDeviceID`). Filter: `content.applications` whose bundle ID
  equals the chosen one or starts with `<id>.`. Config as in AppRec: 48 kHz,
  stereo app track, mono mic track, AAC, `excludesCurrentProcessAudio = true`,
  2×2 px video at 1 fps. Stop finishes the writer and returns the temp `.mov`.
- **`MeetingStore`** — the recordings folder: list (folders containing
  `audio.m4a`, with flags for transcript and summary, sorted by creation date),
  create a folder for a new recording, move a folder to the Trash, rename a
  folder to `yyyy-MM-dd HH.mm <title>` with `2`, `3`… suffix on collision.
  Ported from AppRec's `Recorder`, minus `moveFlatRecordingsIntoFolders`.
- **`MeetingTranscriber`** — `m4a` → 16 kHz samples (`AudioProcessor.processAudioToSamples`)
  → `VadManager.segmentSpeech` with `maxSpeechDuration` ≈ 30 s → each segment
  saved as a temp WAV (`AudioProcessor.saveSamplesAsWav`) and transcribed by one
  `TranscriptionServiceRegistry` for the whole recording (model loaded once,
  `cleanup()` at the end). Each segment's text goes through
  `TranscriptionOutputFilter.filter`, `WordReplacementService.applyReplacements`
  and `TranscriptionOutputFilter.applyUserCleanupPreferences`, as in file
  transcription. Output: one line per non-empty segment, `[mm:ss] text`
  (`[h:mm:ss]` past one hour). The segment transcriber is passed in as a closure
  `(URL) async throws -> String` so assembly is testable without a model.
- **`MeetingSummarizer`** — system prompt ported from AppRec
  (`apprec/Sources/Ollama.swift:108-120`): title line `# <3–6 words>`, then
  `## TL;DR`, `## Key points` (each bullet starts with the `[mm:ss]` of its
  transcript line), `## Action items`; everything in the transcript's language
  (detected with `NLLanguageRecognizer`). Transport by provider:
  - **Ollama:** direct `POST /api/chat` with
    `options.num_ctx = min(max(chars / 3 + 2048, 4096), 32768)`, as AppRec does.
    The existing path, LLMkit `OllamaClient.generate`, sends no `num_ctx`, so a
    long transcript would be cut to Ollama's default context without an error.
  - **Others:** `AIEnhancementService.chatCompletion` with the enhancement
    provider and model.
  - Timeout ≈ 300 s; the final value is set after the manual long-recording test.
- **`MeetingRecorder`** — `@MainActor ObservableObject`: running apps for the
  picker, selected bundle ID and microphone flag (persisted in `UserDefaults`),
  recording state and start time, recordings list, per-folder sets of running
  transcriptions and summaries, last error. Runs the chain after stop.
- **UI.**
  - `ViewType.meetings` (shown on macOS 15+): app picker with icons, microphone
    toggle, Record / Stop with elapsed time, error line, list of recordings.
    Row: name, duration, buttons Transcript (opens `transcript.txt`), Summary
    (opens `summary.md`), Play, Move to Trash; a missing step shows a Create
    button, a running step shows a spinner. Context menu: Show in Finder.
  - `MenuBarView`: "Record call → [app]" submenu and "Stop recording" with an
    indicator while recording.
- **`AppDelegate.applicationShouldTerminate`** — while recording, returns
  `.terminateLater`, stops and saves the recording, then replies.
  Transcription is left for later (the row offers Create).

## Flow

1. **Start.** `MeetingRecorder.start()` → `MeetingCapture.start(...)`. One
   recording at a time.
2. **Stop.** Writer finished → `AVAssetExportSession` (`AppleM4A`) mixes both
   tracks into `~/Music/Recordings/<App> yyyy-MM-dd HH.mm.ss/audio.m4a` → temp
   `.mov` removed → list refreshed.
3. **Transcribe.** `MeetingTranscriber` → `transcript.txt` → list refreshed.
4. **Summarize** (only if `AIEnhancementService.isConfigured`).
   `MeetingSummarizer` → `summary.md` → title from the first `# ` line
   (`/ : \` and control characters replaced by spaces, trimmed of spaces and
   dots, ≤ 60 characters) → folder renamed → list refreshed.

Steps 3 and 4 can be re-run from the row at any time.

## Errors

| Case | Behavior |
|---|---|
| Screen & System Audio Recording not granted | Error text and a button opening that Privacy pane. |
| Chosen app not running at start | Error; no folder created. |
| Stream fails or the app quits mid-recording | `didStopWithError` → `stop()`: what was captured is saved. |
| No samples captured | "No audio was captured"; no folder. |
| Transcription or summary fails | Recording kept; error shown; row offers Create. |
| AI enhancement not configured | Summary step skipped silently. |
| VoiceInk quits mid-recording | Recording saved via `applicationShouldTerminate`. |
| Crash mid-recording | Recording lost (accepted). |

## Testing

Unit tests in `VoiceInkTests`, no ScreenCaptureKit or models:

- timestamp format: `[00:05]`, `[59:59]`, `[1:02:03]`;
- transcript assembly with a fake segment transcriber: empty segments dropped,
  filters applied, lines ordered by segment start;
- title from summary: `# ` line, forbidden characters, 60-character cap, no
  heading → `nil`;
- folder rename with collision suffix, and listing with and without
  transcript/summary, on a temp directory.

Manual, built app on macOS 15+:

- Discord call: other participants and the microphone audible in `audio.m4a`;
  transcript with timestamps;
- Google Meet in a browser, or Zoom;
- microphone off → only app audio;
- dictation during a recording still works;
- target app quits mid-recording → recording saved;
- VoiceInk quits mid-recording → `audio.m4a` present;
- recording longer than 30 minutes → transcript, summary, rename; time the
  summary on Ollama and set the timeout;
- permission denied → clear error and the Settings button.

New UI strings get Russian translations in `Localizable.xcstrings`.
`CHANGELOG.md` gets `## [1.82.0]` with an `### Added` entry, and
`MARKETING_VERSION` goes to 1.82.0.

## Unverified, checked during implementation

- Which Discord process plays call audio (the prefix filter covers all of them).
- Whether `SCStream` with `captureMicrophone` and VoiceInk's dictation capture
  share the microphone without either failing.
- What `SCStream` does when the captured app quits (error vs. silence).
- Ollama's default context size; the fix (`num_ctx`) does not depend on it.
