import Foundation

/// A term, and its meaning when the paste carried one.
///
/// Copying is how a word actually arrives. You are reading something, you meet
/// a word, you select it — and by then the word is already on the clipboard,
/// which is one gesture further along than an empty text field is. So the Add
/// screen takes what is there rather than asking for it to be typed again.
///
/// What comes over is usually just the word, and sometimes a whole dictionary
/// line with the gloss attached. Both are handled here rather than in the view,
/// for the same reason `PastedCredentials` is: nothing about reading a word out
/// of pasted text is about a phone, and the Mac's Add tab can have it the day
/// somebody pastes into that one.
struct PastedCard: Equatable {
    var term: String
    var definition: String?

    /// Whether this is worth filling a field with unasked.
    ///
    /// The automatic path uses it; the paste button does not, because a press
    /// is somebody saying what they want and a paragraph pasted on purpose is
    /// still a paragraph they meant to paste. What it rules out is the case
    /// where the clipboard happens to hold an article, an error message or a
    /// diff — none of which anybody wants dropped into a term field they did
    /// not touch.
    var looksLikeACard: Bool {
        term.count <= 200 && (definition?.count ?? 0) <= 400
    }

    /// Nil when there is nothing in the text worth a card.
    static func parse(_ text: String) -> PastedCard? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Two lines is a word and what it means — the shape of a dictionary
        // entry copied out of anything. Everything after the first line is the
        // meaning, kept whole: a word with three senses under it is three
        // lines, and dropping two of them would be worse than dropping none.
        let lines = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.count > 1 {
            return PastedCard(term: lines[0], definition: lines.dropFirst().joined(separator: "\n"))
        }

        // `Fenster — window`. A dash with spaces around it is somebody writing
        // a gloss; a dash without them is a hyphenated word, and `well-known`
        // must not become a card about `well`. The plain hyphen is left out
        // even spaced, because `to bunch it up - собрать` and `I don't know -
        // he said` look identical from here and only one of them splits well.
        for separator in [" — ", " – ", " -- "] {
            guard let range = trimmed.range(of: separator) else { continue }
            let term = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let meaning = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !term.isEmpty, !meaning.isEmpty {
                return PastedCard(term: term, definition: meaning)
            }
        }

        return PastedCard(term: trimmed, definition: nil)
    }
}
