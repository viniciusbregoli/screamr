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
    static func transcribe(dir: URL, title: String, includeSystem: Bool, apiKey: String, store: Store) async throws -> URL {
        let terms = store.keyterms
        async let micWords = Scribe.words(file: dir.appendingPathComponent("mic.m4a"), apiKey: apiKey, keyterms: terms)
        async let systemWords = includeSystem ? Scribe.words(file: dir.appendingPathComponent("system.m4a"), apiKey: apiKey, keyterms: terms) : []
        let rules = store.replacements
        let md = Transcript.markdown(title: title, mic: try await micWords, system: try await systemWords) {
            TextRules.apply($0, replacements: rules)
        }
        let out = dir.appendingPathComponent("transcript.md")
        try md.write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}
