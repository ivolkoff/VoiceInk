import Foundation
import SwiftData
import Testing
@testable import VoiceInk

@MainActor
struct QuickHistoryTests {
    private let container: ModelContainer

    init() throws {
        container = try ModelContainer(
            for: Transcription.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func makeContext(_ texts: [(text: String, enhanced: String?)]) throws -> ModelContext {
        let context = ModelContext(container)
        let now = Date()
        for (index, item) in texts.enumerated() {
            let transcription = Transcription(text: item.text, duration: 1, enhancedText: item.enhanced)
            transcription.timestamp = now.addingTimeInterval(TimeInterval(index))
            context.insert(transcription)
        }
        try context.save()
        return context
    }

    @Test func loadsOnlyTheMostRecentNewestFirst() throws {
        let context = try makeContext((0..<35).map { ("note \($0)", nil) })
        let viewModel = QuickHistoryViewModel(modelContext: context)

        #expect(viewModel.transcriptions.count == QuickHistoryViewModel.recentResultLimit)
        #expect(viewModel.transcriptions.first?.text == "note 34")
        #expect(viewModel.selectedTranscription?.text == "note 34")
    }

    @Test func searchMatchesOriginalOrEnhancedText() throws {
        let context = try makeContext([
            ("buy milk", nil),
            ("call mom", "Call Mom tonight"),
            ("random", nil),
        ])
        let viewModel = QuickHistoryViewModel(modelContext: context)

        viewModel.searchText = "TONIGHT"
        viewModel.reload()
        #expect(viewModel.transcriptions.map(\.text) == ["call mom"])

        viewModel.searchText = "milk"
        #expect(viewModel.transcriptionForPaste()?.text == "buy milk")
    }

    @Test func preferredTextFallsBackToOriginalWhenEnhancementIsEmpty() {
        #expect(Transcription(text: "raw", duration: 1, enhancedText: "nice").preferredHistoryText == "nice")
        #expect(Transcription(text: "raw", duration: 1, enhancedText: "").preferredHistoryText == "raw")
        #expect(Transcription(text: "raw", duration: 1).preferredHistoryText == "raw")
    }

    @Test func selectionClampsAtListEdges() throws {
        let context = try makeContext([("a", nil), ("b", nil), ("c", nil)])
        let viewModel = QuickHistoryViewModel(modelContext: context)

        viewModel.moveSelection(by: -1)
        #expect(viewModel.selectedTranscription?.text == "c")
        viewModel.moveSelection(by: 5)
        #expect(viewModel.selectedTranscription?.text == "a")
    }

    @Test func escapeClosesInfoThenDetailThenSearchThenPanel() throws {
        let context = try makeContext([("a", nil)])
        let viewModel = QuickHistoryViewModel(modelContext: context)
        viewModel.searchText = "a"
        viewModel.reload()
        viewModel.showDetail()
        viewModel.isShowingInfo = true

        #expect(viewModel.closeInnermostLevel())
        #expect(!viewModel.isShowingInfo && viewModel.isShowingDetail)
        #expect(viewModel.closeInnermostLevel())
        #expect(!viewModel.isShowingDetail && viewModel.searchText == "a")
        #expect(viewModel.closeInnermostLevel())
        #expect(viewModel.searchText.isEmpty)
        #expect(!viewModel.closeInnermostLevel())
    }
}
