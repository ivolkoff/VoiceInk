import SwiftData
import SwiftUI

@MainActor
final class QuickHistoryViewModel: ObservableObject {
    @Published var searchText = "" {
        didSet { scheduleSearch() }
    }
    @Published private(set) var transcriptions: [Transcription] = []
    @Published var selectedID: UUID?
    @Published private(set) var keyboardSelectionID: UUID?
    @Published var isShowingDetail = false
    @Published var isShowingInfo = false
    @Published private(set) var isSearching = false

    static let recentResultLimit = 30

    private let modelContext: ModelContext
    private var searchTask: Task<Void, Never>?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        reload()
    }

    var selectedTranscription: Transcription? {
        transcriptions.first { $0.id == selectedID }
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func reload() {
        searchTask?.cancel()
        load(query: trimmedQuery)
    }

    func reload(selecting transcription: Transcription) {
        searchTask?.cancel()
        load(query: trimmedQuery, selecting: transcription.id)
    }

    func clearSearch() {
        searchText = ""
    }

    func showDetail() {
        guard selectedTranscription != nil else { return }
        isShowingInfo = false
        isShowingDetail = true
    }

    /// Escape closes info, then detail, then the search query. Returns false when nothing was
    /// open, meaning the panel itself should close.
    func closeInnermostLevel() -> Bool {
        if isShowingInfo {
            isShowingInfo = false
        } else if isShowingDetail {
            isShowingDetail = false
        } else if !searchText.isEmpty {
            clearSearch()
        } else {
            return false
        }
        return true
    }

    func transcriptionForPaste(preferredID: UUID? = nil) -> Transcription? {
        // Return pressed before the debounced search landed: paste from the results the user sees typed.
        if isSearching {
            searchTask?.cancel()
            load(query: trimmedQuery, selecting: preferredID ?? selectedID)
        }

        if let preferredID {
            return transcriptions.first { $0.id == preferredID }
        }
        return selectedTranscription
    }

    func moveSelection(by offset: Int) {
        guard !transcriptions.isEmpty else { return }
        guard let selectedID, let index = transcriptions.firstIndex(where: { $0.id == selectedID }) else {
            self.selectedID = transcriptions.first?.id
            keyboardSelectionID = self.selectedID
            return
        }

        let nextIndex = min(max(index + offset, 0), transcriptions.count - 1)
        self.selectedID = transcriptions[nextIndex].id
        keyboardSelectionID = self.selectedID
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = trimmedQuery
        isSearching = true

        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            self?.load(query: query)
        }
    }

    private func load(query: String, selecting id: UUID? = nil) {
        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [SortDescriptor(\Transcription.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = Self.recentResultLimit

        if !query.isEmpty {
            descriptor.predicate = #Predicate<Transcription> {
                $0.text.localizedStandardContains(query)
                    || ($0.enhancedText?.localizedStandardContains(query) ?? false)
            }
        }

        do {
            let results = try modelContext.fetch(descriptor)
            transcriptions = results
            if let id, results.contains(where: { $0.id == id }) {
                selectedID = id
            } else {
                selectedID = results.first?.id
            }
        } catch {
            transcriptions = []
            selectedID = nil
        }
        keyboardSelectionID = nil
        isSearching = false
    }
}

extension Transcription {
    var preferredHistoryText: String {
        guard let enhancedText, !enhancedText.isEmpty else { return text }
        return enhancedText
    }

    var hasEnhancedHistoryText: Bool {
        enhancedText?.isEmpty == false
    }
}
