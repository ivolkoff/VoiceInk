import Foundation
import SwiftData
import Testing
@testable import VoiceInk

@MainActor
struct AutoLearnTests {
    // MARK: - CorrectionDiffEngine

    @Test func singleWordFixYieldsOneCandidateWithContext() {
        let candidates = CorrectionDiffEngine.candidates(from: AutoLearnRevision(
            original: "Please call Jon Smith tomorrow",
            corrected: "Please call John Smith tomorrow"
        ))

        #expect(candidates == [DetectedCorrectionCandidate(
            originalText: "Please call Jon Smith tomorrow",
            correctedText: "Please call John Smith tomorrow"
        )])
    }

    @Test func sourceSpanningACommaIsRejected() {
        let candidates = CorrectionDiffEngine.candidates(from: AutoLearnRevision(
            original: "alpha, beta gamma",
            corrected: "delta gamma"
        ))

        #expect(candidates.isEmpty)
    }

    @Test func hunkOverSegmentLimitIsRejected() {
        let count = AutoLearnLimits.maximumCandidateSegments + 1
        let original = (0..<count).map { "old\($0)" }.joined(separator: " ")
        let corrected = (0..<count).map { "new\($0)" }.joined(separator: " ")

        let candidates = CorrectionDiffEngine.candidates(from: AutoLearnRevision(
            original: "Start \(original) end",
            corrected: "Start \(corrected) end"
        ))

        #expect(candidates.isEmpty)
    }

    // MARK: - FinalSnapshotDiffEngine

    private func snapshot(pasted: String, finalText: String) -> AutoLearnFieldSnapshot {
        let baseline = "Header text. \(pasted) Footer text"
        return AutoLearnFieldSnapshot(
            baselineFieldText: baseline,
            finalFieldText: finalText,
            pastedRange: (baseline as NSString).range(of: pasted),
            originalPastedText: pasted
        )
    }

    @Test func locatesTheEditedPastedSpanBetweenAnchors() {
        let revision = FinalSnapshotDiffEngine.revision(from: snapshot(
            pasted: "Please call Jon Smith tomorrow.",
            finalText: "Header text. Please call John Smith tomorrow. Footer text"
        ))

        #expect(revision?.original == "Please call Jon Smith tomorrow.")
        #expect(revision?.corrected == "Please call John Smith tomorrow.")
    }

    @Test func returnsNilWhenTheFieldWasReplacedBeyondRecognition() {
        let revision = FinalSnapshotDiffEngine.revision(from: snapshot(
            pasted: "Please call Jon Smith tomorrow.",
            finalText: "Something completely different was typed here instead"
        ))

        #expect(revision == nil)
    }

    // MARK: - AutoLearnAIReviewer response validation

    private let candidate = AutoLearnReviewCandidate(
        candidateID: UUID(),
        originalText: "Please call Jon Smith tomorrow",
        correctedText: "Please call John Smith tomorrow"
    )

    @Test func validDecisionIsAccepted() throws {
        let response = #"[{"candidateID":0,"learningAction":"addReplacementAndVocabulary","incorrectTextToReplace":"Jon Smith","correctedVocabularyTerm":"John Smith"}]"#

        let result = try AutoLearnAIReviewer.reviewResult(from: response, for: [candidate])

        #expect(result.unresolvedReviews.isEmpty)
        #expect(result.reviewDecisions.count == 1)
        let decision = try #require(result.reviewDecisions.first)
        #expect(decision.candidateID == candidate.candidateID)
        #expect(decision.learningAction == .addReplacementAndVocabulary)
        #expect(decision.incorrectTextToReplace == "Jon Smith")
        #expect(decision.correctedVocabularyTerm == "John Smith")
    }

    @Test func replacementSourceMissingFromOriginalTextIsRejected() throws {
        let response = #"[{"candidateID":0,"learningAction":"addReplacementOnly","incorrectTextToReplace":"Jan Smith","correctedVocabularyTerm":"John Smith"}]"#

        let result = try AutoLearnAIReviewer.reviewResult(from: response, for: [candidate])

        #expect(result.reviewDecisions.isEmpty)
        #expect(result.unresolvedReviews.map(\.reason) == [.invalidRequiredActionValues])
    }

    @Test func codeFencedResponseIsInvalid() {
        #expect(throws: AutoLearnAIReviewer.ReviewError.self) {
            try AutoLearnAIReviewer.reviewResult(from: "```json\n[]\n```", for: [candidate])
        }
    }

    // MARK: - WordReplacementStore

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: VocabularyWord.self, WordReplacement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func decision(
        _ action: AutoLearnReviewAction,
        _ source: String?,
        _ destination: String
    ) -> AutoLearnReviewDecision {
        AutoLearnReviewDecision(
            candidateID: candidate.candidateID,
            learningAction: action,
            incorrectTextToReplace: source,
            correctedVocabularyTerm: destination
        )
    }

    @Test func applyCreatesReplacementAndVocabularyAndUndoRemovesThem() async throws {
        let container = try makeContainer()
        let store = WordReplacementStore(modelContainer: container)

        let summary = try await store.apply(
            [decision(.addReplacementAndVocabulary, "Jon Smith", "John Smith")],
            candidates: [candidate]
        )

        #expect(summary.createdCount == 1)
        #expect(summary.vocabularyCount == 1)
        let context = ModelContext(container)
        let rules = try context.fetch(FetchDescriptor<WordReplacement>())
        #expect(rules.map(\.originalText) == ["Jon Smith"])
        #expect(rules.map(\.replacementText) == ["John Smith"])
        #expect(try context.fetch(FetchDescriptor<VocabularyWord>()).map(\.word) == ["John Smith"])

        try await store.undo(try #require(summary.learnedCorrections.first))

        let afterUndo = ModelContext(container)
        #expect(try afterUndo.fetch(FetchDescriptor<WordReplacement>()).isEmpty)
        #expect(try afterUndo.fetch(FetchDescriptor<VocabularyWord>()).isEmpty)
    }

    @Test func applyAddsSourceToExistingRuleAndSkipsCycles() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        seed.insert(WordReplacement(originalText: "Jhon Smith", replacementText: "John Smith"))
        try seed.save()
        let store = WordReplacementStore(modelContainer: container)

        let summary = try await store.apply(
            [
                decision(.addReplacementOnly, "Jon Smith", "John Smith"),
                // "John Smith" → "Jhon Smith" would loop with the seeded rule.
                decision(.addReplacementOnly, "John Smith", "Jhon Smith"),
            ],
            candidates: [candidate]
        )

        #expect(summary.createdCount == 0)
        #expect(summary.updatedCount == 1)
        #expect(summary.vocabularyCount == 0)
        let rules = try ModelContext(container).fetch(FetchDescriptor<WordReplacement>())
        #expect(rules.map(\.originalText) == ["Jhon Smith, Jon Smith"])
    }
}
