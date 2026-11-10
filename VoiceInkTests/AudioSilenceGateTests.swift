import Foundation
import Testing
@testable import VoiceInk

struct AudioSilenceGateTests {
    private func wav(_ samples: [Float]) -> Data {
        var data = Data(count: 44)
        for sample in samples {
            var value = Int16(sample * 32767).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    @Test func digitalSilenceIsSilent() {
        #expect(AudioSilenceGate.loudestWindowDBFS(pcm16WAV: wav(Array(repeating: 0, count: 16_000))) < -100)
    }

    @Test func dcOffsetCarriesNoSpeech() {
        #expect(AudioSilenceGate.loudestWindowDBFS(pcm16WAV: wav(Array(repeating: 0.2, count: 16_000))) < AudioSilenceGate.thresholdDBFS)
    }

    @Test func shortToneInsideSilenceIsMeasured() {
        // 0.1-amplitude 1 kHz sine is -23 dBFS RMS
        var samples = [Float](repeating: 0, count: 16_000)
        for i in 8_000..<9_600 { samples[i] = 0.1 * sin(2 * .pi * 1_000 * Float(i) / 16_000) }
        #expect(abs(AudioSilenceGate.loudestWindowDBFS(pcm16WAV: wav(samples)) - -23) < 0.5)
    }

    @Test func whisperLevelIsNotSilent() {
        let amplitude = Float(pow(10, -43.0 / 20) * 2.0.squareRoot())
        let samples = (0..<16_000).map { amplitude * sin(2 * .pi * 300 * Float($0) / 16_000) }
        #expect(AudioSilenceGate.loudestWindowDBFS(pcm16WAV: wav(samples)) > AudioSilenceGate.thresholdDBFS)
    }

    @Test func headerOnlyIsSilent() {
        #expect(AudioSilenceGate.loudestWindowDBFS(pcm16WAV: Data(count: 44)) == -120)
    }

    @Test func oddByteCountDoesNotCrash() {
        var data = wav(Array(repeating: 0.3, count: 960))
        data.append(0x7F)
        _ = AudioSilenceGate.loudestWindowDBFS(pcm16WAV: data)
    }
}
