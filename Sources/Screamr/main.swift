import AppKit
import ApplicationServices

final class App: NSObject, NSApplicationDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let fn = FnKey()
    private let recorder = Recorder()
    private let flowBar = FlowBar()
    private let corrections = CorrectionWatcher()
    private let store = Store.shared
    private let dashboard = DashboardWindow()
    private var ptt = PushToTalk()
    private var recording = false
    private var targetApp: String?
    private var stateItem = NSMenuItem(title: "Hold Fn to dictate", action: nil, keyEquivalent: "")
    private lazy var meetingItem = item("Start Meeting Recording", #selector(toggleMeeting), "m", [.control, .option, .command])
    private var meeting: Meeting?
    private lazy var syncEngine = SyncEngine(root: Meeting.root, stateFile: Store.root.appendingPathComponent("sync-state.json"))
    private var syncing = false
    private var transcribingDir: String?

    func applicationDidFinishLaunching(_ note: Notification) {
        let menu = NSMenu()
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(item("Open Dashboard", #selector(openDashboard), "d", [.control, .option, .command]))
        menu.addItem(meetingItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Screamr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        status.menu = menu
        setIcon("trayIdleTemplate")
        NSApp.mainMenu = mainMenu()
        flowBar.level = { [recorder] in recorder.level }
        syncNow()
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.syncNow() }

        // Fn still gets set up without a key, so it works as soon as one is saved in Settings.
        if Store.apiKey() == nil {
            fail("No API key: add it in Dashboard > Settings")
            openDashboard()
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
            flowBar.show(.locked)
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
        corrections.stop()
        do {
            try recorder.start()
            recording = true
            targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
            NSSound(named: "Tink")?.play()
            flowBar.show(.listening)
            setIcon("trayListeningTemplate")
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
        flowBar.show(.transcribing)
        stateItem.title = "Transcribing..."
        let app = targetApp
        Task { @MainActor in
            do {
                let raw = try await Scribe.transcribe(wav: take.wav, apiKey: key, keyterms: store.keyterms)
                let text = store.postProcess(raw)
                if !text.isEmpty {
                    Paster.insert(text.hasSuffix("\n") ? text : text + " ")
                    store.history.insert(Dictation(date: Date(), text: text, app: app, seconds: take.seconds), at: 0)
                    if UserDefaults.standard.object(forKey: CorrectionWatcher.enabledKey) as? Bool ?? true {
                        corrections.watch(dictated: text) { wrong, right in self.learn(wrong, right) }
                    }
                }
                idle()
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    /// A word fixed by hand right after dictating becomes a dictionary entry, so Scribe gets it next time.
    private func learn(_ wrong: String, _ right: String) {
        guard !store.dictionary.contains(where: { $0.phrase.lowercased() == wrong.lowercased() }) else { return }
        store.dictionary.append(DictionaryEntry(phrase: wrong, replacement: right))
        flowBar.flash("Added to dictionary", "\(wrong) \u{2192} \(right)")
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

    /// Picks an audio file from a voice recorder and transcribes it as a new meeting.
    private func importRecording() {
        // A transcription takes over the meeting menu item, which a running recording needs to stop.
        guard meeting == nil, !store.transcribingMeeting else { return fail("Finish the current meeting first") }
        guard Store.apiKey() != nil else { return fail("No API key") }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose a recording to transcribe as a meeting"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let source = panel.url else { return }
        // Held through the conversion too, so no meeting or second import starts before transcription takes over.
        store.transcribingMeeting = true
        Task { @MainActor in
            do {
                let m = try await Meeting.importRecording(source)
                transcribe(m, includeSystem: false, openWhenDone: false)
            } catch {
                store.transcribingMeeting = false
                fail("Import failed: \(error.localizedDescription)")
            }
        }
    }

    private func transcribe(_ m: MeetingInfo, includeSystem: Bool, openWhenDone: Bool) {
        guard let key = Store.apiKey() else {
            store.transcribingMeeting = false // an import may hold it while converting
            return fail("No API key")
        }
        store.transcribingMeeting = true
        transcribingDir = m.dir.lastPathComponent
        meetingItem.title = "Transcribing Meeting..."
        meetingItem.isEnabled = false
        store.refreshMeetings()
        Task { @MainActor in
            defer {
                store.transcribingMeeting = false
                transcribingDir = nil
                syncNow()
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
            importRecording: { [weak self] in self?.importRecording() },
            retranscribe: { [weak self] m in
                let system = m.dir.appendingPathComponent("system.m4a")
                self?.transcribe(m, includeSystem: FileManager.default.fileExists(atPath: system.path), openWhenDone: false)
            },
            syncNow: { [weak self] in self?.syncNow() },
            meetingDeleted: { [weak self] m in
                guard let self else { return }
                Task { @MainActor in
                    await self.syncEngine.markDeleted(m.dir.lastPathComponent)
                    self.syncNow()
                }
            }
        ))
    }

    /// Pushes local meetings and pulls the iPhone's. Pulled transcripts get speakers recognized here,
    /// and a second pass sends their labels back.
    private func syncNow() {
        guard !syncing, let config = Store.syncConfig() else { return }
        syncing = true
        store.syncStatus = "Syncing..."
        let skip = Set([meeting?.dir.lastPathComponent, transcribingDir].compactMap { $0 })
        Task { @MainActor in
            defer { syncing = false }
            do {
                var recognized = false
                for (dir, files) in try await syncEngine.run(config, skip: skip) {
                    if files.contains(where: { $0.hasSuffix(".words.json") }) {
                        await Meeting.identifySpeakers(dir: dir, store: store)
                        recognized = true
                    } else if !files.contains(MeetingTitle.file) {
                        continue
                    }
                    // A renamed meeting only needs its transcript heading rewritten.
                    _ = try? Meeting.render(dir: dir, title: "Meeting \(dir.lastPathComponent)", store: store)
                }
                if recognized { _ = try await syncEngine.run(config, skip: skip) }
                store.refreshMeetings()
                store.syncStatus = "Synced at \(Date().formatted(date: .omitted, time: .shortened))"
            } catch {
                store.syncStatus = "Sync failed: \(error.localizedDescription)"
            }
        }
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
        flowBar.hide()
        setIcon("trayIdleTemplate")
        stateItem.title = "Hold Fn to dictate"
    }

    private func fail(_ message: String) {
        NSLog("screamr: %@", message)
        flowBar.hide()
        setIcon("mic.slash")
        stateItem.title = message
    }

    /// Takes a tray asset bundled by build.sh (the "Template" suffix makes it tint with the menu bar) or an SF Symbol.
    private func setIcon(_ name: String) {
        let image = NSImage(named: name) ?? NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.accessibilityDescription = "Screamr"
        status.button?.image = image
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
