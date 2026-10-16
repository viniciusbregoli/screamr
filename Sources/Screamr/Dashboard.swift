import AVFoundation
import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case home = "Home", meetings = "Meetings", dictionary = "Dictionary", snippets = "Snippets", settings = "Settings"
    var id: Self { self }
    var icon: String {
        switch self {
        case .home: "house"
        case .meetings: "person.2.wave.2"
        case .dictionary: "character.book.closed"
        case .snippets: "text.badge.plus"
        case .settings: "gearshape"
        }
    }
    var key: KeyEquivalent { KeyEquivalent(Character("\(Pane.allCases.firstIndex(of: self)! + 1)")) }
}

struct DashboardActions {
    let toggleMeeting: () -> Void
    let retranscribe: (MeetingInfo) -> Void
}

let shortcutList: [(keys: String, action: String)] = [
    ("Hold Fn", "Dictate, release to paste"),
    ("Double-tap Fn / Fn+Space", "Hands-free dictation"),
    ("Esc", "Cancel dictation"),
    ("⌃⌥⌘M", "Start or stop a meeting recording"),
    ("⌃⌥⌘D", "Open this dashboard"),
    ("⌘1 to ⌘5", "Switch section"),
    ("⌘K", "Command palette"),
    ("/", "Search history"),
    ("⌘N", "Add a word or snippet"),
    ("?", "Show shortcuts"),
    ("⌘+ / ⌘- / ⌘0", "Zoom in, out, reset"),
    ("Esc", "Close palette, help, or this window"),
]

struct Dashboard: View {
    @ObservedObject var store: Store
    let actions: DashboardActions
    @State private var pane: Pane
    @AppStorage("zoom") private var zoom = 1.0
    @StateObject private var command = CommandKeyWatcher()
    @State private var palette = false
    @State private var help = false
    @State private var searchRequest = 0
    @FocusState private var rootFocused: Bool

    init(store: Store, actions: DashboardActions, pane: Pane = .home) {
        self.store = store
        self.actions = actions
        _pane = State(initialValue: pane)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Group {
                switch pane {
                case .home: HomePane(store: store, searchRequest: searchRequest)
                case .meetings: MeetingsPane(store: store, actions: actions)
                case .dictionary:
                    PairEditor(items: $store.dictionary, first: \.phrase, second: \.replacement, make: DictionaryEntry.init,
                               title: "Dictionary", firstLabel: "Word or name", secondLabel: "Replace with (optional)",
                               blurb: "Words Scribe should listen for. Add a replacement to rewrite what it hears, e.g. Screamer to screamr. Applies to dictation and meetings.")
                case .snippets:
                    PairEditor(items: $store.snippets, first: \.trigger, second: \.expansion, make: Snippet.init,
                               title: "Snippets", firstLabel: "When I say", secondLabel: "Insert",
                               blurb: "Say the trigger phrase and screamr types the expansion. Saying only the trigger inserts the expansion on its own.")
                case .settings: SettingsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Mocha.base)
        }
        .foregroundStyle(Mocha.text)
        .tint(Mocha.mauve)
        .background(shortcutButtons)
        .focusable()
        .focusEffectDisabled()
        .focused($rootFocused)
        .onAppear { rootFocused = true }
        // Single-key shortcuts only reach here when no text field has focus, so typing is never hijacked.
        .onKeyPress("?") { help = true; return .handled }
        .onKeyPress("/") { pane = .home; searchRequest += 1; return .handled }
        .onExitCommand { NSApp.keyWindow?.performClose(nil) }
        .sheet(isPresented: $palette) {
            CommandPalette(commands: commands) { palette = false }
        }
        .sheet(isPresented: $help) { HelpSheet { help = false } }
        .buttonStyle(MochaButton())
        .zfont(13)
        .environment(\.zoom, zoom)
    }

    private func zoom(by step: Double) { zoom = min(max((zoom + step) * 10, 8), 20).rounded() / 10 }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("screamr").zfont(17, .bold).foregroundStyle(Mocha.mauve).padding(.horizontal, 10).padding(.bottom, 12)
            ForEach(Pane.allCases) { p in
                Button { pane = p } label: {
                    HStack {
                        Image(systemName: p.icon).frame(width: 20)
                        Text(p.rawValue)
                        Spacer()
                        KeyChip("⌘\(String(p.key.character))")
                            .opacity(command.held ? 1 : 0)
                            .animation(.easeOut(duration: 0.12), value: command.held)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(pane == p ? Mocha.surface0 : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(pane == p ? Mocha.text : Mocha.subtext0)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button(action: actions.toggleMeeting) {
                Label(store.transcribingMeeting ? "Transcribing..." : store.meetingActive ? "Stop meeting" : "Record meeting",
                      systemImage: store.meetingActive ? "stop.circle.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(store.meetingActive ? Mocha.red : Mocha.surface0, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(store.meetingActive ? Mocha.crust : Mocha.text)
            }
            .buttonStyle(.plain)
            .disabled(store.transcribingMeeting)
            .help("⌃⌥⌘M")
            HStack { KeyChip("⌘K"); Text("commands"); Spacer(); KeyChip("?"); Text("help") }
                .zfont(10).foregroundStyle(Mocha.overlay0).padding(.top, 6)
        }
        .padding(12)
        .padding(.top, 24)
        .frame(width: 210 * zoom)
        .background(Mocha.mantle)
    }

    private var shortcutButtons: some View {
        ZStack {
            ForEach(Pane.allCases) { p in Button("") { pane = p }.keyboardShortcut(p.key, modifiers: .command) }
            Button("") { palette = true }.keyboardShortcut("k", modifiers: .command)
            // "=" is the unshifted "+" key, so Cmd+= and Cmd++ both zoom in, as in browsers.
            Button("") { zoom(by: 0.1) }.keyboardShortcut("=", modifiers: .command)
            Button("") { zoom(by: 0.1) }.keyboardShortcut("+", modifiers: .command)
            Button("") { zoom(by: -0.1) }.keyboardShortcut("-", modifiers: .command)
            Button("") { zoom = 1 }.keyboardShortcut("0", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    private var commands: [PaletteCommand] {
        Pane.allCases.map { p in PaletteCommand(title: "Go to \(p.rawValue)", hint: "⌘\(String(p.key.character))") { pane = p } } + [
            PaletteCommand(title: store.meetingActive ? "Stop meeting recording" : "Start meeting recording", hint: "⌃⌥⌘M", run: actions.toggleMeeting),
            PaletteCommand(title: "Search dictation history", hint: "/") { pane = .home; searchRequest += 1 },
            PaletteCommand(title: "Open meetings folder", hint: "") {
                try? FileManager.default.createDirectory(at: Meeting.root, withIntermediateDirectories: true)
                NSWorkspace.shared.open(Meeting.root)
            },
            PaletteCommand(title: "Show keyboard shortcuts", hint: "?") { help = true },
        ]
    }
}

/// Dashboard zoom (Cmd+/Cmd-). macOS SwiftUI ignores Dynamic Type, so every font size goes through this.
private struct ZoomKey: EnvironmentKey { static let defaultValue = 1.0 }
extension EnvironmentValues {
    var zoom: Double {
        get { self[ZoomKey.self] }
        set { self[ZoomKey.self] = newValue }
    }
}

private struct ZoomedFont: ViewModifier {
    let size: CGFloat, weight: Font.Weight, design: Font.Design
    @Environment(\.zoom) private var zoom
    func body(content: Content) -> some View { content.font(.system(size: size * zoom, weight: weight, design: design)) }
}

extension View {
    /// Point sizes match macOS text styles: caption 10, body 13, title3 15, title2 17, title 22, largeTitle 26.
    func zfont(_ size: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ZoomedFont(size: size, weight: weight, design: design))
    }
}

/// Tracks whether Command is held so shortcut hints can appear on demand.
final class CommandKeyWatcher: ObservableObject {
    @Published private(set) var held = false
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.held = event.modifierFlags.contains(.command)
            return event
        }
        // A Cmd+Tab away releases Command in another app, so this window never sees the key up.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            self?.held = false
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}

/// System bordered buttons keep a fixed control size, so they clip when zoomed and ignore the theme.
struct MochaButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(configuration.isPressed ? Mocha.surface1 : Mocha.surface0, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(configuration.role == .destructive ? Mocha.red : Mocha.text)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// Plain text fields otherwise draw their placeholder in the same color as typed text.
func placeholder(_ text: String) -> Text { Text(text).foregroundColor(Mocha.overlay0) }

struct KeyChip: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label).zfont(10, design: .monospaced)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Mocha.surface0, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(Mocha.subtext0)
    }
}

private struct PaneHeader: View {
    let title: String
    var blurb: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).zfont(26, .bold)
            if let blurb { Text(blurb).foregroundStyle(Mocha.subtext0) }
        }
    }
}

// MARK: Home

private struct HomePane: View {
    @ObservedObject var store: Store
    let searchRequest: Int
    @State private var query = ""
    @State private var selection: Dictation.ID?
    @FocusState private var searchFocused: Bool

    private var filtered: [Dictation] {
        query.isEmpty ? store.history : store.history.filter { $0.text.localizedCaseInsensitiveContains(query) || ($0.app ?? "").localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PaneHeader(title: "Home")
            HStack(spacing: 12) {
                let words = store.history.reduce(0) { $0 + $1.words }
                let seconds = store.history.reduce(0) { $0 + $1.seconds }
                let weekAgo = Date().addingTimeInterval(-7 * 86_400)
                Stat(label: "Dictations", value: "\(store.history.count)", color: Mocha.mauve)
                Stat(label: "Words", value: "\(words)", color: Mocha.blue)
                Stat(label: "Avg WPM", value: seconds > 0 ? "\(Int(Double(words) / seconds * 60))" : "-", color: Mocha.green)
                Stat(label: "Words this week", value: "\(store.history.filter { $0.date > weekAgo }.reduce(0) { $0 + $1.words })", color: Mocha.peach)
                Stat(label: "Meetings", value: "\(store.meetings.count)", color: Mocha.pink)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Mocha.overlay0)
                TextField("", text: $query, prompt: placeholder("Search history")).textFieldStyle(.plain).focused($searchFocused)
                    .onExitCommand { query = ""; searchFocused = false }
                KeyChip("/")
            }
            .padding(10)
            .background(Mocha.surface0, in: RoundedRectangle(cornerRadius: 8))

            if filtered.isEmpty {
                Text(store.history.isEmpty ? "Hold Fn anywhere and start talking. Your dictations show up here." : "No matches.")
                    .foregroundStyle(Mocha.overlay0)
                Spacer()
            } else {
                List(filtered, selection: $selection) { d in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(d.text).lineLimit(3).zfont(13) // List rows don't inherit the outer font
                        HStack(spacing: 6) {
                            Text(d.date, format: .relative(presentation: .named))
                            if let app = d.app { Text("in \(app)") }
                            Text("\(d.words) words")
                        }
                        .zfont(10).foregroundStyle(Mocha.overlay0)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(selection == d.id ? Mocha.surface0 : Mocha.base)
                    .contextMenu {
                        Button("Copy") { copy(d) }
                        Button("Delete", role: .destructive) { store.history.removeAll { $0.id == d.id } }
                    }
                }
                .scrollContentBackground(.hidden)
                .onKeyPress(.return) { selected.map(copy); return .handled }
                .onDeleteCommand { if let id = selection { store.history.removeAll { $0.id == id } } }
                .onCopyCommand { selected.map { [NSItemProvider(object: $0.text as NSString)] } ?? [] }
                Text("Return copies the selected dictation, Delete removes it.").zfont(10).foregroundStyle(Mocha.overlay0)
            }
        }
        .padding(28)
        .onChange(of: searchRequest) { searchFocused = true }
    }

    private var selected: Dictation? { store.history.first { $0.id == selection } }

    private func copy(_ d: Dictation) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(d.text, forType: .string)
    }
}

private struct Stat: View {
    let label: String, value: String, color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).zfont(22, .bold).monospacedDigit().foregroundStyle(color)
            Text(label).zfont(10).foregroundStyle(Mocha.subtext0).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Mocha.mantle, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: Meetings

private struct MeetingsPane: View {
    @ObservedObject var store: Store
    let actions: DashboardActions
    @State private var selection: MeetingInfo.ID?
    @Environment(\.zoom) private var zoom

    private var selected: MeetingInfo? { store.meetings.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: "Meetings", blurb: "Recordings of your mic and call audio, transcribed by Scribe with speaker labels.")
            HStack(spacing: 16) {
                List(store.meetings, selection: $selection) { m in
                    HStack {
                        Text(m.title).zfont(13)
                        Spacer()
                        if m.transcript == nil { Image(systemName: "exclamationmark.circle").foregroundStyle(Mocha.yellow).help("No transcript yet") }
                    }
                    .listRowBackground(selection == m.id ? Mocha.surface0 : Mocha.base)
                }
                .scrollContentBackground(.hidden)
                .frame(width: 240 * zoom)
                .overlay {
                    if store.meetings.isEmpty {
                        Text("Press ⌃⌥⌘M to record your first meeting.").foregroundStyle(Mocha.overlay0).multilineTextAlignment(.center).padding()
                    }
                }

                if let m = selected {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([m.dir]) }
                            Button(m.transcript == nil ? "Transcribe" : "Re-transcribe") { actions.retranscribe(m) }
                                .disabled(store.transcribingMeeting)
                            Spacer()
                            Button("Move to Trash", role: .destructive) {
                                try? FileManager.default.trashItem(at: m.dir, resultingItemURL: nil)
                                selection = nil
                                store.refreshMeetings()
                            }
                        }
                        ScrollView {
                            Text(transcript(m)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        }
                        .background(Mocha.mantle, in: RoundedRectangle(cornerRadius: 10))
                    }
                } else {
                    Text("Select a meeting").foregroundStyle(Mocha.overlay0).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(28)
        .onAppear { store.refreshMeetings(); selection = selection ?? store.meetings.first?.id }
    }

    private func transcript(_ m: MeetingInfo) -> AttributedString {
        guard let url = m.transcript, let md = try? String(contentsOf: url, encoding: .utf8) else {
            return AttributedString(store.transcribingMeeting ? "Transcribing..." : "No transcript yet. The audio is saved, so you can transcribe it now.")
        }
        let body = md.split(separator: "\n", maxSplits: 1).dropFirst().joined() // the title is already in the list
        return (try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(body)
    }
}

// MARK: Dictionary & snippets

private struct PairEditor<Item: Identifiable & Hashable>: View {
    @Binding var items: [Item]
    let first: WritableKeyPath<Item, String>
    let second: WritableKeyPath<Item, String>
    let make: () -> Item
    let title: String, firstLabel: String, secondLabel: String, blurb: String
    @FocusState private var focused: Item.ID?
    @Environment(\.zoom) private var zoom

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                PaneHeader(title: title, blurb: blurb)
                Spacer()
                Button { add() } label: { HStack { Text("Add"); KeyChip("⌘N") } }
                    .keyboardShortcut("n", modifiers: .command)
            }
            HStack {
                Text(firstLabel).frame(width: 220 * zoom, alignment: .leading)
                Text(secondLabel)
            }
            .zfont(10).foregroundStyle(Mocha.subtext0)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($items) { $item in
                        HStack(alignment: .top) {
                            TextField("", text: $item[dynamicMember: first], prompt: placeholder(firstLabel))
                                .focused($focused, equals: item.id)
                                .frame(width: 220 * zoom)
                            TextField("", text: $item[dynamicMember: second], prompt: placeholder(secondLabel), axis: .vertical)
                            Button { items.removeAll { $0.id == item.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).foregroundStyle(Mocha.red).help("Remove")
                        }
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Mocha.mantle, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if items.isEmpty { Text("Nothing yet. Press ⌘N to add one.").foregroundStyle(Mocha.overlay0).frame(maxWidth: .infinity) }
                }
            }
        }
        .padding(28)
    }

    private func add() {
        let item = make()
        items.append(item)
        focused = item.id
    }
}

// MARK: Settings

private struct SettingsPane: View {
    @State private var key = ""
    @State private var keyStatus = Store.apiKey() == nil ? "No key saved" : "Key saved"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var refresh = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PaneHeader(title: "Settings")
                group("ElevenLabs API key") {
                    HStack {
                        SecureField("", text: $key, prompt: placeholder("Paste a new key")).textFieldStyle(.plain)
                            .padding(8).background(Mocha.surface0, in: RoundedRectangle(cornerRadius: 6))
                            .onSubmit(saveKey)
                        Button("Save", action: saveKey).disabled(key.isEmpty)
                    }
                    Text("\(keyStatus). Stored in ~/.config/screamr/api_key, readable only by you.").zfont(10).foregroundStyle(Mocha.subtext0)
                }
                group("Permissions") {
                    let _ = refresh
                    let mic = AVCaptureDevice.authorizationStatus(for: .audio)
                    permission("Accessibility", detail: "Hotkeys and pasting. After granting, quit and reopen screamr.",
                               granted: AXIsProcessTrusted(), pane: "Privacy_Accessibility") {
                        // Shows the system prompt and adds screamr to the list, so there's nothing to add by hand.
                        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
                    }
                    permission("Microphone", detail: mic == .notDetermined ? "Dictation and meetings. Not asked yet." : "Dictation and meetings",
                               granted: mic == .authorized ? true : mic == .notDetermined ? nil : false, pane: "Privacy_Microphone",
                               request: mic == .notDetermined ? { AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { refresh += 1 } } } : nil)
                    permission("System Audio Recording", detail: "Call audio in meetings, asked on your first recording", granted: nil, pane: "Privacy_AudioCapture")
                }
                group("General") {
                    Toggle("Launch screamr at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, on in
                            do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister(); loginError = nil }
                            catch { loginError = error.localizedDescription; launchAtLogin = !on }
                        }
                    if let loginError { Text(loginError).zfont(10).foregroundStyle(Mocha.red) }
                }
                group("Keyboard shortcuts") { ShortcutTable() }
            }
            .padding(28)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh += 1 }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).zfont(13, .semibold).foregroundStyle(Mocha.lavender)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Mocha.mantle, in: RoundedRectangle(cornerRadius: 10))
    }

    /// `granted` nil means unknown or not asked yet. With `request`, the button asks macOS directly.
    private func permission(_ name: String, detail: String, granted: Bool?, pane: String, request: (() -> Void)? = nil) -> some View {
        HStack {
            Image(systemName: granted == true ? "checkmark.circle.fill" : granted == false ? "xmark.circle.fill" : "questionmark.circle")
                .foregroundStyle(granted == true ? Mocha.green : granted == false ? Mocha.red : Mocha.overlay0)
            VStack(alignment: .leading) {
                Text(name)
                Text(detail).zfont(10).foregroundStyle(Mocha.subtext0)
            }
            Spacer()
            if let request, granted != true {
                Button("Allow", action: request)
            } else {
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
            }
        }
    }

    private func saveKey() {
        guard !key.isEmpty else { return }
        do { try Store.saveAPIKey(key); key = ""; keyStatus = "Key saved" } catch { keyStatus = "Could not save: \(error.localizedDescription)" }
    }
}

private struct ShortcutTable: View {
    var body: some View {
        Grid(alignment: .leading, verticalSpacing: 8) {
            ForEach(shortcutList, id: \.action) { s in
                GridRow {
                    KeyChip(s.keys)
                    Text(s.action).foregroundStyle(Mocha.subtext0)
                }
            }
        }
    }
}

// MARK: Overlays

struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let hint: String
    let run: () -> Void
}

private struct CommandPalette: View {
    let commands: [PaletteCommand]
    let dismiss: () -> Void
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool
    @Environment(\.zoom) private var zoom

    private var matches: [PaletteCommand] {
        query.isEmpty ? commands : commands.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("", text: $query, prompt: placeholder("Type a command"))
                .textFieldStyle(.plain).zfont(15).padding(14).focused($focused)
                .onChange(of: query) { index = 0 }
                .onKeyPress(.downArrow) { index = min(index + 1, max(matches.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                .onSubmit(runSelected)
            Divider().overlay(Mocha.surface1)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { i, c in
                        HStack {
                            Text(c.title)
                            Spacer()
                            if !c.hint.isEmpty { KeyChip(c.hint) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(i == index ? Mocha.surface0 : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { index = i; runSelected() }
                    }
                }
                .padding(8)
            }
            .frame(height: 280)
        }
        .frame(width: 520 * zoom)
        .background(Mocha.mantle)
        .foregroundStyle(Mocha.text)
        .onAppear { focused = true }
        .onExitCommand(perform: dismiss)
    }

    private func runSelected() {
        guard matches.indices.contains(index) else { return }
        let command = matches[index]
        dismiss()
        command.run()
    }
}

private struct HelpSheet: View {
    let dismiss: () -> Void
    @Environment(\.zoom) private var zoom
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard shortcuts").zfont(17, .bold).foregroundStyle(Mocha.mauve)
            ShortcutTable()
            HStack { Spacer(); Button("Close", action: dismiss).keyboardShortcut(.cancelAction) }
        }
        .padding(24)
        .frame(width: 440 * zoom)
        .background(Mocha.mantle)
        .foregroundStyle(Mocha.text)
    }
}

// MARK: Window

/// Shows the dashboard and puts screamr in the Dock while it's open, like Wispr's hub.
final class DashboardWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(store: Store, actions: DashboardActions) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "screamr"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(Mocha.base)
            w.minSize = NSSize(width: 820, height: 520)
            w.contentView = NSHostingView(rootView: Dashboard(store: store, actions: actions))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("Dashboard")
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
