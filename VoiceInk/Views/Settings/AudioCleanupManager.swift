import Foundation
import SwiftData

/// A utility class that manages automatic cleanup of audio files while preserving transcript data
class AudioCleanupManager {
    static let shared = AudioCleanupManager()

    private var cleanupTimer: Timer?
    
    // Default cleanup settings
    private let defaultRetentionDays = 7
    private let cleanupCheckInterval: TimeInterval = 86400 // Check once per day (in seconds)
    
    private init() {}
    
    /// Start the automatic cleanup process
    func startAutomaticCleanup(modelContext: ModelContext) {
        // Cancel any existing timer
        cleanupTimer?.invalidate()

        // Perform initial cleanup
        Task {
            await performCleanup(modelContext: modelContext)
        }

        // Schedule regular cleanup
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: cleanupCheckInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.performCleanup(modelContext: modelContext)
            }
        }
    }
    
    /// Stop the automatic cleanup process
    func stopAutomaticCleanup() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
    }
    
    /// Get information about the files that would be cleaned up
    func getCleanupInfo(modelContext: ModelContext) async -> (fileCount: Int, totalSize: Int64, transcriptions: [Transcription]) {
        // Get retention period from UserDefaults
        let effectiveRetentionDays = UserDefaults.standard.integer(forKey: "AudioRetentionPeriod")

        // Calculate the cutoff date
        let calendar = Calendar.current
        guard let cutoffDate = calendar.date(byAdding: .day, value: -effectiveRetentionDays, to: Date()) else {
            return (0, 0, [])
        }

        do {
            // Execute SwiftData operations on the main thread
            return try await MainActor.run {
                // Create a predicate to find transcriptions with audio files older than the cutoff date
                let descriptor = FetchDescriptor<Transcription>(
                    predicate: #Predicate<Transcription> { transcription in
                        transcription.timestamp < cutoffDate &&
                        transcription.audioFileURL != nil
                    }
                )

                let transcriptions = try modelContext.fetch(descriptor)

                // Calculate stats (can be done on any thread)
                var fileCount = 0
                var totalSize: Int64 = 0
                var eligibleTranscriptions: [Transcription] = []

                for transcription in transcriptions {
                    if let urlString = transcription.audioFileURL,
                       let url = URL(string: urlString),
                       FileManager.default.fileExists(atPath: url.path) {
                        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                           let fileSize = attributes[.size] as? Int64 {
                            totalSize += fileSize
                            fileCount += 1
                            eligibleTranscriptions.append(transcription)
                        }
                    }
                }

                return (fileCount, totalSize, eligibleTranscriptions)
            }
        } catch {
            return (0, 0, [])
        }
    }
    
    /// Perform the cleanup operation
    private func performCleanup(modelContext: ModelContext) async {
        // Get retention period from UserDefaults
        let effectiveRetentionDays = UserDefaults.standard.integer(forKey: "AudioRetentionPeriod")

        // Check if automatic cleanup is enabled
        let isCleanupEnabled = UserDefaults.standard.bool(forKey: "IsAudioCleanupEnabled")
        guard isCleanupEnabled else { return }

        // Calculate the cutoff date
        let calendar = Calendar.current
        guard let cutoffDate = calendar.date(byAdding: .day, value: -effectiveRetentionDays, to: Date()) else {
            return
        }

        do {
            // Execute SwiftData operations on the main thread
            try await MainActor.run {
                // Create a predicate to find transcriptions with audio files older than the cutoff date
                let descriptor = FetchDescriptor<Transcription>(
                    predicate: #Predicate<Transcription> { transcription in
                        transcription.timestamp < cutoffDate &&
                        transcription.audioFileURL != nil
                    }
                )

                let transcriptions = try modelContext.fetch(descriptor)
                _ = removeAudio(of: transcriptions, in: modelContext)
            }
        } catch {
            // Silently fail - cleanup is non-critical
        }
    }
    
    /// Run cleanup manually - can be called from settings
    func runManualCleanup(modelContext: ModelContext) async {
        await performCleanup(modelContext: modelContext)
    }
    
    /// Run cleanup on the specified transcriptions
    func runCleanupForTranscriptions(modelContext: ModelContext, transcriptions: [Transcription]) async -> (deletedCount: Int, errorCount: Int) {
        await MainActor.run {
            removeAudio(of: transcriptions, in: modelContext)
        }
    }

    // The rows are unlinked and saved before any file goes: a failed save leaves rows and audio
    // intact instead of rows pointing at deleted files. A file that won't delete is relinked.
    @MainActor
    private func removeAudio(of transcriptions: [Transcription], in modelContext: ModelContext) -> (deletedCount: Int, errorCount: Int) {
        var unlinked: [(transcription: Transcription, urlString: String, url: URL)] = []
        for transcription in transcriptions {
            guard let urlString = transcription.audioFileURL,
                  let url = URL(string: urlString),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            transcription.audioFileURL = nil
            unlinked.append((transcription, urlString, url))
        }
        guard !unlinked.isEmpty else { return (0, 0) }

        do {
            try modelContext.save()
        } catch {
            for entry in unlinked { entry.transcription.audioFileURL = entry.urlString }
            return (0, unlinked.count)
        }

        var failed = 0
        for entry in unlinked where (try? FileManager.default.removeItem(at: entry.url)) == nil {
            entry.transcription.audioFileURL = entry.urlString
            failed += 1
        }
        if failed > 0 {
            try? modelContext.save()
        }
        return (unlinked.count - failed, failed)
    }
    
    /// Format file size in human-readable form
    func formatFileSize(_ size: Int64) -> String {
        let byteCountFormatter = ByteCountFormatter()
        byteCountFormatter.allowedUnits = [.useKB, .useMB, .useGB]
        byteCountFormatter.countStyle = .file
        return byteCountFormatter.string(fromByteCount: size)
    }
} 
