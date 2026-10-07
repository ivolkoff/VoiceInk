import Foundation

struct MeetingRecording: Identifiable, Hashable {
    static let audioName = "audio.m4a"
    static let transcriptName = "transcript.txt"
    static let summaryName = "summary.md"
    static let rawCaptureName = "capture.mov"

    let folder: URL
    let date: Date
    let hasTranscript: Bool
    let hasSummary: Bool

    var id: URL { folder }
    var name: String { folder.lastPathComponent }
    var audioURL: URL { folder.appendingPathComponent(Self.audioName) }
    var transcriptURL: URL { folder.appendingPathComponent(Self.transcriptName) }
    var summaryURL: URL { folder.appendingPathComponent(Self.summaryName) }
}

struct MeetingStore {
    // Same folder as AppRec, so its recordings show up here.
    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Music/Recordings", isDirectory: true)

    let root: URL

    func list() throws -> [MeetingRecording] {
        let fileManager = FileManager.default
        let folders: [URL]
        do {
            folders = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        return folders.compactMap { folder in
            guard fileManager.fileExists(atPath: folder.appendingPathComponent(MeetingRecording.audioName).path) else { return nil }
            return MeetingRecording(
                folder: folder,
                date: Self.creationDate(of: folder) ?? .distantPast,
                hasTranscript: fileManager.fileExists(atPath: folder.appendingPathComponent(MeetingRecording.transcriptName).path),
                hasSummary: fileManager.fileExists(atPath: folder.appendingPathComponent(MeetingRecording.summaryName).path)
            )
        }
        .sorted { $0.date > $1.date }
    }

    func makeFolder(appName: String, startedAt: Date) throws -> URL {
        let safeName = appName.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: " ")
        let folder = uniqueFolder(named: "\(safeName) \(Self.formatter("yyyy-MM-dd HH.mm.ss").string(from: startedAt))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // The folder is created at stop; its creation date is moved to the start so a later rename shows the start time.
    func setStartDate(_ date: Date, of folder: URL) throws {
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: folder.path)
    }

    @discardableResult
    func rename(_ folder: URL, to title: String) throws -> URL {
        let created = Self.creationDate(of: folder) ?? Date()
        let name = "\(Self.formatter("yyyy-MM-dd HH.mm").string(from: created)) \(title)"
        let target = uniqueFolder(named: name, allowing: folder.lastPathComponent)
        guard target.lastPathComponent != folder.lastPathComponent else { return folder }
        try FileManager.default.moveItem(at: folder, to: target)
        return target
    }

    func trash(_ recording: MeetingRecording) throws {
        try FileManager.default.trashItem(at: recording.folder, resultingItemURL: nil)
    }

    // `allowing` is the folder being renamed: its own current name is not a collision.
    private func uniqueFolder(named name: String, allowing current: String? = nil) -> URL {
        var candidate = root.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while candidate.lastPathComponent != current, FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(name) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private static func creationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}
