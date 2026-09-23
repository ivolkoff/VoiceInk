import Foundation
import SwiftData
import Testing
@testable import VoiceInk

@MainActor
struct DictionaryImportExportTests {
    private let container: ModelContainer
    private let context: ModelContext

    init() throws {
        container = try Self.makeContainer()
        context = ModelContext(container)
    }

    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: VocabularyWord.self, WordReplacement.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func words(in context: ModelContext) throws -> Set<String> {
        Set(try context.fetch(FetchDescriptor<VocabularyWord>()).map(\.word))
    }

    private func rules(in context: ModelContext) throws -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<WordReplacement>())
                .map { ($0.originalText, $0.replacementText) }
        )
    }

    private func apply(
        vocabulary: [String] = [],
        replacements: [([String], String)] = [],
        mode: DictionaryImportMode = .merge
    ) async throws -> DictionaryImportSummary {
        let archive = DictionaryArchive(
            vocabulary: vocabulary.map { DictionaryVocabularyEntry(term: $0, createdAt: nil) },
            replacements: replacements.map {
                DictionaryReplacementEntry(sources: $0.0, replacement: $0.1, createdAt: nil)
            }
        )
        return try await DictionaryImportExportService.apply(
            archive: archive,
            mode: mode,
            modelContext: context
        ).summary
    }

    @Test func exportedFileRoundTripsIntoAnEmptyDictionary() async throws {
        context.insert(VocabularyWord(word: "VoiceInk"))
        context.insert(WordReplacement(originalText: "teh, hte", replacementText: "the"))
        try context.save()

        let data = try DictionaryImportExportService.encodeArchive(
            DictionaryImportExportService.makeArchive(modelContext: context)
        )
        let archive = try DictionaryImportExportService.decodeArchiveData(data).archive
        #expect(archive.format == "voiceink.dictionary")
        #expect(archive.schemaVersion == 1)

        let target = try Self.makeContainer()
        let targetContext = ModelContext(target)
        _ = try await DictionaryImportExportService.apply(
            archive: archive,
            mode: .merge,
            modelContext: targetContext
        )

        #expect(try words(in: targetContext) == ["VoiceInk"])
        #expect(try rules(in: targetContext) == ["teh, hte": "the"])
    }

    @Test func skipsVocabularyThatDiffersOnlyByCase() async throws {
        context.insert(VocabularyWord(word: "VoiceInk"))
        try context.save()

        let summary = try await apply(vocabulary: ["voiceink", "Parakeet", "PARAKEET"])

        #expect(summary.vocabularyToImport == 1)
        #expect(summary.duplicateVocabularyCount == 2)
        #expect(try words(in: context) == ["VoiceInk", "Parakeet"])
    }

    @Test func skipsReplacementWhoseSourceAlreadyMapsElsewhere() async throws {
        context.insert(WordReplacement(originalText: "teh", replacementText: "the"))
        try context.save()

        let summary = try await apply(replacements: [
            (["TEH"], "ten"),
            (["foo"], "bar"),
            (["Foo"], "baz"),
        ])

        #expect(summary.conflictingReplacementCount == 2)
        #expect(summary.replacementRulesToImport == 1)
        #expect(try rules(in: context) == ["teh": "the", "foo": "bar"])
    }

    @Test func mergeAddsNewSourcesToTheRuleWithTheSameReplacement() async throws {
        context.insert(WordReplacement(originalText: "teh", replacementText: "the"))
        try context.save()

        let summary = try await apply(replacements: [(["teh", "hte"], "the")])

        #expect(summary.duplicateReplacementCount == 1)
        #expect(summary.replacementSourcesToImport == 1)
        #expect(try rules(in: context) == ["teh, hte": "the"])
    }

    @Test func rejectsReplacementsThatWouldCreateACycle() async throws {
        context.insert(WordReplacement(originalText: "js", replacementText: "JavaScript"))
        try context.save()

        let summary = try await apply(replacements: [
            (["javascript"], "js"),
            (["foo"], "bar"),
            (["bar"], "foo"),
        ])

        #expect(summary.cyclicReplacementCount == 2)
        #expect(try rules(in: context) == ["js": "JavaScript", "foo": "bar"])
    }

    @Test func replaceModeRemovesExistingEntries() async throws {
        context.insert(VocabularyWord(word: "Old"))
        context.insert(WordReplacement(originalText: "x", replacementText: "y"))
        try context.save()

        let summary = try await apply(
            vocabulary: ["New"],
            replacements: [(["a"], "b")],
            mode: .replace
        )

        #expect(summary.vocabularyToRemove == 1)
        #expect(summary.replacementsToRemove == 1)
        #expect(try words(in: context) == ["New"])
        #expect(try rules(in: context) == ["a": "b"])
    }

    @Test func replaceModeWithNothingToImportKeepsTheDictionary() async throws {
        context.insert(VocabularyWord(word: "Old"))
        try context.save()

        await #expect(throws: DictionaryArchiveError.self) {
            _ = try await apply(vocabulary: ["  "], mode: .replace)
        }
        #expect(try words(in: context) == ["Old"])
    }

    @Test func decodesLegacyForkDictionaryExport() throws {
        let legacy = """
            {"version": "1.0", "vocabularyWords": [{"word": "VoiceInk"}], "wordReplacements": {"teh, hte": "the"}}
            """
        let archive = try DictionaryImportExportService.decodeArchiveData(Data(legacy.utf8)).archive

        #expect(archive.vocabulary.map(\.term) == ["VoiceInk"])
        #expect(archive.replacements.map(\.sources) == [["teh", "hte"]])
        #expect(archive.replacements.map(\.replacement) == ["the"])
    }

    @Test func rejectsUnknownFormatAndSchemaVersion() throws {
        let otherFormat = #"{"format": "other", "schemaVersion": 1}"#
        let newerVersion = #"{"format": "voiceink.dictionary", "schemaVersion": 2, "exportedAt": "2026-01-01T00:00:00Z", "vocabulary": [], "replacements": []}"#

        #expect(throws: DictionaryArchiveError.self) {
            try DictionaryImportExportService.decodeArchiveData(Data(otherFormat.utf8))
        }
        #expect(throws: DictionaryArchiveError.self) {
            try DictionaryImportExportService.decodeArchiveData(Data(newerVersion.utf8))
        }
    }
}
