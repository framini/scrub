import Foundation

/// Links written in text: "https://…", "www.…", a host with a path
/// ("t.co/PngvVZic") or a bare host ("mail.example.com"). A link is an
/// address for everyone to follow, so no word inside one is replaced as a
/// name, handle, place or employer, whichever detector read it so: "t.co"
/// replaced as a handle breaks the link and hides no one.
enum Links {
    private static let pattern = TextPattern(
        #"(?i)\b[a-z][a-z0-9+.\-]*://[^\s<>"'`]+|\bwww\.[^\s<>"'`]+"#
        + #"|(?<![\w@.\-/])(?:[a-z0-9](?:[a-z0-9\-]*[a-z0-9])?\.)+[a-z]{2,24}/[^\s<>"'`]*"#
        + #"|(?<![\w@.\-/])(?-i:(?:[a-z0-9](?:[a-z0-9\-]*[a-z0-9])?\.)+(?:com|net|org|edu|gov|mil|int|info|biz|io|co|uk|us|ca|de|fr|au))(?![\w@\-]|\.\w)"#)
    private static let trailing = CharacterSet(charactersIn: ".,;:!?)]}'\"")
    /// What a link may hold that is not a word: no name hides in "https" or ".com".
    static let named: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME", "USERNAME", "LOCATION", "EMPLOYER", "INITIALS"]

    static func ranges(in text: String) -> [Range<Int>] {
        guard text.contains(".") || text.contains("/") else { return [] }
        let ns = text as NSString
        return TextRanges.matches(pattern, in: text).map { match in
            var end = NSMaxRange(match.range)
            while end > match.range.location, let scalar = Unicode.Scalar(ns.character(at: end - 1)), trailing.contains(scalar) { end -= 1 }
            return match.range.location..<end
        }
    }

    /// `spans` without the names, handles and places found inside a link. A
    /// value a key names in full ("profile_url") keeps what its key says.
    static func outside(_ spans: [Span], in text: String) -> [Span] {
        let length = (text as NSString).length
        func judged(_ span: Span) -> Bool { named.contains(span.entity) && !(span.score == 1 && span.range == 0..<length) }
        guard spans.contains(where: judged) else { return spans }
        let links = ranges(in: text)
        guard !links.isEmpty else { return spans }
        return spans.filter { span in !(judged(span) && links.contains { $0.overlaps(span.range) }) }
    }
}
