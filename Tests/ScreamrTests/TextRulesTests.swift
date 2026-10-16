import Testing
@testable import Screamr

@Test func replacesWholeWordsCaseInsensitively() {
    let out = TextRules.apply("Testing Screamer meetings, not screamers.", replacements: [("screamer", "screamr")])
    #expect(out == "Testing screamr meetings, not screamers.")
}

@Test func longestPhraseWinsAndExpansionsAreNotReplacedAgain() {
    let out = TextRules.apply("ship it to my email today", replacements: [("email", "mail"), ("my email", "me@example.com")])
    #expect(out == "ship it to me@example.com today")
}

@Test func snippetTriggerAloneBecomesExpansion() {
    let snippets = [(trigger: "my address", expansion: "Rua X, 123\nSao Paulo")]
    #expect(TextRules.apply("My address.", replacements: [], snippets: snippets) == "Rua X, 123\nSao Paulo")
    #expect(TextRules.apply("Send it to my address please.", replacements: [], snippets: snippets) == "Send it to Rua X, 123\nSao Paulo please.")
}

@Test func emptyRulesLeaveTextAlone() {
    #expect(TextRules.apply("Hello.", replacements: [("", "x")]) == "Hello.")
}

@Test func statementsGetAFinalPeriodButSingleWordsDoNot() {
    #expect(TextRules.endSentence("Now I want something else") == "Now I want something else.")
    #expect(TextRules.endSentence("Estamos quase lá?") == "Estamos quase lá?")
    #expect(TextRules.endSentence("Scheiße!") == "Scheiße!")
    #expect(TextRules.endSentence("Version 2") == "Version 2.")
    #expect(TextRules.endSentence("Kinebot") == "Kinebot")
    #expect(TextRules.endSentence("") == "")
}

@Test func spokenCommandsScribeLeavesAsWordsBecomeSymbols() {
    #expect(TextRules.spokenPunctuation("what happens. New line. Does it work?") == "what happens.\nDoes it work?")
    #expect(TextRules.spokenPunctuation("pears! New paragraph. Second part") == "pears!\n\nSecond part")
    #expect(TextRules.spokenPunctuation("Segunda parte nova linha. Terceira linha") == "Segunda parte\nTerceira linha")
    #expect(TextRules.spokenPunctuation("maçã ponto e vírgula pera ponto de exclamação") == "maçã; pera!")
    #expect(TextRules.spokenPunctuation("Ganhamos dois pontos hoje") == "Ganhamos dois pontos hoje")
    #expect(TextRules.endSentence(TextRules.spokenPunctuation("first line, new line")) == "first line\n")
}
