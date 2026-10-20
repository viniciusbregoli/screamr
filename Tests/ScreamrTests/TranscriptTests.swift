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

@Test func recognizedPeopleOverrideDefaultLabels() {
    let md = Transcript.markdown(title: "T", mic: [w("Hi.", 0)], system: [w("Yo.", 2, "speaker_3")],
                                 names: ["system:speaker_3": "Ana", "mic:speaker_0": "Vinicius"])
    #expect(md.contains("Vinicius:** Hi."))
    #expect(md.contains("Ana:** Yo."))
}

@Test func emptyMeetingSaysSo() {
    #expect(Transcript.markdown(title: "T", mic: [], system: []).contains("No speech detected"))
}

@Test func labelsCoverEverySpeakerWithNamesFirst() {
    let w = { (id: String) in Transcript.Word(text: "hi", start: 0, end: 1, type: "word", speaker_id: id) }
    let labels = Transcript.labels(mic: [w("speaker_0"), w("speaker_1")], system: [w("speaker_0")], names: ["mic:speaker_1": "Ana"])
    #expect(labels == ["mic:speaker_0": "Room 1", "mic:speaker_1": "Ana", "system:speaker_0": "Speaker 1"])
    // The iPhone has no "You" channel, so its mic speakers are plain numbered speakers.
    let phone = Transcript.labels(mic: [w("speaker_0")], system: [], micName: Transcript.systemName)
    #expect(phone == ["mic:speaker_0": "Speaker 1"])
}

@Test func aLineOverrideRelabelsOnlyThatLine() {
    let w = { (text: String, id: String, start: Double) in Transcript.Word(text: text, start: start, end: start + 0.5, type: "word", speaker_id: id) }
    let mic = [w("Hello", "speaker_0", 0), w("there", "speaker_0", 5), w("again", "speaker_0", 10)]
    let labels = ["mic:speaker_0": "You", "line:mic:5.00": "Ana"]
    let lines = Transcript.merged(mic: mic, system: [], labels: labels)
    #expect(lines.map(\.speaker) == ["You", "Ana", "You"])
    #expect(lines[1].lineKey == "mic:5.00")
    #expect(Transcript.markdown(title: "T", mic: mic, system: [], names: labels).contains("Ana:** there"))
}

@Test func aPauseInsideASentenceKeepsTheLineWhole() {
    let mic = [w("fiquei,", 0), w("é,", 0.4), w("fazendo", 2), w("isso.", 2.4), w("E", 4), w("como--", 4.4), w("ele", 15)]
    let lines = Transcript.merged(mic: mic, system: [], labels: [:])
    // Joined after "é,"; split after the period; split past the 10 s cap even though "como--" is unfinished.
    #expect(lines.map(\.text) == ["fiquei, é, fazendo isso.", "E como--", "ele"])
    #expect(lines[0].lineKey == "mic:0.00")
}

@Test func someoneSpeakingInTheGapKeepsTheLinesApart() {
    let mic = [w("vai", 0), w("ser", 0.4), w("o--", 3)]
    let system = [Transcript.Word(text: "Hum.", start: 0.5, end: 2.8, type: "word", speaker_id: "speaker_0")]
    let lines = Transcript.merged(mic: mic, system: system, labels: [:])
    #expect(lines.map(\.text) == ["vai ser", "Hum.", "o--"])
}

@Test func twoScribeIdsWithTheSameNameStayOnSeparateLines() {
    let mic = [w("vai", 0), w("ser", 2, "speaker_1")]
    let lines = Transcript.merged(mic: mic, system: [], labels: ["mic:speaker_0": "Ana", "mic:speaker_1": "Ana"])
    #expect(lines.map(\.speakerID) == ["speaker_0", "speaker_1"])
}

@Test func fillersLeaveOtherPeoplesWordsAlone() {
    #expect(Transcript.withoutFillers("sexta-feira eu fiquei, é, basicamente a tarde inteira,") == "sexta-feira eu fiquei, basicamente a tarde inteira,")
    #expect(Transcript.withoutFillers("Ééé, fazendo ummm-- o CFTV demo") == "Fazendo o CFTV demo")
    // The sentence end a filler carried moves to the word before it.
    #expect(Transcript.withoutFillers("isso é um documento, hum.") == "isso é um documento.")
    #expect(Transcript.withoutFillers("Hmm.") == "")
    #expect(Transcript.withoutFillers("Hã, tô finalizando.") == "Tô finalizando.")
}

@Test func onlyTheUsersLinesKeepTheirFillers() {
    let w = { (text: String, id: String, start: Double) in Transcript.Word(text: text, start: start, end: start + 0.5, type: "word", speaker_id: id) }
    let mic = [w("Hum,", "speaker_0", 0), w("sim.", "speaker_0", 0.6)]
    let system = [w("Ééé,", "speaker_0", 2), w("ok.", "speaker_0", 2.6)]
    let lines = Transcript.merged(mic: mic, system: system, labels: [:])
    #expect(Transcript.tidied(lines, me: nil).map(\.text) == ["Hum, sim.", "Ok."])
    // me.json says who the user is, whatever the label: here the mic voice is someone in the room.
    let me = [Transcript.Span(channel: "system", start: 2, end: 3.1)]
    #expect(Transcript.tidied(lines, me: me).map(\.text) == ["Sim.", "Ééé, ok."])
    // An empty me.json falls back to the "You" label; a span only claims the line starting where it does.
    #expect(Transcript.tidied(lines, me: []).map(\.text) == ["Hum, sim.", "Ok."])
    #expect(Transcript.tidied(lines, me: [Transcript.Span(channel: "system", start: 1.5, end: 3.1)]).map(\.text) == ["Sim.", "Ok."])
    // With no "You" line and no me.json nobody can be told apart, so every line stays verbatim.
    let room = Transcript.merged(mic: [], system: system, labels: [:])
    #expect(Transcript.tidied(room, me: nil).map(\.text) == ["Ééé, ok."])
}
