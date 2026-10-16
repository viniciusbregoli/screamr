import Testing
@testable import Screamr

private func unit(_ v: [Float]) -> [Float] { VoicePrinter.mean([v]) }

@Test func matchesClosestPersonWithinThresholdOnly() {
    let ana = Person(number: 1, voice: unit([1, 0, 0]))
    let bia = Person(number: 2, voice: unit([0, 1, 0]))
    #expect(PeopleMatcher.match(unit([0.95, 0.1, 0]), in: [ana, bia]) == 0)
    #expect(PeopleMatcher.match(unit([0.1, 0.95, 0]), in: [ana, bia]) == 1)
    #expect(PeopleMatcher.match(unit([1, 1, 1]), in: [ana, bia]) == nil) // equally far from both, distance ~0.42
    #expect(PeopleMatcher.match(unit([1, 0, 0]), in: []) == nil)
}

@Test func absorbingKeepsVoiceNormalizedAndWeighted() {
    var p = Person(number: 1, voice: unit([1, 0]), samples: 3)
    PeopleMatcher.absorb(unit([0, 1]), into: &p)
    #expect(p.samples == 4)
    #expect(abs(p.voice[0] - 0.9487) < 0.001) // (3, 1) normalized: three old samples outweigh one new
    #expect(abs(p.voice.reduce(0) { $0 + $1 * $1 } - 1) < 0.0001)
}

@Test func mergeCombinesHistoryAndRemembersMergedIDs() {
    var target = Person(number: 1, voice: unit([1, 0]), meetings: ["a", "b"])
    let source = Person(number: 2, name: "Ana", voice: unit([1, 0]), meetings: ["b", "c"], quote: "hi")
    PeopleMatcher.merge(source, into: &target)
    #expect(target.meetings == ["a", "b", "c"])
    #expect(target.name == "Ana")
    #expect(target.quote == "hi")
    #expect(target.samples == 2)
    #expect(target.mergedIDs == [source.id])
}

@Test func speakerRangesMergeShortPausesPerSpeaker() {
    let words = [
        Transcript.Word(text: "a", start: 0, end: 1, type: "word", speaker_id: "speaker_0"),
        Transcript.Word(text: " ", start: 1, end: 1.2, type: "spacing", speaker_id: "speaker_0"),
        Transcript.Word(text: "b", start: 1.3, end: 2, type: "word", speaker_id: "speaker_0"),
        Transcript.Word(text: "c", start: 2.2, end: 3, type: "word", speaker_id: "speaker_1"),
        Transcript.Word(text: "d", start: 9, end: 10, type: "word", speaker_id: "speaker_0"),
    ]
    let r = PeopleMatcher.speakerRanges(words)
    #expect(r["speaker_0"]!.map(\.start) == [0, 9])
    #expect(r["speaker_0"]!.map(\.end) == [2, 10])
    #expect(r["speaker_1"]!.count == 1)
}

@Test func clipsSkipTooLittleSpeechAndCapWindows() {
    let rate = 16_000.0
    #expect(VoicePrinter.clips(samples: [Float](repeating: 0.1, count: Int(2 * rate))).isEmpty)
    let clips = VoicePrinter.clips(samples: [Float](repeating: 0.1, count: Int(25 * rate)))
    #expect(clips.map(\.count) == [Int(10 * rate), Int(10 * rate), Int(5 * rate)])
    #expect(VoicePrinter.clips(samples: [Float](repeating: 0.1, count: Int(21 * rate))).count == 2) // 1 s tail dropped
}
