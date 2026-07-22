import Foundation
import CoreAudio

final class MediaController: ObservableObject {

    static let shared = MediaController()

    // mute/unmute run as independent nonisolated async tasks (Recorder fires them
    // from separate Tasks, and a delayed unmute can still be pending when the next
    // recording's mute starts), so guard the shared mute-state with a lock.
    private let stateLock = NSLock()
    private var didMuteAudio = false
    private var wasAudioMutedBeforeRecording = false
    private var unmuteTask: Task<Void, Never>?
    private var muteGeneration: Int = 0
    // The exact device we muted. macOS can switch the default output mid-recording (AirPods
    // connect, etc.), so unmute must target the muted device, not whatever is default at stop.
    private var mutedDeviceID: AudioDeviceID?

    @Published var isSystemMuteEnabled: Bool = UserDefaults.standard.bool(forKey: "isSystemMuteEnabled") {
        didSet { UserDefaults.standard.set(isSystemMuteEnabled, forKey: "isSystemMuteEnabled") }
    }

    @Published var audioResumptionDelay: Double = UserDefaults.standard.double(forKey: "audioResumptionDelay") {
        didSet { UserDefaults.standard.set(audioResumptionDelay, forKey: "audioResumptionDelay") }
    }

    private init() {}

    func muteSystemAudio() async -> Bool {
        guard isSystemMuteEnabled else { return false }

        stateLock.lock()
        unmuteTask?.cancel()
        unmuteTask = nil
        muteGeneration += 1
        let previouslyOurs = didMuteAudio
        stateLock.unlock()

        let currentlyMuted = isSystemAudioMuted()

        if currentlyMuted {
            stateLock.lock()
            if previouslyOurs {
                // We muted it previously, stay responsible for unmuting
                wasAudioMutedBeforeRecording = false
            } else {
                // User muted it, don't unmute when done
                wasAudioMutedBeforeRecording = true
                didMuteAudio = false
            }
            stateLock.unlock()
            return true
        }

        guard let deviceID = getDefaultOutputDevice() else {
            stateLock.lock()
            wasAudioMutedBeforeRecording = false
            didMuteAudio = false
            stateLock.unlock()
            return false
        }

        let success = setMuted(true, on: deviceID)
        stateLock.lock()
        wasAudioMutedBeforeRecording = false
        didMuteAudio = success
        mutedDeviceID = success ? deviceID : nil
        stateLock.unlock()
        return success
    }

    func unmuteSystemAudio() async {
        let delay = audioResumptionDelay

        stateLock.lock()
        let shouldUnmute = didMuteAudio && !wasAudioMutedBeforeRecording
        let myGeneration = muteGeneration
        stateLock.unlock()

        // Gate on whether WE actually muted (didMuteAudio), not the live isSystemMuteEnabled flag:
        // the user can toggle the feature off mid-recording, and that must not strand the output muted.
        guard shouldUnmute else { return }

        let task = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            guard let self = self else { return }
            guard !Task.isCancelled else { return }

            // A newer mute (higher generation) supersedes this pending unmute;
            // check and clear our state atomically so the two never interleave.
            self.stateLock.lock()
            let isCurrent = self.muteGeneration == myGeneration
            let deviceToUnmute = isCurrent ? self.mutedDeviceID : nil
            if isCurrent {
                self.didMuteAudio = false
                self.mutedDeviceID = nil
            }
            self.stateLock.unlock()

            if let deviceToUnmute {
                _ = self.setMuted(false, on: deviceToUnmute)
            }
        }

        stateLock.lock()
        unmuteTask = task
        stateLock.unlock()
        await task.value
    }

    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        return status == noErr ? deviceID : nil
    }

    private func isSystemAudioMuted() -> Bool {
        guard let deviceID = getDefaultOutputDevice() else { return false }

        var muted: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if !AudioObjectHasProperty(deviceID, &address) {
            address.mElement = 0
            if !AudioObjectHasProperty(deviceID, &address) { return false }
        }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &muted)
        return status == noErr && muted != 0
    }

    private func setMuted(_ muted: Bool, on deviceID: AudioDeviceID) -> Bool {
        var muteValue: UInt32 = muted ? 1 : 0
        let propertySize = UInt32(MemoryLayout<UInt32>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if !AudioObjectHasProperty(deviceID, &address) {
            address.mElement = 0
            if !AudioObjectHasProperty(deviceID, &address) { return false }
        }

        var isSettable: DarwinBoolean = false
        var status = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        if status != noErr || !isSettable.boolValue { return false }

        status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, propertySize, &muteValue)
        return status == noErr
    }
}
