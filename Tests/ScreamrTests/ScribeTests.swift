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
