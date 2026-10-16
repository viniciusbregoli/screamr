import Foundation

/// Client-side dictionary replacements and snippet expansion, applied after Scribe returns.
/// Same approach as Wispr's findAndReplaceDictionaryWords: one case-insensitive, word-bounded
/// regex over all phrases, longest first, in a single pass so an expansion is never re-matched.
enum TextRules {
    static func apply(_ text: String, replacements: [(from: String, to: String)], snippets: [(trigger: String, expansion: String)] = []) -> String {
        // A dictation that is only a snippet trigger becomes the expansion, dropping Scribe's punctuation.
        let bare = text.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)).lowercased()
        if !bare.isEmpty, let hit = snippets.first(where: { $0.trigger.lowercased() == bare }) { return hit.expansion }

        let rules = (replacements + snippets.map { ($0.trigger, $0.expansion) })
            .map { (from: $0.0.trimmingCharacters(in: .whitespaces), to: $0.1) }
            .filter { !$0.from.isEmpty }
        guard !rules.isEmpty else { return text }
        let lookup = Dictionary(rules.map { ($0.from.lowercased(), $0.to) }, uniquingKeysWith: { first, _ in first })
        let pattern = rules.map(\.from).sorted { $0.count > $1.count }
            // Lookarounds instead of \b, so phrases ending in a symbol ("C++") still match before a space.
            .map { "(?<!\\w)" + NSRegularExpression.escapedPattern(for: $0) + "(?!\\w)" }
            .joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .useUnicodeWordBoundaries]) else { return text }

        var out = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: out), let to = lookup[out[range].lowercased()] else { continue }
            out.replaceSubrange(range, with: to)
        }
        return out
    }

    /// Scribe keeps ? and ! but drops the final period on statements, so back-to-back takes run together.
    /// Single words are left bare: they're usually names or search terms, not sentences.
    static func endSentence(_ text: String) -> String {
        guard let last = text.last, last.isLetter || last.isNumber, text.split(separator: " ").count > 1 else { return text }
        return text + "."
    }

    /// Spoken commands Scribe leaves as words. It already turns "comma", "period", "question mark",
    /// "vírgula" and "ponto final" into symbols on its own, and tells them apart from the plain words.
    /// "dois pontos" is left to Scribe too, since "ganhamos dois pontos" is just as likely.
    static let commands: [(words: [String], symbol: String)] = [
        (["new paragraph", "novo parágrafo"], "\n\n"),
        (["new line", "nova linha"], "\n"),
        (["semicolon", "ponto e vírgula"], ";"),
        (["colon"], ":"),
        (["exclamation mark", "exclamation point", "ponto de exclamação"], "!"),
        (["question mark", "ponto de interrogação"], "?"),
    ]

    /// Replaces spoken commands with their symbol, eating the comma or period Scribe tends to put around them.
    static func spokenPunctuation(_ text: String) -> String {
        var out = text
        for (words, symbol) in commands {
            let names = words.map(NSRegularExpression.escapedPattern).joined(separator: "|")
            // Line breaks swallow the space after them; symbols keep it so the next word stays separated.
            let after = symbol.hasPrefix("\n") ? "[.,]?\\s*" : "[.,]?"
            guard let regex = try? NSRegularExpression(pattern: ",?\\s*\\b(?:\(names))\\b" + after, options: [.caseInsensitive, .useUnicodeWordBoundaries]) else { continue }
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: NSRegularExpression.escapedTemplate(for: symbol))
        }
        return out
    }
}
