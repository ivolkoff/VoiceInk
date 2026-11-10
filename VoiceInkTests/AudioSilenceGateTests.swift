import AudioToolbox
import Foundation
import Testing
@testable import VoiceInk

struct AudioSilenceGateTests {
    /// A canonical 44-byte RIFF/WAVE header followed by 16 kHz mono PCM16 samples.
    private func wav(_ samples: [Float]) -> Data {
        func le32(_ value: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(value).littleEndian, Array.init) }
        func le16(_ value: Int) -> [UInt8] { withUnsafeBytes(of: UInt16(value).littleEndian, Array.init) }
        let dataSize = samples.count * 2
        var data = Data("RIFF".utf8) + le32(36 + dataSize) + Data("WAVE".utf8)
        data += Data("fmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(16_000) + le32(32_000) + le16(2) + le16(16)
        data += Data("data".utf8) + le32(dataSize)
        for sample in samples {
            var value = Int16(sample * 32767).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Writes samples the way `CoreAudioRecorder.createOutputFile` does (ExtAudioFile, WAVE, 16 kHz mono PCM16).
    private func recorderStyleFile(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        var format = AudioStreamBasicDescription(
            mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        var file: ExtAudioFileRef?
        #expect(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType, &format, nil, AudioFileFlags.eraseFile.rawValue, &file) == noErr)
        let ref = try #require(file)
        var ints = samples.map { Int16($0 * 32767) }
        ints.withUnsafeMutableBytes { bytes in
            var buffers = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress)
            )
            _ = ExtAudioFileWrite(ref, UInt32(samples.count), &buffers)
        }
        ExtAudioFileDispose(ref)
        return url
    }

    private func sine(dBFS: Double, count: Int) -> [Float] {
        let amplitude = Float(pow(10, dBFS / 20) * 2.0.squareRoot())
        return (0..<count).map { amplitude * sin(2 * .pi * 300 * Float($0) / 16_000) }
    }

    @Test func digitalSilenceIsSilent() {
        #expect(AudioSilenceGate.loudestWindowDBFS(pcm16WAV: wav(Array(repeating: 0, count: 16_000)))! < -100)
    }

    @Test func dcOffsetCarriesNoSpeech() {
        #expect(AudioSilenceGate.loudestWindowDBFS(pcm16WAV: wav(Array(repeating: 0.2, count: 16_000)))! < AudioSilenceGate.thresholdDBFS)
    }

    @Test func shortToneInsideSilenceIsMeasured() {
        // 0.1-amplitude 1 kHz sine is -23 dBFS RMS
        var samples = [Float](repeating: 0, count: 16_000)
        for i in 8_000..<9_600 { samples[i] = 0.1 * sin(2 * .pi * 1_000 * Float(i) / 16_000) }
        #expect(abs(AudioSilenceGate.loudestWindowDBFS(pcm16WAV: wav(samples))! - -23) < 0.5)
    }

    @Test func whisperLevelIsNotSilent() {
        #expect(AudioSilenceGate.loudestWindowDBFS(pcm16WAV: wav(sine(dBFS: -43, count: 16_000)))! > AudioSilenceGate.thresholdDBFS)
    }

    @Test func headerOnlyIsSilent() {
        #expect(AudioSilenceGate.loudestWindowDBFS(pcm16WAV: wav([])) == -120)
    }

    @Test func missingDataChunkIsNotMeasured() {
        #expect(AudioSilenceGate.loudestWindowDBFS(pcm16WAV: Data(count: 44)) == nil)
    }

    @Test func oddByteCountDoesNotCrash() {
        var data = wav(Array(repeating: 0.3, count: 960))
        data.append(0x7F)
        _ = AudioSilenceGate.loudestWindowDBFS(pcm16WAV: data)
    }

    @Test func recorderStyleSilentFileIsSilent() throws {
        let url = try recorderStyleFile(Array(repeating: 0, count: 16_000))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AudioSilenceGate.isSilent(audioURL: url))
    }

    @Test func recorderStyleSpeechLevelFileIsNotSilent() throws {
        let url = try recorderStyleFile(sine(dBFS: -30, count: 16_000))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!AudioSilenceGate.isSilent(audioURL: url))
    }

    @Test func stopsAtFirstWindowAboveTheLimit() {
        let samples = sine(dBFS: -43, count: 4_800) + sine(dBFS: -10, count: 4_800)
        let level = AudioSilenceGate.loudestWindowDBFS(pcm16WAV: wav(samples), stopAbove: AudioSilenceGate.thresholdDBFS)!
        #expect(abs(level - -43) < 1)
    }
}
