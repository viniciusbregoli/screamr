import Testing
@testable import Screamr

private func all(_: String) -> Bool { true }

@Test func localChangesWinAndRemoteChangesDownload() {
    let base = ["mic.m4a": "a1", "transcript.md": "t1"]
    let local = ["mic.m4a": "a1", "transcript.md": "t1", "mic.words.json": "w1"] // transcribed here
    let remote = ["mic.m4a": "a1", "transcript.md": "t2", "names.json": "n1"] // renamed on the other device
    let r = SyncEngine.merge(base: base, local: local, remote: remote, wants: all)
    #expect(r.merged == ["mic.m4a": "a1", "transcript.md": "t2", "names.json": "n1", "mic.words.json": "w1"])
    #expect(r.download == ["names.json", "transcript.md"])
}

@Test func bothSidesChangedKeepsThisDevicesFile() {
    let r = SyncEngine.merge(base: ["transcript.md": "t1"], local: ["transcript.md": "mine"], remote: ["transcript.md": "theirs"], wants: all)
    #expect(r.merged == ["transcript.md": "mine"])
    #expect(r.download.isEmpty)
}

@Test func unwantedFilesStayListedButAreNeverDownloadedOrDropped() {
    let noAudio: (String) -> Bool = { !$0.hasSuffix(".m4a") }
    let remote = ["mic.m4a": "a1", "mic.words.json": "w1"]
    let first = SyncEngine.merge(base: [:], local: [:], remote: remote, wants: noAudio)
    #expect(first.download == ["mic.words.json"])
    #expect(first.merged == remote)
    // Next run: audio still absent locally, which must not read as a local change.
    let next = SyncEngine.merge(base: first.merged, local: ["mic.words.json": "w1"], remote: first.merged, wants: noAudio)
    #expect(next.merged == remote)
    #expect(next.download.isEmpty)
}

@Test func missingLocalFileIsRestoredFromServer() {
    let r = SyncEngine.merge(base: ["a": "1"], local: [:], remote: ["a": "1"], wants: all)
    #expect(r.download == ["a"])
    #expect(r.merged == ["a": "1"])
}

@Test func retiredAudioWinsOverALocalCopyWhichGetsDeleted() {
    let r = SyncEngine.merge(base: ["mic.m4a": "a1"], local: ["mic.m4a": "a1", "mic.words.json": "w1"],
                             remote: ["mic.m4a": SyncEngine.retired, "mic.words.json": "w1"], wants: all)
    #expect(r.merged["mic.m4a"] == SyncEngine.retired)
    #expect(r.delete == ["mic.m4a"])
    #expect(r.download.isEmpty)
}

@Test func retiredStaysRetiredEvenIfTheServerHasTheFileAgain() {
    // e.g. the server restored from a backup older than the retirement: never download it again.
    let r = SyncEngine.merge(base: ["mic.m4a": SyncEngine.retired], local: [:], remote: ["mic.m4a": "a1"], wants: all)
    #expect(r.merged["mic.m4a"] == SyncEngine.retired)
    #expect(r.download.isEmpty)
    #expect(r.delete.isEmpty)
}

@Test func aDeviceOfflinePastRetentionDeletesItsAudioAndNeverReuploads() {
    // Offline for months: it still has the audio and last saw a hash; the server has since retired it.
    let r = SyncEngine.merge(base: ["system.m4a": "s1"], local: ["system.m4a": "s1"], remote: ["system.m4a": SyncEngine.retired], wants: all)
    #expect(r.delete == ["system.m4a"])
    #expect(r.merged == ["system.m4a": SyncEngine.retired])
    // And after deleting, the next run sees nothing to push or fetch.
    let next = SyncEngine.merge(base: r.merged, local: [:], remote: r.merged, wants: all)
    #expect(next.merged == r.merged && next.download.isEmpty && next.delete.isEmpty)
}
