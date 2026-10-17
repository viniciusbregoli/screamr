import AVFoundation
import Security
import UIKit

/// One recording, stored with the same files as the Mac app (mic.m4a, mic.words.json, transcript.md).
struct MeetingFolder: Identifiable, Hashable {
    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    /// Older Mac meetings have no seconds in their folder name.
    static let minuteStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()

    let dir: URL
    var id: URL { dir }
    var date: Date { Self.stamp.date(from: dir.lastPathComponent) ?? Self.minuteStamp.date(from: dir.lastPathComponent) ?? .distantPast }
    var title: String { date.formatted(date: .abbreviated, time: .shortened) }
    var audio: URL { dir.appendingPathComponent("mic.m4a") }
    var wordsFile: URL { dir.appendingPathComponent("mic.words.json") }
    var transcript: URL { dir.appendingPathComponent("transcript.md") }
    var isTranscribed: Bool { FileManager.default.fileExists(atPath: wordsFile.path) }
    /// Meetings synced from the Mac arrive without audio.
    var hasAudio: Bool { FileManager.default.fileExists(atPath: audio.path) }

    /// Labels come from names.json once the Mac has recognized the speakers. Before that, in-person
    /// meetings have no "You" channel, so every voice is a numbered speaker.
    var segments: [Transcript.Segment] {
        func words(_ channel: String) -> [Transcript.Word] {
            (try? JSONDecoder().decode([Transcript.Word].self, from: Data(contentsOf: dir.appendingPathComponent("\(channel).words.json")))) ?? []
        }
        let mic = words("mic"), system = words("system")
        let names = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: dir.appendingPathComponent("names.json"))))
        return Transcript.merged(mic: mic, system: system, labels: names ?? Transcript.labels(mic: mic, system: system, micName: Transcript.systemName))
    }
}

/// Meetings under Documents/Meetings, which the Files app can browse.
@Observable final class Library {
    static let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Meetings", isDirectory: true)

    private(set) var meetings: [MeetingFolder] = []
    private(set) var transcribing: Set<URL> = []
    var errors: [URL: String] = [:]
    private(set) var syncing = false
    private(set) var syncStatus = ""
    // Audio stays on the device that recorded it; the iPhone only needs transcripts and labels.
    private let sync = SyncEngine(root: root, stateFile: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("sync-state.json"), wants: { !$0.hasSuffix(".m4a") })

    static var syncConfig: SyncEngine.Config? {
        guard let raw = UserDefaults.standard.string(forKey: "syncURL"), let url = URL(string: raw), let token = Keychain.syncToken else { return nil }
        return SyncEngine.Config(url: url, token: token)
    }

    init() { refresh() }

    func refresh() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        meetings = dirs.filter(\.hasDirectoryPath)
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map(MeetingFolder.init)
    }

    func newFolder() throws -> MeetingFolder {
        let dir = Self.root.appendingPathComponent(MeetingFolder.stamp.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return MeetingFolder(dir: dir)
    }

    func delete(_ meeting: MeetingFolder) {
        try? FileManager.default.removeItem(at: meeting.dir)
        refresh()
        Task {
            await sync.markDeleted(meeting.dir.lastPathComponent)
            await syncNow()
        }
    }

    /// Skips meetings still recording or transcribing. Without a configured server this does nothing.
    @MainActor
    func syncNow(skip: Set<String> = []) async {
        guard !syncing, let config = Self.syncConfig else { return }
        syncing = true
        defer { syncing = false }
        do {
            _ = try await sync.run(config, skip: skip.union(transcribing.map(\.lastPathComponent)))
            syncStatus = "Synced at \(Date().formatted(date: .omitted, time: .shortened))"
        } catch {
            syncStatus = "Sync failed: \(error.localizedDescription)"
        }
        refresh()
    }

    @MainActor
    func transcribe(_ meeting: MeetingFolder) async {
        guard !transcribing.contains(meeting.dir) else { return }
        guard let key = Keychain.apiKey else {
            errors[meeting.dir] = "Add your ElevenLabs API key in Settings."
            return
        }
        transcribing.insert(meeting.dir)
        errors[meeting.dir] = nil
        // ponytail: a foreground upload, so auto-lock would kill a long one; keep the screen on meanwhile.
        // A background URLSession upload lifts this if transcribing in the pocket matters.
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            transcribing.remove(meeting.dir)
            UIApplication.shared.isIdleTimerDisabled = !transcribing.isEmpty
        }
        do {
            let words = try await Scribe.words(file: meeting.audio, apiKey: key)
            try JSONEncoder().encode(words).write(to: meeting.wordsFile)
            // Passed as the call channel so the Markdown labels match the in-app "Speaker N".
            let md = Transcript.markdown(title: "Meeting \(meeting.title)", mic: [], system: words)
            try md.write(to: meeting.transcript, atomically: true, encoding: .utf8)
        } catch {
            errors[meeting.dir] = error.localizedDescription
            return
        }
        transcribing.remove(meeting.dir)
        await syncNow()
    }
}

@Observable final class MeetingRecorder {
    private(set) var folder: MeetingFolder?
    private var recorder: AVAudioRecorder?
    private var interruption: NSObjectProtocol?

    var elapsed: TimeInterval { recorder?.currentTime ?? 0 }

    /// Average input level, 0 to 1.
    var level: Float {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        return max(0, (recorder.averagePower(forChannel: 0) + 50) / 50)
    }

    func start(in folder: MeetingFolder) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        // ponytail: m4a is only finalized on stop, so if iOS kills the app mid-meeting the file is lost.
        // Rotating chunks would cap the loss if that ever happens in practice.
        let r = try AVAudioRecorder(url: folder.audio, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ])
        r.isMeteringEnabled = true
        guard r.record() else { throw Scribe.APIError(message: "Could not start recording") }
        recorder = r
        self.folder = folder
        // A phone call pauses the recorder; pick up in the same file when it ends.
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            self?.recorder?.record()
        }
    }

    func stop() -> MeetingFolder? {
        defer { folder = nil }
        recorder?.stop()
        recorder = nil
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return folder
    }
}

/// Secrets, readable after first unlock so a locked phone can still transcribe and sync.
enum Keychain {
    static var apiKey: String? {
        get { read("dev.screamr.elevenlabs") }
        set { write("dev.screamr.elevenlabs", newValue) }
    }

    static var syncToken: String? {
        get { read("dev.screamr.sync") }
        set { write("dev.screamr.sync", newValue) }
    }

    private static func item(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    private static func read(_ service: String) -> String? {
        var query = item(service)
        query[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func write(_ service: String, _ value: String?) {
        SecItemDelete(item(service) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var query = item(service)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }
}
