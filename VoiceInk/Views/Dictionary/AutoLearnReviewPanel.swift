import SwiftUI

struct AutoLearnReviewPanel: View {
    fileprivate enum ReviewComponent: Hashable {
        case replacement
        case vocabulary
    }

    fileprivate struct ReviewDraft: Equatable {
        var incorrectText: String
        var correctedTerm: String

        init(proposal: AutoLearnReviewProposal) {
            incorrectText = proposal.incorrectTextToReplace ?? ""
            correctedTerm = proposal.correctedVocabularyTerm ?? ""
        }
    }

    let onClose: () -> Void

    @State private var proposals: [AutoLearnReviewProposal] = []
    @State private var selections: [UUID: Set<ReviewComponent>] = [:]
    @State private var drafts: [UUID: ReviewDraft] = [:]
    @State private var isReviewing = false
    @State private var isApplying = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            if proposals.isEmpty, !isReviewing {
                emptyState
            } else {
                reviewList
            }

            if !proposals.isEmpty {
                footer
            }
        }
        .task {
            await loadAndReview()
        }
        .onReceive(NotificationCenter.default.publisher(for: .autoLearnReviewProposalsDidChange)) { _ in
            Task { await reloadProposals(selectNewItems: true) }
        }
        .onDisappear(perform: persistEditedDrafts)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Review Corrections")
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            InfoTip("The arrow icon refers to Word Replacement. The book icon refers to Vocabulary.")

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(6)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private var reviewList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if isReviewing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reviewing pending corrections…")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(proposals) { proposal in
                    AutoLearnReviewProposalRow(
                        proposal: proposal,
                        draft: draftBinding(for: proposal),
                        selectedComponents: selections[proposal.id] ?? [],
                        onToggleAll: { isSelected in
                            selections[proposal.id] = isSelected ? availableComponents(for: proposal) : []
                        },
                        onToggleComponent: { component in
                            var selected = selections[proposal.id] ?? []
                            if selected.contains(component) {
                                selected.remove(component)
                            } else {
                                selected.insert(component)
                            }
                            selections[proposal.id] = selected
                        },
                        onCommitEdits: { persist($0, for: proposal) }
                    )
                    .disabled(isApplying)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Corrections to Review", systemImage: "checkmark.circle")
        } description: {
            Text(errorMessage ?? String(localized: "New manual-review suggestions will appear here."))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Dismiss All", role: .destructive) {
                dismiss(Set(proposals.map(\.id)))
            }
            .disabled(isApplying || isReviewing)

            Spacer()

            Button(applyButtonTitle) {
                applySelections()
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedProposalCount == 0 || firstValidationIssue != nil || isApplying || isReviewing)
            .help(firstValidationIssue ?? String(localized: "Apply the selected corrections"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(Divider().opacity(0.5), alignment: .top)
    }

    private var applyButtonTitle: String {
        if proposals.allSatisfy({ selections[$0.id] == availableComponents(for: $0) }) {
            return String(localized: "Apply All (\(proposals.count))")
        }
        return String(localized: "Apply Selected (\(selectedProposalCount))")
    }

    private var selectedProposalCount: Int {
        proposals.filter { !(selections[$0.id] ?? []).isEmpty }.count
    }

    private var firstValidationIssue: String? {
        for proposal in proposals {
            let selected = selections[proposal.id] ?? []
            guard !selected.isEmpty else { continue }
            let draft = drafts[proposal.id] ?? ReviewDraft(proposal: proposal)
            if let issue = Self.validationIssue(for: draft, includesReplacement: selected.contains(.replacement)) {
                return issue
            }
        }
        return nil
    }

    fileprivate static func validationIssue(for draft: ReviewDraft, includesReplacement: Bool) -> String? {
        let correctedTerm = draft.correctedTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        if correctedTerm.isEmpty {
            return String(localized: "The corrected value cannot be empty.")
        }
        guard includesReplacement else { return nil }
        let incorrectText = draft.incorrectText.trimmingCharacters(in: .whitespacesAndNewlines)
        if incorrectText.isEmpty {
            return String(localized: "The original value cannot be empty.")
        }
        if incorrectText.contains(",") {
            return String(localized: "A reviewed replacement can contain only one original value.")
        }
        if incorrectText.precomposedStringWithCanonicalMapping == correctedTerm.precomposedStringWithCanonicalMapping {
            return String(localized: "The original and corrected values must be different.")
        }
        return nil
    }

    @MainActor
    private func loadAndReview() async {
        isReviewing = true
        errorMessage = nil
        await reloadProposals(selectNewItems: true)
        await AutoLearnService.shared.preparePendingReviewForApproval()
        await reloadProposals(selectNewItems: true)
        isReviewing = false

        let pendingCount = (try? await AutoLearnService.shared.pendingReviewCount()) ?? 0
        if pendingCount > 0, errorMessage == nil {
            errorMessage = String(
                localized: "Some corrections could not be reviewed. Check the selected AI provider and try again."
            )
        }
    }

    @MainActor
    private func reloadProposals(selectNewItems: Bool) async {
        do {
            let loaded = try await AutoLearnService.shared.reviewProposals()
            let loadedIDs = Set(loaded.map(\.id))
            for proposal in loaded {
                if drafts[proposal.id] == nil {
                    drafts[proposal.id] = ReviewDraft(proposal: proposal)
                }
                if selectNewItems, selections[proposal.id] == nil {
                    selections[proposal.id] = availableComponents(for: proposal)
                }
            }
            selections = selections.filter { loadedIDs.contains($0.key) }
            drafts = drafts.filter { loadedIDs.contains($0.key) }
            proposals = loaded
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applySelections() {
        let reviewSelections = proposals.compactMap { proposal -> AutoLearnReviewSelection? in
            let selected = selections[proposal.id] ?? []
            guard !selected.isEmpty else { return nil }
            let draft = drafts[proposal.id] ?? ReviewDraft(proposal: proposal)
            return AutoLearnReviewSelection(
                proposalID: proposal.id,
                includesReplacement: selected.contains(.replacement),
                includesVocabulary: selected.contains(.vocabulary),
                incorrectTextToReplace: draft.incorrectText.trimmingCharacters(in: .whitespacesAndNewlines),
                correctedVocabularyTerm: draft.correctedTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard !reviewSelections.isEmpty, firstValidationIssue == nil else { return }
        Task { @MainActor in
            isApplying = true
            errorMessage = nil
            do {
                _ = try await AutoLearnService.shared.applyReviewProposals(reviewSelections)
                await reloadProposals(selectNewItems: false)
            } catch {
                errorMessage = error.localizedDescription
            }
            isApplying = false
        }
    }

    private func draftBinding(for proposal: AutoLearnReviewProposal) -> Binding<ReviewDraft> {
        Binding(
            get: { drafts[proposal.id] ?? ReviewDraft(proposal: proposal) },
            set: { drafts[proposal.id] = $0 }
        )
    }

    // Edits survive closing the panel even when Return was never pressed.
    private func persistEditedDrafts() {
        for proposal in proposals {
            if let draft = drafts[proposal.id], draft != ReviewDraft(proposal: proposal) {
                persist(draft, for: proposal)
            }
        }
    }

    private func persist(_ draft: ReviewDraft, for proposal: AutoLearnReviewProposal) {
        let incorrectText = draft.incorrectText.trimmingCharacters(in: .whitespacesAndNewlines)
        let correctedTerm = draft.correctedTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !correctedTerm.isEmpty, !proposal.addsReplacement || !incorrectText.isEmpty else { return }

        Task { @MainActor in
            do {
                try await AutoLearnService.shared.updateReviewProposal(
                    proposalID: proposal.id,
                    incorrectTextToReplace: proposal.addsReplacement ? incorrectText : nil,
                    correctedVocabularyTerm: correctedTerm
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func availableComponents(for proposal: AutoLearnReviewProposal) -> Set<ReviewComponent> {
        var components = Set<ReviewComponent>()
        if proposal.addsReplacement {
            components.insert(.replacement)
        }
        if proposal.addsVocabulary {
            components.insert(.vocabulary)
        }
        return components
    }

    private func dismiss(_ proposalIDs: Set<UUID>) {
        guard !proposalIDs.isEmpty else { return }
        Task { @MainActor in
            isApplying = true
            errorMessage = nil
            do {
                try await AutoLearnService.shared.dismissReviewProposals(proposalIDs)
                await reloadProposals(selectNewItems: false)
            } catch {
                errorMessage = error.localizedDescription
            }
            isApplying = false
        }
    }
}

private struct AutoLearnReviewProposalRow: View {
    let proposal: AutoLearnReviewProposal
    @Binding var draft: AutoLearnReviewPanel.ReviewDraft
    let selectedComponents: Set<AutoLearnReviewPanel.ReviewComponent>
    let onToggleAll: (Bool) -> Void
    let onToggleComponent: (AutoLearnReviewPanel.ReviewComponent) -> Void
    let onCommitEdits: (AutoLearnReviewPanel.ReviewDraft) -> Void

    var body: some View {
        HStack(spacing: 9) {
            Toggle(
                "Select correction",
                isOn: Binding(get: { !selectedComponents.isEmpty }, set: onToggleAll)
            )
            .labelsHidden()
            .toggleStyle(.checkbox)

            HStack(spacing: 7) {
                if proposal.addsReplacement {
                    TextField("Original", text: $draft.incorrectText)
                        .foregroundColor(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                TextField("Corrected", text: $draft.correctedTerm)
                    .fontWeight(.semibold)
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13))
            .onSubmit { onCommitEdits(draft) }
            .help(
                AutoLearnReviewPanel.validationIssue(
                    for: draft,
                    includesReplacement: selectedComponents.contains(.replacement)
                ) ?? String(localized: "Press Return to save the edit")
            )

            if proposal.addsReplacement {
                componentButton("Word Replacement", systemImage: "arrow.2.squarepath", component: .replacement)
            }
            if proposal.addsVocabulary {
                componentButton("Vocabulary", systemImage: "character.book.closed.fill", component: .vocabulary)
            }
        }
        .padding(10)
        .background(CardBackground(isSelected: false))
    }

    private func componentButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        component: AutoLearnReviewPanel.ReviewComponent
    ) -> some View {
        let isSelected = selectedComponents.contains(component)
        return Button {
            onToggleComponent(component)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .help(Text(title))
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? Text("Selected") : Text("Not selected"))
    }
}
