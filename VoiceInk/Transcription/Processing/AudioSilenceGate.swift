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

    /// Loudest DC-removed RMS over 30 ms windows of a 16 kHz mono PCM16 WAV, or `nil` when
    /// the file has no `data` chunk. With `stopAbove`, returns the first window louder than it.
    static func loudestWindowDBFS(pcm16WAV data: Data, stopAbove: Float? = nil) -> Float? {
        guard let samples = dataChunkRange(in: data) else { return nil }
        let sampleCount = samples.count / 2
        let stopLevel = stopAbove.map { pow(10, Double($0) / 20) }

        var loudest = 0.0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var window = [Double](repeating: 0, count: windowSamples)
            var start = 0
            while start + windowSamples <= sampleCount {
                for i in 0..<windowSamples {
                    let offset = samples.lowerBound + (start + i) * 2
                    let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))
                    window[i] = Double(value) / 32767
                }
                let mean = window.reduce(0, +) / Double(windowSamples)
                let variance = window.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(windowSamples)
                loudest = max(loudest, variance.squareRoot())
                if let stopLevel, loudest > stopLevel { return }
                start += windowSamples
            }
        }
        return Float(20 * log10(max(loudest, 1e-6)))
    }

    static func isSilent(audioURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: audioURL),
              let level = loudestWindowDBFS(pcm16WAV: data, stopAbove: thresholdDBFS) else { return false }
        return level < thresholdDBFS
    }

    /// ExtAudioFile writes a `FLLR` chunk before `data`, so the samples do not start at byte 44.
    private static func dataChunkRange(in data: Data) -> Range<Int>? {
        guard data.count >= 12,
              data.prefix(4) == Data("RIFF".utf8),
              data[data.startIndex + 8..<data.startIndex + 12] == Data("WAVE".utf8) else { return nil }
        var offset = 12
        while offset + 8 <= data.count {
            let base = data.startIndex + offset
            let id = data[base..<base + 4]
            let size = data[base + 4..<base + 8].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            let body = offset + 8
            if id == Data("data".utf8) {
                return body..<min(body + size, data.count)
            }
            offset = body + size + (size & 1)
        }
        return nil
    }
}
