import Foundation

actor AutoLearnPendingQueue {
    private enum ReviewStatus: String, Codable {
        case pending
        case reviewing
    }

    private struct QueuedCorrection: Codable {
        let candidateID: UUID
        let originalText: String
        let correctedText: String
        var reviewStatus: ReviewStatus

        var reviewCandidate: AutoLearnReviewCandidate {
            AutoLearnReviewCandidate(
                candidateID: candidateID,
                originalText: originalText,
                correctedText: correctedText
            )
        }
    }

    private let fileManager: FileManager
    private let queueFileURL: URL
    private var queuedCorrections: [QueuedCorrection] = []
    private var queuedCorrectionsWereLoaded = false

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        queueFileURL = applicationSupport
            .appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
            .appendingPathComponent("auto-learn-pending-corrections.json")
    }

    func recoverInterruptedReviews() throws {
        try loadIfNeeded()
        let snapshot = queuedCorrections
        var changed = false
        for index in queuedCorrections.indices
        where queuedCorrections[index].reviewStatus == .reviewing {
            queuedCorrections[index].reviewStatus = .pending
            changed = true
        }
        if changed {
            do { try save() } catch { queuedCorrections = snapshot; throw error }
        }
    }

    func enqueue(_ candidates: [DetectedCorrectionCandidate]) throws -> Int {
        guard !candidates.isEmpty else { return 0 }
        try loadIfNeeded()
        let originalQueuedCorrections = queuedCorrections

        var knownPairs = Set(
            queuedCorrections.map {
                pairKey(originalText: $0.originalText, correctedText: $0.correctedText)
            }
        )
        var insertedCount = 0
        for candidate in candidates {
            let originalText = candidate.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
            let correctedText = candidate.correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !originalText.isEmpty, !correctedText.isEmpty else { continue }

            let correctionPairKey = pairKey(originalText: originalText, correctedText: correctedText)
            guard knownPairs.insert(correctionPairKey).inserted else { continue }
            queuedCorrections.append(
                QueuedCorrection(
                    candidateID: UUID(),
                    originalText: originalText,
                    correctedText: correctedText,
                    reviewStatus: .pending
                )
            )
            insertedCount += 1
        }

        if insertedCount > 0 {
            do {
                try save()
            } catch {
                queuedCorrections = originalQueuedCorrections
                throw error
            }
        }
        return insertedCount
    }

    /// Excludes entries claimed by an in-flight batch so callers only see actionable work.
    func pendingCount() throws -> Int {
        try loadIfNeeded()
        return queuedCorrections.filter { $0.reviewStatus == .pending }.count
    }

    /// Includes a claimed batch so status reporting still counts it as outstanding.
    func outstandingCount() throws -> Int {
        try loadIfNeeded()
        return queuedCorrections.count
    }

    func claimPending(limit: Int) throws -> [AutoLearnReviewCandidate] {
        try loadIfNeeded()

        let pendingCorrectionIndices = queuedCorrections.indices
            .filter { queuedCorrections[$0].reviewStatus == .pending }
            .prefix(max(0, limit))
        guard !pendingCorrectionIndices.isEmpty else { return [] }

        for index in pendingCorrectionIndices {
            queuedCorrections[index].reviewStatus = .reviewing
        }
        do {
            try save()
        } catch {
            for index in pendingCorrectionIndices {
                queuedCorrections[index].reviewStatus = .pending
            }
            throw error
        }
        return pendingCorrectionIndices.map { queuedCorrections[$0].reviewCandidate }
    }

    func release(_ candidateIDs: Set<UUID>) throws {
        guard !candidateIDs.isEmpty else { return }
        try loadIfNeeded()
        let snapshot = queuedCorrections

        var changed = false
        for index in queuedCorrections.indices
        where candidateIDs.contains(queuedCorrections[index].candidateID) {
            queuedCorrections[index].reviewStatus = .pending
            changed = true
        }
        if changed {
            do { try save() } catch { queuedCorrections = snapshot; throw error }
        }
    }

    func remove(_ candidateIDs: Set<UUID>) throws {
        guard !candidateIDs.isEmpty else { return }
        try loadIfNeeded()

        let snapshot = queuedCorrections
        let originalCount = queuedCorrections.count
        queuedCorrections.removeAll { candidateIDs.contains($0.candidateID) }
        if queuedCorrections.count != originalCount {
            do { try save() } catch { queuedCorrections = snapshot; throw error }
        }
    }

    private func loadIfNeeded() throws {
        guard !queuedCorrectionsWereLoaded else { return }
        guard fileManager.fileExists(atPath: queueFileURL.path) else {
            queuedCorrectionsWereLoaded = true
            return
        }

        let data = try Data(contentsOf: queueFileURL)
        queuedCorrections = try Self.decodeCorrections(from: data)
        queuedCorrectionsWereLoaded = true
    }

    /// Decodes entry by entry so one unreadable record cannot strand the whole queue.
    private static func decodeCorrections(from data: Data) throws -> [QueuedCorrection] {
        let decoder = JSONDecoder()
        guard let records = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Auto Learn queue file is not a JSON array"
                )
            )
        }

        return records.compactMap { record in
            guard let recordData = try? JSONSerialization.data(withJSONObject: record) else {
                return nil
            }
            return try? decoder.decode(QueuedCorrection.self, from: recordData)
        }
    }

    private func save() throws {
        let directory = queueFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(queuedCorrections)
        try data.write(to: queueFileURL, options: .atomic)
    }

    private func pairKey(originalText: String, correctedText: String) -> String {
        WordReplacementVariants.key(for: originalText) + "\u{0}"
            + WordReplacementVariants.destinationKey(for: correctedText)
    }
}
