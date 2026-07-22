import AppKit
import Combine
import Foundation
import SwiftUI
import MediaRemoteAdapter
class PlaybackController: ObservableObject {
    static let shared = PlaybackController()
    private var mediaController: MediaRemoteAdapter.MediaController
    // pauseMedia/resumeMedia are nonisolated async and run off-main (fired from
    // Recorder's Task blocks), while onTrackInfoReceived writes this state on the
    // main thread. Guard the shared media state with a lock to avoid a data race on
    // the TrackInfo struct (its payload holds ARC String/NSImage fields).
    private let stateLock = NSLock()
    private var wasPlayingWhenRecordingStarted = false
    private var isMediaPlaying = false
    private var lastKnownTrackInfo: TrackInfo?
    private var originalMediaAppBundleId: String?
    private var resumeTask: Task<Void, Never>?

    @Published var isPauseMediaEnabled: Bool = UserDefaults.standard.bool(forKey: "isPauseMediaEnabled") {
        didSet {
            UserDefaults.standard.set(isPauseMediaEnabled, forKey: "isPauseMediaEnabled")

            if isPauseMediaEnabled {
                startMediaTracking()
            } else {
                stopMediaTracking()
            }
        }
    }
    
    private init() {
        mediaController = MediaRemoteAdapter.MediaController()

        setupMediaControllerCallbacks()

        if isPauseMediaEnabled {
            startMediaTracking()
        }
    }
    
    private func setupMediaControllerCallbacks() {
        mediaController.onTrackInfoReceived = { [weak self] trackInfo in
            guard let self else { return }
            self.stateLock.lock()
            self.isMediaPlaying = trackInfo?.payload.isPlaying ?? false
            self.lastKnownTrackInfo = trackInfo
            self.stateLock.unlock()
        }
        
        mediaController.onListenerTerminated = { }
    }
    
    private func startMediaTracking() {
        mediaController.startListening()
    }
    
    private func stopMediaTracking() {
        mediaController.stopListening()
        stateLock.lock()
        isMediaPlaying = false
        lastKnownTrackInfo = nil
        wasPlayingWhenRecordingStarted = false
        originalMediaAppBundleId = nil
        stateLock.unlock()
    }

    func pauseMedia() async {
        stateLock.lock()
        resumeTask?.cancel()
        resumeTask = nil
        wasPlayingWhenRecordingStarted = false
        originalMediaAppBundleId = nil
        let playing = isMediaPlaying
        let track = lastKnownTrackInfo
        stateLock.unlock()

        guard isPauseMediaEnabled,
              playing,
              track?.payload.isPlaying == true,
              let bundleId = track?.payload.bundleIdentifier else {
            return
        }

        stateLock.lock()
        wasPlayingWhenRecordingStarted = true
        originalMediaAppBundleId = bundleId
        stateLock.unlock()

        try? await Task.sleep(nanoseconds: 50_000_000)

        mediaController.pause()
    }

    func resumeMedia() async {
        stateLock.lock()
        let shouldResume = wasPlayingWhenRecordingStarted
        let originalBundleId = originalMediaAppBundleId
        let track = lastKnownTrackInfo
        stateLock.unlock()
        let delay = MediaController.shared.audioResumptionDelay

        defer {
            stateLock.lock()
            wasPlayingWhenRecordingStarted = false
            originalMediaAppBundleId = nil
            stateLock.unlock()
        }

        guard isPauseMediaEnabled,
              shouldResume,
              let bundleId = originalBundleId else {
            return
        }

        guard isAppStillRunning(bundleId: bundleId) else {
            return
        }

        guard let currentTrackInfo = track,
              let currentBundleId = currentTrackInfo.payload.bundleIdentifier,
              currentBundleId == bundleId,
              currentTrackInfo.payload.isPlaying == false else {
            return
        }

        let task = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            if Task.isCancelled {
                return
            }

            Self.sendMediaPlayPauseKey()
        }

        stateLock.lock()
        resumeTask = task
        stateLock.unlock()
        await task.value
    }

    /// Simulate the hardware media Play/Pause key (NX_KEYTYPE_PLAY = 16).
    /// Some apps (e.g. Plexamp) ignore the MediaRemote `play` command but
    /// respond to the same HID key event the physical F8 key produces.
    private static func sendMediaPlayPauseKey() {
        func post(down: Bool) {
            let flags: UInt = down ? 0xa00 : 0xb00
            let data1 = Int((16 << 16) | ((down ? 0xa : 0xb) << 8))
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(down: true)
        post(down: false)
    }

    private func isAppStillRunning(bundleId: String) -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.contains { $0.bundleIdentifier == bundleId }
    }
}


