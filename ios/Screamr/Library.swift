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

    let dir: URL
    var id: URL { dir }
    var date: Date { Self.stamp.date(from: dir.lastPathComponent) ?? .distantPast }
    var title: String { date.formatted(date: .abbreviated, time: .shortened) }
    var audio: URL { dir.appendingPathComponent("mic.m4a") }
    var wordsFile: URL { dir.appendingPathComponent("mic.words.json") }
    var transcript: URL { dir.appendingPathComponent("transcript.md") }
    var isTranscribed: Bool { FileManager.default.fileExists(atPath: wordsFile.path) }

    /// In-person meetings have no "You" channel, so every voice is a numbered speaker.
    var segments: [Transcript.Segment] {
        let words = (try? JSONDecoder().decode([Transcript.Word].self, from: Data(contentsOf: wordsFile))) ?? []
        return Transcript.segments(words, name: Transcript.systemName)
    }
}

/// Meetings under Documents/Meetings, which the Files app can browse.
@Observable final class Library {
    static let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Meetings", isDirectory: true)

    private(set) var meetings: [MeetingFolder] = []
    private(set) var transcribing: Set<URL> = []
    var errors: [URL: String] = [:]

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
        }
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

/// The ElevenLabs key, readable after first unlock so a locked phone can still transcribe.
enum Keychain {
    private static let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.screamr.elevenlabs",
    ]

    static var apiKey: String? {
        get {
            var query = item
            query[kSecReturnData as String] = true
            var out: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            SecItemDelete(item as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var query = item
            query[kSecValueData as String] = Data(newValue.utf8)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(query as CFDictionary, nil)
        }
    }
}
