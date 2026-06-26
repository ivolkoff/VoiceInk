# Emotion Annotation for Transcribed Text

**Date:** 2026-06-26
**Status:** Draft Design
**Project:** VoiceInk

## Overview

Add emotional context annotation to transcribed text. When the user speaks with emotion (angry, whisper, excited, etc.), the transcribed output includes an annotation like `(angry voice)` — configurable per application via Power Mode.

Supports two complementary modes:
1. **Voice commands** — explicit spoken commands: `"say angrily: do it properly"` → parsed at transcription level
2. **LLM detection** — AI enhancement pipeline infers emotion from tone/context and appends annotation

Output format is defined per-application in Power Mode, so Claude Code gets `(angry voice)` while rich-text editors could use formatting.

---

## Architecture

### Components

```
Audio → Transcription → [Voice Command Parser] → LLM Enhancement (with emotion prompt) → [Output Formatter] → Paste
                              ↕                              ↕
                      VoiceCommandDetector           EmotionConfig (per Power Mode)
```

### 1. EmotionConfig (Data Model)

New model added to Power Mode, stored per application rule:

```swift
struct EmotionConfig {
    var isEnabled: Bool
    var formatTemplate: String          // e.g. "{text} ({voice:emotion})"
    var supportedEmotions: [EmotionTag] // which emotions to annotate
    var overridePrompt: String?         // custom LLM prompt for this app
}

enum EmotionTag: String, Codable {
    case angry, whisper, excited, sad, sarcastic, neutral
}
```

Integration: extends `PowerModeConfig` (per-app) with optional `EmotionConfig`.

### 2. VoiceCommandDetector

Parses raw transcription text **before** it enters the AI enhancement pipeline. Detects patterns:

- Russian: `"скажи {эмоция} голосом: {текст}"`
- English: `"say in {emotion} voice: {text}"`
- Short: `"{эмоция}: {текст}"` / `"{emotion}: {text}"`

On match:
1. Extracts the emotion tag
2. Strips the command prefix from the text
3. Passes both clean text + forced emotion tag downstream
4. If no match → emotion detection falls to LLM

**Priority:** voice command emotion overrides LLM detection.

### 3. LLM Emotion Detection

Extends `AIEnhancementService.enhance()` with an optional emotion detection mode.

When enabled, the system prompt injected into the LLM request includes:

```
<EMOTION_DETECTION>
Analyze the speaker's emotional tone. If clearly non-neutral, append the appropriate
suffix from this list after the transcribed text (no explanation):
- (angry voice) — raised voice, frustration
- (whisper) — quiet, breathy speech
- (excited) — high energy, fast pace
- (sad) — low energy, subdued
- (sarcastic) — ironic tone, exaggerated intonation
If the tone is neutral, output only the text without any suffix.
</EMOTION_DETECTION>
```

Modifications to `AIEnhancementService`:
- `enhance()` gets an optional `emotionOverride: EmotionTag?` parameter
- System prompt builder appends `EMOTION_DETECTION` section when `isEmotionEnabled` for the active Power Mode
- If `emotionOverride` is set (from voice command), skip LLM emotion detection entirely

### 4. OutputFormatter

New stage in `AIEnhancementOutputFilter` (or chained after it):

- Receives: raw LLM output (text + optional emotion suffix), emotion tag (if detected/forced), `EmotionConfig` for current app
- Applies format template from Power Mode:
  - Template `"{text} ({voice:emotion})"` with angry → `"do it properly (angry voice)"`
  - Template `"[{emotion}] {text}"` → `"[angry] do it properly"`
  - Template `"{text}"` (disabled) → passthrough
- Strips raw emotion suffix from LLM output and re-applies through configured template

### 5. Power Mode UI

New section in Power Mode configuration for each app:

- Toggle: "Emotion Annotation"
- Format picker: preset templates (suffix, prefix, plain) or custom
- Emotion selection: which emotions to detect (checkboxes)

---

## Data Flow

```
1. User dictates text (possibly with emotional tone or explicit command)
2. Transcription produces raw text
3. VoiceCommandDetector parses transcription:
   a. Match found → extract EmotionTag + clean text, skip to step 5
   b. No match → pass raw text to step 4
4. (if enhancement enabled) LLM enhancement with emotion detection prompt
   a. LLM returns enhanced text + optional emotion suffix
   b. Emotion suffix parsed from output
5. OutputFormatter applies Power Mode format template
6. Formatted text pasted/inserted into target application
```

---

## Existing Code Integration

### Files to modify:

| File | Change |
|------|--------|
| `PowerMode/PowerModeConfig.swift` | Add optional `EmotionConfig` |
| `PowerMode/PowerModeConfigView.swift` | Add emotion annotation UI section |
| `Services/AIEnhancement/AIEnhancementService.swift` | Extend `enhance()` with emotion prompt + emotionOverride |
| `Services/AIEnhancement/AIEnhancementOutputFilter.swift` | Add emotion template formatting |
| `Services/AIEnhancement/AIService.swift` | (minor) — no change expected |

### Files to create:

| File | Purpose |
|------|---------|
| `Services/EmotionDetection/VoiceCommandDetector.swift` | Pattern matching for voice commands |
| `Models/EmotionModels.swift` | `EmotionTag`, `EmotionConfig` types |

---

## Future Considerations (Not in v1)

- **Audio-level emotion analysis** — Core ML model analyzing tone/volume/pitch before transcription
- **Rich text output** — for apps supporting attributed text (italic for whisper, bold for angry)
- **On-device ML emotion classifier** — whisper.cpp extension for emotion embedding
- **User-customizable emotion tags** — add custom labels beyond the predefined set
