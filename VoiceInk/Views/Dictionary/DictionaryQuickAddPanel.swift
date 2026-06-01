import AppKit
import SwiftUI
import SwiftData

// MARK: - Manager

@MainActor
final class DictionaryQuickAddManager {
    static let shared = DictionaryQuickAddManager()
    private init() {}

    private var panel: DictionaryQuickAddPanel?
    private var hostingController: NSHostingController<AnyView>?
    private var previousApp: NSRunningApplication?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(modelContainer: ModelContainer) {
        isVisible ? hide() : show(modelContainer: modelContainer)
    }

    private static let panelWidth: CGFloat = 540

    func show(modelContainer: ModelContainer) {
        guard !isVisible else { return }

        previousApp = NSWorkspace.shared.frontmostApplication

        let initialSize = NSSize(width: Self.panelWidth, height: DictionaryQuickAddView.Mode.insert.panelHeight)
        let newPanel = DictionaryQuickAddPanel(manager: self, size: initialSize)

        let view = DictionaryQuickAddView(
            onDismiss: { [weak self] in self?.hide() },
            onResize: { [weak self] height in
                self?.panel?.resize(to: NSSize(width: Self.panelWidth, height: height))
            }
        )
        .modelContainer(modelContainer)

        let controller = NSHostingController(rootView: AnyView(view))
        newPanel.contentView = controller.view
        hostingController = controller
        panel = newPanel
        newPanel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard isVisible else { return }
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
        previousApp?.activate(options: .activateIgnoringOtherApps)
        previousApp = nil
    }
}

// MARK: - Panel

class DictionaryQuickAddPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private weak var manager: DictionaryQuickAddManager?

    init(manager: DictionaryQuickAddManager, size: NSSize) {
        self.manager = manager
        let origin = DictionaryQuickAddPanel.centeredOrigin(for: size)
        super.init(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            manager?.hide()
        } else {
            super.keyDown(with: event)
        }
    }

    override func resignKey() {
        super.resignKey()
        DispatchQueue.main.async { [weak self] in
            self?.manager?.hide()
        }
    }

    func resize(to size: NSSize) {
        let currentFrame = frame
        let x = currentFrame.midX - size.width / 2
        let y = currentFrame.maxY - size.height
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        }
    }

    private static func centeredOrigin(for size: NSSize) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let x = screen.visibleFrame.midX - size.width / 2
        let y = screen.visibleFrame.midY - size.height / 2 + 60
        return NSPoint(x: x, y: y)
    }
}

// MARK: - View

struct DictionaryQuickAddView: View {
    enum Mode: CaseIterable {
        case vocabulary, replacement, insert

        var label: String {
            switch self {
            case .vocabulary: return "Vocabulary"
            case .replacement: return "Word Replacement"
            case .insert: return "Insert"
            }
        }

        var icon: String {
            switch self {
            case .vocabulary: return "character.book.closed.fill"
            case .replacement: return "arrow.2.squarepath"
            case .insert: return "text.insert"
            }
        }

        var panelHeight: CGFloat {
            switch self {
            case .vocabulary: return 130
            case .replacement: return 164
            case .insert: return 340
            }
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Query private var vocabularyWords: [VocabularyWord]
    @Query private var wordReplacements: [WordReplacement]

    @State private var mode: Mode = .insert
    @State private var wordInput = ""
    @State private var originalInput = ""
    @State private var replacementInput = ""
    @State private var insertSearch = ""
    @State private var selectedText = ""
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    enum Field: Hashable { case word, original, replacement, insertSearch }

    let onDismiss: () -> Void
    let onResize: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            modeBar
            Divider().opacity(0.4)
            inputArea
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            } else if mode == .insert, let warning = selectedTextDuplicateWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            Divider().opacity(0.4)
            hintBar
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(PanelHeightKey.self) { height in
            if height > 0 { onResize(height) }
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onAppear {
            DispatchQueue.main.async {
                focusedField = mode == .insert ? .insertSearch : .word
            }
            Task {
                selectedText = await SelectedTextService.fetchSelectedText() ?? ""
            }
        }
        .onChange(of: mode) { _, newMode in
            wordInput = ""
            originalInput = ""
            replacementInput = ""
            insertSearch = ""
            errorMessage = nil
            DispatchQueue.main.async {
                switch newMode {
                case .vocabulary: focusedField = .word
                case .insert: focusedField = .insertSearch
                case .replacement: focusedField = .original
                }
            }
        }
    }

    // MARK: - Mode Bar

    private var modeBar: some View {
        HStack(spacing: 4) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { mode = m }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: m.icon)
                            .font(.system(size: 10, weight: .medium))
                        Text(m.label)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(mode == m ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(mode == m ? Color.primary.opacity(0.1) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    // MARK: - Input Area

    @ViewBuilder
    private var inputArea: some View {
        switch mode {
        case .vocabulary: vocabularyInput
        case .replacement: replacementInputView
        case .insert: insertView
        }
    }

    private var vocabularyInput: some View {
        HStack(spacing: 11) {
            Image(systemName: "character.book.closed.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            TextField("", text: $wordInput, prompt: Text("e.g. Prakash, VoiceInk").foregroundColor(.secondary))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
                .focused($focusedField, equals: .word)
                .onSubmit { submitVocabulary() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var replacementInputView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text("Replace")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
                TextField("", text: $originalInput, prompt: Text("e.g. my email, my mail").foregroundColor(.secondary))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                    .focused($focusedField, equals: .original)
                    .onSubmit { focusedField = .replacement }
            }

            HStack(spacing: 10) {
                Text("With")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
                TextField("", text: $replacementInput, prompt: Text("e.g. support@tryvoiceink.com").foregroundColor(.secondary))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                    .focused($focusedField, equals: .replacement)
                    .onSubmit { submitReplacement() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Insert View

    private var selectedTextDuplicateWarning: String? {
        guard !selectedText.isEmpty else { return nil }
        let lower = selectedText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for replacement in wordReplacements {
            let tokens = replacement.originalText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            if tokens.contains(lower) {
                return "\"\(selectedText)\" уже есть в заменах слов"
            }
        }
        return nil
    }

    private var filteredReplacements: [WordReplacement] {
        guard !insertSearch.isEmpty else { return wordReplacements }
        let query = insertSearch.lowercased()
        return wordReplacements.filter {
            $0.originalText.lowercased().contains(query) ||
            $0.replacementText.lowercased().contains(query)
        }
    }

    @ViewBuilder
    private var insertView: some View {
        VStack(spacing: 8) {
            // Selected text context
            if !selectedText.isEmpty {
                HStack(spacing: 10) {
                    Text("Заменить")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    Text(selectedText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("", text: $insertSearch, prompt: Text(selectedText.isEmpty ? "Поиск замен…" : "На что…").foregroundColor(.secondary))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                    .focused($focusedField, equals: .insertSearch)
                    .onSubmit { submitInsertSearch() }
            }
            .padding(.horizontal, 14)
            .padding(.top, selectedText.isEmpty ? 10 : 0)

            if wordReplacements.isEmpty {
                emptyInsertView
            } else if filteredReplacements.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                    Text(selectedText.isEmpty ? "Нет совпадений — ↵ для нового слова" : "Нет совпадений — ↵ для добавления")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredReplacements) { replacement in
                            InsertReplacementRow(
                                replacement: replacement,
                                onEdit: { editReplacement(replacement) }
                            )
                            if replacement.id != filteredReplacements.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(minHeight: 100, maxHeight: 240)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
        }
    }

    private var emptyInsertView: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)

            Text("Нет замен слов")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { mode = .replacement }
            } label: {
                Text("Добавить замену")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 30)
    }

    private func editReplacement(_ replacement: WordReplacement) {
        if !selectedText.isEmpty {
            // Append selected text to existing entry instead of replacing it
            let newToken = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let existingTokens = replacement.originalText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            if existingTokens.contains(newToken.lowercased()) {
                errorMessage = String.localizedStringWithFormat(String(localized: "\"%@\" already in this replacement"), newToken)
                return
            }
            replacement.originalText += ", " + newToken
            try? modelContext.save()
            NotificationManager.shared.showNotification(
                title: String.localizedStringWithFormat(String(localized: "Word added: %@ → %@"), newToken, replacement.replacementText),
                type: .success,
                duration: 2.5
            )
            onDismiss()
            return
        }
        insertSearch = ""
        withAnimation(.easeInOut(duration: 0.15)) { mode = .replacement }
        DispatchQueue.main.async {
            self.originalInput = replacement.originalText
            self.replacementInput = replacement.replacementText
        }
    }

    private func submitInsertSearch() {
        let text = insertSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let matches = filteredReplacements
        if matches.isEmpty {
            if selectedText.isEmpty {
                // No selected text → navigate to Replacement tab with typed text as original
                insertSearch = ""
                withAnimation(.easeInOut(duration: 0.15)) { mode = .replacement }
                DispatchQueue.main.async {
                    self.originalInput = text
                    self.replacementInput = ""
                }
            } else {
                // Selected text = original, typed text = replacement → add immediately
                let err = DictionaryService.addWordReplacement(
                    original: selectedText,
                    replacement: text,
                    existing: Array(wordReplacements),
                    context: modelContext
                )
                if let err {
                    errorMessage = err
                } else {
                    NotificationManager.shared.showNotification(
                        title: String.localizedStringWithFormat(String(localized: "Replacement added: %@ → %@"), selectedText, text),
                        type: .success,
                        duration: 2.5
                    )
                    onDismiss()
                }
            }
        } else if !selectedText.isEmpty {
            // Match found + selected text present → append to existing entry
            let match = matches[0]
            let newToken = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let existingTokens = match.originalText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            if existingTokens.contains(newToken.lowercased()) {
                errorMessage = String.localizedStringWithFormat(String(localized: "\"%@\" already in this replacement"), newToken)
                return
            }
            match.originalText += ", " + newToken
            try? modelContext.save()
            NotificationManager.shared.showNotification(
                title: String.localizedStringWithFormat(String(localized: "Word added: %@ → %@"), newToken, match.replacementText),
                type: .success,
                duration: 2.5
            )
            onDismiss()
        } else {
            editReplacement(matches[0])
        }
    }

    // MARK: - Insert Row

    private struct InsertReplacementRow: View {
        let replacement: WordReplacement
        let onEdit: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: onEdit) {
                HStack(spacing: 8) {
                    Text(replacement.originalText)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "arrow.right")
                        .foregroundColor(.secondary)
                        .font(.system(size: 10))
                        .frame(width: 10)

                    Text(replacement.replacementText)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 13))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundColor(isHovered ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .onHover { hover in
                withAnimation(.easeInOut(duration: 0.15)) { isHovered = hover }
            }
        }
    }

    // MARK: - Hint Bar

    private var hintBar: some View {
        HStack {
            Spacer()
            HStack(spacing: 14) {
                if mode == .insert {
                    if selectedText.isEmpty {
                        if wordReplacements.isEmpty {
                            HStack(spacing: 4) {
                                KeyHint("esc")
                                Text("Dismiss")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        } else {
                        HStack(spacing: 4) {
                            KeyHint("↵")
                            Text("Новое слово или правка")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                            HStack(spacing: 4) {
                                KeyHint("esc")
                                Text("Dismiss")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } else {
                        HStack(spacing: 4) {
                            KeyHint("↵")
                            Text("Добавить замену")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        HStack(spacing: 4) {
                            KeyHint("esc")
                            Text("Dismiss")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    HStack(spacing: 4) {
                        KeyHint("↵")
                        Text("Add")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 4) {
                        KeyHint("esc")
                        Text("Dismiss")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func submitVocabulary() {
        let input = wordInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        if let error = DictionaryService.addVocabularyWords(input, existing: Array(vocabularyWords), context: modelContext) {
            errorMessage = error
            return
        }
        onDismiss()
    }

    private func submitReplacement() {
        let original = originalInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacementInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, !replacement.isEmpty else { return }
        if let error = DictionaryService.addWordReplacement(original: original, replacement: replacement, existing: Array(wordReplacements), context: modelContext) {
            errorMessage = error
            return
        }
        NotificationManager.shared.showNotification(
            title: String.localizedStringWithFormat(String(localized: "Replacement added: %@ → %@"), original, replacement),
            type: .success,
            duration: 2.5
        )
        onDismiss()
    }
}

// MARK: - Height Preference

private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Key Hint

private struct KeyHint: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
                    )
            )
    }
}
