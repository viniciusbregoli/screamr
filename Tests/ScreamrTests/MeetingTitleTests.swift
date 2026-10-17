import Foundation
import Testing
@testable import Screamr

@Test func titlesAreOneTrimmedLineOfAtMost120Characters() {
    #expect(MeetingTitle.clean("  Planejamento\nsprint 42  ") == "Planejamento sprint 42")
    #expect(MeetingTitle.clean(String(repeating: "é", count: 130)).count == 120)
    #expect(MeetingTitle.clean("   ") == "")
}

@Test func anEmptyTitleFileMeansNoTitle() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(MeetingTitle.read(dir) == nil)
    try MeetingTitle.write(" Retro \n", to: dir)
    #expect(MeetingTitle.read(dir) == "Retro")
    // Cleared by writing an empty file, which still syncs, rather than deleting it.
    try MeetingTitle.write("", to: dir)
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(MeetingTitle.file).path))
    #expect(MeetingTitle.read(dir) == nil)
}
