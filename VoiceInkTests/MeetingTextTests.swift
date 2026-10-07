import Foundation
import Testing
@testable import VoiceInk

struct MeetingTextTests {
    @Test func timestampFormats() {
        #expect(MeetingText.timestamp(5) == "00:05")
        #expect(MeetingText.timestamp(3599) == "59:59")
        #expect(MeetingText.timestamp(3723) == "1:02:03")
        #expect(MeetingText.timestamp(-1) == "00:00")
    }

    @Test func mergeKeepsChunksWithinMaxSpan() {
        let segments: [MeetingText.Chunk] = [.init(start: 0, end: 10), .init(start: 10.8, end: 25), .init(start: 25.9, end: 31), .init(start: 32, end: 40)]
        #expect(MeetingText.mergeSegments(segments) == [.init(start: 0, end: 25), .init(start: 25.9, end: 40)])
    }

    @Test func longPauseStartsNewChunk() {
        let segments: [MeetingText.Chunk] = [.init(start: 0, end: 3), .init(start: 5, end: 12), .init(start: 12.5, end: 20)]
        #expect(MeetingText.mergeSegments(segments) == [.init(start: 0, end: 3), .init(start: 5, end: 20)])
    }

    @Test func mergeLeavesLongSegmentAlone() {
        let segments: [MeetingText.Chunk] = [.init(start: 0, end: 40), .init(start: 41, end: 45)]
        #expect(MeetingText.mergeSegments(segments) == segments)
    }

    @Test func mergeSortsAndHandlesEmpty() {
        #expect(MeetingText.mergeSegments([]).isEmpty)
        #expect(MeetingText.mergeSegments([.init(start: 5.5, end: 14), .init(start: 0, end: 5)]) == [.init(start: 0, end: 14)])
    }

    @Test func fixedChunksCoverDuration() {
        #expect(MeetingText.fixedChunks(duration: 65, span: 30) == [.init(start: 0, end: 30), .init(start: 30, end: 60), .init(start: 60, end: 65)])
        #expect(MeetingText.fixedChunks(duration: 0, span: 30).isEmpty)
    }

    @Test func assembleDropsEmptyCollapsesWhitespaceAndSorts() {
        let text = MeetingText.assembleTranscript([(start: 65, text: "second\nline"), (start: 3, text: "  first "), (start: 30, text: " \n ")])
        #expect(text == "[00:03] first\n[01:05] second line")
    }

    @Test func titleFromFirstHeading() {
        #expect(MeetingText.title(fromSummary: "# Release: plan/Friday.\n\n## TL;DR") == "Release plan Friday")
        #expect(MeetingText.title(fromSummary: "Intro\n# Weekly sync\n") == "Weekly sync")
        #expect(MeetingText.title(fromSummary: "## TL;DR\nNo title") == nil)
        #expect(MeetingText.title(fromSummary: "# ...") == nil)
        #expect(MeetingText.title(fromSummary: "# " + String(repeating: "a", count: 80))?.count == 60)
    }
}
