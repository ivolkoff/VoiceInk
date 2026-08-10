# Post-v2.1 Upstream Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port three independent changes from upstream `Beingpax/VoiceInk` post-v2.1 into this fork: Unicode-aware word-replacement boundaries, an AI model catalog refresh, and a push→pull rewrite of the recorder audio meter.

**Architecture:** Three unrelated commits on one branch. Task 1 is a one-line regex change backed by new unit tests. Task 2 edits two static model lists. Task 3 removes the `@Published` audio meter and its 17 ms timer from `Recorder`, replacing it with a snapshot function that `AudioVisualizer` pulls from inside its existing `TimelineView` clock.

**Tech Stack:** Swift 5, SwiftUI, SwiftData, swift-testing (`import Testing`, `@Test`, `#expect`), Xcode project (`VoiceInk.xcodeproj`, scheme `VoiceInk`), whisper.cpp via a locally built XCFramework.

**Spec:** `docs/superpowers/specs/2026-08-10-upstream-post-2.1-port-design.md`

## Global Constraints

- Branch: `feat/upstream-post-2.1-port` (already created; the spec commit `ba7cc1c` is its tip).
- Commit messages: plain conventional-commit style. Never add "Generated with Claude Code", `Co-Authored-By: Claude`, or any other AI attribution.
- Do not copy upstream's `RecordingPerformanceDiagnostics` instrumentation, which rides along in the same upstream commit as Task 3.
- Do not remove existing model IDs from `availableModels`; only add.
- Do not change any provider's `defaultModel`.
- Do not touch `NSRegularExpression.escapedTemplate(for:)` usage in `WordReplacementService` — it is a fork-only protection that upstream lacks.
- Match surrounding code style: 4-space indent, no trailing whitespace, comments only where they state a constraint the code cannot show.

---

## Task 0: Restore the build prerequisite

The project does not currently compile on this machine: `VoiceInk.xcodeproj` links `whisper.xcframework` from `$(HOME)/VoiceInk-Dependencies/whisper.cpp/build-apple/whisper.xcframework`, and that directory does not exist. Every build fails at `LibWhisper.swift:5` with `#error("Unable to import whisper module...")`. No later task can be verified until this is fixed.

**Files:** none (external dependency only).

**Interfaces:**
- Consumes: nothing.
- Produces: a working `xcodebuild` for every later task.

- [ ] **Step 1: Confirm the dependency is missing**

Run: `ls -d ~/VoiceInk-Dependencies/whisper.cpp/build-apple/whisper.xcframework`
Expected: `No such file or directory`. If it *does* exist, skip to Step 3.

- [ ] **Step 2: Build the whisper XCFramework**

The repo's Makefile clones whisper.cpp into `~/VoiceInk-Dependencies` and builds the XCFramework at the exact path the Xcode project expects. This takes several minutes and needs `cmake` on `PATH`.

```bash
make whisper
```

Expected: the command finishes without error and `~/VoiceInk-Dependencies/whisper.cpp/build-apple/whisper.xcframework` exists.

If `make whisper` fails on a missing tool, run `make check` to see which prerequisite is absent and install it (`brew install cmake`), then re-run.

- [ ] **Step 3: Verify the test suite runs green before any code change**

```bash
xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="" \
  -only-testing:VoiceInkTests/KeyboardLayoutLanguageServiceTests
```

Expected: `** TEST SUCCEEDED **`.

`-configuration Debug` and `CODE_SIGN_IDENTITY=""` matter: the default configuration is Release, which requires a "Mac Development" signing certificate for team `V6J6A3VWY2` that is not installed here.

This establishes the baseline — a red suite here means the problem predates this plan. Nothing to commit in this task.

---

## Task 1: Unicode-aware word boundaries

**Files:**
- Modify: `VoiceInk/Transcription/Processing/WordReplacementService.swift:40-45`
- Create: `VoiceInkTests/WordReplacementServiceTests.swift`

**Interfaces:**
- Consumes: `WordReplacementService.shared.applyReplacements(to:using:) -> String` and the `WordReplacement` SwiftData model (`originalText`, `replacementText`, `dateAdded`, `isEnabled`), both already in the codebase.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add the new test file to the test target**

Create `VoiceInkTests/WordReplacementServiceTests.swift`:

```swift
//
//  WordReplacementServiceTests.swift
//  VoiceInkTests
//

import Foundation
import SwiftData
import Testing
@testable import VoiceInk

@MainActor
struct WordReplacementServiceTests {

    /// Applies `rules` (trigger → replacement) to `text` through an in-memory store.
    private func apply(_ text: String, rules: [(String, String)]) throws -> String {
        let container = try ModelContainer(
            for: WordReplacement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        for (original, replacement) in rules {
            context.insert(WordReplacement(originalText: original, replacementText: replacement))
        }
        return WordReplacementService.shared.applyReplacements(to: text, using: context)
    }

    // MARK: - Combining marks (NFD text)

    @Test func doesNotMatchWhenACombiningMarkFollowsTheTrigger() throws {
        // "cà" decomposed: c + a + U+0300 COMBINING GRAVE ACCENT
        let text = "uống c\u{0061}\u{0300} phê"
        #expect(try apply(text, rules: [("ca", "КОФЕ")]) == text)
    }

    @Test func doesNotMatchARussianWordEndingInACombiningMark() throws {
        // "мой" decomposed: м + о + и + U+0306 COMBINING BREVE
        let text = "это мо\u{0438}\u{0306} текст"
        #expect(try apply(text, rules: [("мои", "МОИ")]) == text)
    }

    // MARK: - Non-spaced scripts

    @Test func matchesALatinTriggerFlushAgainstIdeographs() throws {
        #expect(try apply("我用voiceink录音", rules: [("voiceink", "VoiceInk")]) == "我用VoiceInk录音")
    }

    // MARK: - Existing behavior that must not regress

    @Test func replacesAWholeWordButNotASubstring() throws {
        #expect(try apply("мираж мир", rules: [("мир", "MIR")]) == "мираж MIR")
    }

    @Test func matchesATriggerEndingInPunctuation() throws {
        #expect(
            try apply("я пишу на c++ каждый день", rules: [("c++", "C plus plus")])
                == "я пишу на C plus plus каждый день"
        )
    }

    @Test func insertsRegexTemplateCharactersLiterally() throws {
        // "$1" and "\" are ICU substitution syntax; escapedTemplate must neutralize them.
        #expect(try apply("цена тут", rules: [("цена", "$1 \\ USD")]) == "$1 \\ USD тут")
    }

    @Test func fallsBackToSubstringReplacementForCJKTriggers() throws {
        #expect(try apply("我用录音功能", rules: [("录音", "recording")]) == "我用recording功能")
    }
}
```

Xcode adds files under `VoiceInkTests/` to the test target automatically when the folder is a synchronized group. If the build reports the type as missing, add the file to the `VoiceInkTests` target membership in Xcode's File Inspector.

- [ ] **Step 2: Run the new tests and confirm exactly three fail**

```bash
xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="" \
  -only-testing:VoiceInkTests/WordReplacementServiceTests
```

Expected: `** TEST FAILED **` with these three failing:
- `doesNotMatchWhenACombiningMarkFollowsTheTrigger` — currently yields `"uống КОФЀ phê"`
- `doesNotMatchARussianWordEndingInACombiningMark` — currently yields `"это МОЙ текст"`
- `matchesALatinTriggerFlushAgainstIdeographs` — currently leaves the text unchanged

The other four must already pass. If any of those four fail, stop — the fork's behavior differs from what this plan assumes and the change needs re-checking before proceeding.

- [ ] **Step 3: Widen the word-character class**

In `VoiceInk/Transcription/Processing/WordReplacementService.swift`, replace this block:

```swift
                if usesBoundaries {
                    // Lookarounds instead of \b so punctuation acts as a word boundary.
                    // Unicode-aware classes (\p{L}\p{N}) — an ASCII-only [a-zA-Z0-9] treats every
                    // Cyrillic/Greek/Arabic/etc. letter as a boundary, so a short rule matches
                    // inside longer words and corrupts non-Latin transcripts.
                    let escaped = NSRegularExpression.escapedPattern(for: original)
                    let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
```

with:

```swift
                if usesBoundaries {
                    // Lookarounds instead of \b so punctuation acts as a word boundary.
                    // A word char is any Unicode letter, mark or digit — an ASCII-only
                    // [a-zA-Z0-9] treats every Cyrillic/Greek/Arabic letter as a boundary, and
                    // omitting \p{M} lets a rule fire inside a decomposed (NFD) word. The
                    // non-spaced scripts are subtracted so a Latin trigger flush against CJK or
                    // Thai still matches, mirroring usesWordBoundaries(for:). scx (Script
                    // Extensions) keeps shared marks such as U+30FC (Script=Common) exempt too.
                    let wordChar = "[[\\p{L}\\p{M}\\p{N}]-[\\p{scx=Han}\\p{scx=Hiragana}\\p{scx=Katakana}\\p{scx=Hangul}\\p{scx=Thai}]]"
                    let escaped = NSRegularExpression.escapedPattern(for: original)
                    let pattern = "(?<!\(wordChar))\(escaped)(?!\(wordChar))"
```

Leave the rest of the method — the `escapedTemplate` call, the `stringByReplacingMatches` call, and the `else` substring branch — untouched.

- [ ] **Step 4: Run the tests and confirm all seven pass**

```bash
xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="" \
  -only-testing:VoiceInkTests/WordReplacementServiceTests
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add VoiceInk/Transcription/Processing/WordReplacementService.swift VoiceInkTests/WordReplacementServiceTests.swift
git commit -m "fix(dictionary): treat combining marks as word characters in replacements"
```

---

## Task 2: AI model catalog refresh

**Files:**
- Modify: `VoiceInk/Services/AIEnhancement/AIService.swift` (the `availableModels` computed property)
- Modify: `VoiceInk/Services/AIEnhancement/ReasoningConfig.swift`

**Interfaces:**
- Consumes: `AIProvider.availableModels: [String]` and `ReasoningConfig.getReasoningParameter(for:modelName:) -> String?`, both existing.
- Produces: nothing consumed by later tasks.

Anthropic gets `claude-opus-4-8` only. Claude Opus 5 and Claude Sonnet 5 run adaptive thinking when the request omits a `thinking` parameter, and this fork's Anthropic path (`AIEnhancementService.swift:282` → `AnthropicLLMClient.chatCompletion`) never sends one — so adding them would make every transcript cleanup a reasoning request. See the spec for the full reasoning.

- [ ] **Step 1: Add the new model IDs**

In `VoiceInk/Services/AIEnhancement/AIService.swift`, inside `availableModels`, make four edits.

Gemini — replace:

```swift
        case .gemini:
            return [
                "gemini-3.5-flash",
```

with:

```swift
        case .gemini:
            return [
                "gemini-3.6-flash",
                "gemini-3.5-flash-lite",
                "gemini-3.5-flash",
```

Anthropic — replace:

```swift
        case .anthropic:
            return [
                "claude-opus-4-7",
```

with:

```swift
        case .anthropic:
            return [
                "claude-opus-4-8",
                "claude-opus-4-7",
```

OpenAI — replace:

```swift
        case .openAI:
            return [
                "gpt-5.5",
```

with:

```swift
        case .openAI:
            return [
                "gpt-5.6-luna",
                "gpt-5.6-terra",
                "gpt-5.6-sol",
                "gpt-5.5",
```

Mistral — replace:

```swift
        case .mistral:
            return [
                "mistral-large-latest",
                "mistral-medium-latest",
                "mistral-small-latest"
            ]
```

with:

```swift
        case .mistral:
            return [
                "mistral-medium-3-5",
                "mistral-small-2603",
                "mistral-large-latest",
                "mistral-medium-latest",
                "mistral-small-latest"
            ]
```

- [ ] **Step 2: Register reasoning behavior for the new models**

In `VoiceInk/Services/AIEnhancement/ReasoningConfig.swift`, replace:

```swift
    // These Gemini models only go down to "minimal".
    static let geminiMinimalReasoningModels: Set<String> = [
        "gemini-3.5-flash",
```

with:

```swift
    // These Gemini models only go down to "minimal".
    static let geminiMinimalReasoningModels: Set<String> = [
        "gemini-3.6-flash",
        "gemini-3.5-flash-lite",
        "gemini-3.5-flash",
```

and replace:

```swift
    // OpenAI GPT-5.x models support explicit "none"; GPT-4.1 models need no param.
    static let openAINoneReasoningModels: Set<String> = [
        "gpt-5.5",
```

with:

```swift
    // OpenAI GPT-5.x models support explicit "none"; GPT-4.1 models need no param.
    static let openAINoneReasoningModels: Set<String> = [
        "gpt-5.6-luna",
        "gpt-5.6-terra",
        "gpt-5.6-sol",
        "gpt-5.5",
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk \
  -configuration Debug CODE_SIGN_IDENTITY="" build
```

Expected: `** BUILD SUCCEEDED **`. There is no automated test for these lists — they are static string arrays with no logic.

- [ ] **Step 4: Commit**

```bash
git add VoiceInk/Services/AIEnhancement/AIService.swift VoiceInk/Services/AIEnhancement/ReasoningConfig.swift
git commit -m "feat(ai): add current OpenAI, Gemini, Anthropic and Mistral models"
```

- [ ] **Step 5: Record the manual follow-up**

These model IDs come from upstream commits and cannot be verified without provider API keys. Report to the user after the task: each touched provider needs one round-trip (the "Test connection" button or a single enhancement) with a real key, and any ID the provider rejects should be dropped in a follow-up commit.

---

## Task 3: Audio meter push → pull

**Files:**
- Modify: `VoiceInk/Recorder.swift` (lines 15-17, 125, 145, 161-181, 205-258, 263)
- Modify: `VoiceInk/Views/Recorder/AudioVisualizerView.swift:3-45`
- Modify: `VoiceInk/Views/Recorder/RecorderComponents.swift:303-322`
- Modify: `VoiceInk/Views/Recorder/MiniRecorderView.swift:40`
- Modify: `VoiceInk/Views/Recorder/NotchRecorderView.swift:141`

**Interfaces:**
- Consumes: `Recorder` (`@MainActor class Recorder: NSObject, ObservableObject`) and the existing `struct AudioMeter { let averagePower: Double; let peakPower: Double }`.
- Produces: `Recorder.audioMeterSnapshot() -> AudioMeter`, a main-actor-isolated synchronous read used as an escaping `() -> AudioMeter` by `AudioVisualizer` and `RecorderStatusDisplay`.

There is no unit test for this task: `Recorder` drives real CoreAudio hardware and `AudioVisualizer` is a SwiftUI view. Verification is a compile plus a manual recording pass.

- [ ] **Step 1: Replace the meter timer with a snapshot function in `Recorder`**

In `VoiceInk/Recorder.swift`:

(a) Delete these three stored properties (lines 15-17):

```swift
    @Published var audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
    private var audioMeterUpdateTimer: DispatchSourceTimer?
    private let audioMeterQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.audiometer", qos: .userInteractive)
```

(b) In `startRecording(toOutputFile:)`, delete the line `audioMeterUpdateTimer?.cancel()` that sits just after `audioRestorationTask = nil`.

(c) In `startRecording(toOutputFile:)`, replace `startAudioMeterTimer(for: coreAudioRecorder)` with `resetAudioMeter()`.

(d) In `stopRecording()`, delete these two lines:

```swift
        audioMeterUpdateTimer?.cancel()
        audioMeterUpdateTimer = nil
```

(e) In `stopRecording()`, replace this block:

```swift
        smoothedValuesLock.lock()
        smoothedAverage = 0
        smoothedPeak = 0
        smoothedValuesLock.unlock()

        audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
```

with:

```swift
        resetAudioMeter()
```

(f) Delete the whole `startAudioMeterTimer(for:)` method, including its comment about capturing the recorder weakly.

(g) Replace the `updateAudioMeter(recorder:)` method with these two methods:

```swift
    /// Reads the current meter level. Called from the visualizer's TimelineView on
    /// each frame instead of being pushed from a timer, so `Recorder` publishes
    /// nothing and the recorder views are not invalidated 60 times a second.
    func audioMeterSnapshot() -> AudioMeter {
        guard let recorder else {
            return AudioMeter(averagePower: 0, peakPower: 0)
        }

        // Sample audio levels (thread-safe read)
        let averagePower = recorder.averagePower
        let peakPower = recorder.peakPower

        // Normalize values
        let minVisibleDb: Float = -60.0
        let maxVisibleDb: Float = 0.0

        let normalizedAverage: Float
        if averagePower < minVisibleDb {
            normalizedAverage = 0.0
        } else if averagePower >= maxVisibleDb {
            normalizedAverage = 1.0
        } else {
            normalizedAverage = (averagePower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        let normalizedPeak: Float
        if peakPower < minVisibleDb {
            normalizedPeak = 0.0
        } else if peakPower >= maxVisibleDb {
            normalizedPeak = 1.0
        } else {
            normalizedPeak = (peakPower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        // Apply EMA smoothing with thread-safe access
        smoothedValuesLock.lock()
        smoothedAverage = smoothedAverage * 0.6 + normalizedAverage * 0.4
        smoothedPeak = smoothedPeak * 0.6 + normalizedPeak * 0.4
        let meter = AudioMeter(averagePower: Double(smoothedAverage), peakPower: Double(smoothedPeak))
        smoothedValuesLock.unlock()

        return meter
    }

    private func resetAudioMeter() {
        smoothedValuesLock.lock()
        smoothedAverage = 0
        smoothedPeak = 0
        smoothedValuesLock.unlock()
    }
```

(h) In `deinit`, delete `audioMeterUpdateTimer?.cancel()`.

- [ ] **Step 2: Make `AudioVisualizer` pull instead of receive**

In `VoiceInk/Views/Recorder/AudioVisualizerView.swift`, replace lines 3-45 (the whole `AudioVisualizer` struct, leaving `StaticVisualizer` and `ProcessingStatusDisplay` alone) with:

```swift
struct AudioVisualizer: View {
    let audioMeterProvider: () -> AudioMeter
    let color: Color
    let isActive: Bool

    private let barCount = 15
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2
    private let minHeight: CGFloat = 4
    private let maxHeight: CGFloat = 28

    private let phases: [Double]

    init(audioMeterProvider: @escaping () -> AudioMeter, color: Color, isActive: Bool) {
        self.audioMeterProvider = audioMeterProvider
        self.color = color
        self.isActive = isActive
        self.phases = (0..<barCount).map { Double($0) * 0.4 }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.016)) { context in
            let audioMeter = audioMeterProvider()

            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(color.opacity(0.85))
                        .frame(
                            width: barWidth,
                            height: barHeight(for: index, at: context.date, audioMeter: audioMeter)
                        )
                }
            }
        }
    }

    private func barHeight(for index: Int, at date: Date, audioMeter: AudioMeter) -> CGFloat {
        guard isActive else { return minHeight }

        let time = date.timeIntervalSince1970
        let amplitude = max(0, min(1, pow(audioMeter.averagePower, 0.7))) // boosted for visibility
        let wave = sin(time * 8 + phases[index]) * 0.5 + 0.5
        let centerDistance = abs(Double(index) - Double(barCount) / 2) / Double(barCount / 2)
        let centerBoost = 1.0 - (centerDistance * 0.4)

        return max(minHeight, minHeight + CGFloat(amplitude * wave * centerBoost) * (maxHeight - minHeight))
    }
}
```

- [ ] **Step 3: Forward the provider through `RecorderStatusDisplay`**

In `VoiceInk/Views/Recorder/RecorderComponents.swift`, in `struct RecorderStatusDisplay`:

Replace `let audioMeter: AudioMeter` with `let audioMeterProvider: () -> AudioMeter`.

Replace the initializer:

```swift
    init(currentState: RecordingState, audioMeter: AudioMeter, menuBarHeight: CGFloat? = nil) {
        self.currentState = currentState
        self.audioMeter = audioMeter
        self.menuBarHeight = menuBarHeight
    }
```

with:

```swift
    init(
        currentState: RecordingState,
        audioMeterProvider: @escaping () -> AudioMeter,
        menuBarHeight: CGFloat? = nil
    ) {
        self.currentState = currentState
        self.audioMeterProvider = audioMeterProvider
        self.menuBarHeight = menuBarHeight
    }
```

and in `body`, replace:

```swift
                AudioVisualizer(audioMeter: audioMeter, color: .white, isActive: true)
```

with:

```swift
                AudioVisualizer(audioMeterProvider: audioMeterProvider, color: .white, isActive: true)
```

- [ ] **Step 4: Update both call sites**

In `VoiceInk/Views/Recorder/MiniRecorderView.swift`, replace:

```swift
            RecorderStatusDisplay(
                currentState: stateProvider.recordingState,
                audioMeter: recorder.audioMeter
            )
```

with:

```swift
            RecorderStatusDisplay(
                currentState: stateProvider.recordingState,
                audioMeterProvider: recorder.audioMeterSnapshot
            )
```

In `VoiceInk/Views/Recorder/NotchRecorderView.swift`, replace:

```swift
                RecorderStatusDisplay(
                    currentState: stateProvider.recordingState,
                    audioMeter: recorder.audioMeter,
                    menuBarHeight: notchHeight
                )
```

with:

```swift
                RecorderStatusDisplay(
                    currentState: stateProvider.recordingState,
                    audioMeterProvider: recorder.audioMeterSnapshot,
                    menuBarHeight: notchHeight
                )
```

- [ ] **Step 5: Build and confirm no stale references remain**

```bash
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk \
  -configuration Debug CODE_SIGN_IDENTITY="" build
```

Expected: `** BUILD SUCCEEDED **`.

Then confirm nothing still reaches for the removed property or timer:

```bash
grep -rn "audioMeterUpdateTimer\|audioMeterQueue\|recorder\.audioMeter\b\|startAudioMeterTimer" VoiceInk --include="*.swift"
```

Expected: no output.

- [ ] **Step 6: Manual verification**

Launch the built app (`make run`, or open `.test-build/Build/Products/Debug/VoiceInk.app`) and check both recorder styles:

1. Mini recorder — start a recording, speak: bars react to voice as before.
2. Notch recorder — same check, and the bars scale correctly to the notch height.
3. Stop the recording in each: bars settle to the flat idle state, no residual motion.
4. Start a second recording right after stopping: the meter starts from silence, not from the previous level.

- [ ] **Step 7: Commit**

```bash
git add VoiceInk/Recorder.swift VoiceInk/Views/Recorder/AudioVisualizerView.swift VoiceInk/Views/Recorder/RecorderComponents.swift VoiceInk/Views/Recorder/MiniRecorderView.swift VoiceInk/Views/Recorder/NotchRecorderView.swift
git commit -m "perf(recorder): pull audio meter from the visualizer instead of publishing it"
```

---

## Done criteria

- `xcodebuild test -only-testing:VoiceInkTests/WordReplacementServiceTests` passes (7 tests).
- A full `xcodebuild ... build` succeeds.
- `git log --oneline ba7cc1c..HEAD` shows exactly three commits, one per task.
- The manual recorder pass in Task 3 Step 6 shows no visual regression.
- Reported to the user: the model IDs added in Task 2 still need one live round-trip per provider.
