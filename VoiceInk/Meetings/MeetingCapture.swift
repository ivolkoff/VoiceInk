import AppKit
import AVFoundation
import ScreenCaptureKit

struct RecordableApp: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: NSImage
}

enum MeetingCaptureError: LocalizedError {
    case unsupportedOS
    case appNotRunning
    case noDisplay
    case noAudio
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedOS: return String(localized: "Recording calls needs macOS 15 or later.")
        case .appNotRunning: return String(localized: "The selected app is not running.")
        case .noDisplay: return String(localized: "No display available for capture.")
        case .noAudio: return String(localized: "No audio was captured.")
        case .exportFailed: return String(localized: "Could not convert the recording to m4a.")
        }
    }
}

final class MeetingCapture: NSObject, SCStreamDelegate {
    var onStreamError: ((Error) -> Void)?
    private(set) var appName = ""
    private var stream: SCStream?
    private var writer: MeetingTrackWriter?

    static func runningApps() -> [RecordableApp] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0 != .current }
            .compactMap { app in
                guard let id = app.bundleIdentifier, seen.insert(id).inserted else { return nil }
                let icon = (app.icon?.copy() as? NSImage) ?? NSImage()
                icon.size = NSSize(width: 16, height: 16)
                return RecordableApp(id: id, name: app.localizedName ?? id, icon: icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func start(bundleID: String, includeMicrophone: Bool, microphoneUID: String?) async throws {
        guard #available(macOS 15, *) else { throw MeetingCaptureError.unsupportedOS }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        // Electron apps (Discord, Chrome…) play audio from helper processes with "<id>." bundle IDs.
        let targets = content.applications.filter {
            $0.bundleIdentifier == bundleID || $0.bundleIdentifier.hasPrefix(bundleID + ".")
        }
        guard !targets.isEmpty else { throw MeetingCaptureError.appNotRunning }
        guard let display = content.displays.first else { throw MeetingCaptureError.noDisplay }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = includeMicrophone
        if includeMicrophone, let microphoneUID {
            config.microphoneCaptureDeviceID = microphoneUID
        }
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        let writer = try MeetingTrackWriter(url: tempURL, includeMicrophone: includeMicrophone)
        let stream = SCStream(filter: SCContentFilter(display: display, including: targets, exceptingWindows: []),
                              configuration: config, delegate: self)
        try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
        if includeMicrophone {
            try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue)
        }
        try await stream.startCapture()

        self.stream = stream
        self.writer = writer
        appName = (targets.first { $0.bundleIdentifier == bundleID } ?? targets.first)?.applicationName ?? bundleID
    }

    func stop() async throws -> URL? {
        guard let stream, let writer else { return nil }
        self.stream = nil
        self.writer = nil
        try? await stream.stopCapture()
        return try await writer.finish()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onStreamError?(error) }
    }

    static func mixdown(_ source: URL, to destination: URL) async throws {
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A) else {
            throw MeetingCaptureError.exportFailed
        }
        guard #available(macOS 15, *) else { throw MeetingCaptureError.unsupportedOS }
        try await export.export(to: destination, as: .m4a)
    }
}

final class MeetingTrackWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "VoiceInk.meetingWriter")
    private let writer: AVAssetWriter
    private let appInput: AVAssetWriterInput
    private let micInput: AVAssetWriterInput?
    private var started = false

    init(url: URL, includeMicrophone: Bool) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        appInput = Self.makeInput(channels: 2)
        writer.add(appInput)
        if includeMicrophone {
            let mic = Self.makeInput(channels: 1)
            writer.add(mic)
            micInput = mic
        } else {
            micInput = nil
        }
    }

    private static func makeInput(channels: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 64_000 * channels,
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        let input: AVAssetWriterInput?
        if type == .audio {
            input = appInput
        } else if #available(macOS 15, *), type == .microphone {
            input = micInput
        } else {
            input = nil
        }
        guard let input else { return }

        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard started else {
                    continuation.resume(throwing: MeetingCaptureError.noAudio)
                    return
                }
                // finishWriting raises an exception on a failed writer instead of reporting an error.
                guard writer.status == .writing else {
                    continuation.resume(throwing: writer.error ?? MeetingCaptureError.noAudio)
                    return
                }
                appInput.markAsFinished()
                micInput?.markAsFinished()
                writer.finishWriting { [self] in
                    if let error = writer.error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: writer.outputURL)
                    }
                }
            }
        }
    }
}
