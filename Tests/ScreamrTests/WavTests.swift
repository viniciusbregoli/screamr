import AVFoundation
import Testing
@testable import Screamr

@Test func wavRoundTripsThroughAVAudioFile() throws {
    let samples = (0..<16_000).map { Int16(truncatingIfNeeded: $0 % 2000 - 1000) }
    let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("screamr-test.wav")
    try Recorder.wav(pcm, sampleRate: 16_000).write(to: url)

    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
    #expect(file.fileFormat.sampleRate == 16_000)
    #expect(file.fileFormat.channelCount == 1)
    #expect(file.length == 16_000)

    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000)!
    try file.read(into: buf)
    #expect(buf.int16ChannelData![0][1234] == samples[1234])
}
