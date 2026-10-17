import CryptoKit
import Foundation

/// Two-way sync of meeting folders through the screamr sync server (server/server.mjs), shared by Mac and iPhone.
/// A meeting is a record listing its files by SHA-256; the files themselves are uploaded once as blobs.
/// Each file merges three ways against the last synced version: a local change is pushed, a remote change
/// is downloaded, and files are never removed except by deleting the whole meeting.
actor SyncEngine {
    struct Config: Codable, Equatable {
        var url: URL
        var token: String
    }

    struct SyncError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// File name to SHA-256.
    typealias Manifest = [String: String]

    struct State: Codable {
        var cursor = 0
        /// What each meeting looked like after the last sync, on this device and on the server.
        var base: [String: Manifest] = [:]
        var pendingDeletes: Set<String> = []
    }

    struct Record: Codable {
        var kind: String
        var id: String
        var body: String
        var updated: Double
        var deleted: Bool
    }

    private struct Changes: Decodable {
        let records: [Record]
        let cursor: Int
    }

    let root: URL
    let stateFile: URL
    /// Which files this device downloads: the iPhone skips audio it can't use.
    let wants: @Sendable (String) -> Bool

    init(root: URL, stateFile: URL, wants: @escaping @Sendable (String) -> Bool = { _ in true }) {
        self.root = root
        self.stateFile = stateFile
        self.wants = wants
    }

    /// Deletes the meeting everywhere on the next sync.
    func markDeleted(_ id: String) {
        var state = load()
        state.pendingDeletes.insert(id)
        state.base[id] = nil
        save(state)
    }

    /// Pulls, merges and pushes every meeting except `skip` (still recording or transcribing).
    /// Returns each meeting folder that received files, with the names of those files.
    func run(_ config: Config, skip: Set<String> = []) async throws -> [(dir: URL, files: [String])] {
        var state = load()
        var changes = try await changes(config, since: state.cursor)
        // A server restored from backup is behind this device; re-read everything; merging is idempotent.
        if changes.cursor < state.cursor { changes = try await self.changes(config, since: 0) }

        var remote: [String: Manifest] = [:]
        var deletedRemotely: Set<String> = []
        for r in changes.records where r.kind == "meeting" {
            if r.deleted { deletedRemotely.insert(r.id) } else { remote[r.id] = try JSONDecoder().decode(Manifest.self, from: Data(r.body.utf8)) }
        }
        for id in deletedRemotely where !skip.contains(id) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(id, isDirectory: true))
            state.base[id] = nil
        }

        let now = Date().timeIntervalSince1970
        var outgoing = state.pendingDeletes.map { Record(kind: "meeting", id: $0, body: "{}", updated: now, deleted: true) }
        var received: [(dir: URL, files: [String])] = []
        let local = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }
            .map(\.lastPathComponent)
        let ids = Set(local).union(remote.keys).subtracting(skip).subtracting(deletedRemotely).subtracting(state.pendingDeletes)

        for id in ids.sorted() {
            let dir = root.appendingPathComponent(id, isDirectory: true)
            let base = state.base[id] ?? [:]
            let theirs = remote[id] ?? base
            let mine = try manifest(dir)
            let (merged, download) = Self.merge(base: base, local: mine, remote: theirs, wants: wants)
            if !download.isEmpty {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for name in download { try await fetch(config, hash: theirs[name]!, to: dir.appendingPathComponent(name)) }
                received.append((dir, download))
            }
            if merged != theirs {
                for (name, hash) in merged where theirs[name] != hash && mine[name] == hash {
                    try await upload(config, dir.appendingPathComponent(name), hash: hash)
                }
                let body = String(decoding: try JSONEncoder().encode(merged), as: UTF8.self)
                outgoing.append(Record(kind: "meeting", id: id, body: body, updated: now, deleted: false))
            }
            state.base[id] = merged
        }

        if !outgoing.isEmpty {
            var req = request(config, "POST", config.url.appendingPathComponent("records"))
            req.httpBody = try JSONEncoder().encode(outgoing)
            _ = try await send(config, req)
        }
        state.pendingDeletes = []
        // Our own writes come back next time as no-ops, since they already match `base`.
        state.cursor = changes.cursor
        save(state)
        return received
    }

    private func changes(_ config: Config, since cursor: Int) async throws -> Changes {
        var components = URLComponents(url: config.url.appendingPathComponent("changes"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "since", value: String(cursor))]
        return try JSONDecoder().decode(Changes.self, from: try await send(config, request(config, "GET", components.url!)))
    }

    /// Three-way merge of one meeting's files. A file changed or added here wins and gets pushed;
    /// otherwise a file that differs on the server (or is missing here) is downloaded, if wanted.
    static func merge(base: Manifest, local: Manifest, remote: Manifest, wants: (String) -> Bool) -> (merged: Manifest, download: [String]) {
        var merged = remote
        var download: [String] = []
        for name in Set(base.keys).union(local.keys).union(remote.keys).sorted() {
            if let mine = local[name], mine != base[name] {
                merged[name] = mine
            } else if let theirs = remote[name], theirs != local[name], wants(name) {
                download.append(name)
            }
        }
        return (merged, download)
    }

    static func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // ponytail: hashes every file on every run; cache by size and mtime if long meeting libraries make sync slow.
    private func manifest(_ dir: URL) throws -> Manifest {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [:] }
        var out: Manifest = [:]
        for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
        where !url.lastPathComponent.hasPrefix(".") && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            out[url.lastPathComponent] = try Self.sha256(url)
        }
        return out
    }

    private func upload(_ config: Config, _ file: URL, hash: String) async throws {
        let blob = config.url.appendingPathComponent("blobs/\(hash)")
        var head = request(config, "HEAD", blob)
        head.timeoutInterval = 30
        let (_, resp) = try await URLSession.shared.data(for: head)
        if (resp as? HTTPURLResponse)?.statusCode == 200 { return }
        var put = request(config, "PUT", blob)
        put.timeoutInterval = 900
        let (data, putResp) = try await URLSession.shared.upload(for: put, fromFile: file)
        try check(putResp, data)
    }

    private func fetch(_ config: Config, hash: String, to target: URL) async throws {
        var req = request(config, "GET", config.url.appendingPathComponent("blobs/\(hash)"))
        req.timeoutInterval = 900
        let (temp, resp) = try await URLSession.shared.download(for: req)
        try check(resp, nil)
        guard try Self.sha256(temp) == hash else { throw SyncError(message: "Downloaded \(target.lastPathComponent) does not match its hash") }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
    }

    private func request(_ config: Config, _ method: String, _ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        return req
    }

    private func send(_ config: Config, _ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        return data
    }

    private func check(_ resp: URLResponse, _ data: Data?) throws {
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SyncError(message: "Sync server HTTP \(status): \(String(decoding: (data ?? Data()).prefix(200), as: UTF8.self))")
        }
    }

    private func load() -> State {
        (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateFile))) ?? State()
    }

    private func save(_ state: State) {
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
    }
}
