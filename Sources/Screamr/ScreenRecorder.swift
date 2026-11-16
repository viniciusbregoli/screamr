import AppKit
import CoreMedia
import ScreenCaptureKit

/// What a meeting records besides audio.
enum MeetingVideo: Equatable {
    case none
    case screen
    case app(bundleID: String, name: String)

    static let defaultsKey = "meetingVideo"

    /// The choice that carries over to the next meeting.
    static var current: MeetingVideo {
        get { MeetingVideo(UserDefaults.standard.string(forKey: defaultsKey) ?? "") }
        set { UserDefaults.standard.set(newValue.stored, forKey: defaultsKey) }
    }

    var stored: String {
        switch self {
        case .none: "none"
        case .screen: "screen"
        case .app(let id, let name): "app:\(id):\(name)"
        }
    }

    init(_ stored: String) {
        // The name may hold colons, so only the first two split.
        let parts = stored.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "screen" where parts.count == 1: self = .screen
        case "app" where parts.count == 3 && !parts[1].isEmpty: self = .app(bundleID: parts[1], name: parts[2])
        default: self = .none
        }
    }

    /// Open GUI apps other than Screamr, by name, with a 16pt icon for menus.
    static func running() -> [(video: MeetingVideo, icon: NSImage?)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
            .map { app in
                let icon = (app.icon?.copy() as? NSImage)
                icon?.size = NSSize(width: 16, height: 16)
                let id = app.bundleIdentifier!
                return (.app(bundleID: id, name: app.localizedName ?? id), icon)
            }
    }

    /// Display pixels, capped at 1920 wide, both even because HEVC needs it.
    static func captureSize(points: CGSize, scale: CGFloat) -> (Int, Int) {
        var w = points.width * scale, h = points.height * scale
        if w > 1920 {
            h *= 1920 / w
            w = 1920
        }
        return (max(2, Int(w) & ~1), max(2, Int(h) & ~1))
    }

    var label: String {
        switch self {
        case .none: "Audio only"
        case .screen: "Entire screen"
        case .app(_, let name): name
        }
    }
}

/// Records the screen or one app's windows to an mp4 with ScreenCaptureKit's recording output (macOS 15+).
/// Needs the Screen Recording permission, which macOS prompts for on first use.
@available(macOS 15, *)
final class ScreenRecorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, @unchecked Sendable {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private var stream: SCStream?
    private var finished: CheckedContinuation<Void, Never>?
    private var didFinish = false
    private var cancelled = false
    private var reported = false
    /// Failures after start (the recorded app quit, the disk filled), so the meeting can say the video stopped.
    var onFailure: ((String) -> Void)?
    private let lock = NSLock()

    /// Called on stop, before waiting for a start that may still be loading, so capture never begins after the meeting ended.
    func cancel() { lock.withLock { cancelled = true } }

    func start(_ video: MeetingVideo, writingTo url: URL) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Failure(errorDescription: "Screen not recorded. Grant Screen Recording to Screamr in System Settings > Privacy & Security.")
        }
        let mainID = CGMainDisplayID()
        guard let main = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw Failure(errorDescription: "No display to record")
        }

        let display: SCDisplay
        let filter: SCContentFilter
        switch video {
        case .none:
            throw Failure(errorDescription: "No video source chosen")
        case .screen:
            let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            display = main
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        case .app(let bundleID, let name):
            guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
                throw Failure(errorDescription: "\(name) isn't running")
            }
            display = Self.display(of: app, in: content) ?? main
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        }

        let config = SCStreamConfiguration()
        let scale = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID }?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        let (width, height) = MeetingVideo.captureSize(points: display.frame.size, scale: scale)
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.showsCursor = true
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = true
        // The same mic the meeting's audio uses; a Core Audio UID is also the capture device's unique ID.
        if let uid = UserDefaults.standard.string(forKey: Recorder.inputKey), !uid.isEmpty { config.microphoneCaptureDeviceID = uid }

        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mp4
        recording.videoCodecType = .hevc

        guard !lock.withLock({ cancelled }) else { return }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addRecordingOutput(SCRecordingOutput(configuration: recording, delegate: self))
        self.stream = stream
        try await stream.startCapture()
    }

    /// Finalizes the file. Safe after a failed or skipped start.
    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if didFinish {
                lock.unlock()
                return continuation.resume()
            }
            finished = continuation
            lock.unlock()
            // Stop must not hang the meeting if the delegate never reports back.
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in self?.finish() }
        }
    }

    private func finish() {
        lock.lock()
        didFinish = true
        let continuation = finished
        finished = nil
        lock.unlock()
        continuation?.resume()
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { finish() }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        report(error)
        finish()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { report(error) }

    /// Once: a stopped stream usually also fails its recording output.
    private func report(_ error: Error) {
        guard lock.withLock({ () -> Bool in defer { reported = true }; return !reported }) else { return }
        onFailure?("Screen recording stopped: \(error.localizedDescription)")
    }

    /// The display holding the most area of the app's windows.
    private static func display(of app: SCRunningApplication, in content: SCShareableContent) -> SCDisplay? {
        let windows = content.windows.filter { $0.owningApplication?.processID == app.processID && $0.isOnScreen }
        return content.displays.max { a, b in
            windows.reduce(0.0) { $0 + area($1.frame.intersection(a.frame)) } < windows.reduce(0.0) { $0 + area($1.frame.intersection(b.frame)) }
        }.flatMap { best in windows.contains { !$0.frame.intersection(best.frame).isNull } ? best : nil }
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
}
