import Foundation

/// Merges diarized Scribe channels (mic = the user, system = the call) into one readable transcript.
enum Transcript {
    struct Word: Codable, Equatable {
        let text: String
        let start: Double?
        let end: Double?
        let type: String
        let speaker_id: String?
    }

    struct Segment: Equatable {
        let speakerID: String
        let speaker: String
        let start: Double
        var end: Double
        var text: String
    }

    /// A pause this long starts a new segment, so replies from the other channel interleave in order.
    static let pauseBreak = 1.0

    /// `name` maps (Scribe speaker id, its index within the channel, distinct speakers in the channel) to a label.
    static func segments(_ words: [Word], name: (String, Int, Int) -> String) -> [Segment] {
        let spoken = words.filter { $0.type == "word" }
        let ids = speakerIDs(words)
        var out: [Segment] = []
        for w in spoken {
            let start = w.start ?? out.last?.end ?? 0
            let id = w.speaker_id ?? ""
            let speaker = name(id, ids.firstIndex(of: id) ?? 0, max(ids.count, 1))
            if var last = out.last, last.speaker == speaker, start - last.end < pauseBreak {
                last.text += " " + w.text
                last.end = w.end ?? start
                out[out.count - 1] = last
            } else {
                out.append(Segment(speakerID: id, speaker: speaker, start: start, end: w.end ?? start, text: w.text))
            }
        }
        return out
    }

    static func micName(_ id: String, _ i: Int, _ count: Int) -> String { count == 1 ? "You" : "Room \(i + 1)" }
    static func systemName(_ id: String, _ i: Int, _ count: Int) -> String { "Speaker \(i + 1)" }

    static func speakerIDs(_ words: [Word]) -> [String] {
        words.filter { $0.type == "word" }.compactMap(\.speaker_id).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    /// Every speaker's label, keyed "mic:speaker_0" / "system:speaker_1": `names` (recognized people) first,
    /// then the channel defaults. Saved as names.json so other devices show the same labels.
    static func labels(mic: [Word], system: [Word], names: [String: String] = [:],
                       micName: (String, Int, Int) -> String = micName) -> [String: String] {
        var out: [String: String] = [:]
        func add(_ channel: String, _ words: [Word], _ fallback: (String, Int, Int) -> String) {
            let ids = speakerIDs(words)
            for (i, id) in ids.enumerated() { out["\(channel):\(id)"] = names["\(channel):\(id)"] ?? fallback(id, i, ids.count) }
        }
        add("mic", mic, micName)
        add("system", system, systemName)
        return out
    }

    /// Both channels as one conversation, in time order.
    static func merged(mic: [Word], system: [Word], labels: [String: String]) -> [Segment] {
        let micSegments = segments(mic) { id, i, n in labels["mic:\(id)"] ?? micName(id, i, n) }
        let systemSegments = segments(system) { id, i, n in labels["system:\(id)"] ?? systemName(id, i, n) }
        return (micSegments + systemSegments).sorted { $0.start < $1.start }
    }

    /// `names` overrides labels for recognized people, keyed "mic:speaker_0" / "system:speaker_1".
    static func markdown(title: String, mic: [Word], system: [Word], names: [String: String] = [:], fix: (String) -> String = { $0 }) -> String {
        let all = merged(mic: mic, system: system, labels: labels(mic: mic, system: system, names: names))
        var md = "# \(title)\n\n"
        if all.isEmpty { md += "_No speech detected._\n" }
        for s in all {
            let t = Int(s.start)
            md += String(format: "**[%02d:%02d:%02d] %@:** %@\n\n", t / 3600, t / 60 % 60, t % 60, s.speaker, fix(s.text))
        }
        return md
    }
}
