import Foundation

/// Merges diarized Scribe channels (mic = the user, system = the call) into one readable transcript.
enum Transcript {
    struct Word: Decodable, Equatable {
        let text: String
        let start: Double?
        let end: Double?
        let type: String
        let speaker_id: String?
    }

    struct Segment: Equatable {
        let speaker: String
        let start: Double
        var end: Double
        var text: String
    }

    /// A pause this long starts a new segment, so replies from the other channel interleave in order.
    static let pauseBreak = 1.0

    /// `name` maps (speaker index within the channel, distinct speakers in the channel) to a label.
    static func segments(_ words: [Word], name: (Int, Int) -> String) -> [Segment] {
        let spoken = words.filter { $0.type == "word" }
        let ids = spoken.compactMap(\.speaker_id).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        var out: [Segment] = []
        for w in spoken {
            let start = w.start ?? out.last?.end ?? 0
            let speaker = name(ids.firstIndex(of: w.speaker_id ?? "") ?? 0, max(ids.count, 1))
            if var last = out.last, last.speaker == speaker, start - last.end < pauseBreak {
                last.text += " " + w.text
                last.end = w.end ?? start
                out[out.count - 1] = last
            } else {
                out.append(Segment(speaker: speaker, start: start, end: w.end ?? start, text: w.text))
            }
        }
        return out
    }

    static func micName(_ i: Int, _ count: Int) -> String { count == 1 ? "You" : "Room \(i + 1)" }
    static func systemName(_ i: Int, _ count: Int) -> String { "Speaker \(i + 1)" }

    static func markdown(title: String, mic: [Word], system: [Word]) -> String {
        let all = (segments(mic, name: micName) + segments(system, name: systemName)).sorted { $0.start < $1.start }
        var md = "# \(title)\n\n"
        if all.isEmpty { md += "_No speech detected._\n" }
        for s in all {
            let t = Int(s.start)
            md += String(format: "**[%02d:%02d:%02d] %@:** %@\n\n", t / 3600, t / 60 % 60, t % 60, s.speaker, s.text)
        }
        return md
    }
}
