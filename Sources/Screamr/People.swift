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

    static func absorb(_ voice: [Float], into person: inout Person) {
        person.voice = VoicePrinter.mean([person.voice.map { $0 * Float(person.samples) }, voice])
        person.samples += 1
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
