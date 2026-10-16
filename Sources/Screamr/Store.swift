import Foundation

struct Dictation: Codable, Identifiable, Hashable {
    var id = UUID()
    let date: Date
    let text: String
    let app: String?
    let seconds: Double
    var words: Int { text.split(whereSeparator: \.isWhitespace).count }
}

/// A word Scribe should listen for. With a replacement, matches are also rewritten after transcription.
struct DictionaryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var phrase = ""
    var replacement = ""
}

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var trigger = ""
    var expansion = ""
}

struct MeetingInfo: Identifiable, Hashable {
    var id: URL { dir }
    let dir: URL
    let title: String
    var transcript: URL? {
        let url = dir.appendingPathComponent("transcript.md")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Everything the dashboard manages, persisted as JSON under Application Support/Screamr.
final class Store: ObservableObject {
    static let shared = Store()
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Screamr", isDirectory: true)
    static let keyFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/screamr/api_key")

    // ponytail: whole-file JSON rewrites; move to SQLite if history grows past tens of thousands of entries.
    @Published var history: [Dictation] { didSet { save(history, "history.json") } }
    @Published var dictionary: [DictionaryEntry] { didSet { save(dictionary, "dictionary.json") } }
    @Published var snippets: [Snippet] { didSet { save(snippets, "snippets.json") } }
    @Published var people: [Person] { didSet { save(people, "people.json") } }
    @Published var meetings: [MeetingInfo] = []
    @Published var meetingActive = false
    @Published var transcribingMeeting = false

    private let dir: URL

    init(dir: URL = Store.root) {
        self.dir = dir
        history = Self.load(dir, "history.json") ?? []
        dictionary = Self.load(dir, "dictionary.json") ?? []
        snippets = Self.load(dir, "snippets.json") ?? []
        people = Self.load(dir, "people.json") ?? []
        refreshMeetings()
    }

    var keyterms: [String] {
        dictionary.map { $0.replacement.isEmpty ? $0.phrase : $0.replacement }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var replacements: [(from: String, to: String)] {
        dictionary.filter { !$0.replacement.isEmpty }.map { ($0.phrase, $0.replacement) }
    }

    /// Resolves a person by id, following merges.
    func person(_ id: UUID) -> Person? {
        people.first { $0.id == id || $0.mergedIDs.contains(id) }
    }

    func postProcess(_ text: String) -> String {
        TextRules.apply(text, replacements: replacements, snippets: snippets.map { ($0.trigger, $0.expansion) })
    }

    func refreshMeetings() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Meeting.root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        meetings = dirs.filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { MeetingInfo(dir: $0, title: "Meeting \($0.lastPathComponent)") }
    }

    static func apiKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["ELEVEN_LABS_API_KEY"], !env.isEmpty { return env }
        let key = (try? String(contentsOf: keyFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    static func saveAPIKey(_ key: String) throws {
        try FileManager.default.createDirectory(at: keyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: keyFile.path, contents: Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8),
                                       attributes: [.posixPermissions: 0o600])
    }

    private static func load<T: Decodable>(_ dir: URL, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(value).write(to: dir.appendingPathComponent(name), options: .atomic)
    }
}
