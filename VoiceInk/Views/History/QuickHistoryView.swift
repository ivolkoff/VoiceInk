import AppKit
import SwiftData
import SwiftUI

struct QuickHistoryView: View {
    @ObservedObject var viewModel: QuickHistoryViewModel
    let onPaste: (Transcription) -> Void
    let onDismiss: () -> Void

    @FocusState private var isSearchFocused: Bool

    private var hasSearchQuery: Bool {
        !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isShowingDetail, let transcription = viewModel.selectedTranscription {
                detailView(transcription)
            } else {
                historyView
            }
        }
        .frame(width: 680, height: 470)
        .background {
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
            Color(NSColor.windowBackgroundColor).opacity(0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .onAppear {
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
        .onChange(of: viewModel.isShowingDetail) { _, isShowingDetail in
            isSearchFocused = !isShowingDetail
            if !isShowingDetail {
                viewModel.isShowingInfo = false
            }
        }
    }

    // MARK: - History list

    private var historyView: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider()
            if viewModel.transcriptions.isEmpty {
                emptyState
            } else {
                resultsList
            }
            Divider()
            keyboardHints
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 14) {
            TextField("Search transcriptions...", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($isSearchFocused)
                .frame(maxWidth: 340)

            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
            }

            QuickHistoryWindowDragArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            escapeKeyCap
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(viewModel.transcriptions) { transcription in
                        QuickHistoryRow(
                            transcription: transcription,
                            isSelected: viewModel.selectedID == transcription.id,
                            onSelect: { viewModel.selectedID = transcription.id },
                            onPaste: { onPaste(transcription) }
                        )
                        .id(transcription.id)
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: viewModel.keyboardSelectionID) { _, selectedID in
                guard let selectedID else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: hasSearchQuery ? "magnifyingglass" : "text.bubble")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(hasSearchQuery ? "No matching transcriptions" : "No transcriptions yet")
                .font(.system(size: 14, weight: .medium))
            Text(hasSearchQuery ? "Try another search term." : "Your recent transcriptions will appear here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var keyboardHints: some View {
        HStack(spacing: 10) {
            QuickPanelCommandButton(title: "Details", shortcut: "⌘↵") {
                withAnimation(.easeOut(duration: 0.16)) {
                    viewModel.showDetail()
                }
            }

            Spacer()

            QuickPanelCommandButton(title: "Paste Text", shortcut: "↵") {
                if let transcription = viewModel.selectedTranscription {
                    onPaste(transcription)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
    }

    // MARK: - Detail

    private func detailView(_ transcription: Transcription) -> some View {
        VStack(spacing: 0) {
            detailHeader
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    detailContent(transcription)
                }
                .scrollIndicators(.never)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if viewModel.isShowingInfo {
                    Divider()
                    TranscriptionInfoPanel(transcription: transcription)
                        .frame(width: 300)
                        .id(transcription.id)
                }
            }
            Divider()
            QuickHistoryDetailActionBar(
                transcription: transcription,
                isInfoPresented: viewModel.isShowingInfo,
                onToggleInfo: { viewModel.isShowingInfo.toggle() },
                onPaste: { onPaste(transcription) },
                onTranscriptionCreated: { viewModel.reload(selecting: $0) }
            )
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    viewModel.isShowingDetail = false
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Back to history")

            Text("Transcription Details")
                .font(.system(size: 14, weight: .semibold))

            QuickHistoryWindowDragArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            escapeKeyCap
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    private func detailContent(_ transcription: Transcription) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if transcription.hasEnhancedHistoryText {
                detailTextSection("Enhanced", text: transcription.preferredHistoryText, isPrimary: true)
                detailTextSection("Original", text: transcription.text, isPrimary: false)
            } else {
                detailTextSection("Transcription", text: transcription.text, isPrimary: true)
            }
        }
        .padding(14)
    }

    private func detailTextSection(_ title: LocalizedStringKey, text: String, isPrimary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(isPrimary ? Color.primary : Color.secondary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(11)
                .padding(.trailing, 30)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(isPrimary ? 0.06 : 0.03))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        }
                )
                .overlay(alignment: .topTrailing) {
                    CopyIconButton(textToCopy: text)
                        .padding(6)
                }
        }
    }

    private var escapeKeyCap: some View {
        Button(action: onDismiss) {
            Text("esc")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("Dismiss")
    }
}

// MARK: - Row

private struct QuickHistoryRow: View {
    let transcription: Transcription
    let isSelected: Bool
    let onSelect: () -> Void
    let onPaste: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 26)

                Text(transcription.preferredHistoryText)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if transcription.hasEnhancedHistoryText {
                    badge(String(localized: "Enhanced"), maxWidth: 64)
                } else {
                    Text(transcription.timestamp, format: .relative(presentation: .named))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                if let modelName = transcription.transcriptionModelName, !modelName.isEmpty {
                    badge(modelName, maxWidth: 84)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : (isHovered ? Color.primary.opacity(0.05) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded(onPaste))
        .onHover { isHovered = $0 }
        .accessibilityValue(transcription.preferredHistoryText)
        .accessibilityHint("Selects this transcription. Double-click to paste.")
    }

    private func badge(_ text: String, maxWidth: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 7)
            .frame(maxWidth: maxWidth)
            .frame(height: 24)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - Detail actions

private struct QuickHistoryDetailActionBar: View {
    let transcription: Transcription
    let isInfoPresented: Bool
    let onToggleInfo: () -> Void
    let onPaste: () -> Void
    let onTranscriptionCreated: (Transcription) -> Void

    @EnvironmentObject private var engine: VoiceInkEngine
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @Environment(\.modelContext) private var modelContext

    @State private var isWorking = false

    private var audioURL: URL? {
        guard let urlString = transcription.audioFileURL,
              let url = URL(string: urlString),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    var body: some View {
        HStack(spacing: 8) {
            iconButton("arrow.clockwise", help: "Retranscribe this audio", isLoading: isWorking, action: retranscribe)
                .disabled(isWorking || audioURL == nil)

            iconButton("wand.and.stars", help: "Re-enhance with selected prompt", action: reEnhance)
                .disabled(isWorking || !enhancementService.isEnhancementEnabled || !enhancementService.isConfigured)

            iconButton("folder", help: "Show in Finder") {
                guard let audioURL else { return }
                NSWorkspace.shared.selectFile(audioURL.path, inFileViewerRootedAtPath: audioURL.deletingLastPathComponent().path)
            }
            .disabled(audioURL == nil)

            iconButton("info.circle", help: isInfoPresented ? "Hide transcription info" : "Show transcription info", isSelected: isInfoPresented, action: onToggleInfo)

            Spacer(minLength: 8)

            QuickPanelCommandButton(title: "Paste Text", shortcut: "↵", action: onPaste)
                .help("Paste enhanced text when available, otherwise paste the original transcription")
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
    }

    private func iconButton(
        _ systemImage: String,
        help: LocalizedStringKey,
        isLoading: Bool = false,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 34, height: 32)
            .background(QuickPanelButtonBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func retranscribe() {
        guard let audioURL else {
            showError(String(localized: "Cannot retry: Audio file not found"))
            return
        }
        guard let model = engine.transcriptionModelManager.currentTranscriptionModel else {
            showError(String(localized: "No transcription model selected"))
            return
        }

        isWorking = true
        let service = AudioTranscriptionService(modelContext: modelContext, engine: engine)
        Task {
            do {
                let newTranscription = try await service.retranscribeAudio(from: audioURL, using: model)
                isWorking = false
                NotificationManager.shared.showNotification(
                    title: String(localized: "Retranscription successful"),
                    type: .success,
                    duration: 1.0
                )
                onTranscriptionCreated(newTranscription)
            } catch {
                isWorking = false
                showError(error.localizedDescription.isEmpty ? String(localized: "Retranscription failed") : error.localizedDescription)
            }
        }
    }

    private func reEnhance() {
        guard enhancementService.isEnhancementEnabled, enhancementService.isConfigured else {
            showError(String(localized: "AI Enhancement is not enabled or configured"))
            return
        }

        isWorking = true
        Task {
            do {
                let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(transcription.text)
                transcription.enhancedText = enhancedText
                transcription.aiEnhancementModelName = enhancementService.getAIService()?.currentModel
                transcription.promptName = promptName
                transcription.enhancementDuration = enhancementDuration
                transcription.aiRequestSystemMessage = enhancementService.lastSystemMessageSent
                transcription.aiRequestUserMessage = enhancementService.lastUserMessageSent
                try? modelContext.save()
                isWorking = false
                NotificationManager.shared.showNotification(
                    title: String(localized: "Re-enhancement successful"),
                    type: .success,
                    duration: 1.0
                )
            } catch {
                isWorking = false
                showError(error.localizedDescription.isEmpty ? String(localized: "Re-enhancement failed") : error.localizedDescription)
            }
        }
    }

    private func showError(_ title: String) {
        NotificationManager.shared.showNotification(title: title, type: .error, duration: 3.0)
    }
}

// MARK: - Panel controls

private struct QuickPanelCommandButton: View {
    let title: LocalizedStringKey
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text(shortcut)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .fixedSize(horizontal: true, vertical: false)
            .background(QuickPanelButtonBackground())
        }
        .buttonStyle(.plain)
    }
}

private struct QuickPanelButtonBackground: View {
    var isSelected = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.1), lineWidth: 1)
            }
    }
}

// The panel is borderless, so the header's empty space is the only place to grab it.
private struct QuickHistoryWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableAreaView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableAreaView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
