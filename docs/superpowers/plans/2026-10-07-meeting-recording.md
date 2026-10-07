# Meeting Recording Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record one app's audio plus the microphone (Zoom, Meet, Discord…), save it to `~/Music/Recordings/<folder>/audio.m4a`, write a timestamped transcript with the current VoiceInk model and a summary with the enhancement provider, and rename the folder after the summary title.

**Architecture:** New folder `VoiceInk/Meetings/`. Pure logic (`MeetingText`, `MeetingLanguage`, `MeetingStore`) is unit-tested; `MeetingCapture` ports AppRec's ScreenCaptureKit capture; `MeetingTranscriber` cuts VAD chunks and runs them through `TranscriptionServiceRegistry` with a detect-then-correct language pass; `MeetingSummarizer` talks to Ollama directly (with `num_ctx`) or via `AIEnhancementService.chatCompletion`; `MeetingRecorder` (`@MainActor ObservableObject`) owns state, queue and persistence; UI is a sidebar section plus menu bar items.

**Tech Stack:** Swift 5 mode, SwiftUI, ScreenCaptureKit, AVFoundation, NaturalLanguage, FluidAudio VAD, swift-testing.

**Spec:** `docs/superpowers/specs/2026-10-07-meeting-recording-design.md`

## Global Constraints

- App target macOS 14.4; no type carries `@available(macOS 15, *)`; macOS 15 APIs (`captureMicrophone`, `microphoneCaptureDeviceID`, `.microphone`, `export(to:as:)`) only inside `if/guard #available(macOS 15, *)`; the Meetings UI is hidden below macOS 15.
- Storage: `~/Music/Recordings/<name>/` with `audio.m4a`, `transcript.txt`, `summary.md`; new folder `<App> yyyy-MM-dd HH.mm.ss` (start time), renamed `yyyy-MM-dd HH.mm <title>`, suffix ` 2`, ` 3`… on collision; `DateFormatter` with `en_US_POSIX`.
- Chunks: VAD threshold 0.7, `minSpeechDuration` 0.5 s, `maxSpeechDuration` 28 s, merged while span ≤ 30 s and gap ≤ 1 s; transcript line `[mm:ss] text` (`[h:mm:ss]` ≥ 1 h).
- Language: Auto = detect then correct (dominant needs ≥ 200 chars and p ≥ 0.8 and support by model; pass 2 re-runs chunks detected as another language unless confidently other: ≥ 40 chars and p ≥ 0.8). Fixed language goes through `validLanguageOrFallback`.
- Execution note: after Task 9 a throwaway smoke test on Parakeet Ultra with a mixed TTS file changed the merge gap, `maxSpeechDuration`, the 40-char threshold and dropped Parakeet's blanket pass 2; code blocks below are the pre-measurement version, the repo is the source of truth.
- Retries: `apiRequestFailed` 429/5xx and `networkError`, delays 5, 20, 60 s.
- Summary: auto only if `isEnhancementEnabled && isConfigured`; manual if `isConfigured`; Ollama `num_ctx = min(max(chars/3 + 2048, 4096), 32768)`, `think: false`; timeout 300 s.
- Build/test helper (repo root, ad-hoc signing): `zsh <scratchpad>/vt.sh <Suite…>` runs `xcodebuild test … -only-testing:VoiceInkTests/<Suite>`; with no args it builds the app. Never run the whole VoiceInkTests target (`RetranscribeInPlaceTests` crashes, known).
- File-system-synchronized groups: new `.swift` files need no pbxproj edit.
- New UI strings get Russian translations in `Localizable.xcstrings` (Task 9 script).
- Conventional commits, no AI attribution, no push. Comments only for non-obvious *why*, ≤ 3 lines.

## Review Focus

- **Folder trashed while queued or being processed** → the queued item is dropped, the running one cannot be trashed (button disabled): `MeetingRecorder.trash` + row `disabled` (Task 8/9).
- **Quit right after Stop** (state `saving`) → quit waits for the save: `prepareForTermination` covers `.saving` (Task 8).
- **VAD model unavailable (offline first run)** → fall back to fixed 30 s windows, transcription still works: `MeetingText.fixedChunks` tested in Task 1, used in Task 5.
- **Mixdown fails** → raw `.mov` kept in the folder as `capture.mov`, error names it; nothing deleted (Task 8).
- **Empty or whitespace-only chunk text / zero-length chunk** → dropped from transcript, never sent to the model: `assembleTranscript` test (Task 1) and the `≥ 0.1 s` guard (Task 5).

---

### Task 1: MeetingText — timestamps, chunk merging, transcript, title

**Files:**
- Create: `VoiceInk/Meetings/MeetingText.swift`
- Create: `VoiceInkTests/MeetingTextTests.swift`

**Interfaces:**
- Produces:
  - `MeetingText.Chunk { var start: TimeInterval; var end: TimeInterval }` (Equatable)
  - `MeetingText.timestamp(_:) -> String`
  - `MeetingText.mergeSegments(_:maxSpan:) -> [Chunk]`
  - `MeetingText.fixedChunks(duration:span:) -> [Chunk]`
  - `MeetingText.assembleTranscript(_ lines: [(start: TimeInterval, text: String)]) -> String`
  - `MeetingText.title(fromSummary:) -> String?`

- [x] **Step 1: Write the failing tests** — `VoiceInkTests/MeetingTextTests.swift`:

```swift
import Foundation
import Testing
@testable import VoiceInk

struct MeetingTextTests {
    @Test func timestampFormats() {
        #expect(MeetingText.timestamp(5) == "00:05")
        #expect(MeetingText.timestamp(3599) == "59:59")
        #expect(MeetingText.timestamp(3723) == "1:02:03")
        #expect(MeetingText.timestamp(-1) == "00:00")
    }

    @Test func mergeKeepsChunksWithinMaxSpan() {
        let segments: [MeetingText.Chunk] = [.init(start: 0, end: 10), .init(start: 11, end: 25), .init(start: 26, end: 31), .init(start: 32, end: 40)]
        #expect(MeetingText.mergeSegments(segments) == [.init(start: 0, end: 25), .init(start: 26, end: 40)])
    }

    @Test func mergeLeavesLongSegmentAlone() {
        let segments: [MeetingText.Chunk] = [.init(start: 0, end: 40), .init(start: 41, end: 45)]
        #expect(MeetingText.mergeSegments(segments) == segments)
    }

    @Test func mergeSortsAndHandlesEmpty() {
        #expect(MeetingText.mergeSegments([]).isEmpty)
        #expect(MeetingText.mergeSegments([.init(start: 12, end: 14), .init(start: 0, end: 5)]) == [.init(start: 0, end: 14)])
    }

    @Test func fixedChunksCoverDuration() {
        #expect(MeetingText.fixedChunks(duration: 65, span: 30) == [.init(start: 0, end: 30), .init(start: 30, end: 60), .init(start: 60, end: 65)])
        #expect(MeetingText.fixedChunks(duration: 0, span: 30).isEmpty)
    }

    @Test func assembleDropsEmptyCollapsesWhitespaceAndSorts() {
        let text = MeetingText.assembleTranscript([(start: 65, text: "second\nline"), (start: 3, text: "  first "), (start: 30, text: " \n ")])
        #expect(text == "[00:03] first\n[01:05] second line")
    }

    @Test func titleFromFirstHeading() {
        #expect(MeetingText.title(fromSummary: "# Release: plan/Friday.\n\n## TL;DR") == "Release plan Friday")
        #expect(MeetingText.title(fromSummary: "Intro\n# Weekly sync\n") == "Weekly sync")
        #expect(MeetingText.title(fromSummary: "## TL;DR\nNo title") == nil)
        #expect(MeetingText.title(fromSummary: "# ...") == nil)
        #expect(MeetingText.title(fromSummary: "# " + String(repeating: "a", count: 80))?.count == 60)
    }
}
```

- [x] **Step 2: Run, expect FAIL** — `zsh vt.sh MeetingTextTests` → build error "cannot find 'MeetingText'".

- [x] **Step 3: Implement** — `VoiceInk/Meetings/MeetingText.swift`:

```swift
import Foundation

enum MeetingText {
    struct Chunk: Equatable {
        var start: TimeInterval
        var end: TimeInterval
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // VAD closes a segment on every short pause; merging keeps enough context per model call.
    static func mergeSegments(_ segments: [Chunk], maxSpan: TimeInterval = 30) -> [Chunk] {
        var chunks: [Chunk] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if var last = chunks.last, segment.end - last.start <= maxSpan {
                last.end = max(last.end, segment.end)
                chunks[chunks.count - 1] = last
            } else {
                chunks.append(segment)
            }
        }
        return chunks
    }

    static func fixedChunks(duration: TimeInterval, span: TimeInterval = 30) -> [Chunk] {
        stride(from: 0, to: duration, by: span).map { Chunk(start: $0, end: min($0 + span, duration)) }
    }

    static func assembleTranscript(_ lines: [(start: TimeInterval, text: String)]) -> String {
        lines.sorted { $0.start < $1.start }
            .map { (start: $0.start, text: collapseWhitespace($0.text)) }
            .filter { !$0.text.isEmpty }
            .map { "[\(timestamp($0.start))] \($0.text)" }
            .joined(separator: "\n")
    }

    static func title(fromSummary summary: String) -> String? {
        guard let line = summary.split(separator: "\n").first(where: { $0.hasPrefix("# ") }) else { return nil }
        let cleaned = collapseWhitespace(
            line.dropFirst(2)
                .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
                .joined(separator: " ")
        ).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let title = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
```

- [x] **Step 4: Run, expect PASS** — `zsh vt.sh MeetingTextTests` → "Test run with 7 tests … passed".
- [x] **Step 5: Commit** — `git add VoiceInk/Meetings/MeetingText.swift VoiceInkTests/MeetingTextTests.swift && git commit -m "feat(meetings): transcript text helpers"`

---

### Task 2: MeetingLanguage — detection and correction decisions

**Files:**
- Create: `VoiceInk/Meetings/MeetingLanguage.swift`
- Create: `VoiceInkTests/MeetingLanguageTests.swift`

**Interfaces:**
- Produces:
  - `MeetingLanguage.auto: String` (`"auto"`)
  - `MeetingLanguage.Detection { let code: String; let probability: Double }`
  - `MeetingLanguage.voiceInkCode(_ nlCode: String) -> String`
  - `MeetingLanguage.detect(_ text: String) -> Detection?`
  - `MeetingLanguage.dominantLanguage(detection:characterCount:supported:) -> String?`
  - `MeetingLanguage.pass2Indices(chunkTexts:language:retranscribeAll:detect:) -> [Int]`

- [x] **Step 1: Write the failing tests** — `VoiceInkTests/MeetingLanguageTests.swift`:

```swift
import Foundation
import Testing
@testable import VoiceInk

struct MeetingLanguageTests {
    @Test func mapsNaturalLanguageCodes() {
        #expect(MeetingLanguage.voiceInkCode("zh-Hans") == "zh")
        #expect(MeetingLanguage.voiceInkCode("zh-Hant") == "zh")
        #expect(MeetingLanguage.voiceInkCode("nb") == "no")
        #expect(MeetingLanguage.voiceInkCode("pt-BR") == "pt")
        #expect(MeetingLanguage.voiceInkCode("ru") == "ru")
    }

    @Test func detectsRussianAndEnglish() {
        let russian = "Давайте обсудим план релиза на пятницу. Нужно закрыть оставшиеся задачи, проверить сборку и договориться, кто отвечает за выкладку."
        let english = "Let's go over the release plan for Friday. We need to close the remaining tasks, check the build and agree on who owns the rollout."
        #expect(MeetingLanguage.detect(russian)?.code == "ru")
        #expect(MeetingLanguage.detect(english)?.code == "en")
        #expect(MeetingLanguage.detect("") == nil)
    }

    @Test func dominantLanguageDecision() {
        let supported: Set<String> = ["auto", "ru", "en"]
        let ru = MeetingLanguage.Detection(code: "ru", probability: 0.95)
        #expect(MeetingLanguage.dominantLanguage(detection: ru, characterCount: 500, supported: supported) == "ru")
        #expect(MeetingLanguage.dominantLanguage(detection: ru, characterCount: 150, supported: supported) == nil)
        #expect(MeetingLanguage.dominantLanguage(detection: .init(code: "ru", probability: 0.6), characterCount: 500, supported: supported) == nil)
        #expect(MeetingLanguage.dominantLanguage(detection: .init(code: "ja", probability: 0.99), characterCount: 500, supported: supported) == nil)
        #expect(MeetingLanguage.dominantLanguage(detection: nil, characterCount: 500, supported: supported) == nil)
    }

    @Test func pass2SelectsMisdetectedChunks() {
        let long = String(repeating: "x", count: 120)
        let detections: [String: MeetingLanguage.Detection] = [
            "Okay.": .init(code: "en", probability: 0.9),
            long: .init(code: "en", probability: 0.95),
            "Привет всем": .init(code: "ru", probability: 0.99),
        ]
        let texts = ["Okay.", long, "Привет всем", " "]
        let detect: (String) -> MeetingLanguage.Detection? = { detections[$0] }
        #expect(MeetingLanguage.pass2Indices(chunkTexts: texts, language: "ru", retranscribeAll: false, detect: detect) == [0])
        #expect(MeetingLanguage.pass2Indices(chunkTexts: texts, language: "ru", retranscribeAll: true, detect: detect) == [0, 2])
    }
}
```

- [x] **Step 2: Run, expect FAIL** — `zsh vt.sh MeetingLanguageTests` → "cannot find 'MeetingLanguage'".

- [x] **Step 3: Implement** — `VoiceInk/Meetings/MeetingLanguage.swift`:

```swift
import Foundation
import NaturalLanguage

enum MeetingLanguage {
    static let auto = "auto"
    static let dominantMinCharacters = 200
    static let confidentOtherMinCharacters = 100
    static let minProbability = 0.8

    struct Detection: Equatable {
        let code: String
        let probability: Double
    }

    static func voiceInkCode(_ nlCode: String) -> String {
        switch nlCode {
        case "zh-Hans", "zh-Hant": return "zh"
        case "nb": return "no"
        default: return String(nlCode.split(separator: "-").first ?? Substring(nlCode))
        }
    }

    static func detect(_ text: String) -> Detection? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 5).max(by: { $0.value < $1.value }),
              best.key != .undetermined else { return nil }
        return Detection(code: voiceInkCode(best.key.rawValue), probability: best.value)
    }

    static func dominantLanguage(detection: Detection?, characterCount: Int, supported: Set<String>) -> String? {
        guard characterCount >= dominantMinCharacters,
              let detection,
              detection.probability >= minProbability,
              supported.contains(detection.code) else { return nil }
        return detection.code
    }

    // A chunk confidently in another language is a real switch (a guest speaking English), not a misdetection.
    static func pass2Indices(
        chunkTexts: [String],
        language: String,
        retranscribeAll: Bool,
        detect: (String) -> Detection? = MeetingLanguage.detect
    ) -> [Int] {
        chunkTexts.indices.filter { index in
            let text = chunkTexts[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return false }
            let detection = detect(text)
            if let detection, detection.code != language,
               detection.probability >= minProbability, text.count >= confidentOtherMinCharacters {
                return false
            }
            return retranscribeAll || detection?.code != language
        }
    }
}
```

- [x] **Step 4: Run, expect PASS** — `zsh vt.sh MeetingLanguageTests` → 4 tests passed.
- [x] **Step 5: Commit** — `git add VoiceInk/Meetings/MeetingLanguage.swift VoiceInkTests/MeetingLanguageTests.swift && git commit -m "feat(meetings): language detect-then-correct decisions"`

---

### Task 3: MeetingStore — recordings folder

**Files:**
- Create: `VoiceInk/Meetings/MeetingStore.swift`
- Create: `VoiceInkTests/MeetingStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct MeetingRecording: Identifiable, Hashable { folder, date, hasTranscript, hasSummary; id, name, audioURL, transcriptURL, summaryURL }` with static `audioName`, `transcriptName`, `summaryName`, `rawCaptureName`
  - `struct MeetingStore { let root: URL; static let defaultRoot: URL; list() throws -> [MeetingRecording]; makeFolder(appName:startedAt:) throws -> URL; setStartDate(_:of:) throws; rename(_:to:) throws -> URL; trash(_:) throws }`

- [x] **Step 1: Write the failing tests** — `VoiceInkTests/MeetingStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import VoiceInk

struct MeetingStoreTests {
    private func makeStore() throws -> MeetingStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return MeetingStore(root: root)
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    private func touch(_ url: URL) throws { try Data("x".utf8).write(to: url) }

    @Test func listsFoldersWithAudioNewestFirst() throws {
        let store = try makeStore()
        let older = try store.makeFolder(appName: "Zoom", startedAt: date(2026, 10, 1, 9, 0))
        let newer = try store.makeFolder(appName: "Discord", startedAt: date(2026, 10, 2, 9, 0))
        let noAudio = store.root.appendingPathComponent("junk", isDirectory: true)
        try FileManager.default.createDirectory(at: noAudio, withIntermediateDirectories: true)
        try touch(older.appendingPathComponent(MeetingRecording.audioName))
        try touch(older.appendingPathComponent(MeetingRecording.transcriptName))
        try touch(newer.appendingPathComponent(MeetingRecording.audioName))
        try store.setStartDate(date(2026, 10, 1, 9, 0), of: older)
        try store.setStartDate(date(2026, 10, 2, 9, 0), of: newer)

        let list = try store.list()
        #expect(list.map(\.name) == [newer.lastPathComponent, older.lastPathComponent])
        #expect(list.map(\.hasTranscript) == [false, true])
        #expect(list.map(\.hasSummary) == [false, false])
    }

    @Test func missingRootListsNothing() throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(try store.list().isEmpty)
    }

    @Test func folderNameUsesStartTimeAndAvoidsCollisions() throws {
        let store = try makeStore()
        let start = date(2026, 10, 7, 14, 5, 9)
        let first = try store.makeFolder(appName: "Google Chrome", startedAt: start)
        let second = try store.makeFolder(appName: "Google Chrome", startedAt: start)
        #expect(first.lastPathComponent == "Google Chrome 2026-10-07 14.05.09")
        #expect(second.lastPathComponent == "Google Chrome 2026-10-07 14.05.09 2")
    }

    @Test func renameUsesCreationDateAndSuffix() throws {
        let store = try makeStore()
        let start = date(2026, 10, 7, 9, 5)
        let a = try store.makeFolder(appName: "Zoom", startedAt: start)
        let b = try store.makeFolder(appName: "Zoom", startedAt: start.addingTimeInterval(1))
        try store.setStartDate(start, of: a)
        try store.setStartDate(start, of: b)
        let renamedA = try store.rename(a, to: "Weekly sync")
        let renamedB = try store.rename(b, to: "Weekly sync")
        #expect(renamedA.lastPathComponent == "2026-10-07 09.05 Weekly sync")
        #expect(renamedB.lastPathComponent == "2026-10-07 09.05 Weekly sync 2")
        #expect(try store.rename(renamedA, to: "Weekly sync") == renamedA)
    }
}
```

- [x] **Step 2: Run, expect FAIL** — `zsh vt.sh MeetingStoreTests` → "cannot find 'MeetingStore'".

- [x] **Step 3: Implement** — `VoiceInk/Meetings/MeetingStore.swift`:

```swift
import Foundation

struct MeetingRecording: Identifiable, Hashable {
    static let audioName = "audio.m4a"
    static let transcriptName = "transcript.txt"
    static let summaryName = "summary.md"
    static let rawCaptureName = "capture.mov"

    let folder: URL
    let date: Date
    let hasTranscript: Bool
    let hasSummary: Bool

    var id: URL { folder }
    var name: String { folder.lastPathComponent }
    var audioURL: URL { folder.appendingPathComponent(Self.audioName) }
    var transcriptURL: URL { folder.appendingPathComponent(Self.transcriptName) }
    var summaryURL: URL { folder.appendingPathComponent(Self.summaryName) }
}

struct MeetingStore {
    // Same folder as AppRec, so its recordings show up here.
    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Music/Recordings", isDirectory: true)

    let root: URL

    func list() throws -> [MeetingRecording] {
        let fileManager = FileManager.default
        let folders: [URL]
        do {
            folders = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        return folders.compactMap { folder in
            guard fileManager.fileExists(atPath: folder.appendingPathComponent(MeetingRecording.audioName).path) else { return nil }
            return MeetingRecording(
                folder: folder,
                date: Self.creationDate(of: folder) ?? .distantPast,
                hasTranscript: fileManager.fileExists(atPath: folder.appendingPathComponent(MeetingRecording.transcriptName).path),
                hasSummary: fileManager.fileExists(atPath: folder.appendingPathComponent(MeetingRecording.summaryName).path)
            )
        }
        .sorted { $0.date > $1.date }
    }

    func makeFolder(appName: String, startedAt: Date) throws -> URL {
        let safeName = appName.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: " ")
        let folder = uniqueFolder(named: "\(safeName) \(Self.formatter("yyyy-MM-dd HH.mm.ss").string(from: startedAt))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // The folder is created at stop; its creation date is moved to the start so a later rename shows the start time.
    func setStartDate(_ date: Date, of folder: URL) throws {
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: folder.path)
    }

    @discardableResult
    func rename(_ folder: URL, to title: String) throws -> URL {
        let created = Self.creationDate(of: folder) ?? Date()
        let name = "\(Self.formatter("yyyy-MM-dd HH.mm").string(from: created)) \(title)"
        guard name != folder.lastPathComponent else { return folder }
        let target = uniqueFolder(named: name)
        try FileManager.default.moveItem(at: folder, to: target)
        return target
    }

    func trash(_ recording: MeetingRecording) throws {
        try FileManager.default.trashItem(at: recording.folder, resultingItemURL: nil)
    }

    private func uniqueFolder(named name: String) -> URL {
        var candidate = root.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(name) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private static func creationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}
```

- [x] **Step 4: Run, expect PASS** — `zsh vt.sh MeetingStoreTests` → 4 tests passed.
- [x] **Step 5: Commit** — `git add VoiceInk/Meetings/MeetingStore.swift VoiceInkTests/MeetingStoreTests.swift && git commit -m "feat(meetings): recordings folder store"`

---

### Task 4: Whisper keeps its own context across a run

**Files:**
- Modify: `VoiceInk/Transcription/Whisper/WhisperTranscriptionService.swift:5-99`
- Modify: `VoiceInk/Transcription/Engine/TranscriptionServiceRegistry.swift:71-73`

**Interfaces:**
- Produces: `WhisperTranscriptionService.retainsOwnContext: Bool` (default `false`), `WhisperTranscriptionService.releaseRetainedContext() async`; `TranscriptionServiceRegistry.cleanup()` also releases it.

- [x] **Step 1: Add the flag and retained context** — after `private weak var modelProvider` (line 10):

```swift
    // Meeting transcription calls this hundreds of times; reloading the model per call is the bottleneck.
    var retainsOwnContext = false
    private var retainedContext: (context: WhisperContext, modelName: String)?
```

- [x] **Step 2: Reuse it in the load branch** — replace the `} else {` branch that loads the model (lines 42-57) with:

```swift
        } else if retainsOwnContext, let retained = retainedContext, retained.modelName == model.name {
            whisperContext = retained.context
        } else {
            if retainsOwnContext {
                await releaseRetainedContext()
            }
            // Resolve the on-disk URL using the provider's availableModels (covers imports)
            let resolvedURL: URL? = await modelProvider?.availableModels.first(where: { $0.name == model.name })?.url
            guard let modelURL = resolvedURL, FileManager.default.fileExists(atPath: modelURL.path) else {
                logger.error("❌ Model file not found for: \(model.name, privacy: .public)")
                throw VoiceInkEngineError.modelLoadFailed
            }

            logger.notice("Loading model: \(model.name, privacy: .public)")
            do {
                whisperContext = try await WhisperContext.createContext(path: modelURL.path)
            } catch {
                logger.error("❌ Failed to load model: \(model.name, privacy: .public) - \(error.localizedDescription, privacy: .public)")
                throw VoiceInkEngineError.modelLoadFailed
            }
            if retainsOwnContext, let created = whisperContext {
                retainedContext = (created, model.name)
            }
        }
```

- [x] **Step 3: Skip release for the retained context** — replace lines 92-96:

```swift
        // Only release resources if we created a new context (not the shared or the retained one)
        if await modelProvider?.whisperContext !== whisperContext, retainedContext?.context !== whisperContext {
            await whisperContext.releaseResources()
            self.whisperContext = nil
        }
```

and add before `private func readAudioSamples`:

```swift
    // Only ever a context this service created, never the shared one a dictation may be using.
    func releaseRetainedContext() async {
        guard let retained = retainedContext else { return }
        retainedContext = nil
        if whisperContext === retained.context {
            whisperContext = nil
        }
        await retained.context.releaseResources()
    }
```

- [x] **Step 4: Registry cleanup** — `TranscriptionServiceRegistry.cleanup()`:

```swift
    func cleanup() async {
        await fluidAudioTranscriptionService.cleanup()
        await localTranscriptionService.releaseRetainedContext()
    }
```

- [x] **Step 5: Build + regression suites** — `zsh vt.sh RetranscribeHotkeyTests QuickHistoryTests` → passed (no model-backed tests exist; the flag defaults to `false`, so existing paths are unchanged).
- [x] **Step 6: Commit** — `git commit -am "feat(whisper): optionally keep a self-loaded context across calls"`

---

### Task 5: MeetingTranscriber

**Files:**
- Create: `VoiceInk/Meetings/MeetingTranscriber.swift`
- Create: `VoiceInkTests/MeetingTranscriberTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 2, 4; `AudioProcessor`, `TranscriptionServiceRegistry`, `TranscriptionLanguageSupport`, `CloudProviderRegistry`, `TranscriptionOutputFilter`, `WordReplacementService`, FluidAudio `VadManager`.
- Produces:
  - `MeetingTranscriber(engine: VoiceInkEngine)` (`@MainActor`)
  - `MeetingTranscriber.Result { let transcript: String; let language: String? }`
  - `transcribe(audioURL:languageChoice:onStatus:) async throws -> Result`
  - `static func isRetryable(_ error: Error) -> Bool`

- [x] **Step 1: Write the failing test** — `VoiceInkTests/MeetingTranscriberTests.swift`:

```swift
import Foundation
import Testing
@testable import VoiceInk

struct MeetingTranscriberTests {
    @Test func retriesOnlyTransientCloudErrors() {
        #expect(MeetingTranscriber.isRetryable(CloudTranscriptionError.apiRequestFailed(statusCode: 429, message: "")))
        #expect(MeetingTranscriber.isRetryable(CloudTranscriptionError.apiRequestFailed(statusCode: 503, message: "")))
        #expect(MeetingTranscriber.isRetryable(CloudTranscriptionError.networkError(URLError(.timedOut))))
        #expect(!MeetingTranscriber.isRetryable(CloudTranscriptionError.apiRequestFailed(statusCode: 401, message: "")))
        #expect(!MeetingTranscriber.isRetryable(CloudTranscriptionError.streamingOnlyProvider))
        #expect(!MeetingTranscriber.isRetryable(CancellationError()))
    }
}
```

- [x] **Step 2: Run, expect FAIL** — `zsh vt.sh MeetingTranscriberTests` → "cannot find 'MeetingTranscriber'".

- [x] **Step 3: Implement** — `VoiceInk/Meetings/MeetingTranscriber.swift`:

```swift
import Foundation
import FluidAudio
import os

@MainActor
final class MeetingTranscriber {
    struct Result {
        let transcript: String
        let language: String?
    }

    enum Failure: LocalizedError {
        case noModel
        case streamingOnly(String)

        var errorDescription: String? {
            switch self {
            case .noModel:
                return String(localized: "No transcription model selected")
            case .streamingOnly(let name):
                return String(localized: "\(name) works only in streaming mode and can't transcribe recordings. Pick another model.")
            }
        }
    }

    private static let sampleRate = 16_000.0
    private static let retryDelays: [UInt64] = [5, 20, 60]

    private let engine: VoiceInkEngine
    private let audioProcessor = AudioProcessor()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingTranscriber")

    init(engine: VoiceInkEngine) {
        self.engine = engine
    }

    func transcribe(audioURL: URL, languageChoice: String, onStatus: @escaping (String) -> Void) async throws -> Result {
        guard let model = engine.transcriptionModelManager.currentTranscriptionModel else { throw Failure.noModel }
        if let cloud = CloudProviderRegistry.provider(for: model.provider), cloud.isStreamingOnly {
            throw Failure.streamingOnly(model.displayName)
        }
        let supported = TranscriptionLanguageSupport.languages(for: model)
        let fixedLanguage = Self.fixedLanguage(choice: languageChoice, model: model, supported: supported)

        onStatus(String(localized: "Preparing audio…"))
        let samples = try await audioProcessor.processAudioToSamples(audioURL)
        let chunks = await speechChunks(samples)

        let registry = TranscriptionServiceRegistry(
            modelProvider: engine.whisperModelManager,
            modelsDirectory: engine.whisperModelManager.modelsDirectory,
            modelContext: engine.modelContext
        )
        registry.localTranscriptionService.retainsOwnContext = true
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        do {
            let result = try await run(chunks: chunks, samples: samples, model: model, supported: supported,
                                       fixedLanguage: fixedLanguage, registry: registry, tempDirectory: tempDirectory, onStatus: onStatus)
            await registry.cleanup()
            return result
        } catch {
            await registry.cleanup()
            throw error
        }
    }

    nonisolated static func isRetryable(_ error: Error) -> Bool {
        switch error as? CloudTranscriptionError {
        case .apiRequestFailed(let statusCode, _): return statusCode == 429 || statusCode >= 500
        case .networkError: return true
        default: return false
        }
    }

    // nil means Auto with detect-then-correct; models without "auto" get a concrete language up front.
    private static func fixedLanguage(choice: String, model: any TranscriptionModel, supported: [String: String]) -> String? {
        if choice != MeetingLanguage.auto {
            return TranscriptionLanguageSupport.validLanguageOrFallback(choice, for: model)
        }
        if supported[MeetingLanguage.auto] != nil { return nil }
        if let selected = UserDefaults.standard.string(forKey: "SelectedLanguage"), supported[selected] != nil {
            return selected
        }
        return TranscriptionLanguageSupport.validLanguageOrFallback(nil, for: model)
    }

    private func run(
        chunks: [MeetingText.Chunk], samples: [Float], model: any TranscriptionModel, supported: [String: String],
        fixedLanguage: String?, registry: TranscriptionServiceRegistry, tempDirectory: URL, onStatus: (String) -> Void
    ) async throws -> Result {
        let languageLabel = fixedLanguage.map(Self.displayName) ?? String(localized: "Auto-detect")
        var texts: [String] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            onStatus(String(localized: "Transcribing \(index + 1) of \(chunks.count) · \(languageLabel)…"))
            texts.append(try await transcribeChunk(chunk, samples: samples, language: fixedLanguage ?? MeetingLanguage.auto,
                                                   model: model, registry: registry, tempDirectory: tempDirectory))
        }

        var language = fixedLanguage
        if fixedLanguage == nil {
            let allText = texts.joined(separator: " ")
            let detection = MeetingLanguage.detect(allText)
            if let dominant = MeetingLanguage.dominantLanguage(detection: detection, characterCount: allText.count, supported: Set(supported.keys)) {
                language = dominant
                let redo = MeetingLanguage.pass2Indices(chunkTexts: texts, language: dominant, retranscribeAll: model.provider == .fluidAudio)
                for (step, index) in redo.enumerated() {
                    try Task.checkCancellation()
                    onStatus(String(localized: "Correcting to \(Self.displayName(dominant)): \(step + 1) of \(redo.count)…"))
                    texts[index] = try await transcribeChunk(chunks[index], samples: samples, language: dominant,
                                                             model: model, registry: registry, tempDirectory: tempDirectory)
                }
            } else {
                language = detection?.code
            }
        }
        logger.notice("Meeting transcribed: \(chunks.count) chunks, language \(language ?? "unknown", privacy: .public)")
        let transcript = MeetingText.assembleTranscript(zip(chunks, texts).map { (start: $0.start, text: $1) })
        return Result(transcript: transcript, language: language)
    }

    private func transcribeChunk(
        _ chunk: MeetingText.Chunk, samples: [Float], language: String, model: any TranscriptionModel,
        registry: TranscriptionServiceRegistry, tempDirectory: URL
    ) async throws -> String {
        let from = max(0, min(samples.count, Int(chunk.start * Self.sampleRate)))
        let to = max(from, min(samples.count, Int(chunk.end * Self.sampleRate)))
        guard to - from >= Int(Self.sampleRate / 10) else { return "" }
        let url = tempDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try audioProcessor.saveSamplesAsWav(samples: Array(samples[from..<to]), to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var attempt = 0
        while true {
            do {
                let raw = try await registry.transcribe(audioURL: url, model: model, language: language)
                let filtered = TranscriptionOutputFilter.filter(raw)
                return WordReplacementService.shared.applyReplacements(to: filtered, using: engine.modelContext)
            } catch let error where attempt < Self.retryDelays.count && Self.isRetryable(error) {
                logger.notice("Chunk failed, retrying: \(error.localizedDescription, privacy: .public)")
                try await Task.sleep(nanoseconds: Self.retryDelays[attempt] * 1_000_000_000)
                attempt += 1
            }
        }
    }

    private static func displayName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    private func speechChunks(_ samples: [Float]) async -> [MeetingText.Chunk] {
        do {
            let vad = try await VadManager(config: VadConfig(defaultThreshold: 0.7))
            var config = VadSegmentationConfig.default
            config.minSpeechDuration = 0.5
            let segments = try await vad.segmentSpeech(samples, config: config)
            return MeetingText.mergeSegments(segments.map { MeetingText.Chunk(start: $0.startTime, end: $0.endTime) })
        } catch {
            logger.notice("VAD unavailable, using fixed 30 s chunks: \(error.localizedDescription, privacy: .public)")
            return MeetingText.fixedChunks(duration: Double(samples.count) / Self.sampleRate)
        }
    }
}
```

- [x] **Step 4: Run, expect PASS** — `zsh vt.sh MeetingTranscriberTests` → 1 test passed.
- [x] **Step 5: Commit** — `git add VoiceInk/Meetings/MeetingTranscriber.swift VoiceInkTests/MeetingTranscriberTests.swift && git commit -m "feat(meetings): chunked transcription with language correction"`

---

### Task 6: MeetingSummarizer

**Files:**
- Create: `VoiceInk/Meetings/MeetingSummarizer.swift`
- Create: `VoiceInkTests/MeetingSummarizerTests.swift`

**Interfaces:**
- Consumes: `AIService.selectedProvider/currentModel`, `AIEnhancementService.isEnhancementEnabled/isConfigured/chatCompletion`, `AIProvider.ollama.baseURL`, `AIEnhancementOutputFilter.filter`, `MeetingLanguage.detect`.
- Produces: `MeetingSummarizer(aiService:enhancementService:)` (`@MainActor`); `canSummarize: Bool`; `shouldAutoSummarize: Bool`; `summarize(_:languageCode:) async throws -> String`; `static languageName(_:) -> String`; `static ollamaContextSize(characters:) -> Int`.

- [x] **Step 1: Write the failing tests** — `VoiceInkTests/MeetingSummarizerTests.swift`:

```swift
import Foundation
import Testing
@testable import VoiceInk

struct MeetingSummarizerTests {
    @Test func languageNames() {
        #expect(MeetingSummarizer.languageName("ru") == "Russian")
        #expect(MeetingSummarizer.languageName("de-DE") == "German")
        #expect(MeetingSummarizer.languageName(nil) == "the same language as the transcript")
        #expect(MeetingSummarizer.languageName("auto") == "the same language as the transcript")
    }

    @Test func ollamaContextSizeIsClamped() {
        #expect(MeetingSummarizer.ollamaContextSize(characters: 100) == 4_096)
        #expect(MeetingSummarizer.ollamaContextSize(characters: 30_000) == 12_048)
        #expect(MeetingSummarizer.ollamaContextSize(characters: 200_000) == 32_768)
    }
}
```

- [x] **Step 2: Run, expect FAIL** — `zsh vt.sh MeetingSummarizerTests`.

- [x] **Step 3: Implement** — `VoiceInk/Meetings/MeetingSummarizer.swift`:

```swift
import Foundation
import os

@MainActor
final class MeetingSummarizer {
    enum Failure: LocalizedError {
        case server(Int, String)
        case empty

        var errorDescription: String? {
            switch self {
            case .server(let status, let body): return String(localized: "Ollama returned \(status): \(body)")
            case .empty: return String(localized: "The model returned an empty summary.")
            }
        }
    }

    static let timeout: TimeInterval = 300

    private let aiService: AIService
    private let enhancementService: AIEnhancementService
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingSummarizer")

    init(aiService: AIService, enhancementService: AIEnhancementService) {
        self.aiService = aiService
        self.enhancementService = enhancementService
    }

    var canSummarize: Bool { enhancementService.isConfigured }

    // Without the toggle a saved cloud key would send every call transcript out with enhancement switched off.
    var shouldAutoSummarize: Bool { enhancementService.isEnhancementEnabled && enhancementService.isConfigured }

    func summarize(_ transcript: String, languageCode: String?) async throws -> String {
        let provider = aiService.selectedProvider
        let model = aiService.currentModel
        let system = Self.instructions(language: Self.languageName(languageCode ?? MeetingLanguage.detect(transcript)?.code))
        let summary: String
        if provider == .ollama {
            summary = AIEnhancementOutputFilter.filter(try await ollamaChat(system: system, transcript: transcript, model: model))
        } else {
            summary = try await enhancementService.chatCompletion(
                systemPrompt: system, userContent: transcript, provider: provider, modelName: model, timeout: Self.timeout
            )
        }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.empty }
        return trimmed + "\n"
    }

    nonisolated static func languageName(_ code: String?) -> String {
        guard let code, code != MeetingLanguage.auto,
              let languageCode = Locale(identifier: code).language.languageCode?.identifier,
              let name = Locale(identifier: "en").localizedString(forLanguageCode: languageCode) else {
            return "the same language as the transcript"
        }
        return name
    }

    nonisolated static func ollamaContextSize(characters: Int) -> Int {
        min(max(characters / 3 + 2_048, 4_096), 32_768)
    }

    private static func instructions(language: String) -> String {
        """
        You summarize recording transcripts. Write everything in \(language), including the section headings. \
        Reply in Markdown. Start with a title line "# <short descriptive title, 3 to 6 words>", then exactly these sections:
        ## TL;DR
        One or two sentences, no list.
        ## Key points
        Bullets with the facts, decisions and numbers discussed. Start each bullet with the [mm:ss] time from the transcript line where it was said.
        ## Action items
        Bullets of tasks only, as "Name: task". Write "None" if there are none.
        Never repeat the same point in two sections. Do not invent details. Reply with the summary only.
        """
    }

    // LLMkit's OllamaClient sends no num_ctx, so Ollama would silently cut a long transcript to its default context.
    private func ollamaChat(system: String, transcript: String, model: String) async throws -> String {
        guard let base = URL(string: AIProvider.ollama.baseURL) else { throw Failure.server(0, "Invalid Ollama URL") }
        let contextSize = Self.ollamaContextSize(characters: transcript.count)
        if transcript.count / 3 + 2_048 > contextSize {
            logger.warning("Transcript exceeds the Ollama context cap; its beginning may be cut")
        }
        var request = URLRequest(url: base.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "think": false,
            "messages": [["role": "system", "content": system], ["role": "user", "content": transcript]],
            "options": ["num_ctx": contextSize],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.server(status, String(decoding: data.prefix(200), as: UTF8.self))
        }
        struct Reply: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        return try JSONDecoder().decode(Reply.self, from: data).message.content
    }
}
```

- [x] **Step 4: Run, expect PASS** — `zsh vt.sh MeetingSummarizerTests` → 2 tests passed.
- [x] **Step 5: Commit** — `git add VoiceInk/Meetings/MeetingSummarizer.swift VoiceInkTests/MeetingSummarizerTests.swift && git commit -m "feat(meetings): summaries via Ollama or the enhancement provider"`

---

### Task 7: MeetingCapture (ScreenCaptureKit port)

**Files:**
- Create: `VoiceInk/Meetings/MeetingCapture.swift`

**Interfaces:**
- Produces:
  - `struct RecordableApp: Identifiable, Hashable { let id: String; let name: String; let icon: NSImage }`
  - `enum MeetingCaptureError: LocalizedError { unsupportedOS, appNotRunning, noDisplay, noAudio, exportFailed }`
  - `final class MeetingCapture: NSObject, SCStreamDelegate` — `static runningApps() -> [RecordableApp]`; `onStreamError: ((Error) -> Void)?`; `appName: String`; `start(bundleID:includeMicrophone:microphoneUID:) async throws`; `stop() async throws -> URL?`; `static mixdown(_:to:) async throws`

- [x] **Step 1: Implement** — `VoiceInk/Meetings/MeetingCapture.swift` (ported from `apprec/Sources/Recorder.swift:73-123, 282-361`):

```swift
import AppKit
import AVFoundation
import ScreenCaptureKit

struct RecordableApp: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: NSImage
}

enum MeetingCaptureError: LocalizedError {
    case unsupportedOS
    case appNotRunning
    case noDisplay
    case noAudio
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedOS: return String(localized: "Recording calls needs macOS 15 or later.")
        case .appNotRunning: return String(localized: "The selected app is not running.")
        case .noDisplay: return String(localized: "No display available for capture.")
        case .noAudio: return String(localized: "No audio was captured.")
        case .exportFailed: return String(localized: "Could not convert the recording to m4a.")
        }
    }
}

final class MeetingCapture: NSObject, SCStreamDelegate {
    var onStreamError: ((Error) -> Void)?
    private(set) var appName = ""
    private var stream: SCStream?
    private var writer: MeetingTrackWriter?

    static func runningApps() -> [RecordableApp] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0 != .current }
            .compactMap { app in
                guard let id = app.bundleIdentifier, seen.insert(id).inserted else { return nil }
                let icon = (app.icon?.copy() as? NSImage) ?? NSImage()
                icon.size = NSSize(width: 16, height: 16)
                return RecordableApp(id: id, name: app.localizedName ?? id, icon: icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func start(bundleID: String, includeMicrophone: Bool, microphoneUID: String?) async throws {
        guard #available(macOS 15, *) else { throw MeetingCaptureError.unsupportedOS }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        // Electron apps (Discord, Chrome…) play audio from helper processes with "<id>." bundle IDs.
        let targets = content.applications.filter {
            $0.bundleIdentifier == bundleID || $0.bundleIdentifier.hasPrefix(bundleID + ".")
        }
        guard !targets.isEmpty else { throw MeetingCaptureError.appNotRunning }
        guard let display = content.displays.first else { throw MeetingCaptureError.noDisplay }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = includeMicrophone
        if includeMicrophone, let microphoneUID {
            config.microphoneCaptureDeviceID = microphoneUID
        }
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        let writer = try MeetingTrackWriter(url: tempURL, includeMicrophone: includeMicrophone)
        let stream = SCStream(filter: SCContentFilter(display: display, including: targets, exceptingWindows: []),
                              configuration: config, delegate: self)
        try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
        if includeMicrophone {
            try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue)
        }
        try await stream.startCapture()

        self.stream = stream
        self.writer = writer
        appName = targets.first?.applicationName ?? bundleID
    }

    func stop() async throws -> URL? {
        guard let stream, let writer else { return nil }
        self.stream = nil
        self.writer = nil
        try? await stream.stopCapture()
        return try await writer.finish()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onStreamError?(error) }
    }

    static func mixdown(_ source: URL, to destination: URL) async throws {
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A) else {
            throw MeetingCaptureError.exportFailed
        }
        guard #available(macOS 15, *) else { throw MeetingCaptureError.unsupportedOS }
        try await export.export(to: destination, as: .m4a)
    }
}

final class MeetingTrackWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "VoiceInk.meetingWriter")
    private let writer: AVAssetWriter
    private let appInput: AVAssetWriterInput
    private let micInput: AVAssetWriterInput?
    private var started = false

    init(url: URL, includeMicrophone: Bool) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        appInput = Self.makeInput(channels: 2)
        writer.add(appInput)
        if includeMicrophone {
            let mic = Self.makeInput(channels: 1)
            writer.add(mic)
            micInput = mic
        } else {
            micInput = nil
        }
    }

    private static func makeInput(channels: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 64_000 * channels,
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        let input: AVAssetWriterInput?
        if type == .audio {
            input = appInput
        } else if #available(macOS 15, *), type == .microphone {
            input = micInput
        } else {
            input = nil
        }
        guard let input else { return }

        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard started else {
                    continuation.resume(throwing: MeetingCaptureError.noAudio)
                    return
                }
                appInput.markAsFinished()
                micInput?.markAsFinished()
                writer.finishWriting { [self] in
                    if let error = writer.error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: writer.outputURL)
                    }
                }
            }
        }
    }
}
```

- [x] **Step 2: Build** — `zsh vt.sh` → `BUILD SUCCEEDED`.
- [x] **Step 3: Commit** — `git add VoiceInk/Meetings/MeetingCapture.swift && git commit -m "feat(meetings): app audio and microphone capture"`

---

### Task 8: MeetingRecorder + app wiring + quit handling

**Files:**
- Create: `VoiceInk/Meetings/MeetingRecorder.swift`
- Modify: `VoiceInk/VoiceInk.swift` (StateObject, init, environment for ContentView and MenuBarView)
- Modify: `VoiceInk/AppDelegate.swift` (property + `applicationShouldTerminate`)

**Interfaces:**
- Consumes: Tasks 3, 5, 6, 7; `AudioDeviceManager.shared`.
- Produces (for Task 9): `MeetingRecorder` with `@Published apps, selectedBundleID, includeMicrophone, languageChoice, state, recordings, steps, status, error, needsScreenPermission`; `enum State { idle, recording(startedAt: Date, appName: String), saving }`; `enum Step { queued, transcribing, summarizing }`; `isRecording`, `canSummarize`; `refreshApps()`, `refreshRecordings()`, `start(bundleID:) async`, `stop() async`, `enqueueTranscription(_:)`, `createSummary(_:)`, `trash(_:)`, `prepareForTermination(completion:) -> Bool`.

- [x] **Step 1: Implement** — `VoiceInk/Meetings/MeetingRecorder.swift`:

```swift
import AppKit
import os

@MainActor
final class MeetingRecorder: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(startedAt: Date, appName: String)
        case saving
    }

    enum Step: Equatable {
        case queued
        case transcribing
        case summarizing
    }

    private enum Keys {
        static let app = "MeetingsSelectedApp"
        static let microphone = "MeetingsIncludeMicrophone"
        static let language = "MeetingsLanguage"
    }

    @Published private(set) var apps: [RecordableApp] = []
    @Published var selectedBundleID: String? { didSet { UserDefaults.standard.set(selectedBundleID, forKey: Keys.app) } }
    @Published var includeMicrophone: Bool { didSet { UserDefaults.standard.set(includeMicrophone, forKey: Keys.microphone) } }
    @Published var languageChoice: String { didSet { UserDefaults.standard.set(languageChoice, forKey: Keys.language) } }
    @Published private(set) var state: State = .idle
    @Published private(set) var recordings: [MeetingRecording] = []
    @Published private(set) var steps: [URL: Step] = [:]
    @Published private(set) var status: String?
    @Published var error: String?
    @Published private(set) var needsScreenPermission = false

    let store = MeetingStore(root: MeetingStore.defaultRoot)
    private let capture = MeetingCapture()
    private let transcriber: MeetingTranscriber
    private let summarizer: MeetingSummarizer
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingRecorder")
    private var queue: [URL] = []
    private var isTranscribing = false
    private var isStarting = false
    private var isTerminating = false
    private var saveTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []

    init(engine: VoiceInkEngine, aiService: AIService, enhancementService: AIEnhancementService) {
        transcriber = MeetingTranscriber(engine: engine)
        summarizer = MeetingSummarizer(aiService: aiService, enhancementService: enhancementService)
        let defaults = UserDefaults.standard
        selectedBundleID = defaults.string(forKey: Keys.app)
        includeMicrophone = defaults.object(forKey: Keys.microphone) as? Bool ?? true
        languageChoice = defaults.string(forKey: Keys.language) ?? MeetingLanguage.auto

        capture.onStreamError = { [weak self] error in
            Task { @MainActor in await self?.handleStreamError(error) }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshApps() }
            })
        }
        refreshApps()
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var canSummarize: Bool { summarizer.canSummarize }

    func refreshApps() {
        apps = MeetingCapture.runningApps()
    }

    func refreshRecordings() {
        do {
            recordings = try store.list()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func start(bundleID: String? = nil) async {
        if let bundleID { selectedBundleID = bundleID }
        guard state == .idle, !isStarting, let bundleID = selectedBundleID else { return }
        isStarting = true
        defer { isStarting = false }
        error = nil
        needsScreenPermission = false
        do {
            try await capture.start(bundleID: bundleID, includeMicrophone: includeMicrophone, microphoneUID: Self.currentMicrophoneUID())
            state = .recording(startedAt: Date(), appName: capture.appName)
        } catch {
            self.error = error.localizedDescription
            needsScreenPermission = !CGPreflightScreenCaptureAccess()
        }
    }

    func stop() async {
        guard case let .recording(startedAt, appName) = state else { return }
        state = .saving
        let task = Task { await self.save(startedAt: startedAt, appName: appName) }
        saveTask = task
        await task.value
        saveTask = nil
        state = .idle
    }

    func enqueueTranscription(_ folder: URL) {
        guard steps[folder] == nil else { return }
        steps[folder] = .queued
        queue.append(folder)
        processQueue()
    }

    func createSummary(_ recording: MeetingRecording) {
        guard steps[recording.folder] == nil else { return }
        guard let transcript = try? String(contentsOf: recording.transcriptURL, encoding: .utf8),
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = String(localized: "The transcript is empty.")
            return
        }
        Task { await summarize(recording.folder, transcript: transcript, languageCode: nil) }
    }

    func trash(_ recording: MeetingRecording) {
        guard steps[recording.folder] == nil || steps[recording.folder] == .queued else { return }
        queue.removeAll { $0 == recording.folder }
        steps[recording.folder] = nil
        do {
            try store.trash(recording)
        } catch {
            self.error = error.localizedDescription
        }
        refreshRecordings()
    }

    // Returns true when quitting must wait; `completion` then fires once the recording is on disk.
    func prepareForTermination(completion: @escaping () -> Void) -> Bool {
        switch state {
        case .idle:
            return false
        case .recording:
            isTerminating = true
            Task {
                await stop()
                completion()
            }
        case .saving:
            isTerminating = true
            Task {
                await saveTask?.value
                completion()
            }
        }
        return true
    }

    private func handleStreamError(_ streamError: Error) async {
        logger.error("Capture stopped: \(streamError.localizedDescription, privacy: .public)")
        error = streamError.localizedDescription
        await stop()
    }

    private func save(startedAt: Date, appName: String) async {
        do {
            guard let tempURL = try await capture.stop() else { return }
            let folder = try store.makeFolder(appName: appName, startedAt: startedAt)
            do {
                try await MeetingCapture.mixdown(tempURL, to: folder.appendingPathComponent(MeetingRecording.audioName))
                try? FileManager.default.removeItem(at: tempURL)
            } catch {
                // Never lose a call: keep the raw two-track capture next to where the m4a should be.
                try? FileManager.default.moveItem(at: tempURL, to: folder.appendingPathComponent(MeetingRecording.rawCaptureName))
                logger.error("Mixdown failed: \(error.localizedDescription, privacy: .public)")
                self.error = String(localized: "Could not convert the recording to m4a: \(error.localizedDescription). The raw capture is kept in \(folder.path).")
                return
            }
            try? store.setStartDate(startedAt, of: folder)
            refreshRecordings()
            if !isTerminating {
                enqueueTranscription(folder)
            }
        } catch {
            logger.error("Saving the recording failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    private func processQueue() {
        guard !isTranscribing, !queue.isEmpty else { return }
        isTranscribing = true
        let folder = queue.removeFirst()
        Task {
            await transcribe(folder)
            isTranscribing = false
            processQueue()
        }
    }

    private func transcribe(_ folder: URL) async {
        steps[folder] = .transcribing
        var result: MeetingTranscriber.Result?
        do {
            let transcription = try await transcriber.transcribe(
                audioURL: folder.appendingPathComponent(MeetingRecording.audioName),
                languageChoice: languageChoice
            ) { [weak self] in self?.status = $0 }
            try transcription.transcript.write(to: folder.appendingPathComponent(MeetingRecording.transcriptName), atomically: true, encoding: .utf8)
            result = transcription
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            self.error = String(localized: "Transcription failed: \(error.localizedDescription)")
        }
        status = nil
        steps[folder] = nil
        refreshRecordings()
        guard let result, !result.transcript.isEmpty, summarizer.shouldAutoSummarize else { return }
        Task { await summarize(folder, transcript: result.transcript, languageCode: result.language) }
    }

    private func summarize(_ folder: URL, transcript: String, languageCode: String?) async {
        steps[folder] = .summarizing
        defer {
            steps[folder] = nil
            refreshRecordings()
        }
        do {
            let summary = try await summarizer.summarize(transcript, languageCode: languageCode)
            try summary.write(to: folder.appendingPathComponent(MeetingRecording.summaryName), atomically: true, encoding: .utf8)
            if let title = MeetingText.title(fromSummary: summary) {
                try store.rename(folder, to: title)
            }
        } catch {
            logger.error("Summary failed: \(error.localizedDescription, privacy: .public)")
            self.error = String(localized: "Summary failed: \(error.localizedDescription)")
        }
    }

    private static func currentMicrophoneUID() -> String? {
        let manager = AudioDeviceManager.shared
        let id = manager.getCurrentDevice()
        guard id != 0 else { return nil }
        return manager.availableDevices.first { $0.id == id }?.uid
    }
}
```

- [x] **Step 2: Wire into `VoiceInkApp`** (`VoiceInk/VoiceInk.swift`):
  - after `@StateObject private var prewarmService: ModelPrewarmService` add `@StateObject private var meetingRecorder: MeetingRecorder`;
  - after `_prewarmService = StateObject(wrappedValue: prewarmService)` add:

```swift
        let meetingRecorder = MeetingRecorder(engine: engine, aiService: aiService, enhancementService: enhancementService)
        _meetingRecorder = StateObject(wrappedValue: meetingRecorder)
        appDelegate.meetingRecorder = meetingRecorder
```

  - add `.environmentObject(meetingRecorder)` after `.environmentObject(enhancementService)` in the `ContentView()` chain and in the `MenuBarView()` chain.

- [x] **Step 3: Quit handling** (`VoiceInk/AppDelegate.swift`): after `weak var menuBarManager: MenuBarManager?` add `weak var meetingRecorder: MeetingRecorder?`, and after `applicationShouldTerminateAfterLastWindowClosed`:

```swift
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let meetingRecorder else { return .terminateNow }
        let mustWait = meetingRecorder.prepareForTermination {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return mustWait ? .terminateLater : .terminateNow
    }
```

- [x] **Step 4: Build** — `zsh vt.sh` → `BUILD SUCCEEDED`.
- [x] **Step 5: Commit** — `git add VoiceInk/Meetings/MeetingRecorder.swift VoiceInk/VoiceInk.swift VoiceInk/AppDelegate.swift && git commit -m "feat(meetings): recorder state, queue and quit handling"`

---

### Task 9: UI — Meetings section, menu bar, localization

**Files:**
- Create: `VoiceInk/Views/Meetings/MeetingsView.swift`
- Modify: `VoiceInk/Views/ContentView.swift` (enum case, icon, visibility, detail, navigation)
- Modify: `VoiceInk/Views/MenuBarView.swift` (environment object + record/stop items)
- Modify: `VoiceInk/Resources/Localizable.xcstrings` (script)

**Interfaces:**
- Consumes: Task 8 `MeetingRecorder` API; `TranscriptionModelManager.currentTranscriptionModel`; `TranscriptionLanguageSupport.languages(for:)`; `AudioFileMetadata.duration(for:)`; `MenuBarManager.openMainWindowAndNavigate(to:)`.

- [x] **Step 1: Meetings view** — `VoiceInk/Views/Meetings/MeetingsView.swift`:

```swift
import SwiftUI

struct MeetingsView: View {
    @EnvironmentObject private var recorder: MeetingRecorder
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager

    var body: some View {
        Form {
            Section("Recording") {
                Picker("App", selection: $recorder.selectedBundleID) {
                    Text("Choose an app").tag(String?.none)
                    ForEach(recorder.apps) { app in
                        Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                            .tag(Optional(app.id))
                    }
                }
                .disabled(recorder.state != .idle)

                Toggle("Include microphone", isOn: $recorder.includeMicrophone)
                    .disabled(recorder.state != .idle)

                Picker("Language", selection: $recorder.languageChoice) {
                    ForEach(languageOptions, id: \.code) { option in
                        Text(option.name).tag(option.code)
                    }
                }

                HStack(spacing: 10) {
                    recordButton
                    stateLabel
                    Spacer()
                }

                if let status = recorder.status {
                    Text(status).foregroundStyle(.secondary)
                }

                if let error = recorder.error {
                    HStack(alignment: .firstTextBaseline) {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                        Spacer()
                        if recorder.needsScreenPermission {
                            Button("Open Privacy Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        Button("Dismiss") { recorder.error = nil }
                    }
                }
            }

            Section("Recordings") {
                if recorder.recordings.isEmpty {
                    Text("No recordings yet. They're saved in ~/Music/Recordings.")
                        .foregroundStyle(.secondary)
                }
                ForEach(recorder.recordings) { recording in
                    MeetingRow(recording: recording)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            recorder.refreshApps()
            recorder.refreshRecordings()
        }
    }

    @ViewBuilder
    private var recordButton: some View {
        if recorder.isRecording {
            Button {
                Task { await recorder.stop() }
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
            }
        } else {
            Button {
                Task { await recorder.start() }
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .disabled(recorder.selectedBundleID == nil || recorder.state != .idle)
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch recorder.state {
        case .recording(let startedAt, let appName):
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text("Recording \(appName) · \(MeetingText.timestamp(context.date.timeIntervalSince(startedAt)))")
                    .monospacedDigit()
                    .foregroundStyle(.red)
            }
        case .saving:
            ProgressView().controlSize(.small)
            Text("Saving…").foregroundStyle(.secondary)
        case .idle:
            EmptyView()
        }
    }

    private var languageOptions: [(code: String, name: String)] {
        var languages: [String: String] = [:]
        if let model = transcriptionModelManager.currentTranscriptionModel {
            languages = TranscriptionLanguageSupport.languages(for: model)
        }
        languages[MeetingLanguage.auto] = nil
        var options = languages.map { (code: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
        if recorder.languageChoice != MeetingLanguage.auto, languages[recorder.languageChoice] == nil {
            options.insert((code: recorder.languageChoice, name: recorder.languageChoice), at: 0)
        }
        return [(code: MeetingLanguage.auto, name: String(localized: "Auto-detect"))] + options
    }
}

private struct MeetingRow: View {
    @EnvironmentObject private var recorder: MeetingRecorder
    let recording: MeetingRecording
    @State private var duration: TimeInterval?

    var body: some View {
        let step = recorder.steps[recording.folder]
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.name).lineLimit(1).truncationMode(.middle)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch step {
            case .queued:
                Text("Queued").font(.caption).foregroundStyle(.secondary)
            case .transcribing, .summarizing:
                ProgressView().controlSize(.small)
            case nil:
                EmptyView()
            }
            if recording.hasTranscript {
                iconButton("doc.text", help: "Transcript") { NSWorkspace.shared.open(recording.transcriptURL) }
            } else if step == nil {
                Button("Transcribe") { recorder.enqueueTranscription(recording.folder) }
            }
            if recording.hasSummary {
                iconButton("list.bullet.rectangle", help: "Summary") { NSWorkspace.shared.open(recording.summaryURL) }
            } else if recording.hasTranscript, step == nil, recorder.canSummarize {
                Button("Summarize") { recorder.createSummary(recording) }
            }
            iconButton("play.circle", help: "Play") { NSWorkspace.shared.open(recording.audioURL) }
            iconButton("trash", help: "Move to Trash") { recorder.trash(recording) }
                .disabled(step == .transcribing || step == .summarizing)
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([recording.folder]) }
        }
        .task(id: recording.folder) {
            duration = await AudioFileMetadata.duration(for: recording.audioURL)
        }
    }

    private var details: String {
        let date = recording.date.formatted(date: .abbreviated, time: .shortened)
        guard let duration, duration > 0 else { return date }
        return "\(date) · \(MeetingText.timestamp(duration))"
    }

    private func iconButton(_ systemImage: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: systemImage) }
            .buttonStyle(.borderless)
            .help(help)
    }
}
```

- [x] **Step 2: ContentView** (`VoiceInk/Views/ContentView.swift`):
  - enum: after `case transcribeAudio = "Transcribe Audio"` add `case meetings = "Meetings"`; icon: `case .meetings: return "record.circle"`;
  - `visibleViewTypes` — add as the first statement inside the filter closure:

```swift
            if viewType == .meetings {
                if #available(macOS 15, *) { return true }
                return false
            }
```

  - `navigateToDestination` switch: `case "Meetings": selectedView = .meetings`;
  - `detailView`: `case .meetings: MeetingsView()`.

- [x] **Step 3: MenuBarView** (`VoiceInk/Views/MenuBarView.swift`): add `@EnvironmentObject var meetingRecorder: MeetingRecorder` after `@EnvironmentObject var aiService: AIService`, and after the "Enhance Selected Text" button (before its `Divider()`):

```swift
            if #available(macOS 15, *) {
                if case let .recording(_, appName) = meetingRecorder.state {
                    Button("Stop Recording — \(appName)") {
                        Task { await meetingRecorder.stop() }
                    }
                } else {
                    Menu("Record Call") {
                        ForEach(meetingRecorder.apps) { app in
                            Button(app.name) {
                                Task { await meetingRecorder.start(bundleID: app.id) }
                            }
                        }
                        if meetingRecorder.apps.isEmpty {
                            Text("No apps running")
                        }
                        Divider()
                        Button("Open Meetings") {
                            menuBarManager.openMainWindowAndNavigate(to: "Meetings")
                        }
                    }
                    .disabled(meetingRecorder.state != .idle)
                }
            }
```

- [x] **Step 4: Localization** — run from repo root (adds only missing keys, preserves order):

```bash
python3 - <<'PY'
import json
path = 'VoiceInk/Resources/Localizable.xcstrings'
d = json.load(open(path))
ru = {
    "Meetings": "Созвоны",
    "Recording": "Запись",
    "Recordings": "Записи",
    "App": "Приложение",
    "Choose an app": "Выберите приложение",
    "Include microphone": "Записывать микрофон",
    "Auto-detect": "Автоопределение",
    "Stop": "Остановить",
    "Recording %@ · %@": "Запись %@ · %@",
    "Saving…": "Сохранение…",
    "Open Privacy Settings": "Открыть настройки конфиденциальности",
    "No recordings yet. They're saved in ~/Music/Recordings.": "Записей пока нет. Они сохраняются в ~/Music/Recordings.",
    "Queued": "В очереди",
    "Transcribe": "Транскрибировать",
    "Summarize": "Сделать саммари",
    "Transcript": "Транскрипт",
    "Summary": "Саммари",
    "Play": "Воспроизвести",
    "Move to Trash": "Переместить в корзину",
    "Record Call": "Записать созвон",
    "Stop Recording — %@": "Остановить запись — %@",
    "No apps running": "Нет запущенных приложений",
    "Open Meetings": "Открыть созвоны",
    "Preparing audio…": "Подготовка аудио…",
    "Transcribing %lld of %lld · %@…": "Транскрибация: %lld из %lld · %@…",
    "Correcting to %@: %lld of %lld…": "Исправление на %@: %lld из %lld…",
    "Could not convert the recording to m4a: %@. The raw capture is kept in %@.": "Не удалось сохранить запись в m4a: %@. Исходный захват лежит в %@.",
    "Transcription failed: %@": "Не удалось транскрибировать: %@",
    "Summary failed: %@": "Не удалось сделать саммари: %@",
    "The transcript is empty.": "Транскрипт пуст.",
    "%@ works only in streaming mode and can't transcribe recordings. Pick another model.": "%@ работает только в потоковом режиме и не умеет транскрибировать записи. Выберите другую модель.",
    "Ollama returned %lld: %@": "Ollama вернула %lld: %@",
    "The model returned an empty summary.": "Модель вернула пустое саммари.",
    "Recording calls needs macOS 15 or later.": "Для записи созвонов нужна macOS 15 или новее.",
    "The selected app is not running.": "Выбранное приложение не запущено.",
    "No display available for capture.": "Нет дисплея для захвата.",
    "No audio was captured.": "Звук не записан.",
    "Could not convert the recording to m4a.": "Не удалось сохранить запись в m4a.",
}
added = [k for k in ru if k not in d['strings']]
for k in added:
    d['strings'][k] = {"localizations": {"ru": {"stringUnit": {"state": "translated", "value": ru[k]}}}}
open(path, 'w').write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
print("added", len(added), added)
PY
```

- [x] **Step 5: Build + unit suites** — `zsh vt.sh` → `BUILD SUCCEEDED`; then `zsh vt.sh MeetingTextTests MeetingLanguageTests MeetingStoreTests MeetingTranscriberTests MeetingSummarizerTests QuickHistoryTests` → all passed.
- [x] **Step 6: Commit** — `git add VoiceInk/Views/Meetings VoiceInk/Views/ContentView.swift VoiceInk/Views/MenuBarView.swift VoiceInk/Resources/Localizable.xcstrings && git commit -m "feat(meetings): Meetings section and menu bar items"`

---

### Task 10: Release notes, version, smoke run

**Files:**
- Modify: `CHANGELOG.md` (new top entry)
- Modify: `VoiceInk.xcodeproj/project.pbxproj` (`MARKETING_VERSION = 1.81.0;` → `1.82.0;`, both occurrences)

- [x] **Step 1: CHANGELOG** — insert after the header paragraph:

```markdown
## [1.82.0] - 2026-10-07

### Added
- Запись созвонов: раздел «Созвоны» и пункт «Записать созвон» в меню-баре пишут звук выбранного приложения (Zoom, Google Meet в браузере, Discord и др.) вместе с микрофоном в `~/Music/Recordings`. После остановки запись транскрибируется текущей моделью с таймкодами `[мм:сс]` (язык — автоопределение с исправлением ошибочно распознанных кусков или заданный вручную), а при включённом AI-улучшении получает саммари и имя папки по его заголовку. Нужна macOS 15+; папки AppRec в том же каталоге видны в списке.
```

- [x] **Step 2: Version bump** — `sed -i '' 's/MARKETING_VERSION = 1.81.0;/MARKETING_VERSION = 1.82.0;/' VoiceInk.xcodeproj/project.pbxproj` and check 2 replacements with `grep -c 'MARKETING_VERSION = 1.82.0;'`.
- [x] **Step 3: Smoke run** — `make local`, launch the built app; open «Созвоны»; play an audio file in QuickTime Player; record QuickTime for ~40 s with the microphone; Stop → `audio.m4a` appears, transcript gets written with `[mm:ss]` lines; with Ollama configured and enhancement on, `summary.md` appears and the folder is renamed. Record what was and was not verified (permission dialogs may need the user).
- [x] **Step 4: Commit** — `git commit -am "chore(release): 1.82.0 changelog and version bump"`

---

### Task 11: Manual verification (needs the user)

Done during implementation (signed local build, `VoiceInk Local` identity, QuickTime playing a mixed ru/en TTS file):
- [x] Capture of an app plus microphone → `audio.m4a` 31.7 s, 2 ch, 48 kHz; transcript with `[mm:ss]` lines written automatically.
- [x] Quit VoiceInk mid-recording → 11.7 s `audio.m4a` saved, app exited after the save, transcription deferred.
- [x] Enhancement off → no automatic summary.
- [x] No screen-recording permission (ad-hoc build) → SCStream error -3801 surfaced; `needsScreenPermission` path.

Still to check by hand (spec "Testing → Manual"):
- [ ] Discord call: other participants and the microphone audible; folder named "Discord …", not a helper.
- [ ] Google Meet in Chrome and in Safari. If Safari records silence → add `com.apple.WebKit.GPU` processes to the filter for Safari.
- [ ] Microphone off → only app audio; a non-default microphone in VoiceInk → that one is recorded.
- [ ] Dictation during a recording still works.
- [ ] Language fixed to Russian; saved language unsupported by a newly selected model → fallback shown in the status line.
- [ ] Recording > 30 min with Parakeet and with a local Whisper model; summary on Ollama timed → set `MeetingSummarizer.timeout`.
- [ ] Enhancement on → summary written, folder renamed `yyyy-MM-dd HH.mm <title>`.
- [ ] Deepgram on Auto with a Russian call. If it comes out English → send `detect_language=true` for Deepgram on Auto.

