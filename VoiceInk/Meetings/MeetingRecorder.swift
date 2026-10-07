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
        static let autoDelete = "MeetingsAutoDeleteEnabled"
        static let retention = "MeetingsRetentionMinutes"
    }

    @Published private(set) var apps: [RecordableApp] = []
    @Published var selectedBundleID: String? { didSet { UserDefaults.standard.set(selectedBundleID, forKey: Keys.app) } }
    @Published var includeMicrophone: Bool { didSet { UserDefaults.standard.set(includeMicrophone, forKey: Keys.microphone) } }
    @Published var languageChoice: String { didSet { UserDefaults.standard.set(languageChoice, forKey: Keys.language) } }
    @Published private(set) var state: State = .idle
    @Published private(set) var recordings: [MeetingRecording] = []
    @Published private(set) var steps: [String: Step] = [:]
    @Published private(set) var status: String?
    @Published var error: String?
    @Published private(set) var needsScreenPermission = false
    @Published var isAutoDeleteEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoDeleteEnabled, forKey: Keys.autoDelete)
            sweepExpired()
        }
    }
    @Published var retentionMinutes: Int {
        didSet {
            UserDefaults.standard.set(retentionMinutes, forKey: Keys.retention)
            sweepExpired()
        }
    }

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
    private var observers: [NSObjectProtocol] = []
    private var sweepTimer: Timer?

    init(engine: VoiceInkEngine, aiService: AIService, enhancementService: AIEnhancementService) {
        transcriber = MeetingTranscriber(engine: engine)
        summarizer = MeetingSummarizer(aiService: aiService, enhancementService: enhancementService)
        let defaults = UserDefaults.standard
        selectedBundleID = defaults.string(forKey: Keys.app) ?? MeetingCapture.systemAudioID
        includeMicrophone = defaults.object(forKey: Keys.microphone) as? Bool ?? true
        languageChoice = defaults.string(forKey: Keys.language) ?? MeetingLanguage.auto
        isAutoDeleteEnabled = defaults.bool(forKey: Keys.autoDelete)
        retentionMinutes = defaults.object(forKey: Keys.retention) as? Int ?? 24 * 60

        capture.onStreamError = { [weak self] error in
            Task { @MainActor in await self?.handleStreamError(error) }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshApps() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .toggleCallRecording, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.toggleFromShortcut() }
        })
        // A 1 hour retention needs a sweep while the app stays open, not only at launch.
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweepExpired() }
        }
        refreshApps()
        sweepExpired()
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

    // The shortcut fires while VoiceInk is in the background, so the outcome goes to a notification.
    func toggleFromShortcut() async {
        switch state {
        case .idle:
            await start()
            if case let .recording(_, appName) = state {
                NotificationManager.shared.showNotification(title: String(localized: "Recording \(appName)…"), type: .info)
            } else if let error {
                NotificationManager.shared.showNotification(title: error, type: .error)
            }
        case .recording:
            error = nil
            await stop()
            if let error {
                NotificationManager.shared.showNotification(title: error, type: .error)
            } else {
                NotificationManager.shared.showNotification(title: String(localized: "Call recording saved"), type: .success)
            }
        case .saving:
            break
        }
    }

    // Moves expired recordings to the Trash; returns how many, or nil when listing failed.
    @discardableResult
    func sweepExpired() -> Int? {
        guard isAutoDeleteEnabled else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(retentionMinutes) * 60)
        do {
            var trashed = 0
            for folder in try store.expiredFolders(before: cutoff) where steps[folder.lastPathComponent] == nil {
                do {
                    try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
                    trashed += 1
                } catch {
                    logger.error("Auto-delete failed for \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            if trashed > 0 {
                logger.notice("Auto-delete moved \(trashed) recording(s) to the Trash")
                refreshRecordings()
            }
            return trashed
        } catch {
            logger.error("Auto-delete listing failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func stop() async {
        if state == .saving {
            await saveTask?.value
            return
        }
        guard case let .recording(startedAt, appName) = state else { return }
        state = .saving
        let task = Task { await self.save(startedAt: startedAt, appName: appName) }
        saveTask = task
        await task.value
        saveTask = nil
        state = .idle
    }

    // Keyed by folder name: URLs of the same folder from different APIs differ (trailing slash, /private).
    func step(for recording: MeetingRecording) -> Step? {
        steps[recording.name]
    }

    func enqueueTranscription(_ folder: URL) {
        guard steps[folder.lastPathComponent] == nil else { return }
        steps[folder.lastPathComponent] = .queued
        queue.append(folder)
        processQueue()
    }

    func createSummary(_ recording: MeetingRecording) {
        guard step(for: recording) == nil else { return }
        guard let transcript = try? String(contentsOf: recording.transcriptURL, encoding: .utf8),
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = String(localized: "The transcript is empty.")
            return
        }
        steps[recording.name] = .summarizing
        Task { await summarize(recording.folder, transcript: transcript, languageCode: nil) }
    }

    func trash(_ recording: MeetingRecording) {
        guard step(for: recording) == nil || step(for: recording) == .queued else { return }
        queue.removeAll { $0.lastPathComponent == recording.name }
        steps[recording.name] = nil
        do {
            try store.trash(recording)
        } catch {
            self.error = error.localizedDescription
        }
        refreshRecordings()
    }

    // Returns true when quitting must wait; `completion` then fires once the recording is on disk.
    func prepareForTermination(completion: @escaping () -> Void) -> Bool {
        guard state != .idle else { return false }
        isTerminating = true
        Task {
            await stop()
            completion()
        }
        return true
    }

    private func handleStreamError(_ streamError: Error) async {
        logger.error("Capture stopped: \(streamError.localizedDescription, privacy: .public)")
        error = streamError.localizedDescription
        await stop()
    }

    private func save(startedAt: Date, appName: String) async {
        let tempURL: URL
        do {
            guard let url = try await capture.stop() else { return }
            tempURL = url
        } catch {
            logger.error("Finishing the capture failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
            return
        }
        let folder: URL
        do {
            folder = try store.makeFolder(appName: appName, startedAt: startedAt)
        } catch {
            logger.error("Creating the recording folder failed: \(error.localizedDescription, privacy: .public)")
            self.error = String(localized: "Could not save the recording: \(error.localizedDescription). The raw capture is kept at \(tempURL.path).")
            return
        }
        let audioURL = folder.appendingPathComponent(MeetingRecording.audioName)
        do {
            try await MeetingCapture.mixdown(tempURL, to: audioURL)
            try? FileManager.default.removeItem(at: tempURL)
        } catch {
            // Never lose a call: keep the raw two-track capture where the m4a should have been.
            try? FileManager.default.removeItem(at: audioURL)
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
        let name = folder.lastPathComponent
        steps[name] = .transcribing
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
        steps[name] = nil
        refreshRecordings()
        guard let result else {
            status = nil
            return
        }
        status = result.language.map { String(localized: "Transcript ready · \(MeetingTranscriber.displayName($0))") }
            ?? String(localized: "Transcript ready")
        guard !result.transcript.isEmpty, summarizer.shouldAutoSummarize else { return }
        steps[name] = .summarizing
        Task { await summarize(folder, transcript: result.transcript, languageCode: result.language) }
    }

    private func summarize(_ folder: URL, transcript: String, languageCode: String?) async {
        let name = folder.lastPathComponent
        steps[name] = .summarizing
        defer {
            steps[name] = nil
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
