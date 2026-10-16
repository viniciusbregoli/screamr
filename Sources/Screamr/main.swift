import AppKit
import ApplicationServices

final class App: NSObject, NSApplicationDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let fn = FnKey()
    private let recorder = Recorder()
    private var ptt = PushToTalk()
    private var recording = false
    private var stateItem = NSMenuItem(title: "Hold Fn to dictate", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ note: Notification) {
        let menu = NSMenu()
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Screamr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        status.menu = menu
        setIcon("mic")

        guard apiKey() != nil else {
            return fail("No API key: set ELEVEN_LABS_API_KEY or write it to ~/.config/screamr/api_key")
        }
        // Event tap and synthetic Cmd+V both need Accessibility; this shows the system prompt once.
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        fn.onEvent = { [weak self] event in self?.handle(event) ?? false }
        if !trusted || !fn.start() {
            fail("Grant Accessibility in System Settings, then relaunch")
        }
    }

    private func handle(_ event: FnKey.Event) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        switch event {
        case .fnDown: perform(ptt.fnDown(at: now))
        case .fnUp:
            perform(ptt.fnUp(at: now))
            DispatchQueue.main.asyncAfter(deadline: .now() + PushToTalk.tapWindow) { [weak self] in
                guard let self else { return }
                self.perform(self.ptt.tick(at: ProcessInfo.processInfo.systemUptime))
            }
        case .space:
            guard ptt.space() else { return false }
            perform(.lock)
            return true
        case .escape:
            guard ptt.escape() else { return false }
            perform(.cancel)
            return true
        }
        return false
    }

    private func perform(_ action: PushToTalk.Action) {
        switch action {
        case .none: break
        case .start: begin()
        case .lock:
            NSSound(named: "Morse")?.play()
            stateItem.title = "Hands-free: press Fn to finish, Esc to cancel"
        case .finish: finish()
        case .cancel:
            guard recording else { return }
            recording = false
            _ = recorder.stop()
            NSSound(named: "Basso")?.play()
            idle()
        }
    }

    private func begin() {
        guard !recording else { return }
        do {
            try recorder.start()
            recording = true
            NSSound(named: "Tink")?.play()
            setIcon("mic.fill")
            stateItem.title = "Listening..."
        } catch {
            fail("Mic error: \(error.localizedDescription)")
        }
    }

    private func finish() {
        guard recording else { return }
        recording = false
        let take = recorder.stop()
        NSSound(named: "Pop")?.play()
        // Very short locked takes are accidental; don't bill a transcription for them.
        guard take.seconds > 0.3, let key = apiKey() else { return idle() }
        setIcon("ellipsis")
        stateItem.title = "Transcribing..."
        Task { @MainActor in
            do {
                let text = try await Scribe.transcribe(wav: take.wav, apiKey: key)
                if !text.isEmpty { Paster.insert(text + " ") }
                idle()
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func idle() {
        setIcon("mic")
        stateItem.title = "Hold Fn to dictate"
    }

    private func fail(_ message: String) {
        NSLog("screamr: %@", message)
        setIcon("mic.slash")
        stateItem.title = message
    }

    private func setIcon(_ symbol: String) {
        status.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Screamr")
    }

    private func apiKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["ELEVEN_LABS_API_KEY"], !env.isEmpty { return env }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/screamr/api_key")
        let key = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
