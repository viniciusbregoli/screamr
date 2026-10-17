import Testing
@testable import Screamr

private func known(_ word: String) -> Bool {
    ["the", "meeting", "call", "about", "app", "screamer", "kind", "of", "bot", "their", "there", "is", "at", "we", "ship"].contains(word.lowercased())
}

@Test func findsTheWordsSwappedInsideTheDictation() {
    let dictated = "We ship Screamer on Friday."
    let before = "Notes: We ship Screamer on Friday. "
    #expect(Corrections.correction(before: before, after: "Notes: We ship screamr on Friday. ", dictated: dictated)! == ("Screamer", "screamr"))
    // Deleting two letters mid-word still reports the whole word.
    #expect(Corrections.correction(before: before, after: "Notes: We ship Screamr on Friday. ", dictated: dictated)! == ("Screamer", "Screamr"))
    // Two words heard for one.
    #expect(Corrections.correction(before: "Ask kind of bot about it ", after: "Ask Kinebot about it ", dictated: "Ask kind of bot about it")! == ("kind of bot", "Kinebot"))
}

@Test func ignoresEditsOutsideTheDictationOrTooLarge() {
    let dictated = "We ship Screamer on Friday."
    #expect(Corrections.correction(before: "Notes: We ship Screamer on Friday.", after: "Note: We ship Screamer on Friday.", dictated: dictated) == nil)
    #expect(Corrections.correction(before: "We ship Screamer on Friday.", after: "Totally different text now", dictated: dictated) == nil)
    #expect(Corrections.correction(before: "We ship Screamer on Friday.", after: "We ship Screamer on Friday.", dictated: dictated) == nil)
    #expect(Corrections.correction(before: "We ship Screamer on Friday.", after: "We ship screamer on Friday.", dictated: dictated) == nil) // case only
}

@Test func learnsMishearingsOfUnknownWordsOnly() {
    #expect(Corrections.isVocabulary(wrong: "Screamer", right: "screamr", isKnown: known))
    #expect(Corrections.isVocabulary(wrong: "kind of bot", right: "Kinebot", isKnown: known))
    #expect(!Corrections.isVocabulary(wrong: "their", right: "there", isKnown: known)) // both real words
    #expect(!Corrections.isVocabulary(wrong: "meeting", right: "Kinebot", isKnown: known)) // a rewrite, not a mishearing
}
