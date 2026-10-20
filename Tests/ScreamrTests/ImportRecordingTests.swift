import AVFoundation
import Foundation
import Testing
@testable import Screamr

@Test func aRecorderFileBecomesAMeetingDatedWhenItWasRecorded() async throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tmp) }
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let source = tmp.appendingPathComponent("Daily standup.wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    do {
        let file = try AVAudioFile(forWriting: source, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        try file.write(from: buffer)
    }
    let recorded = Date(timeIntervalSince1970: 1_760_000_000)
    try FileManager.default.setAttributes([.modificationDate: recorded], ofItemAtPath: source.path)

    let root = tmp.appendingPathComponent("Meetings")
    let m = try await Meeting.importRecording(source, into: root)
    #expect(m.dir.lastPathComponent == Meeting.stamp(recorded))
    #expect(MeetingTitle.read(m.dir) == "Daily standup")
    // Marked as imported, so neither the Mac nor the server takes its one channel to be the user.
    #expect(Scribe.Meta.source(in: m.dir) == "import")
    let audio = try AVAudioFile(forReading: m.dir.appendingPathComponent("mic.m4a"))
    #expect(abs(Double(audio.length) / audio.fileFormat.sampleRate - 1) < 0.1)

    // Importing the same file again is refused and leaves the first import alone.
    await #expect(throws: (any Error).self) { try await Meeting.importRecording(source, into: root) }
    #expect(FileManager.default.fileExists(atPath: m.dir.appendingPathComponent("mic.m4a").path))
}
