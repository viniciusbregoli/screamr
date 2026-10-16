import Foundation

/// Client-side dictionary replacements and snippet expansion, applied after Scribe returns.
/// Same approach as Wispr's findAndReplaceDictionaryWords: one case-insensitive, word-bounded
/// regex over all phrases, longest first, in a single pass so an expansion is never re-matched.
enum TextRules {
    static func apply(_ text: String, replacements: [(from: String, to: String)], snippets: [(trigger: String, expansion: String)] = []) -> String {
        // A dictation that is only a snippet trigger becomes the expansion, dropping Scribe's punctuation.
        let bare = text.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)).lowercased()
        if let hit = snippets.first(where: { $0.trigger.lowercased() == bare }) { return hit.expansion }

        let rules = (replacements + snippets.map { ($0.trigger, $0.expansion) })
            .map { (from: $0.0.trimmingCharacters(in: .whitespaces), to: $0.1) }
            .filter { !$0.from.isEmpty }
        guard !rules.isEmpty else { return text }
        let lookup = Dictionary(rules.map { ($0.from.lowercased(), $0.to) }, uniquingKeysWith: { first, _ in first })
        let pattern = rules.map(\.from).sorted { $0.count > $1.count }
            .map { "\\b" + NSRegularExpression.escapedPattern(for: $0) + "\\b" }
            .joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .useUnicodeWordBoundaries]) else { return text }

        var out = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: out), let to = lookup[out[range].lowercased()] else { continue }
            out.replaceSubrange(range, with: to)
        }
        return out
    }
}
