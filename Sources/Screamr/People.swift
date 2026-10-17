import Foundation

/// Someone screamr has heard in meetings, recognized by voice fingerprint across recordings.
struct Person: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Stable "Unknown N" label until the user names them.
    var number: Int
    var name = ""
    /// Running mean of every fingerprint matched to this person (L2-normalized).
    var voice: [Float]
    var samples = 1
    /// Meeting folder names, so the dashboard can say how often someone shows up.
    var meetings: [String] = []
    var lastSeen = Date()
    var quote = ""
    /// People merged into this one; their old meeting assignments still resolve here.
    var mergedIDs: [UUID] = []
    /// The user. Optional, like `prints`, so people saved before these existed still load.
    var isMe: Bool?
    /// The fingerprint each meeting contributed, so a correction can move it to the right person.
    var prints: [String: [Float]]?

    var displayName: String { name.isEmpty ? "Unknown \(number)" : name }
}

enum PeopleMatcher {
    // ponytail: one global cutoff tuned on synthetic voices (same voice 0.05, similar voices 0.40+);
    // calibrate against real meetings, or keep a per-person margin if false merges show up.
    static let threshold: Float = 0.35

    /// The closest person within the threshold, if any.
    static func match(_ voice: [Float], in people: [Person]) -> Int? {
        let scored = people.indices.map { ($0, VoicePrinter.distance(voice, people[$0].voice)) }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 < threshold else { return nil }
        return best.0
    }

    static func absorb(_ voice: [Float], into person: inout Person, meeting: String? = nil) {
        // Someone added by hand starts with no voice, so their first sample is their whole profile.
        person.voice = person.voice.isEmpty ? voice : VoicePrinter.mean([person.voice.map { $0 * Float(person.samples) }, voice])
        person.samples = person.voice == voice ? max(person.samples, 1) : person.samples + 1
        if let meeting { person.prints = (person.prints ?? [:]).merging([meeting: voice]) { _, new in new } }
    }

    /// Takes a meeting's fingerprint back out of a person, e.g. when a correction says that voice was
    /// someone else. Returns it so it can be added to the right person.
    static func release(meeting: String, from person: inout Person) -> [Float]? {
        guard let print = person.prints?[meeting] else { return nil }
        let before = person.samples
        person.prints?[meeting] = nil
        person.samples = max(1, before - 1)
        if let prints = person.prints, !prints.isEmpty, prints.count == person.samples {
            person.voice = VoicePrinter.mean(Array(prints.values))
        } else if before > 1 {
            // ponytail: the stored voice is a normalized mean, so subtracting from it is approximate;
            // exact once every sample a person has comes from a meeting with a stored fingerprint.
            person.voice = VoicePrinter.mean([person.voice.map { $0 * Float(before) }, print.map { -$0 }])
        }
        return print
    }

    /// Folds `source` into `target`, keeping its history and voice weight.
    static func merge(_ source: Person, into target: inout Person) {
        target.voice = VoicePrinter.mean([target.voice.map { $0 * Float(target.samples) }, source.voice.map { $0 * Float(source.samples) }])
        target.samples += source.samples
        target.meetings = Array(Set(target.meetings + source.meetings)).sorted()
        target.lastSeen = max(target.lastSeen, source.lastSeen)
        if target.quote.isEmpty { target.quote = source.quote }
        if target.name.isEmpty { target.name = source.name }
        target.mergedIDs += [source.id] + source.mergedIDs
        if let prints = source.prints { target.prints = (target.prints ?? [:]).merging(prints) { mine, _ in mine } }
        if source.isMe == true { target.isMe = true }
    }

    /// Time ranges per diarized speaker, merging words separated by short pauses.
    static func speakerRanges(_ words: [Transcript.Word]) -> [String: [(start: Double, end: Double)]] {
        var out: [String: [(start: Double, end: Double)]] = [:]
        for w in words where w.type == "word" {
            guard let id = w.speaker_id, let start = w.start, let end = w.end else { continue }
            if let last = out[id]?.last, start - last.end < Transcript.pauseBreak {
                out[id]![out[id]!.count - 1].end = end
            } else {
                out[id, default: []].append((start, end))
            }
        }
        return out
    }
}
