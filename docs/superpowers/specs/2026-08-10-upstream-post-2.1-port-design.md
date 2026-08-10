# Port three upstream changes from post-v2.1 `Beingpax/VoiceInk`

## Problem

Upstream shipped v2.1 (2026-07-27) and 47 further commits on `main`. Most of it
is either experimental (Cohere Transcribe / `transcribe.cpp`), architecturally
unreachable from this fork (anything sitting on the v2 Modes system), already
present here, or upstream-specific product decisions (onboarding rework, GitHub
star prompt). Three changes are worth taking. They are independent of each other
and land as three separate commits.

The wider audit of post-2.1 upstream work — including what was rejected and why —
is summarized in the Appendix.

## Decisions (locked)

- **In scope:** audio-meter push→pull, Unicode-aware word boundaries, AI model
  catalog refresh.
- **Out of scope:** VoiceInk Refine (local MLX enhancement), Cohere Transcribe,
  license/keychain hardening (licensing is stripped from this fork), Sparkle
  update UI (Sparkle is commented out here), onboarding changes, popover
  appearance (depends on `AppAppearancePreference`, which this fork lacks).
- **Not copied verbatim:** upstream's `RecordingPerformanceDiagnostics`
  instrumentation, which rides along in the same commit as the audio-meter
  change, is left out.

---

## Component 1 — audio meter: push → pull

### Current behavior

`Recorder` (`VoiceInk/Recorder.swift`) runs a `DispatchSourceTimer` every 17 ms
on a dedicated queue, computes a normalized + EMA-smoothed `AudioMeter`, and
hops to the main queue to assign it to `@Published var audioMeter`.

`audioMeter` is the **only** `@Published` property on `Recorder`. Both
`MiniRecorderView` and `NotchRecorderView` hold `@ObservedObject var recorder`,
so every assignment invalidates each of those views in full — roughly 60 times
per second — to animate 15 bars inside `AudioVisualizer`, which already redraws
itself on its own `TimelineView(.animation)` clock.

### Change

**`VoiceInk/Recorder.swift`**

- Delete `@Published var audioMeter`, `audioMeterUpdateTimer`, `audioMeterQueue`,
  and `startAudioMeterTimer(for:)`, plus their call sites in `startRecording`,
  `stopRecording`, and `deinit`.
- Convert `updateAudioMeter(recorder:)` into
  `func audioMeterSnapshot() -> AudioMeter`: same dB normalization and same
  `0.6/0.4` EMA under `smoothedValuesLock`, but reading `self.recorder` and
  returning the value instead of dispatching to the main queue. Returns
  `AudioMeter(averagePower: 0, peakPower: 0)` when `recorder` is nil — which is
  the state `stopRecording` already leaves behind, since it sets `recorder = nil`.
- Add `private func resetAudioMeter()` that zeroes `smoothedAverage` /
  `smoothedPeak` under the lock, and call it where `stopRecording` currently
  zeroes them inline.

`Recorder` is already `@MainActor`, so `audioMeterSnapshot()` is main-actor
isolated and callable synchronously from a SwiftUI `body`.

**`VoiceInk/Views/Recorder/AudioVisualizerView.swift`**

- `AudioVisualizer` takes `let audioMeterProvider: () -> AudioMeter` instead of
  `let audioMeter: AudioMeter` (initializer parameter marked `@escaping`).
- `body` calls `audioMeterProvider()` once inside the `TimelineView` closure and
  passes the value into `barHeight(for:at:audioMeter:)`.

**`VoiceInk/Views/Recorder/RecorderComponents.swift`**

- `RecorderStatusDisplay` forwards the same `() -> AudioMeter` instead of a value.

**`VoiceInk/Views/Recorder/MiniRecorderView.swift`** and
**`VoiceInk/Views/Recorder/NotchRecorderView.swift`**

- Pass `recorder.audioMeterSnapshot` where they currently pass
  `recorder.audioMeter`.

After this, `Recorder` publishes nothing, so `@ObservedObject var recorder` in
both recorder views stops invalidating entirely.

### Accepted trade-offs

- **EMA advances inside the render pass.** `audioMeterSnapshot()` mutates
  `smoothedAverage` / `smoothedPeak` while SwiftUI evaluates `body`. These are
  plain class properties, not SwiftUI state, so this does not trigger
  "Modifying state during view update"; it is still a deliberate compromise, and
  it matches upstream.
- **Smoothing only advances while visible.** If the visualizer is off-screen the
  EMA does not tick, so the meter catches up over a couple of frames when it
  reappears. Visually irrelevant at 60 Hz.
- **Two simultaneous visualizers would double-advance the EMA** per frame,
  making smoothing effectively faster. In practice only one recorder (mini or
  notch) is on screen at a time.

### Verification

Record with each recorder style: bars track speech as before and drop to the
floor on stop. Under Instruments (SwiftUI / View Body), `MiniRecorderView` and
`NotchRecorderView` bodies no longer re-evaluate at ~60 Hz during recording;
only `AudioVisualizer` does.

---

## Component 2 — Unicode-aware word boundaries in replacements

### Current behavior

`VoiceInk/Transcription/Processing/WordReplacementService.swift:45` builds

```
(?<![\p{L}\p{N}])<trigger>(?![\p{L}\p{N}])
```

This already fixes the original upstream bug (an ASCII-only `[a-zA-Z0-9]` class,
which treated every Cyrillic/Greek/German letter as a word boundary and let short
rules match inside longer words). Two gaps remain, both fixed upstream in
`491f581`.

### Change

Replace the inline character class with a named constant:

```swift
let wordChar = "[[\\p{L}\\p{M}\\p{N}]-[\\p{scx=Han}\\p{scx=Hiragana}\\p{scx=Katakana}\\p{scx=Hangul}\\p{scx=Thai}]]"
let pattern = "(?<!\(wordChar))\(escaped)(?!\(wordChar))"
```

Two effects:

- **`\p{M}`** treats combining marks as part of a word. Without it, a rule can
  fire inside a decomposed (NFD) word and corrupt it — verified against
  `NSRegularExpression`: rule `ca → КОФЕ` on `"uống cà phê"` (where `à` is
  `a` + U+0300) currently yields `"uống КОФЀ phê"`, and rule `мои → МОИ` fires on
  `"мой"` (`и` + U+0306).
- **Subtracting the non-spaced scripts** via `Script_Extensions` lets a Latin
  trigger flush against CJK/Thai text still match — rule
  `voiceink → VoiceInk` on `"我用voiceink录音"` currently does not fire, because the
  ideograph counts as `\p{L}`. `scx` rather than `sc` so shared marks such as the
  prolonged sound mark U+30FC (Script=Common) stay exempt. This mirrors the
  exemptions `usesWordBoundaries(for:)` already applies when deciding between the
  regex path and the substring fallback.

Everything else in the method is untouched — in particular
`NSRegularExpression.escapedTemplate(for:)`, which this fork has and upstream
does not, and which protects `$` / `\` in the replacement text.

### Testing

New `VoiceInkTests/WordReplacementServiceTests.swift`, swift-testing style to
match the existing suite. `applyReplacements(to:using:)` needs a `ModelContext`,
so each test builds an in-memory container:

```swift
let container = try ModelContainer(
    for: WordReplacement.self,
    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
)
```

inserts the rules under test, and calls the service on a `ModelContext(container)`.
Cases:

1. NFD diacritic after the trigger — `ca → КОФЕ` leaves `"uống cà phê"` unchanged.
2. NFD diacritic as the following character — `мои → МОИ` leaves `"это мой текст"`
   unchanged.
3. Latin trigger between ideographs — `voiceink → VoiceInk` rewrites
   `"我用voiceink录音"`.
4. Whole-word match still fires and a substring match still does not —
   `мир → MIR` on `"мираж мир"` touches only the standalone word.
5. Punctuation-ending trigger still works — `c++ → C plus plus`.
6. Replacement text containing `$` and `\` is inserted literally (guards the
   `escapedTemplate` behavior against regressions from this edit).

---

## Component 3 — AI model catalog refresh

### Constraint found during design

`AIEnhancementService.swift:282` routes the Anthropic provider through
`AnthropicLLMClient.chatCompletion` (LLMkit) and never passes a `thinking`
parameter; `ReasoningConfig.getReasoningParameter` returns `nil` for Anthropic.

On Claude Opus 5 and Claude Sonnet 5, **omitting `thinking` runs adaptive
thinking** — the opposite of Opus 4.8 / 4.7, where omitting it means no thinking.
Adding those two model IDs would therefore make every transcript cleanup a
reasoning request: extra latency, extra tokens, and a truncation risk, because
`max_tokens` bounds thinking and response text together.

**Decision:** add `claude-opus-4-8` only. Revisit Sonnet 5 / Opus 5 when the
Anthropic call path can send `thinking: {"type": "disabled"}`.

### Change

**`VoiceInk/Services/AIEnhancement/AIService.swift`** — `availableModels`:

- `.openAI`: prepend `gpt-5.6-luna`, `gpt-5.6-terra`, `gpt-5.6-sol`.
- `.gemini`: add `gemini-3.6-flash` and `gemini-3.5-flash-lite`.
- `.anthropic`: add `claude-opus-4-8` at the top. (The list currently holds
  4.7 / 4.6 / sonnet-4.6 / 4.5 / sonnet-4.5 / haiku-4.5 — no retired ID is
  present, so nothing needs removing.)
- `.mistral`: add `mistral-medium-3-5` and `mistral-small-2603`.

Nothing else is removed. `defaultModel` is left as-is for every provider: the
active model comes from `selectedModels` in `UserDefaults`, so changing a default
only affects a fresh install while creating a divergence from the configuration
already in use here.

**`VoiceInk/Services/AIEnhancement/ReasoningConfig.swift`:**

- `openAINoneReasoningModels`: add the three `gpt-5.6-*` IDs.
- `geminiMinimalReasoningModels`: add `gemini-3.6-flash` and
  `gemini-3.5-flash-lite`.

### Explicitly not done

Upstream also moved Gemini from the OpenAI-compatible endpoint
(`/v1beta/openai/chat/completions`) to the Interactions API (`/v1/interactions`)
via a new `GeminiLLMClient` and `GeminiThinkingLevel` in LLMkit. That needs an
LLMkit revision bump and a rewrite of the Gemini reasoning path; it is a separate
piece of work and is not part of this change.

### Verification

Model IDs beyond the Anthropic ones were taken from upstream commits and cannot
be verified from this repository. After the change, exercise "Test connection"
(or one enhancement round-trip) per touched provider with a real key, and drop
any ID the provider rejects.

---

## Out of scope

- VoiceInk Refine — local MLX-based enhancement (Apple silicon, ≥16 GB, a
  multi-gigabyte HuggingFace download). This fork already has Ollama and Local
  CLI providers for local enhancement.
- Cohere Transcribe and the `transcribe.cpp` local engine — upstream keeps them
  behind an experimental flag.
- License / keychain accessibility hardening — licensing is stripped here.
- Sparkle update UI on the dashboard — Sparkle is commented out in this fork.
- Onboarding rework, GitHub star prompt, popover appearance following the app
  theme, `TriggerInstalledApps` symlink fix, mode transcription-model
  availability — either upstream product decisions or code paths this fork does
  not have (v2 Modes vs. PowerMode).
- Renaming the AI prompt tag to `TRANSCRIPT` — already the case here.

## Appendix — post-2.1 upstream audit

Reviewed: v2.1 release notes plus the 47 commits in `v2.1..upstream/main`.
Coverage of v2.0 and earlier lives in `docs/voiceink-v2-feature-diff.md`.

| Upstream change | Verdict |
|---|---|
| `perf: reduce recording UI contention` (`576ed67`) | **Port** — minus the diagnostics scaffolding (Component 1) |
| Unicode word boundaries (`491f581`) | **Port** — as a `wordChar` constant only (Component 2) |
| AI provider/model updates (`6afbd81`, `af1c1bb`) | **Port** — model lists only, no Gemini API migration (Component 3) |
| VoiceInk Refine (`cc9b597` + follow-ups) | Skip — duplicates existing Ollama / Local CLI at high cost |
| Cohere Transcribe (`8931da5` + follow-ups) | Skip — upstream-experimental |
| License/keychain resilience (`3d77058`, `7ee83d2`) | Skip — no licensing in this fork |
| Sparkle updates from dashboard (`75dc8a0`) | Skip — Sparkle disabled here |
| Onboarding trim + star prompt (`501681a`, `b4feaee`, …) | Skip — upstream product decision |
| Popovers follow app appearance (`cd2da7b`) | Skip — needs `AppAppearancePreference` |
| App discovery symlink fix (`f1fe3db`) | N/A — `TriggerInstalledApps` does not exist here |
| Enforce mode model availability (`ed7e163`) | N/A — v2 Modes, not PowerMode |
| Rename prompt tag to `TRANSCRIPT` (`ec61032`) | N/A — already done here |
| macOS release workflow (`a319571`) | Skip — upstream CI |
