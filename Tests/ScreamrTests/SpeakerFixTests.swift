import Foundation
import Testing
@testable import Screamr

private func unit(_ v: [Float]) -> [Float] { VoicePrinter.mean([v]) }

@MainActor
@Test func fixingSpeakersMovesVoicesAndMarksTheUsersLines() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(dir: root)
    let meeting = "2026-10-17 09.00.00"
    let dir = root.appendingPathComponent("Meetings/\(meeting)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let me = Person(number: 1, name: "You", voice: unit([1, 0]), isMe: true)
    let ana = Person(number: 2, name: "Ana", voice: unit([0, 1]), samples: 2, meetings: [meeting], prints: [meeting: unit([1, 0.1])])
    store.people = [me, ana]
    let w = { (text: String, id: String, start: Double) in Transcript.Word(text: text, start: start, end: start + 0.5, type: "word", speaker_id: id) }
    // Scribe heard the user as speaker_0 and wrongly matched that voice to Ana.
    let words = [w("Proponho", "speaker_0", 0), w("isso", "speaker_0", 5), w("Concordo", "speaker_1", 10)]
    try JSONEncoder().encode(words).write(to: dir.appendingPathComponent("mic.words.json"))
    try JSONEncoder().encode(["mic:speaker_0": ana.id, "mic:speaker_1": ana.id]).write(to: dir.appendingPathComponent("speakers.json"))

    try await Meeting.assign(dir: dir, title: "T", speaker: "mic:speaker_0", to: me.id, store: store)
    let fixedAna = store.people[1]
    #expect(fixedAna.prints?[meeting] == nil) // the misattributed sample left Ana's profile
    #expect(fixedAna.samples == 1)
    #expect(store.people[0].prints?[meeting] != nil) // and joined the user's
    #expect(fixedAna.meetings == [meeting]) // Ana still speaks as speaker_1

    // One line of speaker_0 was actually Ana.
    try Meeting.assign(dir: dir, title: "T", line: Transcript.lineKey("mic", 5), to: ana.id, store: store)
    let names = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: dir.appendingPathComponent("names.json")))
    #expect(names["mic:speaker_0"] == "You")
    #expect(names["line:mic:5.00"] == "Ana")
    let spans = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("me.json"))) as? [String: [[String: Any]]])["spans"]
    #expect(spans?.map { $0["start"] as? Double } == [0]) // only the line the user actually said

    // Removing the correction gives the line back to the user.
    try Meeting.assign(dir: dir, title: "T", line: Transcript.lineKey("mic", 5), to: nil, store: store)
    let again = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("me.json"))) as? [String: [[String: Any]]])["spans"]
    #expect(again?.map { $0["start"] as? Double } == [0, 5])
}

@Test func releasingTheOnlyStoredSamplesGivesTheExactAverageBack() {
    var p = Person(number: 1, voice: VoicePrinter.mean([unit([1, 0]), unit([0, 1])]), samples: 2, prints: ["a": unit([1, 0]), "b": unit([0, 1])])
    let out = PeopleMatcher.release(meeting: "b", from: &p)
    #expect(out == unit([0, 1]))
    #expect(p.samples == 1)
    #expect(p.voice == unit([1, 0]))
}
