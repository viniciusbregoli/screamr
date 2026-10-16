import AppKit
import ApplicationServices

final class App: NSObject, NSApplicationDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let fn = FnKey()
    private let recorder = Recorder()
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
        fn.onChange = { [weak self] down in down ? self?.begin() : self?.finish() }
        if !trusted || !fn.start() {
            fail("Grant Accessibility in System Settings, then relaunch")
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
        // A quick tap of Fn is almost always accidental; don't bill a transcription for it.
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
