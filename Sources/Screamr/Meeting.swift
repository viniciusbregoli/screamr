import AVFoundation
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

    /// The folder name. Seconds, so two meetings started in the same minute get separate folders.
    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: date)
    }

    init() throws {
        let stamp = Self.stamp(Date())
        title = "Meeting \(stamp)"
        dir = Self.root.appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try mic.start(writingTo: dir.appendingPathComponent("mic.m4a"))
        // An in-person meeting still works without call audio, so this is not fatal.
        do { try system.start(writingTo: dir.appendingPathComponent("system.m4a")) } catch { systemError = error.localizedDescription }
    }

    /// A recording made elsewhere (a voice recorder) as a new meeting, dated when it was recorded and named
    /// after the file. Its one channel becomes the mic, so it's handled like an in-person meeting recorded here.
    static func importRecording(_ source: URL, into root: URL = root) async throws -> MeetingInfo {
        let values = try? source.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        // Copying a file can reset its creation date, so the earlier of the two is closer to the recording.
        let date = [values?.creationDate, values?.contentModificationDate].compactMap { $0 }.min() ?? Date()
        let stamp = stamp(date)
        let dir = root.appendingPathComponent(stamp, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: dir.path) else {
            throw Scribe.APIError(message: "A meeting from \(stamp) already exists; this recording may already be imported.")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            guard let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A) else {
                throw Scribe.APIError(message: "Can't read \(source.lastPathComponent) as audio.")
            }
            export.outputURL = dir.appendingPathComponent("mic.m4a")
            export.outputFileType = .m4a
            await export.export()
            guard export.status == .completed else {
                throw export.error ?? Scribe.APIError(message: "Converting \(source.lastPathComponent) failed.")
            }
            try MeetingTitle.write(source.deletingPathExtension().lastPathComponent, to: dir)
            // Marks the origin before transcription, which keeps it, so a re-transcription still knows.
            try Scribe.Meta(verbatim: Scribe.meetingVerbatim, languages: [:], source: "import").write(to: dir)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return MeetingInfo(dir: dir, title: "Meeting \(stamp)")
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
        let verbatim = Scribe.meetingVerbatim
        async let mic = Scribe.words(file: dir.appendingPathComponent("mic.m4a"), apiKey: apiKey, keyterms: terms, verbatim: verbatim)
        async let system = includeSystem
            ? Scribe.words(file: dir.appendingPathComponent("system.m4a"), apiKey: apiKey, keyterms: terms, verbatim: false)
            : Scribe.Channel(words: [], language: nil)
        let (micChannel, systemChannel) = try await (mic, system)
        // Raw words are kept so transcripts can be re-rendered with new names without paying Scribe again.
        try saveWords(micChannel.words, dir, "mic")
        try saveWords(systemChannel.words, dir, "system")
        let languages = ["mic": micChannel.language, "system": systemChannel.language].compactMapValues { $0 }
        var meta = Scribe.Meta(verbatim: verbatim, languages: languages, source: Scribe.Meta.source(in: dir) == "import" ? "import" : nil)
        if verbatim && includeSystem { meta.system_mode = "clean" }
        try meta.write(to: dir)
        await identifySpeakers(dir: dir, store: store)
        return try render(dir: dir, title: title, store: store)
    }

    /// The time spans of the user's own lines, so the sync server measures the right person even when
    /// everyone shares one channel (iPhone recordings). Written only once speakers are assigned.
    private static func writeMe(dir: URL, mic: [Transcript.Word], system: [Transcript.Word], labels: [String: String],
                                assigned: [String: UUID], lines: [String: UUID], store: Store) throws {
        let url = dir.appendingPathComponent("me.json")
        guard let me = store.me?.id, !(assigned.isEmpty && lines.isEmpty) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let spans = Transcript.merged(mic: mic, system: system, labels: labels).filter { s in
            let id = lines[s.lineKey] ?? assigned["\(s.channel):\(s.speakerID)"]
            return id.flatMap { store.person($0)?.id } == me
        }
        .map { ["channel": $0.channel, "start": $0.start, "end": $0.end] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: ["spans": spans], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    static func loadIDs(_ dir: URL, _ file: String) -> [String: UUID] {
        (try? JSONDecoder().decode([String: UUID].self, from: Data(contentsOf: dir.appendingPathComponent(file)))) ?? [:]
    }

    private static func saveIDs(_ ids: [String: UUID], _ dir: URL, _ file: String) throws {
        try JSONEncoder().encode(ids).write(to: dir.appendingPathComponent(file), options: .atomic)
    }

    /// "Everywhere in this meeting": this speaker was someone else. Moves the meeting's voice sample too,
    /// so a wrong match stops pulling the old person's voice profile toward someone else.
    @MainActor
    static func assign(dir: URL, title: String, speaker key: String, to id: UUID, store: Store) async throws {
        var assigned = loadIDs(dir, "speakers.json")
        let meeting = dir.lastPathComponent
        let old = assigned[key].flatMap { store.person($0)?.id }
        guard old != id, let target = store.person(id)?.id else { return }
        assigned[key] = target
        try saveIDs(assigned, dir, "speakers.json")

        var print: [Float]?
        if let old, let i = store.people.firstIndex(where: { $0.id == old }) {
            print = PeopleMatcher.release(meeting: meeting, from: &store.people[i])
            let stillHere = assigned.values.contains { store.person($0)?.id == old } || loadIDs(dir, "lines.json").values.contains { store.person($0)?.id == old }
            if !stillHere { store.people[i].meetings.removeAll { $0 == meeting } }
        }
        if print == nil {
            // Older profiles have no per-meeting sample: fingerprint this speaker again from the audio.
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let spans = PeopleMatcher.speakerRanges(loadWords(dir, parts[0]))[parts[1]] {
                print = try? await VoicePrinter.shared.fingerprint(file: dir.appendingPathComponent("\(parts[0]).m4a"), segments: spans)
            }
        }
        if let j = store.people.firstIndex(where: { $0.id == target }) {
            if let print { PeopleMatcher.absorb(print, into: &store.people[j], meeting: meeting) }
            if !store.people[j].meetings.contains(meeting) { store.people[j].meetings.append(meeting) }
        }
        _ = try render(dir: dir, title: title, store: store)
    }

    /// "This line": one line was someone else, typically where Scribe merged two voices into one speaker.
    /// Too short to fingerprint reliably, so voice profiles stay as they are. `nil` removes the correction.
    @MainActor
    static func assign(dir: URL, title: String, line key: String, to id: UUID?, store: Store) throws {
        var lines = loadIDs(dir, "lines.json")
        lines[key] = id.flatMap { store.person($0)?.id }
        try saveIDs(lines, dir, "lines.json")
        if let id, let j = store.people.firstIndex(where: { $0.id == store.person(id)?.id }),
           !store.people[j].meetings.contains(dir.lastPathComponent) {
            store.people[j].meetings.append(dir.lastPathComponent)
        }
        _ = try render(dir: dir, title: title, store: store)
    }

    /// Fingerprints each diarized speaker and matches them to known people, creating new ones as needed.
    /// Best effort: if the voice model can't load (first run offline), the transcript just keeps generic labels.
    @MainActor
    static func identifySpeakers(dir: URL, store: Store) async {
        var assigned: [String: UUID] = [:]
        // A recorder's one channel holds everyone, so a lone voice on it says nothing about who the user is.
        let imported = Scribe.Meta.source(in: dir) == "import"
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
                    PeopleMatcher.absorb(voice, into: &store.people[i], meeting: meeting)
                    if !store.people[i].meetings.contains(meeting) { store.people[i].meetings.append(meeting) }
                    store.people[i].lastSeen = Date()
                    if store.people[i].quote.isEmpty { store.people[i].quote = quote }
                    assigned["\(channel):\(speaker)"] = store.people[i].id
                } else {
                    // A lone voice on the mic is almost always the user, so start them off named.
                    let isUser = !imported && channel == "mic" && ranges.count == 1 && !store.people.contains { $0.name == "You" }
                    let person = Person(number: (store.people.map(\.number).max() ?? 0) + 1, name: isUser ? "You" : "",
                                        voice: voice, meetings: [meeting], quote: quote,
                                        isMe: isUser && store.me == nil ? true : nil, prints: [meeting: voice])
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
        let assigned = loadIDs(dir, "speakers.json")
        let lines = loadIDs(dir, "lines.json")
        var names = assigned.compactMapValues { store.person($0)?.displayName }
        for (line, id) in lines { names["line:\(line)"] = store.person(id)?.displayName }
        let rules = store.replacements
        let mic = loadWords(dir, "mic"), system = loadWords(dir, "system")
        // Other devices have no people database, so they read the final labels, line corrections included, from here.
        let labels = Transcript.labels(mic: mic, system: system, names: names).merging(names.filter { $0.key.hasPrefix("line:") }) { a, _ in a }
        try JSONEncoder().encode(labels).write(to: dir.appendingPathComponent("names.json"), options: .atomic)
        try writeMe(dir: dir, mic: mic, system: system, labels: labels, assigned: assigned, lines: lines, store: store)
        let md = Transcript.markdown(title: MeetingTitle.read(dir) ?? title, mic: mic, system: system, names: names,
                                     me: Transcript.mySpans(in: dir)) {
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
