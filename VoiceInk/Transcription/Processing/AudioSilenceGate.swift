import Foundation

/// Models hallucinate closing phrases on silence, so a capture whose loudest 30 ms stays
/// below the threshold is not transcribed (anomalyco/hex `SILENCE_THRESHOLD_DBFS`).
enum AudioSilenceGate {
    static let thresholdDBFS: Float = -50
    static let windowSamples = 480

    enum NoSpeechError: LocalizedError {
        case noSpeech

        var errorDescription: String? { String(localized: "No speech detected") }
    }

    /// Loudest DC-removed RMS over 30 ms windows of a 16 kHz PCM16 WAV with a 44-byte header.
    static func loudestWindowDBFS(pcm16WAV data: Data) -> Float {
        let headerSize = 44
        let sampleCount = max(0, (data.count - headerSize) / 2)
        guard sampleCount >= windowSamples else { return -120 }

        var loudest = 0.0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var window = [Double](repeating: 0, count: windowSamples)
            var start = 0
            while start + windowSamples <= sampleCount {
                for i in 0..<windowSamples {
                    let offset = headerSize + (start + i) * 2
                    let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))
                    window[i] = Double(value) / 32767
                }
                let mean = window.reduce(0, +) / Double(windowSamples)
                let variance = window.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(windowSamples)
                loudest = max(loudest, variance.squareRoot())
                start += windowSamples
            }
        }
        return Float(20 * log10(max(loudest, 1e-6)))
    }

    static func isSilent(audioURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: audioURL) else { return false }
        return loudestWindowDBFS(pcm16WAV: data) < thresholdDBFS
    }
}
