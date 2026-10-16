import AppKit
import ApplicationServices

final class App: NSObject, NSApplicationDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let fn = FnKey()
    private let recorder = Recorder()
    private let store = Store.shared
    private let dashboard = DashboardWindow()
    private var ptt = PushToTalk()
    private var recording = false
    private var targetApp: String?
    private var stateItem = NSMenuItem(title: "Hold Fn to dictate", action: nil, keyEquivalent: "")
    private lazy var meetingItem = item("Start Meeting Recording", #selector(toggleMeeting), "m", [.control, .option, .command])
    private var meeting: Meeting?

    func applicationDidFinishLaunching(_ note: Notification) {
        let menu = NSMenu()
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(item("Open Dashboard", #selector(openDashboard), "d", [.control, .option, .command]))
        menu.addItem(meetingItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Screamr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        status.menu = menu
        setIcon("mic")
        NSApp.mainMenu = mainMenu()

        guard Store.apiKey() != nil else {
            fail("No API key: add it in Dashboard > Settings")
            return openDashboard()
        }
        // Event tap and synthetic Cmd+V both need Accessibility; this shows the system prompt once.
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        fn.onEvent = { [weak self] event in self?.handle(event) ?? false }
        if !trusted || !fn.start() {
            fail("Grant Accessibility in System Settings, then relaunch")
        }
    }

    // Clicking the Dock icon while the dashboard is closed reopens it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openDashboard() }
        return true
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
        case .meetingToggle:
            toggleMeeting()
            return true
        case .dashboard:
            openDashboard()
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
            targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
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
        guard take.seconds > 0.3, let key = Store.apiKey() else { return idle() }
        setIcon("ellipsis")
        stateItem.title = "Transcribing..."
        let app = targetApp
        Task { @MainActor in
            do {
                let raw = try await Scribe.transcribe(wav: take.wav, apiKey: key, keyterms: store.keyterms)
                let text = store.postProcess(raw)
                if !text.isEmpty {
                    Paster.insert(text + " ")
                    store.history.insert(Dictation(date: Date(), text: text, app: app, seconds: take.seconds), at: 0)
                }
                idle()
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    @objc private func toggleMeeting() {
        guard let current = meeting else {
            guard !store.transcribingMeeting else { return }
            do {
                meeting = try Meeting()
                store.meetingActive = true
                meetingItem.title = "Stop Meeting Recording"
                NSSound(named: "Hero")?.play()
                if let err = meeting?.systemError { NSLog("screamr: recording mic only, %@", err) }
            } catch {
                fail("Meeting error: \(error.localizedDescription)")
            }
            return
        }
        meeting = nil
        store.meetingActive = false
        let hasSystem = current.stop()
        NSSound(named: "Bottle")?.play()
        transcribe(MeetingInfo(dir: current.dir, title: current.title), includeSystem: hasSystem, openWhenDone: true)
    }

    private func transcribe(_ m: MeetingInfo, includeSystem: Bool, openWhenDone: Bool) {
        guard let key = Store.apiKey() else { return fail("No API key") }
        store.transcribingMeeting = true
        meetingItem.title = "Transcribing Meeting..."
        meetingItem.isEnabled = false
        store.refreshMeetings()
        Task { @MainActor in
            defer {
                store.transcribingMeeting = false
                store.refreshMeetings()
                meetingItem.title = "Start Meeting Recording"
                meetingItem.isEnabled = true
            }
            do {
                let url = try await Meeting.transcribe(dir: m.dir, title: m.title, includeSystem: includeSystem, apiKey: key, store: store)
                if openWhenDone { NSWorkspace.shared.open(url) }
            } catch {
                // Audio stays on disk, so a failed transcription loses nothing; retry from the dashboard.
                fail("Meeting transcription failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func openDashboard() {
        dashboard.show(store: store, actions: DashboardActions(
            toggleMeeting: { [weak self] in self?.toggleMeeting() },
            retranscribe: { [weak self] m in
                let system = m.dir.appendingPathComponent("system.m4a")
                self?.transcribe(m, includeSystem: FileManager.default.fileExists(atPath: system.path), openWhenDone: false)
            }
        ))
    }

    /// The dashboard puts screamr in the Dock, so it needs a real menu bar: without an Edit menu,
    /// Cmd+C/V/A don't work in its text fields.
    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem()
            holder.submenu = menu
            main.addItem(holder)
        }
        sub("screamr", [NSMenuItem(title: "Quit screamr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")])
        sub("Edit", [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"),
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ])
        sub("Window", [
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
            NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
        ])
        return main
    }

    private func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = self
        return item
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
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
