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
