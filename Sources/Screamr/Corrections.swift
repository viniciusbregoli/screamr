import AppKit
import ApplicationServices

/// Learns dictionary entries from fixes the user types right after a dictation, as Wispr does.
/// Wispr asks a server-side model which edited words are vocabulary; here two local checks decide:
/// the new spelling is a word the spell checker doesn't know (a name, jargon), and it sounds close
/// enough to what Scribe wrote that it's a mishearing, not a rewrite.
enum Corrections {
    /// The words the user replaced inside the dictated text, if the edit is a single small swap.
    static func correction(before: String, after: String, dictated: String) -> (wrong: String, right: String)? {
        let dictated = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dictated.isEmpty, before != after, let span = before.range(of: dictated, options: .backwards) else { return nil }
        let b = Array(before), a = Array(after)
        var prefix = 0
        while prefix < b.count, prefix < a.count, b[prefix] == a[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < b.count - prefix, suffix < a.count - prefix, b[b.count - 1 - suffix] == a[a.count - 1 - suffix] { suffix += 1 }

        // Widen the changed span to whole words on both sides.
        let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "-" }
        var start = prefix
        while start > 0, isWord(b[start - 1]) { start -= 1 }
        var endB = b.count - suffix, endA = a.count - suffix
        while endB < b.count, isWord(b[endB]) { endB += 1 }
        while endA < a.count, isWord(a[endA]) { endA += 1 }

        // Only edits inside what was just dictated count; anything else is the user's own writing.
        let lower = before.distance(from: before.startIndex, to: span.lowerBound)
        let upper = before.distance(from: before.startIndex, to: span.upperBound)
        guard start >= lower, endB <= upper, start <= endA else { return nil }

        let trim = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let wrong = String(b[start..<endB]).trimmingCharacters(in: trim)
        let right = String(a[start..<endA]).trimmingCharacters(in: trim)
        let words = { (s: String) in s.split(whereSeparator: \.isWhitespace).count }
        guard (1...3).contains(words(wrong)), (1...3).contains(words(right)), wrong.lowercased() != right.lowercased() else { return nil }
        return (wrong, right)
    }

    /// Worth a dictionary entry: the fix contains a word the spell checker doesn't know, and it's a
    /// respelling of what Scribe heard rather than a different word.
    static func isVocabulary(wrong: String, right: String, isKnown: (String) -> Bool) -> Bool {
        let unknown = right.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { !isKnown(String($0)) }
        return unknown && distance(wrong, right) <= 0.5
    }

    /// Edit distance between the letters of both phrases, from 0 (same) to 1 (nothing in common).
    static func distance(_ x: String, _ y: String) -> Double {
        let a = Array(x.lowercased().filter { $0.isLetter || $0.isNumber })
        let b = Array(y.lowercased().filter { $0.isLetter || $0.isNumber })
        guard !a.isEmpty, !b.isEmpty else { return 1 }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return Double(row[b.count]) / Double(max(a.count, b.count))
    }

    /// A regular English or Portuguese word. Words the user taught macOS ("Learn Spelling") are their
    /// own vocabulary, so they don't count as known.
    static func isKnownWord(_ word: String) -> Bool {
        guard !NSSpellChecker.shared.hasLearnedWord(word) else { return false }
        return ["en", "pt_BR"].contains { language in
            NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                                inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }
}

/// Watches the text field a dictation was pasted into for the fix the user makes next. Reads the
/// field through Accessibility only while watching; the text itself is never stored.
final class CorrectionWatcher {
    private var timer: Timer?

    func watch(dictated: String, onLearn: @escaping (_ wrong: String, _ right: String) -> Void) {
        stop()
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        // Electron apps (Slack, VS Code, T3 Code) only expose their text fields when a client asks.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        // Give the Cmd+V paste time to land before taking the "before" snapshot.
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            guard let self, let field = Self.focused(appElement), let before = Self.value(field),
                  before.contains(dictated.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            var latest = before
            let started = Date()
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                let sameApp = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                let sameField = sameApp && Self.focused(appElement).map { CFEqual($0, field) } == true
                let value = sameField ? Self.value(field) : nil
                if let value, !value.isEmpty { latest = value }
                // Done when the user moves on, sends the message (the field empties) or 30 s pass.
                guard !sameField || value?.isEmpty == true || Date().timeIntervalSince(started) > 30 else { return }
                self?.stop()
                if let fix = Corrections.correction(before: before, after: latest, dictated: dictated),
                   Corrections.isVocabulary(wrong: fix.wrong, right: fix.right, isKnown: Corrections.isKnownWord) {
                    onLearn(fix.wrong, fix.right)
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private static func focused(_ app: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success else { return nil }
        return (value as! AXUIElement)
    }

    private static func value(_ element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
