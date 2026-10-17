import Foundation
import Testing
@testable import Screamr

@Test func misdetectedLanguagesFallBackToEnglishOrPortuguese() {
    #expect(Scribe.fallbackLanguage(detected: "eng") == nil)
    #expect(Scribe.fallbackLanguage(detected: "por") == nil)
    #expect(Scribe.fallbackLanguage(detected: nil) == nil)
    #expect(Scribe.fallbackLanguage(detected: "spa") == "por")
    #expect(Scribe.fallbackLanguage(detected: "glg") == "por")
    #expect(Scribe.fallbackLanguage(detected: "deu") == "eng")
}

@Test func verbatimOnlyFlipsNoVerbatim() {
    let fields = { (verbatim: Bool) in Dictionary(uniqueKeysWithValues: Scribe.formFields(verbatim: verbatim)) }
    #expect(fields(true)["no_verbatim"] == "false")
    #expect(fields(false)["no_verbatim"] == "true")
    #expect(fields(true)["model_id"] == Scribe.model)
}

@Test func metaRecordsModeModelAndLanguages() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Scribe.Meta(verbatim: true, languages: ["mic": "por", "system": "eng"], at: Date(timeIntervalSince1970: 0)).write(to: dir)
    let json = try String(contentsOf: dir.appendingPathComponent("meta.json"), encoding: .utf8)
    #expect(json.contains("\"transcription_mode\" : \"verbatim\""))
    #expect(json.contains("\"model_id\" : \"scribe_v2\""))
    #expect(json.contains("\"transcribed_at\" : \"1970-01-01T00:00:00Z\""))
    #expect(json.contains("\"mic\" : \"por\""))
    #expect(json.contains("\"source\" : \"mac\""))
}
