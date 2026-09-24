import Foundation
import OSLog

@MainActor
final class AutoLearnAIReviewer {
    private struct AutoLearnReviewRequest: Encodable {
        struct CandidateForReview: Encodable {
            let candidateID: Int
            let originalText: String
            let correctedText: String
        }

        let candidatesForReview: [CandidateForReview]
    }

    private struct CandidateReviewDecision: Decodable {
        let candidateID: Int
        let learningAction: AutoLearnReviewAction
        let incorrectTextToReplace: String?
        let correctedVocabularyTerm: String?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case candidateID
            case learningAction
            case incorrectTextToReplace
            case correctedVocabularyTerm
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let returnedKeys = Set(container.allKeys.map(\.stringValue))
            let expectedKeys = Set(CodingKeys.allCases.map(\.stringValue))
            guard returnedKeys == expectedKeys else {
                throw DecodingError.dataCorruptedError(
                    forKey: .candidateID,
                    in: container,
                    debugDescription: "Each decision must contain exactly the four required fields."
                )
            }

            candidateID = try container.decode(Int.self, forKey: .candidateID)
            learningAction = try container.decode(AutoLearnReviewAction.self, forKey: .learningAction)
            incorrectTextToReplace = try container.decodeIfPresent(String.self, forKey: .incorrectTextToReplace)
            correctedVocabularyTerm = try container.decodeIfPresent(String.self, forKey: .correctedVocabularyTerm)
        }
    }

    enum ReviewError: LocalizedError {
        case unavailable
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return String(localized: "The configured AI enhancement provider cannot review Auto Learn candidates.")
            case .invalidResponse:
                return String(localized: "The AI returned an invalid Auto Learn review response.")
            }
        }
    }

    private let enhancementService: AIEnhancementService
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AutoLearnAIReview")

    init(enhancementService: AIEnhancementService) {
        self.enhancementService = enhancementService
    }

    /// Lets queued reviews wait for a provider that is still starting up instead of recording a failure.
    var hasAvailableProvider: Bool {
        guard let aiService = enhancementService.getAIService() else { return false }
        return resolvedProvider(in: aiService) != nil
    }

    func review(_ candidates: [AutoLearnReviewCandidate]) async throws -> AutoLearnReviewResult {
        guard !candidates.isEmpty else {
            return AutoLearnReviewResult(reviewDecisions: [], unresolvedReviews: [])
        }
        guard let aiService = enhancementService.getAIService(),
              let provider = resolvedProvider(in: aiService) else {
            throw ReviewError.unavailable
        }
        // Custom has no model list to pick from, so follow the model configured for it in AI settings.
        let modelName = provider == .custom
            ? aiService.selectedModel(for: provider)
            : AutoLearnSettings.selectedModel ?? aiService.selectedModel(for: provider)

        let candidatesForReview = candidates.enumerated().map { index, candidate in
            AutoLearnReviewRequest.CandidateForReview(
                candidateID: index,
                originalText: candidate.originalText,
                correctedText: candidate.correctedText
            )
        }
        let requestData = try JSONEncoder().encode(
            AutoLearnReviewRequest(candidatesForReview: candidatesForReview)
        )
        let requestText = String(decoding: requestData, as: UTF8.self)

        Self.logger.notice(
            "Auto Learn review started provider=\(provider.rawValue, privacy: .public) model=\(modelName, privacy: .public) candidates=\(candidates.count, privacy: .public)"
        )
        let responseText = try await enhancementService.reviewAutoLearnCandidates(
            payload: requestText,
            systemPrompt: Self.reviewPrompt,
            provider: provider,
            modelName: modelName
        )
        return try Self.reviewResult(from: responseText, for: candidates)
    }

    /// Adopts the enhancement provider once at launch, before a Power Mode session can swap it.
    func prepareProviderAtLaunch() async {
        guard let aiService = enhancementService.getAIService() else { return }
        if (AutoLearnSettings.selectedProvider ?? aiService.selectedProvider) == .ollama {
            _ = await aiService.refreshOllamaConnectionAndModels()
        }
        guard AutoLearnSettings.selectedProvider == nil,
              let provider = resolvedProvider(in: aiService) else { return }
        UserDefaults.standard.set(provider.rawValue, forKey: AutoLearnSettings.providerKey)
        UserDefaults.standard.set(aiService.selectedModel(for: provider), forKey: AutoLearnSettings.modelKey)
    }

    // The user's Auto Learn choice wins, else the enhancement provider. Never an arbitrary
    // provider that merely has a key (e.g. one saved only for transcription).
    private func resolvedProvider(in aiService: AIService) -> AIProvider? {
        let connectedProviders = aiService.connectedProviders.filter {
            AutoLearnProviderPolicy.isSupported($0)
                && ($0 != .ollama || !aiService.availableModels(for: $0).isEmpty)
        }
        let provider = AutoLearnSettings.selectedProvider ?? aiService.selectedProvider
        guard connectedProviders.contains(provider) else { return nil }
        return provider
    }

    static func reviewResult(
        from responseText: String,
        for candidates: [AutoLearnReviewCandidate]
    ) throws -> AutoLearnReviewResult {
        let candidateReviewDecisions = try decodeResponse(responseText)
        let expectedCandidateIDs = Set(candidates.indices)
        let decisionsByCandidateID = Dictionary(grouping: candidateReviewDecisions) { $0.candidateID }
        let correctedContexts = candidates.map(\.correctedText)
        for unknownCandidateID in decisionsByCandidateID.keys
        where !expectedCandidateIDs.contains(unknownCandidateID) {
            logger.warning("Ignoring Auto Learn decision with unknown candidate ID=\(unknownCandidateID, privacy: .public)")
        }

        var reviewDecisions: [AutoLearnReviewDecision] = []
        var unresolvedReviews: [AutoLearnUnresolvedReview] = []

        for (index, candidate) in candidates.enumerated() {
            guard let matchingDecisions = decisionsByCandidateID[index] else {
                unresolvedReviews.append(unresolvedReview(for: candidate, reason: .missingDecision))
                continue
            }

            // One diff candidate can hold adjacent corrections with no unchanged token
            // between them; allow separating them, never mixing acceptance with rejection.
            if matchingDecisions.count > 1,
               matchingDecisions.contains(where: { $0.learningAction == .rejectCorrection }) {
                unresolvedReviews.append(
                    unresolvedReview(for: candidate, reason: .conflictingDecisions, decision: matchingDecisions.first)
                )
                continue
            }

            var validatedDecisions: [AutoLearnReviewDecision] = []
            var unresolvedDecision: AutoLearnUnresolvedReview?
            for decision in matchingDecisions {
                let validation = validate(decision, for: candidate, correctedContexts: correctedContexts)
                guard let validatedDecision = validation.decision else {
                    unresolvedDecision = unresolvedReview(
                        for: candidate,
                        reason: validation.failure ?? .invalidRequiredActionValues,
                        decision: decision
                    )
                    break
                }
                validatedDecisions.append(validatedDecision)
            }

            if let unresolvedDecision {
                unresolvedReviews.append(unresolvedDecision)
            } else if !decisionsAreIndependent(validatedDecisions, for: candidate) {
                unresolvedReviews.append(
                    unresolvedReview(for: candidate, reason: .conflictingDecisions, decision: matchingDecisions.first)
                )
            } else {
                reviewDecisions.append(contentsOf: validatedDecisions)
            }
        }

        return AutoLearnReviewResult(reviewDecisions: reviewDecisions, unresolvedReviews: unresolvedReviews)
    }

    private static func unresolvedReview(
        for candidate: AutoLearnReviewCandidate,
        reason: AutoLearnUnresolvedReason,
        decision: CandidateReviewDecision? = nil
    ) -> AutoLearnUnresolvedReview {
        AutoLearnUnresolvedReview(
            candidateID: candidate.candidateID,
            reason: reason,
            learningAction: decision?.learningAction,
            incorrectTextToReplace: decision?.incorrectTextToReplace,
            correctedVocabularyTerm: decision?.correctedVocabularyTerm
        )
    }

    private static func validate(
        _ decision: CandidateReviewDecision,
        for candidate: AutoLearnReviewCandidate,
        correctedContexts: [String]
    ) -> (decision: AutoLearnReviewDecision?, failure: AutoLearnUnresolvedReason?) {
        let rejection = AutoLearnReviewDecision(
            candidateID: candidate.candidateID,
            learningAction: .rejectCorrection,
            incorrectTextToReplace: nil,
            correctedVocabularyTerm: nil
        )
        if decision.learningAction == .rejectCorrection {
            return (rejection, nil)
        }

        guard let correctedVocabularyTerm = decision.correctedVocabularyTerm?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return (nil, .missingRequiredActionValues)
        }
        guard !correctedVocabularyTerm.isEmpty,
              correctedVocabularyTerm.count <= AutoLearnLimits.maximumCandidateCharacters,
              correctedContexts.contains(where: { isExactSubstring(correctedVocabularyTerm, of: $0) }) else {
            return (nil, .invalidRequiredActionValues)
        }

        if decision.learningAction == .addVocabularyOnly {
            return (
                AutoLearnReviewDecision(
                    candidateID: candidate.candidateID,
                    learningAction: .addVocabularyOnly,
                    incorrectTextToReplace: nil,
                    correctedVocabularyTerm: correctedVocabularyTerm
                ),
                nil
            )
        }

        guard let incorrectTextToReplace = decision.incorrectTextToReplace?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return (nil, .missingRequiredActionValues)
        }
        guard !incorrectTextToReplace.isEmpty,
              incorrectTextToReplace != correctedVocabularyTerm,
              incorrectTextToReplace.count <= AutoLearnLimits.maximumCandidateCharacters,
              !incorrectTextToReplace.contains(","),
              isExactSubstring(incorrectTextToReplace, of: candidate.originalText) else {
            return (nil, .invalidRequiredActionValues)
        }

        if incorrectTextToReplace.compare(correctedVocabularyTerm, options: .caseInsensitive) == .orderedSame {
            return (rejection, nil)
        }

        return (
            AutoLearnReviewDecision(
                candidateID: candidate.candidateID,
                learningAction: decision.learningAction,
                incorrectTextToReplace: incorrectTextToReplace,
                correctedVocabularyTerm: correctedVocabularyTerm
            ),
            nil
        )
    }

    private static func isExactSubstring(_ term: String, of context: String) -> Bool {
        context.range(of: term, options: .literal) != nil
    }

    private static func decisionsAreIndependent(
        _ decisions: [AutoLearnReviewDecision],
        for candidate: AutoLearnReviewCandidate
    ) -> Bool {
        let originalTerms = decisions.compactMap(\.incorrectTextToReplace)
        guard canLocateWithoutOverlap(originalTerms, in: candidate.originalText) else {
            return false
        }

        // Batch canonicalization may return a corrected term from another
        // candidate, so only test terms present in this snippet.
        let localCorrectedTerms = decisions.compactMap(\.correctedVocabularyTerm).filter {
            isExactSubstring($0, of: candidate.correctedText)
        }
        return canLocateWithoutOverlap(localCorrectedTerms, in: candidate.correctedText)
    }

    private static func canLocateWithoutOverlap(_ terms: [String], in text: String) -> Bool {
        guard terms.count > 1 else { return true }
        let text = text as NSString
        let rangesByTerm = terms.map { term -> [NSRange] in
            var matches: [NSRange] = []
            var searchRange = NSRange(location: 0, length: text.length)
            while searchRange.length > 0 {
                let match = text.range(of: term, options: .literal, range: searchRange)
                guard match.location != NSNotFound else { break }
                matches.append(match)
                let nextLocation = match.location + 1
                guard nextLocation < text.length else { break }
                searchRange = NSRange(location: nextLocation, length: text.length - nextLocation)
            }
            return matches
        }

        func assign(_ termIndex: Int, occupied: [NSRange]) -> Bool {
            guard termIndex < rangesByTerm.count else { return true }
            for range in rangesByTerm[termIndex]
            where occupied.allSatisfy({ NSIntersectionRange($0, range).length == 0 }) {
                if assign(termIndex + 1, occupied: occupied + [range]) {
                    return true
                }
            }
            return false
        }

        return assign(0, occupied: [])
    }

    private static func decodeResponse(_ text: String) throws -> [CandidateReviewDecision] {
        let payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasPrefix("```") {
            logInvalidResponse(payload, reason: "markdown-code-fence")
            throw ReviewError.invalidResponse
        }

        let data = Data(payload.utf8)
        do {
            return try JSONDecoder().decode([CandidateReviewDecision].self, from: data)
        } catch {
            logInvalidResponse(payload, reason: invalidResponseReason(for: data))
            throw ReviewError.invalidResponse
        }
    }

    private static func logInvalidResponse(_ payload: String, reason: String) {
        let preview = String(payload.prefix(1_000))
        logger.error(
            "Auto Learn response invalid reason=\(reason, privacy: .public) characters=\(payload.count, privacy: .public) responsePreview=\(preview, privacy: .private)"
        )
    }

    private static func invalidResponseReason(for data: Data) -> String {
        guard let value = try? JSONSerialization.jsonObject(with: data) else { return "malformed-json" }
        if value is [Any] { return "invalid-decision-array" }
        if value is [String: Any] { return "expected-top-level-array" }
        return "unsupported-json-shape"
    }

    private static let reviewPrompt = """
        Review speech-to-text corrections. Each candidate has originalText and correctedText containing the edit plus up to three surrounding words on each side.

        Mandatory personal-name rule: A personal name is one indivisible term. For a visible multiword personal name, incorrectTextToReplace and correctedVocabularyTerm must contain every visible name component, including every unchanged component. Apply this rule even when only a middle name, surname, particle, spacing, punctuation, or suffix changed. Returning only the changed fragment or one component of a visible multiword name is invalid. When only one personal-name component is visible, such as only a first name or only a surname, it may qualify for addReplacementOnly but must not be added to Vocabulary. Allow a single-word personal name into Vocabulary only when context clearly establishes that the person is genuinely known by that complete mononym, not merely because only one name component appears in the snippet. Never invent name components that are not visible.

        Identify every independently reusable correction. Usually return one decision per candidate. Separate adjacent independent terms. If learnable and ordinary edits are mixed, return only the learnable corrections. Return rejectCorrection only when nothing is learnable, and never mix rejection with acceptance for one candidateID.

        Before selecting an action, every acceptance must pass both gates:

        1. Phonetic evidence: the changed source and destination spans must recognizably resemble two renderings of the same spoken term. Judge a multiword personal name collectively. Differences caused by accent, transliteration, word boundaries, hyphenation, or omitted diacritics may still be phonetic when the pronunciations plausibly correspond. Related meaning, context, specificity, private status, and Vocabulary usefulness are not themselves phonetic evidence. Reject absent or uncertain resemblance.

        2. No semantic rewrite: reject edits that change meaning or replace coherent language—a description, role, category, purpose, location, relationship, criterion, synonym, or placeholder—with a specific person, place, product, service, or term. Discard them completely even when the destination qualifies for Vocabulary.

        Only edits passing both gates may be accepted. Audit every acceptance against both gates before returning it; convert failures or uncertainty to rejectCorrection with both text fields null.

        Choose one learningAction:

        1. addReplacementAndVocabulary: the corrected term passes the Vocabulary gate and the original plausibly sounds like it.
        2. addReplacementOnly: use for a distinctive, unambiguous, user-specific correction that is worth applying again but whose corrected term should not enter Vocabulary. This includes a learnable correction to a single visible first name or surname when the person's complete name is not visible. Never use this as a fallback for public, common, or generic terms.
        3. addVocabularyOnly: the corrected term passes the Vocabulary gate and the pair passes the phonetic gate, but the source is too broad or ambiguous for a safe global replacement. Never use this for a partial personal name, coherent descriptions, semantic rewrites, deliberate abbreviations, or expansions.
        4. rejectCorrection: nothing is safely reusable, including ordinary wording, grammar, style, meaning, facts, numbers, dates, abbreviations, expansions, changed qualifiers, editions, generic type words, and corrections a capable general-purpose ASR model should handle without permanent user-specific learning.

        Vocabulary is primarily for complete personal names. A person's first name, surname, or other single component must not enter Vocabulary by itself unless it is clearly the person's complete mononym. This personal-name restriction does not apply to qualifying non-person entities: a single-token internal brand, project, private product, username, specialized term, small organization, or uncommon local place may enter Vocabulary when it is genuinely user-specific, private, or obscure enough to improve recognition.

        Use context to identify user-specific entities. “Call”, “email”, “ask”, “invite”, or “send to” supports interpreting the adjacent text as a personal name. For a phonetically plausible personal name, spelling, apostrophe, spacing, hyphenation, and diacritic corrections are learnable—not formatting-only edits. A personal name remains learnable when it belongs to a well-known or public person. Labels such as “project”, “internal”, “repository”, “account”, “tenant”, or “pipeline” similarly support a user-specific entity. Context never substitutes for phonetic evidence or permits a semantic rewrite.

        Do not learn ordinary words, brands, products, technologies, places, or organizations. Examples include Microsoft, Apple, Google, Xcode, Markdown, React, PostgreSQL, and GitHub. VoiceInk is user-specific and may be learned. Outside the user-specific contexts above, capitalization or proper-noun appearance alone is insufficient; when uncertain, reject.

        Reject case-only changes and partial unsafe mappings.

        Batch canonicalization: when corrected terms are clearly spelling or pronunciation variants of one entity, use one corrected form already present in correctedText for all related acceptances. Prefer the most frequent, then most complete plausible form. Never invent a form or merge by meaning alone.

        For replacement actions, incorrectTextToReplace must be an exact nonempty contiguous substring of that candidate's originalText and correctedVocabularyTerm must be copied from correctedText, except canonicalization may copy it from another candidate. For addVocabularyOnly set incorrectTextToReplace to null. For rejectCorrection set both fields to null.

        Before returning a personal-name decision, treat a visible multiword name as one indivisible term and verify that both fields contain the complete original and corrected names, even if only one component changed. Example: "Prakash Joshi Pages" to "Prakash Joshi Pax" must use the complete names, never only "Pages" to "Pax". If only one first name or surname is visible and the correction is otherwise safe and learnable, return addReplacementOnly for that visible component. Do not add it to Vocabulary and do not reject it merely because the person's full name is unavailable. Use a Vocabulary action for a single-word personal name only when the context clearly identifies a genuine mononym.

        Return only one JSON array. Do not return an outer object, reviewDecisions key, explanation, Markdown, or code fence. Each array object must contain exactly these four fields: candidateID, learningAction, incorrectTextToReplace, and correctedVocabularyTerm.

        Exact output format:
        [{"candidateID":0,"learningAction":"addReplacementAndVocabulary","incorrectTextToReplace":"original term","correctedVocabularyTerm":"corrected term"},{"candidateID":1,"learningAction":"rejectCorrection","incorrectTextToReplace":null,"correctedVocabularyTerm":null}]

        Allowed actions are addReplacementAndVocabulary, addReplacementOnly, addVocabularyOnly, and rejectCorrection. Copy every integer candidateID exactly and return each input candidateID at least once. Repeat an ID only for independent accepted corrections.

        """
}
