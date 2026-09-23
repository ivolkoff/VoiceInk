import SwiftData
import SwiftUI

struct DictionaryImportPreviewSheet: View {
    private enum PresentedAlert: Identifiable {
        case replaceConfirmation
        case importFailure(String)
        case importSuccess(DictionaryImportResult)

        var id: String {
            switch self {
            case .replaceConfirmation:
                return "replaceConfirmation"
            case .importFailure:
                return "importFailure"
            case .importSuccess:
                return "importSuccess"
            }
        }
    }

    let payload: DictionaryImportPayload
    let onCancel: () -> Void
    let onImported: (DictionaryImportResult) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var mode: DictionaryImportMode = .merge
    @State private var summary: DictionaryImportSummary?
    @State private var summaryCache: [DictionaryImportMode: DictionaryImportSummary] = [:]
    @State private var errorMessage: String?
    @State private var presentedAlert: PresentedAlert?
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .overlay(Divider().opacity(0.5), alignment: .bottom)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    importModeSection

                    if let summary {
                        summarySection(summary)
                    } else if let errorMessage {
                        errorSection(errorMessage)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 460, height: 400)
        .task(id: mode) {
            await refreshSummary()
        }
        .alert(item: $presentedAlert) { alert in
            switch alert {
            case .replaceConfirmation:
                return Alert(
                    title: Text("Replace Current Dictionary?"),
                    message: Text(replaceConfirmationMessage),
                    primaryButton: .destructive(Text("Replace Dictionary")) {
                        performImport(mode: .replace)
                    },
                    secondaryButton: .cancel()
                )
            case .importFailure(let message):
                return Alert(
                    title: Text("Import Failed"),
                    message: Text(message),
                    dismissButton: .cancel(Text("OK"))
                )
            case .importSuccess(let result):
                // The sheet is dismissed from this button so the summary can never
                // be lost to sheet-dismissal timing.
                return Alert(
                    title: Text("Dictionary Imported"),
                    message: Text(result.message),
                    dismissButton: .cancel(Text("OK")) {
                        onImported(result)
                    }
                )
            }
        }
    }

    private var header: some View {
        HStack {
            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            Text("Import Dictionary")
                .font(.headline)

            Spacer()

            if isImporting {
                ProgressView()
                    .controlSize(.small)
            }

            Button(mode == .merge ? LocalizedStringKey("Import Dictionary") : "Replace Dictionary") {
                if mode == .replace {
                    presentedAlert = .replaceConfirmation
                } else {
                    performImport(mode: .merge)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(mode == .merge ? .accentColor : .red)
            .controlSize(.small)
            .disabled(!hasImportableEntries || summary == nil || isImporting)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private var importModeSection: some View {
        HStack(spacing: 4) {
            Text("Import Mode")
                .font(.system(size: 12, weight: .semibold))

            InfoTip(importModeHelp)

            Spacer()

            Picker("Import Mode", selection: $mode) {
                ForEach(DictionaryImportMode.allCases) { mode in
                    switch mode {
                    case .merge:
                        Text("Merge").tag(mode)
                    case .replace:
                        Text("Replace").tag(mode)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Import Mode")
        }
    }

    private func summarySection(_ summary: DictionaryImportSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import Preview")
                .font(.system(size: 12, weight: .semibold))

            VStack(spacing: 8) {
                summaryRow(
                    "Vocabulary",
                    value: String(localized: "\(summary.vocabularyToImport) entries")
                )
                summaryRow(
                    "Word Replacements",
                    value: [
                        String(localized: "\(summary.replacementRulesToImport) rules"),
                        String(localized: "\(summary.replacementSourcesToImport) source phrases"),
                    ].joined(separator: ", ")
                )

                if summary.duplicateVocabularyCount + summary.duplicateReplacementCount > 0 {
                    summaryRow(
                        "Duplicates Skipped",
                        value: String(
                            summary.duplicateVocabularyCount + summary.duplicateReplacementCount
                        ),
                        color: .secondary
                    )
                }

                if summary.conflictingReplacementCount > 0 {
                    summaryRow(
                        "Conflicts Skipped",
                        value: String(summary.conflictingReplacementCount),
                        color: .orange
                    )
                }

                if summary.invalidEntryCount + summary.cyclicReplacementCount > 0 {
                    summaryRow(
                        "Invalid or Cyclic Skipped",
                        value: String(summary.invalidEntryCount + summary.cyclicReplacementCount),
                        color: .orange
                    )
                }

                if summary.commaContainingSourceCount > 0 {
                    summaryRow(
                        "Sources With Commas Skipped",
                        value: String(summary.commaContainingSourceCount),
                        color: .orange
                    )
                }

                if mode == .replace {
                    Divider()
                    summaryRow(
                        "Current Entries Removed",
                        value: String(
                            summary.vocabularyToRemove + summary.replacementsToRemove
                        ),
                        color: .red
                    )
                }

                if !hasImportableEntries {
                    Divider()
                    Label("No valid entries are available to import.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }
            .padding(12)
            .background(CardBackground(isSelected: false))
        }
    }

    private func summaryRow(_ title: LocalizedStringKey, value: String, color: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
        }
    }

    private func errorSection(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var importModeHelp: LocalizedStringKey {
        "Merge adds new entries while keeping the current dictionary and skips duplicates or conflicts. Replace removes the current vocabulary and word replacements before importing."
    }

    private var hasImportableEntries: Bool {
        summary?.hasImportableEntries == true
    }

    private var replaceConfirmationMessage: String {
        guard let summary else {
            return String(localized: "This action cannot be undone.")
        }

        let currentVocabulary = String(
            localized: "\(summary.vocabularyToRemove) current vocabulary entries"
        )
        let currentReplacements = String(
            localized: "\(summary.replacementsToRemove) current word replacements"
        )
        return String(
            format: String(localized: "This removes %@ and %@. This action cannot be undone."),
            currentVocabulary,
            currentReplacements
        )
    }

    @MainActor
    private func refreshSummary() async {
        if let cachedSummary = summaryCache[mode] {
            summary = cachedSummary
            errorMessage = nil
            return
        }

        summary = nil
        errorMessage = nil
        do {
            let plannedSummary = try await DictionaryImportExportService.preview(
                payload,
                mode: mode,
                modelContext: modelContext
            )
            summaryCache[mode] = plannedSummary
            summary = plannedSummary
        } catch is CancellationError {
            return
        } catch {
            summary = nil
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func performImport(mode: DictionaryImportMode) {
        guard !isImporting else { return }
        isImporting = true

        Task { @MainActor in
            defer { isImporting = false }
            do {
                let result = try await DictionaryImportExportService.apply(
                    archive: payload.archive,
                    mode: mode,
                    modelContext: modelContext
                )
                presentedAlert = .importSuccess(result)
            } catch {
                presentedAlert = .importFailure(error.localizedDescription)
                summaryCache.removeAll()
                await refreshSummary()
            }
        }
    }
}
