import Foundation
import SwiftData
import OSLog

enum SessionMetricRecorder {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SessionMetricRecorder")
    private static let source = "recorder"

    @discardableResult
    static func recordRecorderSession(
        transcription: Transcription,
        model: (any TranscriptionModel)?,
        in modelContext: ModelContext,
        timestamp: Date = Date()
    ) throws -> Bool {
        guard transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue else {
            return false
        }

        let transcriptionId = transcription.id
        let descriptor = FetchDescriptor<SessionMetric>(
            predicate: #Predicate<SessionMetric> { metric in
                metric.transcriptionId == transcriptionId
            }
        )

        if try modelContext.fetchCount(descriptor) > 0 {
            return false
        }

        let textForCounting = finalTextForCounting(from: transcription)
        let wordCount = WordCounter.count(in: textForCounting)
        let audioDuration = max(transcription.duration, 0)
        let transcriptionDuration = transcription.transcriptionDuration.flatMap { $0 > 0 ? $0 : nil }
        let speedFactor = transcriptionDuration.flatMap { duration in
            audioDuration > 0 ? audioDuration / duration : nil
        }

        let enhancementDuration = transcription.enhancementDuration.flatMap { $0 > 0 ? $0 : nil }

        let metric = SessionMetric(
            transcriptionId: transcription.id,
            timestamp: timestamp,
            source: source,
            wordCount: wordCount,
            audioDuration: audioDuration,
            transcriptionModelName: transcription.transcriptionModelName ?? model?.displayName,
            transcriptionDuration: transcriptionDuration,
            speedFactor: speedFactor,
            powerModeName: transcription.powerModeName,
            aiEnhancementModelName: transcription.aiEnhancementModelName,
            enhancementDuration: enhancementDuration
        )

        modelContext.insert(metric)
        logger.notice("Recorded session metric for transcription \(transcriptionId.uuidString, privacy: .public)")
        return true
    }

    private static func finalTextForCounting(from transcription: Transcription) -> String {
        if let enhancedText = transcription.enhancedText,
           transcription.enhancementDuration != nil,
           !enhancedText.isEmpty {
            return enhancedText
        }

        return transcription.text
    }

    /// Keeps the metric row in sync after an in-place re-transcription overwrote the
    /// record — insert-only recording left the dashboard on the old word count and
    /// durations until the record was deleted.
    static func syncAfterRetranscribe(
        transcription: Transcription,
        model: (any TranscriptionModel)?,
        in modelContext: ModelContext
    ) {
        let transcriptionId = transcription.id
        let descriptor = FetchDescriptor<SessionMetric>(
            predicate: #Predicate<SessionMetric> { metric in
                metric.transcriptionId == transcriptionId
            }
        )

        guard let metric = try? modelContext.fetch(descriptor).first else {
            // No row yet (record predates metrics or was migrated without one): insert.
            _ = try? recordRecorderSession(
                transcription: transcription,
                model: model,
                in: modelContext
            )
            return
        }

        let audioDuration = max(transcription.duration, 0)
        let transcriptionDuration = transcription.transcriptionDuration.flatMap { $0 > 0 ? $0 : nil }

        metric.timestamp = transcription.timestamp
        metric.wordCount = WordCounter.count(in: finalTextForCounting(from: transcription))
        metric.audioDuration = audioDuration
        metric.transcriptionModelName = transcription.transcriptionModelName ?? model?.displayName
        metric.transcriptionDuration = transcriptionDuration
        metric.speedFactor = transcriptionDuration.flatMap { duration in
            audioDuration > 0 ? audioDuration / duration : nil
        }
        // retranscribeInPlace clears enhancement fields; mirror that on the metric.
        // powerModeName is NOT reset by the re-transcription — mirror it as-is.
        metric.aiEnhancementModelName = nil
        metric.enhancementDuration = nil
        metric.powerModeName = transcription.powerModeName
    }
}
