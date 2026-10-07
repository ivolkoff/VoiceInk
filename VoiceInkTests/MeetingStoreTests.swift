import Foundation
import Testing
@testable import VoiceInk

struct MeetingStoreTests {
    private func makeStore() throws -> MeetingStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return MeetingStore(root: root)
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    private func touch(_ url: URL) throws { try Data("x".utf8).write(to: url) }

    @Test func listsFoldersWithAudioNewestFirst() throws {
        let store = try makeStore()
        let older = try store.makeFolder(appName: "Zoom", startedAt: date(2026, 10, 1, 9, 0))
        let newer = try store.makeFolder(appName: "Discord", startedAt: date(2026, 10, 2, 9, 0))
        let noAudio = store.root.appendingPathComponent("junk", isDirectory: true)
        try FileManager.default.createDirectory(at: noAudio, withIntermediateDirectories: true)
        try touch(older.appendingPathComponent(MeetingRecording.audioName))
        try touch(older.appendingPathComponent(MeetingRecording.transcriptName))
        try touch(newer.appendingPathComponent(MeetingRecording.audioName))
        try store.setStartDate(date(2026, 10, 1, 9, 0), of: older)
        try store.setStartDate(date(2026, 10, 2, 9, 0), of: newer)

        let list = try store.list()
        #expect(list.map(\.name) == [newer.lastPathComponent, older.lastPathComponent])
        #expect(list.map(\.hasTranscript) == [false, true])
        #expect(list.map(\.hasSummary) == [false, false])
    }

    @Test func missingRootListsNothing() throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(try store.list().isEmpty)
    }

    @Test func folderNameUsesStartTimeAndAvoidsCollisions() throws {
        let store = try makeStore()
        let start = date(2026, 10, 7, 14, 5, 9)
        let first = try store.makeFolder(appName: "Google Chrome", startedAt: start)
        let second = try store.makeFolder(appName: "Google Chrome", startedAt: start)
        #expect(first.lastPathComponent == "Google Chrome 2026-10-07 14.05.09")
        #expect(second.lastPathComponent == "Google Chrome 2026-10-07 14.05.09 2")
    }

    @Test func renameUsesCreationDateAndSuffix() throws {
        let store = try makeStore()
        let start = date(2026, 10, 7, 9, 5)
        let a = try store.makeFolder(appName: "Zoom", startedAt: start)
        let b = try store.makeFolder(appName: "Zoom", startedAt: start.addingTimeInterval(1))
        try store.setStartDate(start, of: a)
        try store.setStartDate(start, of: b)
        let renamedA = try store.rename(a, to: "Weekly sync")
        let renamedB = try store.rename(b, to: "Weekly sync")
        #expect(renamedA.lastPathComponent == "2026-10-07 09.05 Weekly sync")
        #expect(renamedB.lastPathComponent == "2026-10-07 09.05 Weekly sync 2")
        #expect(try store.rename(renamedA, to: "Weekly sync") == renamedA)
    }
}
