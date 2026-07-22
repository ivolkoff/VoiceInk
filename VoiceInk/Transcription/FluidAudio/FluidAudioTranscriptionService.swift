import Foundation
import CoreML
import AVFoundation
import FluidAudio
import os.log

class FluidAudioTranscriptionService: TranscriptionService {
    private var asrManager: AsrManager?
    private var vadManager: VadManager?
    private var activeVersion: AsrModelVersion?
    private var cachedModels: AsrModels?
    private var loadingTask: (version: AsrModelVersion, task: Task<AsrModels, Error>)?
    private let loadingTaskLock = NSLock()
    // These methods are nonisolated async (they run off the main actor on the cooperative pool),
    // so cleanup() nil-ing the managers can race a concurrent transcribe()/ensureModelsLoaded()
    // reading/writing the same class-reference storage — a data race that corrupts the refcount.
    // Guard every access with this lock (never held across an await).
    private let stateLock = NSLock()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FluidAudioTranscriptionService")

    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func version(for model: any TranscriptionModel) -> AsrModelVersion {
        FluidAudioModelManager.asrVersion(for: model.name)
    }

    static func languageHint(from selectedLanguage: String?, model: any TranscriptionModel) -> Language? {
        guard model.provider == .fluidAudio else {
            return nil
        }
        return FluidAudioModelManager.languageHint(from: selectedLanguage, for: model.name)
    }

    private func ensureModelsLoaded(for version: AsrModelVersion) async throws {
        if withState({ asrManager != nil && activeVersion == version }) {
            return
        }

        // Clean up existing manager but preserve cachedModels for reuse
        let existing = withState { asrManager }
        await existing?.cleanup()
        withState {
            asrManager = nil
            vadManager = nil
            activeVersion = nil
        }

        let models = try await getOrLoadModels(for: version)

        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        withState {
            self.asrManager = manager
            self.activeVersion = version
        }
    }

    // Returns cached models or loads from disk; deduplicates concurrent loads
    func getOrLoadModels(for version: AsrModelVersion) async throws -> AsrModels {
        if let cached = withState({ cachedModels }), cached.version == version {
            return cached
        }

        // Deduplicate concurrent loads for the same version
        loadingTaskLock.lock()
        let existingTask = loadingTask
        loadingTaskLock.unlock()
        if let (existingVersion, existingTask) = existingTask, existingVersion == version {
            return try await existingTask.value
        }

        let task = Task {
            try await AsrModels.downloadAndLoad(
                configuration: nil,
                version: version
            )
        }
        loadingTaskLock.lock()
        loadingTask = (version, task)
        loadingTaskLock.unlock()

        do {
            let models = try await task.value
            withState { self.cachedModels = models }
            // Only clear if we're still the current loading task
            loadingTaskLock.lock()
            if loadingTask?.version == version {
                self.loadingTask = nil
            }
            loadingTaskLock.unlock()
            return models
        } catch {
            // Only clear if we're still the current loading task
            loadingTaskLock.lock()
            if loadingTask?.version == version {
                self.loadingTask = nil
            }
            loadingTaskLock.unlock()
            throw error
        }
    }

    func loadModel(for model: FluidAudioModel) async throws {
        try await ensureModelsLoaded(for: version(for: model))
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel, language: String?) async throws -> String {
        let targetVersion = version(for: model)
        try await ensureModelsLoaded(for: targetVersion)

        guard let asrManager = withState({ self.asrManager }) else {
            throw ASRError.notInitialized
        }

        let languageHint = Self.languageHint(
            from: language
                ?? TranscriptionLanguagePreference.layoutOverride(for: model)
                ?? UserDefaults.standard.string(forKey: "SelectedLanguage"),
            model: model
        )
        let audioSamples = try readAudioSamples(from: audioURL)

        let durationSeconds = Double(audioSamples.count) / 16000.0
        let isVADEnabled = UserDefaults.standard.bool(forKey: "IsVADEnabled")

        var speechAudio = audioSamples
        if durationSeconds >= 20.0, isVADEnabled {
            let vadConfig = VadConfig(defaultThreshold: 0.7)
            if withState({ vadManager }) == nil {
                do {
                    let created = try await VadManager(config: vadConfig)
                    withState { vadManager = created }
                } catch {
                    logger.notice("VAD init failed; falling back to full audio: \(error.localizedDescription, privacy: .public)")
                    withState { vadManager = nil }
                }
            }

            if let vadManager = withState({ self.vadManager }) {
                do {
                    let segments = try await vadManager.segmentSpeechAudio(audioSamples)
                    speechAudio = segments.isEmpty ? audioSamples : segments.flatMap { $0 }
                } catch {
                    logger.notice("VAD segmentation failed; using full audio: \(error.localizedDescription, privacy: .public)")
                    speechAudio = audioSamples
                }
            }
        }

        // Pad with 1s of silence to capture final punctuation at sequence boundary
        let trailingSilenceSamples = 16_000
        let maxSingleChunkSamples = 240_000
        if speechAudio.count + trailingSilenceSamples <= maxSingleChunkSamples {
            speechAudio += [Float](repeating: 0, count: trailingSilenceSamples)
        }

        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(
            speechAudio,
            decoderState: &decoderState,
            language: languageHint
        )

        return TextNormalizer.shared.normalizeSentence(result.text)
    }

    private func readAudioSamples(from url: URL) throws -> [Float] {
        do {
            let data = try Data(contentsOf: url)
            guard data.count > 44 else {
                throw ASRError.invalidAudioData
            }

            // Stop one short of the end so the final 2-byte slice never runs past
            // the buffer: an odd byte count (truncated/corrupt WAV) would otherwise
            // make data[$0..<$0+2] read out of bounds and crash (same guard as
            // WhisperTranscriptionService.readAudioSamples).
            let floats = stride(from: 44, to: data.count - 1, by: 2).map {
                return data[$0..<$0 + 2].withUnsafeBytes {
                    let short = Int16(littleEndian: $0.load(as: Int16.self))
                    return max(-1.0, min(Float(short) / 32767.0, 1.0))
                }
            }

            return floats
        } catch {
            throw ASRError.invalidAudioData
        }
    }

    // Releases ASR/VAD resources but preserves cached models for reuse
    func cleanup() async {
        let manager = withState { asrManager }
        if let manager {
            await manager.cleanup()
        }
        withState {
            asrManager = nil
            vadManager = nil
            activeVersion = nil
        }
    }

}
