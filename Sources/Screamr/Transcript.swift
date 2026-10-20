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
        var speaker: String
        let start: Double
        var end: Double
        var text: String
        /// "mic" or "system", set by `merged`.
        var channel = ""

        /// Identifies this line for a per-line correction, e.g. "mic:12.34".
        var lineKey: String { Transcript.lineKey(channel, start) }
    }

    static func lineKey(_ channel: String, _ start: Double) -> String { "\(channel):\(String(format: "%.2f", start))" }

    /// A pause this long starts a new segment, so replies from the other channel interleave in order.
    static let pauseBreak = 1.0
    /// Past this, even an unfinished sentence ends the line: the thought was dropped, not paused.
    static let midSentencePause = 10.0

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

    /// Both channels as one conversation, in time order. A "line:<channel>:<start>" label overrides
    /// who said that one line (a correction made by hand when Scribe merged two voices).
    static func merged(mic: [Word], system: [Word], labels: [String: String]) -> [Segment] {
        func tag(_ segments: [Segment], _ channel: String) -> [Segment] {
            segments.map { s in
                var s = s
                s.channel = channel
                if let who = labels["line:\(s.lineKey)"] { s.speaker = who }
                return s
            }
        }
        let micSegments = tag(segments(mic) { id, i, n in labels["mic:\(id)"] ?? micName(id, i, n) }, "mic")
        let systemSegments = tag(segments(system) { id, i, n in labels["system:\(id)"] ?? systemName(id, i, n) }, "system")
        return joinUnfinished((micSegments + systemSegments).sorted { $0.start < $1.start })
    }

    /// Joins a line a pause cut mid-sentence ("vai ser o-- [1.2 s] qual o trampo") back onto the speaker's
    /// previous line, as long as nobody else spoke in the gap. Same rule as joinUnfinished in server/metrics.mjs.
    static func joinUnfinished(_ lines: [Segment]) -> [Segment] {
        // The id too: the speaker menu reassigns "channel:speakerID", which must cover the whole line.
        let sameVoice = { (a: Segment, b: Segment) in a.channel == b.channel && a.speakerID == b.speakerID && a.speaker == b.speaker }
        var out: [Segment] = []
        for s in lines {
            if var last = out.last, sameVoice(last, s), !endsSentence(last.text), s.start - last.end < midSentencePause,
               // Any line of someone else's that overlaps the gap, not only one that starts inside it.
               !lines.contains(where: { !sameVoice($0, s) && $0.start < s.start && $0.end > last.end }) {
                last.text += " " + s.text
                last.end = s.end
                out[out.count - 1] = last
            } else {
                out.append(s)
            }
        }
        return out
    }

    /// Scribe closes a sentence with one of these; a line that stops before one was cut by a pause for thought.
    static func endsSentence(_ text: String) -> Bool {
        text.range(of: #"[.!?…]["'”»)\]]*$"#, options: .regularExpression) != nil
    }

    /// `names` overrides labels for recognized people, keyed "mic:speaker_0" / "system:speaker_1".
    static func markdown(title: String, mic: [Word], system: [Word], names: [String: String] = [:], fix: (String) -> String = { $0 }) -> String {
        let lines = names.filter { $0.key.hasPrefix("line:") }
        let all = merged(mic: mic, system: system, labels: labels(mic: mic, system: system, names: names).merging(lines) { a, _ in a })
        var md = "# \(title)\n\n"
        if all.isEmpty { md += "_No speech detected._\n" }
        for s in all {
            let t = Int(s.start)
            md += String(format: "**[%02d:%02d:%02d] %@:** %@\n\n", t / 3600, t / 60 % 60, t % 60, s.speaker, fix(s.text))
        }
        return md
    }
}

/// A meeting's own name, kept in title.txt so it syncs between devices like any other meeting file.
enum MeetingTitle {
    static let file = "title.txt"
    static let maxLength = 120

    /// One line, trimmed, at most 120 characters. Empty means the meeting has no title.
    static func clean(_ raw: String) -> String {
        String(raw.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces).prefix(maxLength))
            .trimmingCharacters(in: .whitespaces)
    }

    static func read(_ dir: URL) -> String? {
        let title = clean((try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)) ?? "")
        return title.isEmpty ? nil : title
    }

    /// Clearing writes an empty file instead of deleting it: sync never propagates a removed file,
    /// so another device would bring the old title back.
    static func write(_ title: String, to dir: URL) throws {
        try clean(title).write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    /// Swaps an existing transcript's "# heading" line. Only the heading: on the iPhone the transcript may
    /// come from the Mac, with names and both channels this device can't render again.
    static func retitle(transcript url: URL, heading: String) throws {
        guard let md = try? String(contentsOf: url, encoding: .utf8), md.hasPrefix("# ") else { return }
        let rest = md.firstIndex(of: "\n").map { md[$0...] } ?? ""
        try ("# \(heading)" + rest).write(to: url, atomically: true, encoding: .utf8)
    }
}
