import Testing
@testable import Screamr

private func w(_ text: String, _ start: Double, _ speaker: String = "speaker_0") -> Transcript.Word {
    Transcript.Word(text: text, start: start, end: start + 0.3, type: "word", speaker_id: speaker)
}

@Test func channelsInterleaveByTime() {
    let mic = [w("Hi", 0), w("there.", 0.4), w("Agreed.", 5)]
    let system = [w("Hello.", 2), w("Ship", 2.4, "speaker_1"), w("it.", 2.8, "speaker_1")]
    let md = Transcript.markdown(title: "T", mic: mic, system: system)
    #expect(md == """
    # T

    **[00:00:00] You:** Hi there.

    **[00:00:02] Speaker 1:** Hello.

    **[00:00:02] Speaker 2:** Ship it.

    **[00:00:05] You:** Agreed.


    """)
}

@Test func spacingIsIgnoredAndMultipleMicSpeakersAreRoomLabels() {
    let mic = [w("A", 0), Transcript.Word(text: " ", start: 0.3, end: 0.4, type: "spacing", speaker_id: "speaker_0"), w("B", 0.5, "speaker_1")]
    let segs = Transcript.segments(mic, name: Transcript.micName)
    #expect(segs.map(\.speaker) == ["Room 1", "Room 2"])
    #expect(segs.map(\.text) == ["A", "B"])
}

@Test func emptyMeetingSaysSo() {
    #expect(Transcript.markdown(title: "T", mic: [], system: []).contains("No speech detected"))
}
