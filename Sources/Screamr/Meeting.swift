import Foundation

/// One meeting: mic and system audio recorded to separate files, transcribed per channel on stop.
/// Keeping the channels apart (as Wispr does) means the mic is always "You" and only the call is diarized.
final class Meeting {
    static let root = Store.root.appendingPathComponent("Meetings", isDirectory: true)

    let dir: URL
    let title: String
    private let mic = Recorder()
    private let system = SystemAudioTap()
    private(set) var systemError: String?

    init() throws {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let stamp = f.string(from: Date())
        title = "Meeting \(stamp)"
        dir = Self.root.appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try mic.start(writingTo: dir.appendingPathComponent("mic.m4a"))
        // An in-person meeting still works without call audio, so this is not fatal.
        do { try system.start(writingTo: dir.appendingPathComponent("system.m4a")) } catch { systemError = error.localizedDescription }
    }

    /// Stops recording and returns whether the system channel has anything worth transcribing.
    func stop() -> Bool {
        _ = mic.stop()
        system.stop()
        return systemError == nil && system.peak > 0.001
    }

    /// Static so the dashboard can re-run it on a past recording whose transcription failed.
    /// MainActor because it updates the store's people as it goes.
    @MainActor
    static func transcribe(dir: URL, title: String, includeSystem: Bool, apiKey: String, store: Store) async throws -> URL {
        let terms = store.keyterms
        async let micWords = Scribe.words(file: dir.appendingPathComponent("mic.m4a"), apiKey: apiKey, keyterms: terms)
        async let systemWords = includeSystem ? Scribe.words(file: dir.appendingPathComponent("system.m4a"), apiKey: apiKey, keyterms: terms) : []
        // Raw words are kept so transcripts can be re-rendered with new names without paying Scribe again.
        try saveWords(try await micWords, dir, "mic")
        try saveWords(try await systemWords, dir, "system")
        await identifySpeakers(dir: dir, store: store)
        return try render(dir: dir, title: title, store: store)
    }

    /// Fingerprints each diarized speaker and matches them to known people, creating new ones as needed.
    /// Best effort: if the voice model can't load (first run offline), the transcript just keeps generic labels.
    @MainActor
    static func identifySpeakers(dir: URL, store: Store) async {
        var assigned: [String: UUID] = [:]
        for channel in ["mic", "system"] {
            let words = loadWords(dir, channel)
            let ranges = PeopleMatcher.speakerRanges(words)
            let segments = Transcript.segments(words) { id, _, _ in id }
            for (speaker, spans) in ranges.sorted(by: { $0.key < $1.key }) {
                let audio = dir.appendingPathComponent("\(channel).m4a")
                let voice: [Float]?
                do { voice = try await VoicePrinter.shared.fingerprint(file: audio, segments: spans) } catch {
                    NSLog("screamr: voice fingerprint failed, %@", error.localizedDescription)
                    return
                }
                guard let voice else { continue } // too little speech to recognize reliably
                let quote = excerpt(segments.filter { $0.speakerID == speaker }.max { $0.text.count < $1.text.count }?.text ?? "")
                let meeting = dir.lastPathComponent
                if let i = PeopleMatcher.match(voice, in: store.people) {
                    PeopleMatcher.absorb(voice, into: &store.people[i])
                    if !store.people[i].meetings.contains(meeting) { store.people[i].meetings.append(meeting) }
                    store.people[i].lastSeen = Date()
                    if store.people[i].quote.isEmpty { store.people[i].quote = quote }
                    assigned["\(channel):\(speaker)"] = store.people[i].id
                } else {
                    // A lone voice on the mic is almost always the user, so start them off named.
                    let isUser = channel == "mic" && ranges.count == 1 && !store.people.contains { $0.name == "You" }
                    let person = Person(number: (store.people.map(\.number).max() ?? 0) + 1, name: isUser ? "You" : "",
                                        voice: voice, meetings: [meeting], quote: quote)
                    store.people.append(person)
                    assigned["\(channel):\(speaker)"] = person.id
                }
            }
        }
        try? JSONEncoder().encode(assigned).write(to: dir.appendingPathComponent("speakers.json"))
    }

    /// Writes transcript.md from saved words, labeling recognized people by their current names.
    @MainActor
    @discardableResult
    static func render(dir: URL, title: String, store: Store) throws -> URL {
        let assigned = (try? JSONDecoder().decode([String: UUID].self, from: Data(contentsOf: dir.appendingPathComponent("speakers.json")))) ?? [:]
        let names = assigned.compactMapValues { store.person($0)?.displayName }
        let rules = store.replacements
        let md = Transcript.markdown(title: title, mic: loadWords(dir, "mic"), system: loadWords(dir, "system"), names: names) {
            TextRules.apply($0, replacements: rules)
        }
        let out = dir.appendingPathComponent("transcript.md")
        try md.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// Trims to about 160 characters on a word boundary, so quotes never end mid-word.
    static func excerpt(_ text: String, limit: Int = 160) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        return String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]) + "\u{2026}"
    }

    private static func saveWords(_ words: [Transcript.Word], _ dir: URL, _ channel: String) throws {
        try JSONEncoder().encode(words).write(to: dir.appendingPathComponent("\(channel).words.json"))
    }

    static func loadWords(_ dir: URL, _ channel: String) -> [Transcript.Word] {
        (try? JSONDecoder().decode([Transcript.Word].self, from: Data(contentsOf: dir.appendingPathComponent("\(channel).words.json")))) ?? []
    }
}
