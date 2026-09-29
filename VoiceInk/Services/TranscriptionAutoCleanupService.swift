import Foundation
import SwiftData
import OSLog

class TranscriptionAutoCleanupService {
    static let shared = TranscriptionAutoCleanupService()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionAutoCleanupService")
    private var modelContext: ModelContext?

    private let keyIsEnabled = "IsTranscriptionCleanupEnabled"
    private let keyRetentionMinutes = "TranscriptionRetentionMinutes"

    private let defaultRetentionMinutes: Int = 24 * 60

    private var recordingsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
            .appendingPathComponent("Recordings")
    }

    private init() {}

    func startMonitoring(modelContext: ModelContext) {
        self.modelContext = modelContext

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTranscriptionCompleted(_:)),
            name: .transcriptionCompleted,
            object: nil
        )

        if UserDefaults.standard.bool(forKey: keyIsEnabled) {
            Task { [weak self] in
                guard let self = self, let modelContext = self.modelContext else { return }
                _ = await self.sweepOldTranscriptions(modelContext: modelContext)
                await self.cleanupOrphanAudioFiles(modelContext: modelContext)
            }
        }
    }

    func stopMonitoring() {
        NotificationCenter.default.removeObserver(self, name: .transcriptionCompleted, object: nil)
    }

    /// Returns the number of deleted transcriptions, or nil when the sweep failed
    /// (the caller must not report success on nil).
    @discardableResult
    func runManualCleanup(modelContext: ModelContext) async -> Int? {
        await sweepOldTranscriptions(modelContext: modelContext)
    }

    @objc private func handleTranscriptionCompleted(_ notification: Notification) {
        let isEnabled = UserDefaults.standard.bool(forKey: keyIsEnabled)
        guard isEnabled else { return }

        let minutes = UserDefaults.standard.integer(forKey: keyRetentionMinutes)
        if minutes > 0 {
            if let modelContext = self.modelContext {
                Task { [weak self] in
                    guard let self = self else { return }
                    _ = await self.sweepOldTranscriptions(modelContext: modelContext)
                }
            }
            return
        }

        guard let transcription = notification.object as? Transcription,
              let modelContext = self.modelContext else {
            logger.error("Invalid transcription or missing model context")
            return
        }

        // Defer past the poster's call stack: posters keep using the record after
        // `post` returns (e.g. the audio-file queue links it to its item), and a
        // synchronous delete+save invalidates the model under their feet.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            modelContext.delete(transcription)
            do {
                try modelContext.save()
            } catch {
                self.logger.error("Failed to save after transcription deletion: \(error.localizedDescription, privacy: .public)")
                return
            }
            // Delete the record first, the file after: a crash between the two leaves an
            // orphan file the startup sweep collects, not a record pointing at deleted audio.
            if let urlString = transcription.audioFileURL,
               let url = URL(string: urlString) {
                try? FileManager.default.removeItem(at: url)
            }
            NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
        }
    }

    /// Deleted count on success, nil on failure (store error).
    private func sweepOldTranscriptions(modelContext: ModelContext) async -> Int? {
        guard UserDefaults.standard.bool(forKey: keyIsEnabled) else {
            return nil
        }

        let retentionMinutes = UserDefaults.standard.integer(forKey: keyRetentionMinutes)
        let effectiveMinutes = max(retentionMinutes, 0)

        let cutoffDate = Date().addingTimeInterval(TimeInterval(-effectiveMinutes * 60))
        // Never touch a pending row: it is the record a live pipeline is transcribing into,
        // and with retention 0 ("Immediately") a sweep on another completion would delete it
        // — and its WAV — out from under that pipeline.
        let pendingStatus = TranscriptionStatus.pending.rawValue

        let modelContainer = await MainActor.run { modelContext.container }

        do {
            let backgroundContext = ModelContext(modelContainer)

            let descriptor = FetchDescriptor<Transcription>(
                predicate: #Predicate<Transcription> { transcription in
                    transcription.timestamp < cutoffDate
                        && transcription.transcriptionStatus != pendingStatus
                }
            )
            let items = try backgroundContext.fetch(descriptor)
            var deletedCount = 0
            var audioURLs: [URL] = []
            for transcription in items {
                if let urlString = transcription.audioFileURL,
                   let url = URL(string: urlString) {
                    audioURLs.append(url)
                }
                backgroundContext.delete(transcription)
                deletedCount += 1
            }
            if deletedCount > 0 {
                try backgroundContext.save()
                // Files only after the record delete committed: a failed save must leave
                // the records intact; orphaned files are collectable, dangling records are not.
                for url in audioURLs where FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
                logger.notice("Cleaned up \(deletedCount, privacy: .public) old transcription(s)")
                await MainActor.run {
                    NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
                }
            }
            return deletedCount
        } catch {
            logger.error("Failed during transcription cleanup: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Deletes audio files in Recordings directory that have no corresponding Transcription record
    private func cleanupOrphanAudioFiles(modelContext: ModelContext) async {
        guard UserDefaults.standard.bool(forKey: keyIsEnabled) else {
            return
        }

        let modelContainer = await MainActor.run { modelContext.container }

        do {
            let backgroundContext = ModelContext(modelContainer)

            var descriptor = FetchDescriptor<Transcription>()
            descriptor.propertiesToFetch = [\.audioFileURL]

            let transcriptions = try backgroundContext.fetch(descriptor)
            let referencedFiles = Set(transcriptions.compactMap { transcription -> String? in
                guard let urlString = transcription.audioFileURL,
                      let url = URL(string: urlString) else { return nil }
                return url.lastPathComponent
            })

            guard FileManager.default.fileExists(atPath: recordingsDirectory.path) else { return }
            let filesInDirectory = try FileManager.default.contentsOfDirectory(
                at: recordingsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )

            // A recording in progress (or one just stopped, before its Transcription
            // record is saved) has a WAV on disk with no reference yet. Skip files
            // touched within this window so cleanup never deletes live audio; genuine
            // orphans from crashes/cancels are still collected on a later run.
            let recentGrace: TimeInterval = 5 * 60
            let now = Date()

            var deletedCount = 0
            for fileURL in filesInDirectory {
                let fileName = fileURL.lastPathComponent
                guard !referencedFiles.contains(fileName) else { continue }

                if let modified = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   now.timeIntervalSince(modified) < recentGrace {
                    continue
                }

                try? FileManager.default.removeItem(at: fileURL)
                deletedCount += 1
            }

            if deletedCount > 0 {
                logger.notice("Cleaned up \(deletedCount, privacy: .public) orphan audio file(s)")
            }
        } catch {
            logger.error("Failed during orphan audio cleanup: \(error.localizedDescription, privacy: .public)")
        }
    }
}