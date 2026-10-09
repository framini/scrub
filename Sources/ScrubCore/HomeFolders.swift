import Foundation

/// The account name in a home folder's path: "/Users/odalys/Library",
/// "/home/odalys/.cache", "C:\Users\odalys\AppData", "\\files\home\odalys",
/// "/var/mail/odalys", "~odalys/". A stack trace, a crash report or a log
/// writes it wherever it names a file, and it is its owner's handle. Only
/// that segment is replaced, as a username; the rest of the path stays as
/// written, separators and all, escaped or not. A system's or a shared
/// account ("root", "Shared", "Public", "runner") is no one's, nor is
/// a placeholder ("$USER", "%USERNAME%", "<you>", "*").
enum HomeFolders {
    private static let pattern = TextPattern(
        // macOS's and Unix's homes and mail spools, also on a mounted disk.
        #"(?<![\p{L}\p{N}_.~:-])(?:/Volumes/[^/\s]{1,64})?/(?:Users|home|export/home|usr/home|var/mail|var/spool/mail)/([^\s/\\:*?"'<>|]{1,64})(?=[/\\\s"'<>|:;,)\]}]|$)"#
        // Windows's, its separators written once or escaped ("C:\\Users\\…"), a profile's name with spaces closed by one.
        + #"|(?<![\p{L}\p{N}_])[A-Za-z]:(?:\\+|/)(?:Users|Documents and Settings)(?:\\+|/)([^\\/\r\n\t"'<>|:*?]{1,64}?(?=\\|/)|[^\s\\/"'<>|:*?]{1,64}(?=[\s"'<>|;,)\]}]|$))"#
        // A share's home folders: "\\files\home\odalys", "\\nas01\users$\odalys".
        + #"|(?<![\\\p{L}\p{N}])\\{2,}[\p{L}\p{N}._-]{1,64}(?:\\+[\p{L}\p{N}._$-]{1,64}){0,3}?\\+(?:home|homes|Home|Homes|users|Users|users\$|profiles|Profiles)\\+([^\s\\/"'<>|:*?]{1,64})(?=[\\\s"'<>|;,)\]}]|$)"#
        // "~odalys/…": a user's home by their name.
        + #"|(?<![\p{L}\p{N}_~/.\\-])~([A-Za-z_][A-Za-z0-9_.-]{0,31})(?=/|\\|[\s"'<>|;,)\]}]|$)"#,
        options: [.anchorsMatchLines])

    /// Accounts a system, a build or everyone uses, and words a manual writes in a user's place.
    private static let shared: Set<String> = [
        "root", "admin", "administrator", "administrators", "shared", "public", "default", "default user", "defaultuser0", "default.migrated", "all users", "guest",
        "nobody", "daemon", "www-data", "www", "httpd", "pi",
        "runner", "runneradmin", "build", "builder", "ci", "worker",
        "git", "deploy", "deployer", "app", "apps", "node",
        "service", "services", "system", "localservice", "networkservice", "test", "tester", "demo", "dev",
        "user", "username", "user_name", "yourname", "your_name", "your-name", "yourusername", "your_username", "you", "me", "name", "someone", "somebody",
        "example", "foo", "bar", "xxx", "lost+found", "mail", "spool"]

    /// The account names in `text`'s home-folder paths.
    static func scan(_ text: String) -> [Span] {
        guard text.contains("/") || text.contains("\\") || text.contains("~") else { return [] }
        let ns = text as NSString
        var spans: [Span] = []
        for match in TextRanges.matches(pattern, in: text) {
            guard let group = (1..<match.numberOfRanges).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { continue }
            let name = ns.substring(with: group)
            guard owned(name) else { continue }
            // A profile named by its owner's full name ("C:\Users\Rufus Pemberton-Hale") is that person.
            let named = name.contains(" ") && name.split(separator: " ").allSatisfy { $0.first?.isUppercase == true && $0.dropFirst().allSatisfy { $0.isLetter || "'’-.".contains($0) } }
            spans.append(Span(range: group.location..<NSMaxRange(group), entity: named ? "PERSON" : "USERNAME", score: 1))
        }
        return spans
    }

    /// Whether a home folder's name is a person's: no system's or shared account, no placeholder, and some letter.
    static func owned(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed == name, trimmed.contains(where: \.isLetter),
              let first = trimmed.first, first.isLetter || first.isNumber || first == "_" else { return false }
        guard !trimmed.contains(where: { "$%{}<>*[]".contains($0) }) else { return false }
        return !shared.contains(trimmed.lowercased())
    }

    /// `spans` with every home folder's account name in `text`: what else was read inside one gives way
    /// to it, and one read across more than it (an address, a link's part) keeps its own reading.
    static func over(_ spans: [Span], in text: String) -> [Span] {
        let homes = scan(text)
        guard !homes.isEmpty else { return spans }
        let others = spans.filter { span in !homes.contains { $0.range.lowerBound <= span.range.lowerBound && span.range.upperBound <= $0.range.upperBound } }
        let kept = homes.filter { home in !others.contains { $0.range.overlaps(home.range) } }
        // A name the account's spells, written elsewhere as words ("genevieve.oduya" and "Genevieve Oduya.ledger"), is its owner.
        // A part of it read alone ("Genevieve") gives way to it.
        let names: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME"]
        let within = { (span: Span, name: Span) in names.contains(span.entity) && name.range.lowerBound <= span.range.lowerBound && span.range.upperBound <= name.range.upperBound }
        let spelled = Detector.spelledByEmail(kept, in: text, handles: true).filter { name in !(others + kept).contains { $0.range.overlaps(name.range) && !within($0, name) } }
        return others.filter { span in !spelled.contains { within(span, $0) } } + kept + spelled
    }
}
