import Foundation

/// The secrets and the user in a connection string, written as pairs a ";" ends:
/// "Server=db01;User ID=okafor.e;Password=Tr0ub4dor&3x!;", "AccountName=…;AccountKey=…",
/// "Endpoint=sb://…;SharedAccessKey=…". A value runs to its ";", spaces and all, or
/// is quoted ("Pwd=\"p@ss;word\"", "{p@ss;word}"); written inside XML or JSON it is
/// read as written there, an entity ("&amp;") or an escape ("\"") part of it. The
/// whole value is replaced, so no tail of a password stays; a service's account
/// ("svc_orders", "sa") and every other pair stay as written.
enum ConnectionStrings {
    /// A pair a connection string opens or names its store with.
    private static let store = TextPattern(#"(?i)(?:^|[;"'\s{(])(?:server|data source|host|hostname|address|addr|network address|endpoint|accountname|defaultendpointsprotocol|database|initial catalog|dsn|driver|provider)[ \t]*="#)
    private static let pair = TextPattern(
        #"(?i)(?:^|(?<=[;"'\s{(]))(password|pwd|pass|passwd|user id|userid|uid|user|username|user name|accountkey|account key|sharedaccesskey|shared access key|sharedaccesssignature|shared access signature|clientsecret|client secret|secret|token)[ \t]*=[ \t]*"#
        // Quoted: its content, quotes doubled or escaped inside it.
        + #"(?:"((?:[^"\r\n]|"")*)"|'((?:[^'\r\n]|'')*)'|&quot;(.*?)&quot;|\\"((?:[^"\\\r\n]|\\.)*?)\\"|\{([^{}\r\n]*)\}"#
        // Bare: to the pair's ";", an entity's own ";" and an escape part of it, never past the quote or closing tag its container ends with.
        + #"|((?:&(?:amp|lt|gt|quot|apos|#[0-9]{1,7}|#x[0-9A-Fa-f]{1,6});|\\.|<(?!/)|[^;\r\n"'<\\])+))"#)
    private static let users: Set<String> = ["user id", "userid", "uid", "user", "username", "user name"]
    /// An account a service, a database or its administrator signs in with, not a person.
    private static let service = TextPattern(#"(?i)^(?:sa|dbo|sys|system|root|admin|administrator|guest|app|api|web|etl|bot|ci|svc|service|readonly|readwrite|reader|writer|reporting|replication|replicator|monitor|backup)$|^(?:svc|service|app|api|sa|srv|sys|etl|bot|ci|db)[_.-]|[_.-](?:svc|service|app|api|ro|rw|readonly|reader|writer|etl|bot|srv|admin|user|prod|staging|dev|test)$"#)

    static func scan(_ text: String) -> [Span] {
        guard text.contains("="), text.contains(";") || text.contains("&quot;"), !TextRanges.matches(store, in: text).isEmpty else { return [] }
        let ns = text as NSString
        var spans: [Span] = []
        for match in TextRanges.matches(pair, in: text) {
            guard let group = (2..<match.numberOfRanges).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }), group.length > 0 else { continue }
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            let value = ns.substring(with: group)
            let range = group.location..<NSMaxRange(group)
            if users.contains(key) {
                let bare = value.trimmingCharacters(in: .whitespaces)
                // An address is read as one; a service's account and a placeholder stay.
                guard !bare.contains("@"), HomeFolders.owned(bare), TextRanges.matches(service, in: bare).isEmpty else { continue }
                spans.append(Span(range: range, entity: "USERNAME", score: 1))
            } else if KeyHints.fits("password", value.trimmingCharacters(in: .whitespaces)), !value.allSatisfy({ $0 == "*" || $0 == " " }) {
                spans.append(Span(range: range, entity: "SECRET", score: 1))
            }
        }
        return spans
    }
}
