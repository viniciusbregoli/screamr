import AVFoundation
import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case home = "Home", meetings = "Meetings", people = "People", dictionary = "Dictionary", snippets = "Snippets", settings = "Settings"
    var id: Self { self }
    var icon: String {
        switch self {
        case .home: "house"
        case .meetings: "person.2.wave.2"
        case .people: "person.crop.circle"
        case .dictionary: "character.book.closed"
        case .snippets: "text.badge.plus"
        case .settings: "gearshape"
        }
    }
    var key: KeyEquivalent { KeyEquivalent(Character("\(Pane.allCases.firstIndex(of: self)! + 1)")) }
}

struct DashboardActions {
    let toggleMeeting: () -> Void
    var importRecording: () -> Void = {}
    let retranscribe: (MeetingInfo) -> Void
    var syncNow: () -> Void = {}
    var meetingDeleted: (MeetingInfo) -> Void = { _ in }
}

let shortcutList: [(keys: String, action: String)] = [
    ("Hold Fn", "Dictate, release to paste"),
    ("Double-tap Fn / Fn+Space", "Hands-free dictation"),
    ("Esc", "Cancel dictation"),
    ("⌃⌥⌘M", "Start or stop a meeting recording"),
    ("⌘I", "Import a recording as a meeting"),
    ("⌃⌥⌘D", "Open this dashboard"),
    ("⌘1 to ⌘6", "Switch section"),
    ("⌘K", "Command palette"),
    ("/", "Search history"),
    ("⌘N", "Add a word or snippet"),
    ("⌘R", "Rename the selected meeting"),
    ("?", "Show shortcuts"),
    ("⌘+ / ⌘- / ⌘0", "Zoom in, out, reset"),
    ("Esc", "Close palette, help, or this window"),
]

struct Dashboard: View {
    @ObservedObject var store: Store
    let actions: DashboardActions
    @State private var pane: Pane
    @AppStorage("zoom") private var zoom = 1.0
    @AppStorage(Theme.key) private var theme = "mocha"
    @StateObject private var command = CommandKeyWatcher()
    @State private var palette = false
    @State private var help = false
    @State private var searchRequest = 0
    @State private var renameRequested = false
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
                case .meetings: MeetingsPane(store: store, actions: actions, renameRequested: $renameRequested)
                case .people: PeoplePane(store: store)
                case .dictionary:
                    PairEditor(items: $store.dictionary, first: \.phrase, second: \.replacement, make: DictionaryEntry.init,
                               title: "Dictionary", firstLabel: "Word or name", secondLabel: "Replace with (optional)",
                               blurb: "Words Scribe should listen for. Add a replacement to rewrite what it hears, e.g. Screamer to screamr. Applies to dictation and meetings.")
                case .snippets:
                    PairEditor(items: $store.snippets, first: \.trigger, second: \.expansion, make: Snippet.init,
                               title: "Snippets", firstLabel: "When I say", secondLabel: "Insert",
                               blurb: "Say the trigger phrase and screamr types the expansion. Saying only the trigger inserts the expansion on its own.")
                case .settings: SettingsPane(store: store, actions: actions)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.base)
            .id(theme) // panes read the palette when drawn, so a theme change redraws them
        }
        .foregroundStyle(Theme.text)
        .tint(Theme.mauve)
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
        .buttonStyle(ThemeButton())
        .zfont(13)
        .environment(\.zoom, zoom)
    }

    private func zoom(by step: Double) { zoom = min(max((zoom + step) * 10, 8), 20).rounded() / 10 }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
                Text("screamr").zfont(15, .semibold).glow(Theme.mauve, radius: 5)
            }
            .padding(.horizontal, 8).padding(.bottom, 14)
            ForEach(Pane.allCases) { p in
                Button { pane = p } label: {
                    HStack(spacing: 10) {
                        Image(systemName: p.icon).zfont(13).frame(width: 18).foregroundStyle(pane == p ? Theme.mauve : Theme.overlay2)
                            .glow(pane == p ? Theme.mauve : .clear)
                        Text(p.rawValue)
                        Spacer()
                        KeyChip("⌘\(String(p.key.character))")
                            .opacity(command.held ? 1 : 0)
                            .animation(.easeOut(duration: 0.12), value: command.held)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(pane == p ? Theme.surface0 : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        if pane == p && Theme.glows {
                            RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.mauve.opacity(0.55), lineWidth: 1).glow(Theme.mauve, radius: 5)
                        }
                    }
                    .foregroundStyle(pane == p ? Theme.text : Theme.subtext0)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button(action: actions.toggleMeeting) {
                HStack(spacing: 8) {
                    Image(systemName: store.meetingActive ? "stop.fill" : "circle.fill")
                        .zfont(store.meetingActive ? 10 : 9)
                        .foregroundStyle(store.meetingActive ? Theme.crust : Theme.red)
                        .glow(store.meetingActive ? .clear : Theme.red, radius: 4)
                    Text(store.transcribingMeeting ? "Transcribing..." : store.meetingActive ? "Stop meeting" : "Record meeting")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(store.meetingActive ? Theme.red : Theme.surface0, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(store.meetingActive ? Theme.crust : Theme.text)
            }
            .buttonStyle(.plain)
            .disabled(store.transcribingMeeting)
            .help("⌃⌥⌘M")
            HStack(spacing: 6) { KeyChip("⌘K"); Text("Commands"); Spacer(); KeyChip("?"); Text("Help") }
                .zfont(11).foregroundStyle(Theme.overlay2).padding(.top, 10).padding(.horizontal, 2)
        }
        .padding(12)
        .padding(.top, 34) // clears the window buttons, since the sidebar runs under the title bar
        .frame(width: 210 * zoom)
        .background {
            ZStack {
                Theme.mantle
                if Theme.glows { NeonAmbient() }
            }
            .clipped()
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var shortcutButtons: some View {
        ZStack {
            ForEach(Pane.allCases) { p in Button("") { pane = p }.keyboardShortcut(p.key, modifiers: .command) }
            Button("") { palette = true }.keyboardShortcut("k", modifiers: .command)
            Button("") { pane = .meetings; actions.importRecording() }.keyboardShortcut("i", modifiers: .command)
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
            PaletteCommand(title: "Import a recording", hint: "⌘I") { pane = .meetings; actions.importRecording() },
            PaletteCommand(title: "Search dictation history", hint: "/") { pane = .home; searchRequest += 1 },
            PaletteCommand(title: "Rename meeting", hint: "⌘R") { pane = .meetings; renameRequested = true },
            PaletteCommand(title: "Open meetings folder", hint: "") {
                try? FileManager.default.createDirectory(at: Meeting.root, withIntermediateDirectories: true)
                NSWorkspace.shared.open(Meeting.root)
            },
            PaletteCommand(title: "Show keyboard shortcuts", hint: "?") { help = true },
        ] + Theme.all.map { p in PaletteCommand(title: "Theme: \(p.name)", hint: "") { theme = p.id } }
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
struct ThemeButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(configuration.isPressed ? Theme.surface1 : Theme.surface0, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(configuration.role == .destructive ? Theme.red : Theme.text)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// Plain text fields otherwise draw their placeholder in the same color as typed text.
func placeholder(_ text: String) -> Text { Text(text).foregroundColor(Theme.overlay2) }

struct KeyChip: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label).zfont(10, design: .monospaced)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Theme.surface0, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(Theme.subtext0)
    }
}

private struct PaneHeader: View {
    let title: String
    var blurb: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).zfont(22, .bold).glow(Theme.mauve, radius: 7)
            if let blurb { Text(blurb).foregroundStyle(Theme.subtext0).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// Pane padding: the window's transparent title bar already adds room at the top.
extension View {
    func panePadding() -> some View { padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 22) }
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

    /// History split by day, newest first, so a long list stays scannable.
    private var days: [(title: String, items: [Dictation])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { day in
            let title = calendar.isDateInToday(day) ? "Today" : calendar.isDateInYesterday(day) ? "Yesterday"
                : day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            return (title, groups[day]!.sorted { $0.date > $1.date })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(title: "Home")
            stats
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.overlay2)
                TextField("", text: $query, prompt: placeholder("Search history")).textFieldStyle(.plain).focused($searchFocused)
                    .onExitCommand { query = ""; searchFocused = false }
                KeyChip("/")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Theme.surface0, in: RoundedRectangle(cornerRadius: 8))

            if filtered.isEmpty {
                Text(store.history.isEmpty ? "Hold Fn anywhere and start talking. Your dictations show up here." : "No dictations match \u{201C}\(query)\u{201D}.")
                    .foregroundStyle(Theme.subtext0)
                Spacer()
            } else {
                List(selection: $selection) {
                    ForEach(days, id: \.title) { day in
                        // A plain row rather than a Section header, which macOS paints with a gray bar.
                        Text(day.title).zfont(11, .semibold).foregroundStyle(Theme.subtext0)
                            .padding(.top, 8)
                            .listRowBackground(Theme.base)
                            .listRowSeparator(.hidden)
                            .selectionDisabled()
                        ForEach(day.items) { d in row(d).tag(d.id) }
                    }
                }
                .scrollContentBackground(.hidden)
                .onKeyPress(.return) { selected.map(copy); return .handled }
                .onDeleteCommand { if let id = selection { store.history.removeAll { $0.id == id } } }
                .onCopyCommand { selected.map { [NSItemProvider(object: $0.text as NSString)] } ?? [] }
                HStack(spacing: 4) {
                    KeyChip("↩"); Text("copies")
                    KeyChip("⌫").padding(.leading, 8); Text("deletes the selected dictation")
                }
                .zfont(11).foregroundStyle(Theme.overlay2)
            }
        }
        .panePadding()
        .onChange(of: searchRequest) { searchFocused = true }
    }

    /// One quiet line of numbers rather than a row of cards: the history is the content here.
    private var stats: some View {
        let words = store.history.reduce(0) { $0 + $1.words }
        let seconds = store.history.reduce(0) { $0 + $1.seconds }
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        let week = store.history.filter { $0.date > weekAgo }.reduce(0) { $0 + $1.words }
        let items: [(String, String)] = [
            ("\(store.history.count)", store.history.count == 1 ? "dictation" : "dictations"),
            ("\(words)", "words"),
            ("\(week)", "this week"),
            (seconds > 0 ? "\(Int(Double(words) / seconds * 60))" : "-", "words per minute"),
        ]
        return HStack(spacing: 22) {
            ForEach(items, id: \.1) { value, label in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value).zfont(17, .semibold).monospacedDigit()
                    Text(label).foregroundStyle(Theme.subtext0)
                }
            }
        }
    }

    private func row(_ d: Dictation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AppIcon(name: d.app).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(d.text).lineLimit(3).zfont(13) // List rows don't inherit the outer font
                Text([d.date.formatted(date: .omitted, time: .shortened), d.app, "\(d.words) word\(d.words == 1 ? "" : "s")"]
                        .compactMap { $0 }.joined(separator: " \u{00B7} "))
                    .zfont(11).foregroundStyle(Theme.overlay2)
            }
        }
        .padding(.vertical, 5)
        .listRowBackground(selection == d.id ? Theme.surface0 : Theme.base)
        .contextMenu {
            Button("Copy") { copy(d) }
            Button("Delete", role: .destructive) { store.history.removeAll { $0.id == d.id } }
        }
    }

    private var selected: Dictation? { store.history.first { $0.id == selection } }

    private func copy(_ d: Dictation) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(d.text, forType: .string)
    }
}

/// The icon of the app a dictation went to, looked up by name once and cached.
private struct AppIcon: View {
    let name: String?
    private static var cache: [String: NSImage] = [:]
    @Environment(\.zoom) private var zoom

    var body: some View {
        Group {
            if let image = name.flatMap(Self.icon) {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "text.cursor").foregroundStyle(Theme.overlay2)
            }
        }
        .frame(width: 18 * zoom, height: 18 * zoom)
    }

    private static func icon(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        let running = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.bundleURL
        let installed = ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
            .map { URL(fileURLWithPath: "\($0)/\(name).app") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let url = running ?? installed else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[name] = image
        return image
    }
}

// MARK: Meetings

private struct MeetingsPane: View {
    @ObservedObject var store: Store
    let actions: DashboardActions
    /// A flag rather than a counter: the palette can open this pane fresh, and it has to consume the request on appear.
    @Binding var renameRequested: Bool
    @State private var selection: MeetingInfo.ID?
    @State private var renaming = false
    @State private var draft = ""
    @State private var renameError: String?
    @FocusState private var titleFocused: Bool
    /// Bumped after a correction, since a line fix rewrites files without changing the store.
    @State private var edits = 0
    @Environment(\.zoom) private var zoom
    // Computed, so a theme change is picked up: a stored static would keep the first theme's colors.
    private static var colors: [Color] { [Theme.mauve, Theme.peach, Theme.teal, Theme.pink, Theme.blue, Theme.yellow, Theme.green, Theme.lavender] }

    private var selected: MeetingInfo? { store.meetings.first { $0.id == selection } }

    /// Who to offer in the correction menu: the user first, then whoever shows up most.
    private var people: [Person] {
        store.people.sorted { ($0.id == store.me?.id ? 1 : 0, $0.meetings.count) > ($1.id == store.me?.id ? 1 : 0, $1.meetings.count) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                PaneHeader(title: "Meetings", blurb: "Mic and call audio, transcribed by Scribe with speakers recognized by voice.")
                Spacer()
                Button(action: actions.importRecording) { HStack(spacing: 4) { Text("Import recording"); KeyChip("⌘I") } }
                    .disabled(store.transcribingMeeting || store.meetingActive)
                    .help("Transcribe audio from a voice recorder as a meeting")
            }
            if store.meetings.isEmpty {
                empty
            } else {
                HStack(alignment: .top, spacing: 16) {
                    List(store.meetings, selection: $selection) { m in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.name ?? m.date?.formatted(date: .abbreviated, time: .shortened) ?? m.title).zfont(13, .medium)
                            Group {
                                if m.transcript == nil {
                                    Label("Not transcribed", systemImage: "exclamationmark.circle").foregroundStyle(Theme.yellow)
                                } else {
                                    Text(m.speakers.isEmpty ? "Transcribed" : m.speakers.joined(separator: ", ")).foregroundStyle(Theme.overlay2)
                                }
                            }
                            .zfont(11).lineLimit(1)
                        }
                        .padding(.vertical, 3)
                        .listRowBackground(selection == m.id ? Theme.surface0 : Theme.base)
                    }
                    .scrollContentBackground(.hidden)
                    .frame(width: 240 * zoom)

                    if let m = selected { detail(m) } else {
                        Text("Select a meeting").foregroundStyle(Theme.subtext0).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .panePadding()
        .onAppear {
            store.refreshMeetings()
            selection = selection ?? store.meetings.first?.id
            consumeRenameRequest()
        }
        .onChange(of: renameRequested) { consumeRenameRequest() }
        .onChange(of: selection) { renaming = false; renameError = nil }
    }

    private func consumeRenameRequest() {
        guard renameRequested else { return }
        renameRequested = false
        startRename()
    }

    private func startRename() {
        guard let m = selected else { return }
        draft = m.name ?? ""
        renameError = nil
        renaming = true
    }

    /// An empty name clears the title, so the list goes back to showing the date.
    /// A failed write keeps the field open with the error, so nothing claims a rename that didn't happen.
    private func commitRename(_ m: MeetingInfo) {
        do { try MeetingTitle.write(draft, to: m.dir) } catch {
            renameError = "Couldn't save the title: \(error.localizedDescription)"
            return
        }
        renaming = false
        renameError = nil
        _ = try? Meeting.render(dir: m.dir, title: m.title, store: store)
        store.refreshMeetings()
        actions.syncNow()
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform").zfont(28).foregroundStyle(Theme.overlay2)
            Text("No meetings yet").zfont(15, .semibold)
            Text("Record a call or an in-person meeting. Your mic and the call audio are kept apart, and each voice is recognized across meetings.")
                .foregroundStyle(Theme.subtext0).multilineTextAlignment(.center).frame(maxWidth: 380)
            Button(action: actions.toggleMeeting) { HStack { Text("Record meeting"); KeyChip("⌃⌥⌘M") } }
                .padding(.top, 4)
            Text("Recorded on a voice recorder? Import it with ⌘I.").zfont(11).foregroundStyle(Theme.overlay2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(_ m: MeetingInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if renaming {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Meeting title", text: $draft)
                            .textFieldStyle(.plain).zfont(15, .semibold)
                            .focused($titleFocused)
                            // Focused once it exists: setting focus in the same update that shows it doesn't stick.
                            .onAppear { titleFocused = true }
                            .onSubmit { commitRename(m) }
                            .onKeyPress(.escape) { renaming = false; renameError = nil; return .handled }
                        if let renameError { Text(renameError).zfont(11).foregroundStyle(Theme.red) }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.name ?? m.date?.formatted(date: .complete, time: .shortened) ?? m.title).zfont(15, .semibold)
                        if m.name != nil, let date = m.date {
                            Text(date.formatted(date: .complete, time: .shortened)).zfont(11).foregroundStyle(Theme.overlay2)
                        }
                    }
                }
                Spacer()
                Button { startRename() } label: { HStack(spacing: 4) { Text("Rename"); KeyChip("⌘R") } }
                    .keyboardShortcut("r", modifiers: .command)
                Button(m.transcript == nil ? "Transcribe" : "Re-transcribe") { actions.retranscribe(m) }
                    // Audio is retired 90 days after the meeting; the transcript stays.
                    .disabled(store.transcribingMeeting || !FileManager.default.fileExists(atPath: m.dir.appendingPathComponent("mic.m4a").path))
                Button { NSWorkspace.shared.activateFileViewerSelecting([m.dir]) } label: { Image(systemName: "folder") }
                    .help("Reveal in Finder")
                Button(role: .destructive) {
                    try? FileManager.default.trashItem(at: m.dir, resultingItemURL: nil)
                    actions.meetingDeleted(m)
                    selection = nil
                    store.refreshMeetings()
                } label: { Image(systemName: "trash") }
                    .help("Move to Trash")
            }
            ScrollView {
                let segments = self.segments(m)
                let speakers = segments.map(\.speaker).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                if segments.isEmpty {
                    Text(store.transcribingMeeting ? "Transcribing..." : "No transcript yet. The audio is saved, so you can transcribe it now.")
                        .foregroundStyle(Theme.subtext0).frame(maxWidth: .infinity, alignment: .leading).padding(18)
                } else {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(segments.indices, id: \.self) { i in
                            let s = segments[i]
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    speakerMenu(m, s, color: Self.colors[(speakers.firstIndex(of: s.speaker) ?? 0) % Self.colors.count])
                                    Text(clock(s.start)).zfont(11).monospacedDigit().foregroundStyle(Theme.overlay2)
                                }
                                Text(TextRules.apply(s.text, replacements: store.replacements)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(18)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.mantle, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// The same labels the transcript file uses: recognized names first, then channel defaults.
    /// Click a name to fix who said it: just this line (Scribe merged two voices), or this speaker
    /// everywhere in the meeting (the voice was matched to the wrong person).
    private func speakerMenu(_ m: MeetingInfo, _ s: Transcript.Segment, color: Color) -> some View {
        let lineFixed = Meeting.loadIDs(m.dir, "lines.json")[s.lineKey] != nil
        return Menu {
            Section("This line") {
                ForEach(people) { p in Button(label(p)) { fix(m) { try Meeting.assign(dir: m.dir, title: m.title, line: s.lineKey, to: p.id, store: store) } } }
                Button("New person") { let id = newPerson(); fix(m) { try Meeting.assign(dir: m.dir, title: m.title, line: s.lineKey, to: id, store: store) } }
                if lineFixed {
                    Button("Back to automatic") { fix(m) { try Meeting.assign(dir: m.dir, title: m.title, line: s.lineKey, to: nil, store: store) } }
                }
            }
            Section("Everywhere in this meeting") {
                ForEach(people) { p in
                    Button(label(p)) { fixAsync(m) { try await Meeting.assign(dir: m.dir, title: m.title, speaker: "\(s.channel):\(s.speakerID)", to: p.id, store: store) } }
                }
                Button("New person") {
                    let id = newPerson()
                    fixAsync(m) { try await Meeting.assign(dir: m.dir, title: m.title, speaker: "\(s.channel):\(s.speakerID)", to: id, store: store) }
                }
            }
        } label: {
            Text(s.speaker).zfont(12, .semibold).foregroundStyle(color)
                .underline(lineFixed, color: color.opacity(0.5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Wrong person? Click to fix who said this.")
    }

    private func label(_ p: Person) -> String { p.id == store.me?.id && p.displayName != "You" ? "\(p.displayName) (you)" : p.displayName }

    private func newPerson() -> UUID {
        let person = Person(number: (store.people.map(\.number).max() ?? 0) + 1, voice: [], samples: 0)
        store.people.append(person)
        return person.id
    }

    private func fix(_ m: MeetingInfo, _ change: () throws -> Void) {
        do { try change() } catch { NSLog("screamr: fixing a speaker failed, %@", error.localizedDescription) }
        edits += 1
        actions.syncNow()
    }

    private func fixAsync(_ m: MeetingInfo, _ change: @escaping () async throws -> Void) {
        Task { @MainActor in
            do { try await change() } catch { NSLog("screamr: fixing a speaker failed, %@", error.localizedDescription) }
            edits += 1
            actions.syncNow()
        }
    }

    private func segments(_ m: MeetingInfo) -> [Transcript.Segment] {
        _ = edits
        let mic = Meeting.loadWords(m.dir, "mic"), system = Meeting.loadWords(m.dir, "system")
        let names = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: m.dir.appendingPathComponent("names.json"))))
        return Transcript.tidied(Transcript.merged(mic: mic, system: system, labels: names ?? Transcript.labels(mic: mic, system: system)),
                                 me: Transcript.mySpans(in: m.dir))
    }

    private func clock(_ seconds: Double) -> String {
        let t = Int(seconds)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }
}

// MARK: People

private struct PeoplePane: View {
    @ObservedObject var store: Store

    /// Most frequent first, so the people worth naming are at the top.
    private var sorted: [Person] {
        store.people.sorted { ($0.meetings.count, $0.lastSeen) > ($1.meetings.count, $1.lastSeen) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: "People", blurb: "Recognized by voice across your meetings, entirely on this Mac. Name someone once and every transcript uses it.")
            if store.people.isEmpty {
                Text("People show up here after your next transcribed meeting.").foregroundStyle(Theme.subtext0)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(sorted) { p in
                            PersonRow(person: p, others: sorted.filter { $0.id != p.id },
                                      rename: { rename(p.id, to: $0) }, merge: { merge(p.id, into: $0) }, delete: { delete(p.id) },
                                      isMe: p.id == store.me?.id, markMe: { markMe(p.id) })
                        }
                    }
                }
            }
        }
        .panePadding()
    }

    private func rename(_ id: UUID, to name: String) {
        guard let i = store.people.firstIndex(where: { $0.id == id }), store.people[i].name != name else { return }
        store.people[i].name = name
        rerender(store.people[i].meetings)
    }

    private func merge(_ id: UUID, into target: UUID) {
        guard let s = store.people.firstIndex(where: { $0.id == id }), let t = store.people.firstIndex(where: { $0.id == target }) else { return }
        let source = store.people[s]
        PeopleMatcher.merge(source, into: &store.people[t])
        let meetings = store.people[t].meetings
        store.people.remove(at: s)
        rerender(meetings)
    }

    /// Which person is the user decides whose lines feed the speech metrics, in every meeting.
    private func markMe(_ id: UUID) {
        for i in store.people.indices { store.people[i].isMe = store.people[i].id == id ? true : false }
        rerender(store.meetings.map(\.dir.lastPathComponent))
    }

    private func delete(_ id: UUID) {
        guard let i = store.people.firstIndex(where: { $0.id == id }) else { return }
        let meetings = store.people[i].meetings
        store.people.remove(at: i)
        rerender(meetings)
    }

    /// Transcripts are rebuilt from saved words, so renames apply to past meetings at no Scribe cost.
    private func rerender(_ meetings: [String]) {
        for m in store.meetings where meetings.contains(m.dir.lastPathComponent) {
            _ = try? Meeting.render(dir: m.dir, title: m.title, store: store)
        }
    }
}

private struct PersonRow: View {
    let person: Person
    let others: [Person]
    let rename: (String) -> Void
    let merge: (UUID) -> Void
    let delete: () -> Void
    var isMe = false
    var markMe: () -> Void = {}
    @State private var draft = ""
    @FocusState private var editing: Bool
    // Computed, so a theme change is picked up: a stored static would keep the first theme's colors.
    private static var colors: [Color] { [Theme.mauve, Theme.blue, Theme.green, Theme.peach, Theme.pink, Theme.teal, Theme.yellow, Theme.lavender] }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(person.name.isEmpty ? "?" : String(person.name.prefix(1)).uppercased())
                .zfont(15, .bold)
                .frame(width: 36, height: 36)
                .background(Self.colors[person.number % Self.colors.count], in: Circle())
                .foregroundStyle(Theme.crust)
            VStack(alignment: .leading, spacing: 4) {
                TextField("", text: $draft, prompt: placeholder("\(person.displayName): who is this?"))
                    .textFieldStyle(.plain)
                    .zfont(13, .semibold)
                    .focused($editing)
                    .onSubmit { rename(draft.trimmingCharacters(in: .whitespaces)) }
                    .onChange(of: editing) { _, now in if !now { rename(draft.trimmingCharacters(in: .whitespaces)) } }
                HStack(spacing: 6) {
                    Text("\(person.meetings.count) meeting\(person.meetings.count == 1 ? "" : "s")")
                    Text("·")
                    Text("last heard ") + Text(person.lastSeen, format: .relative(presentation: .named))
                }
                .zfont(11).foregroundStyle(Theme.subtext0)
                if !person.quote.isEmpty {
                    Text("\u{201C}\(person.quote)\u{201D}").italic().zfont(11).foregroundStyle(Theme.overlay2).lineLimit(2)
                }
            }
            Spacer()
            if person.name.isEmpty && person.meetings.count >= 2 {
                Text("Appears often").zfont(11, .semibold)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.yellow.opacity(0.2), in: Capsule())
                    .foregroundStyle(Theme.yellow)
            }
            Menu("Merge into") {
                ForEach(others) { o in Button(o.displayName) { merge(o.id) } }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(others.isEmpty)
            .help("Same person split in two? Merge them.")
            Button(action: markMe) { Image(systemName: isMe ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle.badge.checkmark") }
                .buttonStyle(.plain)
                .foregroundStyle(isMe ? Theme.green : Theme.overlay1)
                .help(isMe ? "This is you: your lines feed the speech metrics" : "This is me")
                .disabled(isMe)
            Button { delete() } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(Theme.overlay1).help("Forget this person")
        }
        .padding(12)
        .background(Theme.mantle, in: RoundedRectangle(cornerRadius: 10))
        .onAppear { draft = person.name }
        .onChange(of: person.name) { _, name in if !editing { draft = name } }
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
    @State private var hovered: Item.ID?
    @Environment(\.zoom) private var zoom

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                PaneHeader(title: title, blurb: blurb)
                Spacer(minLength: 24)
                Button { add() } label: { HStack { Image(systemName: "plus"); Text("Add"); KeyChip("⌘N") } }
                    .keyboardShortcut("n", modifiers: .command)
            }
            if items.isEmpty {
                Text("Nothing here yet. Press ⌘N to add one.").foregroundStyle(Theme.subtext0)
                Spacer()
            } else {
                // One table, rows split by hairlines, instead of a stack of cards.
                VStack(spacing: 0) {
                    HStack {
                        Text(firstLabel).frame(width: 220 * zoom, alignment: .leading)
                        Text(secondLabel)
                        Spacer()
                    }
                    .zfont(11, .semibold).foregroundStyle(Theme.subtext0)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach($items) { $item in
                                Divider().overlay(Theme.surface0)
                                HStack(alignment: .top) {
                                    TextField("", text: $item[dynamicMember: first], prompt: placeholder(firstLabel))
                                        .focused($focused, equals: item.id)
                                        .frame(width: 220 * zoom)
                                    TextField("", text: $item[dynamicMember: second], prompt: placeholder(secondLabel), axis: .vertical)
                                    Button { items.removeAll { $0.id == item.id } } label: { Image(systemName: "trash") }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(hovered == item.id ? Theme.red : Theme.overlay1)
                                        .help("Remove")
                                }
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(hovered == item.id ? Theme.surface0.opacity(0.5) : .clear)
                                .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
                            }
                        }
                    }
                }
                .background(Theme.mantle, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .panePadding()
    }

    private func add() {
        let item = make()
        items.append(item)
        focused = item.id
    }
}

// MARK: Settings

private struct SettingsPane: View {
    @ObservedObject var store: Store
    let actions: DashboardActions
    @State private var syncURL = Store.syncConfig()?.url.absoluteString ?? ""
    @State private var syncToken = ""
    @State private var syncError: String?
    @State private var key = ""
    @State private var keyStatus = Store.apiKey() == nil ? "No key saved" : "Key saved"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var refresh = 0
    @AppStorage(Recorder.inputKey) private var input = ""
    @AppStorage(CorrectionWatcher.enabledKey) private var learnCorrections = true
    @AppStorage(Scribe.meetingVerbatimKey) private var meetingVerbatim = true
    @AppStorage(Scribe.dictationVerbatimKey) private var dictationVerbatim = false
    @AppStorage(Theme.key) private var theme = "mocha"
    @Environment(\.zoom) private var zoom

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PaneHeader(title: "Settings")
                group("Appearance") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150 * zoom), spacing: 10)], alignment: .leading, spacing: 10) {
                        ForEach(Theme.all, id: \.id) { p in
                            Button { theme = p.id } label: { ThemeSwatch(palette: p, selected: theme == p.id) }
                                .buttonStyle(.plain)
                                .help(p.name)
                        }
                    }
                    Text("Also in the command palette: \u{2318}K, then type \u{201C}theme\u{201D}.").zfont(11).foregroundStyle(Theme.subtext0)
                }
                group("ElevenLabs API key") {
                    HStack {
                        SecureField("", text: $key, prompt: placeholder("Paste a new key")).textFieldStyle(.plain)
                            .padding(8).background(Theme.surface0, in: RoundedRectangle(cornerRadius: 6))
                            .onSubmit(saveKey)
                        Button("Save", action: saveKey).disabled(key.isEmpty)
                    }
                    Text("\(keyStatus). Stored in ~/.config/screamr/api_key, readable only by you.").zfont(11).foregroundStyle(Theme.subtext0)
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
                group("Sync") {
                    HStack {
                        TextField("", text: $syncURL, prompt: placeholder("https://server.tailnet.ts.net:8796")).textFieldStyle(.plain)
                            .padding(8).background(Theme.surface0, in: RoundedRectangle(cornerRadius: 6))
                        SecureField("", text: $syncToken, prompt: placeholder(Store.syncConfig() == nil ? "Token" : "Token saved")).textFieldStyle(.plain)
                            .padding(8).background(Theme.surface0, in: RoundedRectangle(cornerRadius: 6))
                            .onSubmit(saveSync)
                        Button("Save", action: saveSync).disabled(syncURL.isEmpty)
                        Button("Sync now", action: actions.syncNow).disabled(Store.syncConfig() == nil)
                    }
                    Text(syncError ?? (store.syncStatus.isEmpty ? "Meetings sync with the iPhone app through your sync server." : store.syncStatus))
                        .zfont(11).foregroundStyle(syncError == nil ? Theme.subtext0 : Theme.red)
                }
                group("Microphone") {
                    let _ = refresh
                    let inputs = Recorder.inputs()
                    Picker("Input", selection: $input) {
                        Text("System default").tag("")
                        ForEach(inputs, id: \.id) { Text($0.name).tag($0.id) }
                        if !input.isEmpty, !inputs.contains(where: { $0.id == input }) {
                            Text("Disconnected mic (using system default)").tag(input)
                        }
                    }
                    .frame(maxWidth: 420)
                    Text("Used for dictation and meetings, from the next recording on.").zfont(11).foregroundStyle(Theme.subtext0)
                }
                group("Transcription") {
                    Toggle("Meetings: keep fillers and false starts (verbatim)", isOn: $meetingVerbatim)
                    Text("Keeps \u{201C}um\u{201D}, \u{201C}é\u{201D}, \u{201C}hum\u{201D} and restarts, which speech analysis measures. Each meeting saves the mode it used in meta.json; re-transcribing uses the current setting.")
                        .zfont(11).foregroundStyle(Theme.subtext0).fixedSize(horizontal: false, vertical: true)
                    Toggle("Dictation: keep fillers and false starts (verbatim)", isOn: $dictationVerbatim)
                    Text("Off by default, so pasted text comes out clean.")
                        .zfont(11).foregroundStyle(Theme.subtext0)
                }
                group("General") {
                    Toggle("Launch screamr at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, on in
                            // Also skips the change made by the rollback below, so a failure can't bounce the toggle.
                            guard on != (SMAppService.mainApp.status == .enabled) else { return }
                            do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister(); loginError = nil }
                            catch { loginError = error.localizedDescription; launchAtLogin = !on }
                        }
                    if let loginError { Text(loginError).zfont(11).foregroundStyle(Theme.red) }
                    Toggle("Learn words I correct after dictating", isOn: $learnCorrections)
                    Text("For 30 seconds after a paste, screamr reads the text field you dictated into. If you retype a misheard name or term, it's added to the Dictionary. The text stays on this Mac.")
                        .zfont(11).foregroundStyle(Theme.subtext0).fixedSize(horizontal: false, vertical: true)
                }
                group("Keyboard shortcuts") { ShortcutTable() }
            }
            .panePadding()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh += 1 }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).zfont(13, .semibold).foregroundStyle(Theme.lavender)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.mantle, in: RoundedRectangle(cornerRadius: 10))
    }

    /// `granted` nil means unknown or not asked yet. With `request`, the button asks macOS directly.
    private func permission(_ name: String, detail: String, granted: Bool?, pane: String, request: (() -> Void)? = nil) -> some View {
        HStack {
            Image(systemName: granted == true ? "checkmark.circle.fill" : granted == false ? "xmark.circle.fill" : "questionmark.circle")
                .foregroundStyle(granted == true ? Theme.green : granted == false ? Theme.red : Theme.subtext0)
            VStack(alignment: .leading) {
                Text(name)
                Text(detail).zfont(11).foregroundStyle(Theme.subtext0)
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

    private func saveSync() {
        guard let url = URL(string: syncURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
            syncError = "Enter the server URL, including https://"
            return
        }
        let token = syncToken.isEmpty ? Store.syncConfig()?.token ?? "" : syncToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { syncError = "Enter the token"; return }
        do {
            try Store.saveSyncConfig(.init(url: url, token: token))
            syncToken = ""
            syncError = nil
            actions.syncNow()
        } catch {
            syncError = "Could not save: \(error.localizedDescription)"
        }
    }

    private func saveKey() {
        guard !key.isEmpty else { return }
        do { try Store.saveAPIKey(key); key = ""; keyStatus = "Key saved" } catch { keyStatus = "Could not save: \(error.localizedDescription)" }
    }
}

/// A theme drawn in its own colors, so the choice is visible before picking it.
private struct ThemeSwatch: View {
    let palette: Palette
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                // By position: palettes can repeat a color.
                ForEach(Array([palette.mauve, palette.blue, palette.green, palette.yellow, palette.red].enumerated()), id: \.offset) { _, hex in
                    Circle().fill(Color(hex: hex)).frame(width: 10, height: 10)
                        .shadow(color: palette.glows ? Color(hex: hex).opacity(0.9) : .clear, radius: 4)
                }
            }
            Text(palette.name).zfont(12, .medium).foregroundStyle(Color(hex: palette.text)).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: palette.base), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.mauve : Color(hex: palette.surface1), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
    }
}

private struct ShortcutTable: View {
    var body: some View {
        Grid(alignment: .leading, verticalSpacing: 8) {
            ForEach(shortcutList, id: \.action) { s in
                GridRow {
                    KeyChip(s.keys)
                    Text(s.action).foregroundStyle(Theme.subtext0)
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
            Divider().overlay(Theme.surface1)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { i, c in
                        HStack {
                            Text(c.title)
                            Spacer()
                            if !c.hint.isEmpty { KeyChip(c.hint) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(i == index ? Theme.surface0 : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { index = i; runSelected() }
                    }
                }
                .padding(8)
            }
            .frame(height: 280)
        }
        .frame(width: 520 * zoom)
        .background(Theme.mantle)
        .foregroundStyle(Theme.text)
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
            Text("Keyboard shortcuts").zfont(17, .bold).foregroundStyle(Theme.mauve)
            ShortcutTable()
            HStack { Spacer(); Button("Close", action: dismiss).keyboardShortcut(.cancelAction) }
        }
        .padding(24)
        .frame(width: 440 * zoom)
        .background(Theme.mantle)
        .foregroundStyle(Theme.text)
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
            w.backgroundColor = NSColor(Theme.base)
            w.minSize = NSSize(width: 820, height: 520)
            let host = NSHostingView(rootView: Dashboard(store: store, actions: actions))
            // The window keeps the size the user gives it; long transcripts scroll instead of growing it.
            host.sizingOptions = []
            w.contentView = host
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
