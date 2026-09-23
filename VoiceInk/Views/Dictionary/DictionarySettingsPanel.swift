import SwiftUI
import SwiftData

private struct DictionaryTransferAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct DictionarySettingsPanel: View {
    @Environment(\.modelContext) private var modelContext
    let onDismiss: () -> Void
    let onReviewNow: () -> Void
    @AppStorage(AutoLearnSettings.isEnabledKey) private var isAutoLearnEnabled = true
    @AppStorage(AutoLearnSettings.reviewScheduleKey)
    private var reviewScheduleRawValue = AutoLearnReviewSchedule.immediately.rawValue
    @AppStorage(AutoLearnSettings.hasFailureKey) private var hasAutoLearnFailure = false
    @AppStorage(AutoLearnSettings.failureMessageKey) private var autoLearnFailureMessage = ""
    @State private var pendingCorrectionCount = 0
    @State private var pendingImport: DictionaryImportPayload?
    @State private var transferAlert: DictionaryTransferAlert?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Text("Dictionary Settings")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                Spacer()

                Button(action: onDismiss) {
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
            .overlay(
                Divider().opacity(0.5), alignment: .bottom
            )

            // Content
            Form {
                Section {
                    LabeledContent("Quick Add to Dictionary") {
                        ShortcutRecorder(action: .quickAddToDictionary)
                            .controlSize(.small)
                    }
                } header: {
                    Text("Shortcuts")
                }

                autoLearnSection

                Section {
                    LabeledContent("Export Dictionary") {
                        Button("Export…") {
                            exportDictionary()
                        }
                    }

                    LabeledContent("Import Dictionary") {
                        Button("Import…") {
                            chooseDictionaryFile()
                        }
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Export or import your vocabulary words and word replacements.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .task {
            await refreshPendingCorrectionCount()
        }
        .onReceive(NotificationCenter.default.publisher(for: .autoLearnQueueDidChange)) { _ in
            Task { await refreshPendingCorrectionCount() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .autoLearnReviewProposalsDidChange)) { _ in
            Task { await refreshPendingCorrectionCount() }
        }
        .sheet(item: $pendingImport) { payload in
            DictionaryImportPreviewSheet(
                payload: payload,
                onCancel: {
                    pendingImport = nil
                },
                onImported: { _ in
                    pendingImport = nil
                }
            )
        }
        .alert(item: $transferAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .cancel(Text("OK"))
            )
        }
    }

    private var autoLearnSection: some View {
        Section {
            Toggle("Auto-Learn Dictionary", isOn: $isAutoLearnEnabled)
                .onChange(of: isAutoLearnEnabled) { _, isEnabled in
                    Task { await AutoLearnService.shared.settingDidChange(isEnabled: isEnabled) }
                }

            if isAutoLearnEnabled {
                AutoLearnModelSelectionView()

                Picker(selection: $reviewScheduleRawValue) {
                    ForEach(AutoLearnReviewSchedule.allCases) { schedule in
                        Text(schedule.title).tag(schedule.rawValue)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Review corrections")
                        InfoTip("Choose when saved corrections are sent to your AI provider. Manual review keeps them local until you select Review Now.")
                    }
                }
                .onChange(of: reviewScheduleRawValue) { _, _ in
                    Task { await AutoLearnService.shared.reviewScheduleDidChange() }
                }

                LabeledContent("Corrections to review") {
                    HStack(spacing: 10) {
                        Text("\(pendingCorrectionCount)")
                            .foregroundColor(.secondary)
                        Button("Review Now", action: onReviewNow)
                            .disabled(pendingCorrectionCount == 0)
                    }
                }

                if hasAutoLearnFailure {
                    VStack(alignment: .leading, spacing: 8) {
                        Label {
                            Text(autoLearnFailureMessage.isEmpty
                                 ? String(localized: "The selected provider or model could not review the pending corrections.")
                                 : autoLearnFailureMessage)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        }
                        Text("Choose another model or provider above, then retry.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Retry") {
                            Task { await AutoLearnService.shared.retryPendingReviews() }
                        }
                    }
                }
            }
        } header: {
            HStack(spacing: 4) {
                Text("Auto Learn")
                InfoTip(
                    "Automatically learns corrections you make after dictation.",
                    learnMoreURL: "https://tryvoiceink.com/docs/auto-learn-dictionary"
                )
            }
        } footer: {
            Text("Each correction and up to three surrounding words on each side are sent to your selected AI provider; recordings and full text fields are never sent.")
        }
    }

    @MainActor
    private func refreshPendingCorrectionCount() async {
        let pending = (try? await AutoLearnService.shared.outstandingReviewCount()) ?? 0
        let proposals = (try? await AutoLearnService.shared.reviewProposalCount()) ?? 0
        pendingCorrectionCount = pending + proposals
    }

    @MainActor
    private func exportDictionary() {
        do {
            let archive = try DictionaryImportExportService.makeArchive(modelContext: modelContext)
            let data = try DictionaryImportExportService.encodeArchive(archive)
            guard try DictionaryFilePanelService.saveDictionaryData(data) != nil else {
                return
            }
            NotificationManager.shared.showNotification(
                title: String(localized: "Dictionary exported successfully"),
                type: .success
            )
        } catch {
            transferAlert = DictionaryTransferAlert(
                title: String(localized: "Export Error"),
                message: error.localizedDescription
            )
        }
    }

    @MainActor
    private func chooseDictionaryFile() {
        do {
            guard let data = try DictionaryFilePanelService.chooseDictionaryData() else {
                return
            }
            pendingImport = try DictionaryImportExportService.decodeArchiveData(data)
        } catch {
            transferAlert = DictionaryTransferAlert(
                title: String(localized: "Import Error"),
                message: error.localizedDescription
            )
        }
    }
}
