import AVFoundation
import SwiftUI

@main
struct ScreamrApp: App {
    @State private var library = Library()
    @State private var recorder = MeetingRecorder()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(library)
                .environment(recorder)
                .tint(Mocha.mauve)
                .preferredColorScheme(.dark)
        }
    }
}

struct HomeView: View {
    @Environment(Library.self) private var library
    @Environment(MeetingRecorder.self) private var recorder
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(library.meetings) { m in
                    NavigationLink(value: m) { MeetingRow(meeting: m) }
                        .listRowBackground(Mocha.surface0)
                        .deleteDisabled(m == recorder.folder)
                }
                .onDelete { $0.map { library.meetings[$0] }.forEach(library.delete) }
            }
            .scrollContentBackground(.hidden)
            .background(Mocha.base)
            .refreshable { await sync() }
            .overlay {
                if library.meetings.isEmpty {
                    ContentUnavailableView("No meetings yet", systemImage: "waveform",
                                           description: Text("Tap record when the meeting starts. Recording continues with the screen locked."))
                }
            }
            .navigationTitle("screamr")
            .navigationDestination(for: MeetingFolder.self) { MeetingView(meeting: $0) }
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .keyboardShortcut(",", modifiers: .command)
            }
            .safeAreaInset(edge: .bottom) { recordBar }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert("screamr", isPresented: .constant(error != nil)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .onAppear { if Keychain.apiKey == nil { showSettings = true } }
        // iOS doesn't let the app sync in the background, so it catches up whenever it's opened.
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await sync() } } }
    }

    private func sync() async {
        await library.syncNow(skip: Set([recorder.folder?.dir.lastPathComponent].compactMap { $0 }))
    }

    private var recordBar: some View {
        VStack(spacing: 10) {
            if recorder.folder != nil {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    HStack(spacing: 10) {
                        Circle().fill(Mocha.red).frame(width: 8, height: 8)
                        Text(clock(recorder.elapsed)).monospacedDigit().foregroundStyle(Mocha.text)
                        Capsule().fill(Mocha.surface0)
                            .overlay(alignment: .leading) {
                                GeometryReader { g in Capsule().fill(Mocha.green).frame(width: g.size.width * CGFloat(recorder.level)) }
                            }
                            .frame(width: 120, height: 6)
                    }
                }
            }
            Button(action: toggle) {
                Image(systemName: recorder.folder == nil ? "mic.fill" : "stop.fill")
                    .font(.title)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(recorder.folder == nil ? Mocha.mauve : Mocha.red))
                    .foregroundStyle(Mocha.crust)
            }
            .accessibilityLabel(recorder.folder == nil ? "Start recording" : "Stop recording")
            .keyboardShortcut("r", modifiers: .command)
            .sensoryFeedback(.impact, trigger: recorder.folder)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Mocha.mantle)
    }

    private func toggle() {
        if let done = recorder.stop() {
            library.refresh()
            Task { await library.transcribe(done) }
            return
        }
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                error = "Allow microphone access for screamr in Settings."
                return
            }
            do {
                try recorder.start(in: library.newFolder())
                library.refresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct MeetingRow: View {
    @Environment(Library.self) private var library
    @Environment(MeetingRecorder.self) private var recorder
    let meeting: MeetingFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title).foregroundStyle(Mocha.text)
            Group {
                if meeting == recorder.folder {
                    Label("Recording", systemImage: "record.circle").foregroundStyle(Mocha.red)
                } else if library.transcribing.contains(meeting.dir) {
                    Label("Transcribing", systemImage: "ellipsis").foregroundStyle(Mocha.yellow)
                } else if library.errors[meeting.dir] != nil {
                    Label("Transcription failed", systemImage: "exclamationmark.triangle").foregroundStyle(Mocha.red)
                } else if let first = meeting.segments.first {
                    Text(first.text).lineLimit(2).foregroundStyle(Mocha.subtext0)
                } else {
                    Text(meeting.isTranscribed ? "No speech detected" : "Not transcribed").foregroundStyle(Mocha.overlay0)
                }
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
    }
}

struct MeetingView: View {
    @Environment(Library.self) private var library
    @Environment(MeetingRecorder.self) private var recorder
    let meeting: MeetingFolder

    private static let colors = [Mocha.mauve, Mocha.peach, Mocha.teal, Mocha.pink, Mocha.blue, Mocha.yellow, Mocha.green, Mocha.lavender]

    var body: some View {
        let segments = library.transcribing.contains(meeting.dir) ? [] : meeting.segments
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(segments.indices, id: \.self) { i in
                    let s = segments[i]
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(s.speaker).bold().foregroundStyle(color(s.speakerID))
                            Text(clock(s.start)).monospacedDigit().foregroundStyle(Mocha.overlay0)
                        }
                        .font(.subheadline)
                        Text(s.text).foregroundStyle(Mocha.text).textSelection(.enabled)
                    }
                }
            }
            .padding()
        }
        .background(Mocha.base)
        .overlay { if segments.isEmpty { status } }
        .navigationTitle(meeting.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if meeting.isTranscribed {
                ShareLink(item: meeting.transcript)
            }
        }
    }

    @ViewBuilder private var status: some View {
        if meeting == recorder.folder {
            ContentUnavailableView("Recording", systemImage: "record.circle", description: Text("The transcript appears here after you stop."))
        } else if library.transcribing.contains(meeting.dir) {
            ProgressView("Transcribing").tint(Mocha.mauve)
        } else if meeting.isTranscribed {
            ContentUnavailableView("No speech detected", systemImage: "waveform.slash")
        } else if !meeting.hasAudio {
            ContentUnavailableView("Transcript not synced yet", systemImage: "arrow.triangle.2.circlepath",
                                   description: Text("This meeting was recorded on the Mac. Its transcript arrives once the Mac transcribes it."))
        } else {
            ContentUnavailableView {
                Label(library.errors[meeting.dir] == nil ? "Not transcribed" : "Transcription failed", systemImage: "waveform")
            } description: {
                Text(library.errors[meeting.dir] ?? "The recording is saved. Transcribe it when you're online.")
            } actions: {
                Button("Transcribe") { Task { await library.transcribe(meeting) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private func color(_ speakerID: String) -> Color {
        Self.colors[(Int(speakerID.split(separator: "_").last ?? "") ?? 0) % Self.colors.count]
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    @State private var key = Keychain.apiKey ?? ""
    @State private var syncURL = UserDefaults.standard.string(forKey: "syncURL") ?? ""
    @State private var syncToken = Keychain.syncToken ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("API key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(save)
                } header: {
                    Text("ElevenLabs")
                } footer: {
                    Text("Stored in the iOS Keychain. Scribe bills about 18 credits per minute of recording.")
                }
                .listRowBackground(Mocha.surface0)
                Section {
                    TextField("Server URL", text: $syncURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Token", text: $syncToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(save)
                } header: {
                    Text("Sync")
                } footer: {
                    Text(library.syncStatus.isEmpty ? "Meetings sync with the Mac through your sync server, over Tailscale." : library.syncStatus)
                }
                .listRowBackground(Mocha.surface0)
            }
            .scrollContentBackground(.hidden)
            .background(Mocha.base)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done", action: save).keyboardShortcut(.defaultAction) }
        }
    }

    private func save() {
        Keychain.apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(syncURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "syncURL")
        Keychain.syncToken = syncToken.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await library.syncNow() }
        dismiss()
    }
}

private func clock(_ seconds: TimeInterval) -> String {
    let t = Int(seconds)
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
}
