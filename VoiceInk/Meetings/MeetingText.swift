import Foundation

enum MeetingText {
    struct Chunk: Equatable {
        var start: TimeInterval
        var end: TimeInterval
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // VAD closes a segment on every short pause; merging keeps enough context per model call.
    // A longer pause usually means a turn change, so it starts a new chunk: one language per chunk.
    static func mergeSegments(_ segments: [Chunk], maxSpan: TimeInterval = 30, maxGap: TimeInterval = 1) -> [Chunk] {
        var chunks: [Chunk] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if var last = chunks.last, segment.end - last.start <= maxSpan, segment.start - last.end <= maxGap {
                last.end = max(last.end, segment.end)
                chunks[chunks.count - 1] = last
            } else {
                chunks.append(segment)
            }
        }
        return chunks
    }

    static func fixedChunks(duration: TimeInterval, span: TimeInterval = 30) -> [Chunk] {
        stride(from: 0, to: duration, by: span).map { Chunk(start: $0, end: min($0 + span, duration)) }
    }

    static func assembleTranscript(_ lines: [(start: TimeInterval, text: String)]) -> String {
        lines.sorted { $0.start < $1.start }
            .map { (start: $0.start, text: collapseWhitespace($0.text)) }
            .filter { !$0.text.isEmpty }
            .map { "[\(timestamp($0.start))] \($0.text)" }
            .joined(separator: "\n")
    }

    static func title(fromSummary summary: String) -> String? {
        guard let line = summary.split(separator: "\n").first(where: { $0.hasPrefix("# ") }) else { return nil }
        let cleaned = collapseWhitespace(
            line.dropFirst(2)
                .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
                .joined(separator: " ")
        ).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let title = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
