import Foundation

/// Where in a link a value sits, which says how it is written there.
public enum URLPart: Sendable, Equatable {
    /// A query or fragment parameter's value: percent-encoded, "+" for a space.
    case query
    /// A path segment: percent-encoded.
    case path
    /// The user name before the host ("https://odalys@host"): percent-encoded.
    case user
}

/// The personal parts of links. A link itself is an address for everyone to
/// follow (see `Links`), but some of its parts name someone: a query value
/// under a personal key (`?email=…&name=…&phone=…`), a token or signature, a
/// path segment under a collection of people (`/users/odalys.ferriter`,
/// `/u/12345`, `/~odalys`), and the user name before the host. Those are read
/// decoded, replaced with the stand-in the same value takes elsewhere, and
/// written back encoded as the original was, so the link stays valid. A link
/// with none of these (a page, a short link, a host) stays as written.
enum URLs {
    struct Component {
        let range: Range<Int>
        let part: URLPart
        /// The parameter's key, or for a path segment the segment before it.
        let key: String?
    }

    /// Segments before an identifier of one person or account.
    private static let collections: Set<String> = [
        "u", "user", "users", "profile", "profiles", "people", "person", "persons", "member", "members", "customer", "customers", "client", "clients",
        "account", "accounts", "patient", "patients", "employee", "employees", "staff", "student", "students", "contact", "contacts", "author", "authors",
        "applicant", "applicants", "subscriber", "subscribers", "owner", "owners", "in", "@"]
    /// User names in a link's credentials that name a service, not a person.
    private static let serviceUsers: Set<String> = ["admin", "administrator", "root", "user", "git", "deploy", "deployer", "postgres", "mysql", "ubuntu", "ec2-user", "anonymous",
                                                     "ftp", "guest", "test", "www", "www-data", "oauth2", "x-access-token", "token", "api", "bot", "ci", "jenkins", "service"]
    /// Query keys that hold a credential or a signature whatever else they say.
    private static let secretKeys: Set<String> = ["sig", "signature", "xamzsignature", "xamzsecuritytoken", "xgoogsignature", "code", "key", "apikey", "accesstoken",
                                                  "idtoken", "refreshtoken", "token", "auth", "authtoken", "sessionid", "sid", "session", "jwt", "password", "pwd", "pass", "secret", "clientsecret", "hmac", "otp"]

    /// Every component of every link in `text` that can hold a value.
    static func components(in text: String, links: [Range<Int>]? = nil) -> [Component] {
        let ranges = links ?? Links.ranges(in: text)
        guard !ranges.isEmpty else { return [] }
        let ns = text as NSString
        var result: [Component] = []
        for link in ranges {
            let units = Array(ns.substring(with: NSRange(location: link.lowerBound, length: link.count)).utf16)
            result += components(units).map { Component(range: ($0.range.lowerBound + link.lowerBound)..<($0.range.upperBound + link.lowerBound), part: $0.part, key: $0.key) }
        }
        return result
    }

    private static func components(_ units: [UInt16]) -> [Component] {
        let slash: UInt16 = 47, question: UInt16 = 63, hash: UInt16 = 35, at: UInt16 = 64, colon: UInt16 = 58, amp: UInt16 = 38, semicolon: UInt16 = 59, equals: UInt16 = 61
        var result: [Component] = []
        func string(_ range: Range<Int>) -> String { String(decoding: units[range], as: UTF16.self) }
        // Scheme and authority: "https://user:pass@host:port".
        var cursor = 0
        if let scheme = (0..<min(units.count, 24)).first(where: { units[$0] == colon }), scheme + 2 < units.count, units[scheme + 1] == slash, units[scheme + 2] == slash {
            cursor = scheme + 3
            let end = (cursor..<units.count).first { [slash, question, hash].contains(units[$0]) } ?? units.count
            if let atSign = (cursor..<end).last(where: { units[$0] == at }) {
                let userEnd = (cursor..<atSign).first { units[$0] == colon } ?? atSign
                if userEnd > cursor { result.append(Component(range: cursor..<userEnd, part: .user, key: nil)) }
            }
            cursor = end
        } else {
            // "www.example.com/…" or "t.co/…": the host runs to the first slash.
            cursor = (0..<units.count).first { [slash, question, hash].contains(units[$0]) } ?? units.count
        }
        let queryStart = (cursor..<units.count).first { units[$0] == question || units[$0] == hash } ?? units.count
        // Path segments, each keyed by the one before it.
        var previous: String?
        var start = cursor
        for index in cursor...queryStart where index == queryStart || units[index] == slash {
            if index > start {
                result.append(Component(range: start..<index, part: .path, key: previous))
                previous = string(start..<index).lowercased()
            }
            start = index + 1
        }
        // Query and fragment parameters ("?a=1&b=2", "#a=1"); a fragment that is a path ("#/users/odalys") reads as one.
        var index = queryStart
        while index < units.count {
            let section = index + 1
            let sectionEnd = (section..<units.count).first { units[$0] == hash } ?? units.count
            if units[index] == hash, section < sectionEnd, units[section] == slash {
                var previous: String?
                var start = section + 1
                for at in (section + 1)...sectionEnd where at == sectionEnd || units[at] == slash {
                    if at > start { result.append(Component(range: start..<at, part: .path, key: previous)); previous = string(start..<at).lowercased() }
                    start = at + 1
                }
            } else {
                var pairStart = section
                for at in section...sectionEnd where at == sectionEnd || units[at] == amp || units[at] == semicolon {
                    if let equal = (pairStart..<at).first(where: { units[$0] == equals }), equal + 1 < at {
                        result.append(Component(range: (equal + 1)..<at, part: .query, key: string(pairStart..<equal)))
                    }
                    pairStart = at + 1
                }
            }
            index = sectionEnd
        }
        return result
    }

    /// The personal parts of the links in `text`, each with how it is written.
    static func scan(_ text: String, links: [Range<Int>]? = nil) -> [Span] {
        guard text.contains("/") || text.contains("?") else { return [] }
        var spans: [Span] = []
        for component in components(in: text, links: links) {
            let raw = TextRanges.substring(text, component.range)
            let value = decode(raw, component.part)
            guard !value.isEmpty, value.utf16.count <= 256, let entity = kind(of: value, component) else { continue }
            spans.append(Span(range: component.range, entity: entity, score: 1, url: component.part))
        }
        return spans
    }

    private static let email = TextPattern(#"^[A-Za-z0-9._%+'-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#)
    private static let handle = TextPattern(#"^[@~]?[A-Za-z][A-Za-z0-9._-]{1,63}$"#)

    /// What a component holds, if anything personal.
    private static func kind(of value: String, _ component: Component) -> String? {
        if !TextRanges.matches(email, in: value).isEmpty { return "EMAIL_ADDRESS" }
        switch component.part {
        case .user:
            // A user name is one handle: "[user@]host" in a manual is a placeholder.
            return serviceUsers.contains(value.lowercased()) || TextRanges.matches(handle, in: value).isEmpty ? nil : "USERNAME"
        case .query:
            let compact = (component.key ?? "").lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            if secretKeys.contains(compact) { return value.count >= 4 ? "SECRET" : nil }
            // A signed link's credential is scoped ("AKIA…/20240101/us-east-1/s3/aws4_request"):
            // only its key ID is secret, and the patterns find that.
            if compact.hasSuffix("credential") && value.contains("/") { return nil }
            guard let hint = KeyHints.hint(component.key), KeyHints.fits(component.key, value) else {
                return RecordIDs.identifying(key: component.key, value: value) ? "RECORD_ID" : nil
            }
            // A name is words of letters: "name=report.pdf" names a file.
            if ["PERSON", "FIRST_NAME", "LAST_NAME"].contains(hint) {
                let words = value.split(separator: " ")
                guard (1...4).contains(words.count), words.allSatisfy({ $0.allSatisfy { $0.isLetter || "'’-.".contains($0) } && $0.first?.isLetter == true }) else { return nil }
            }
            // A query value is one value: "name=Odalys+Ferriter" is a person, "state=CA" a region.
            return ["LATITUDE", "LONGITUDE", "COORDINATES", "TIME_ZONE"].contains(hint) ? nil : hint
        case .path:
            guard let key = component.key else { return nil }
            let bare = value.hasPrefix("~") || value.hasPrefix("@")
            guard bare || collections.contains(key) else { return RecordIDs.prefixed(value) && RecordIDs.isPersonCollection(key) ? "RECORD_ID" : nil }
            if value.allSatisfy(\.isNumber) { return value.count >= 3 ? "RECORD_ID" : nil }
            if RecordIDs.prefixed(value) { return "RECORD_ID" }
            // A page under a person ("/users/sign_in", "/profile/settings") is no one.
            // Nor is a word for a part of the site ("/authors/id/T/TOMC"), and a
            // two-letter handle is too likely a word to replace wherever it is written.
            if pages.contains(value.lowercased()) || value.count < 3 && !bare { return nil }
            return TextRanges.matches(handle, in: value).isEmpty ? nil : "USERNAME"
        }
    }
    /// Pages a site keeps under its people, not people.
    private static let pages: Set<String> = ["new", "edit", "settings", "me", "self", "login", "logout", "signin", "sign_in", "signup", "sign_up", "register", "search", "list", "all",
                                             "index", "home", "about", "help", "profile", "account", "dashboard", "admin", "api", "v1", "v2", "v3", "public", "private", "followers", "following",
                                             "id", "ids", "uid", "uuid", "name", "names", "by", "page", "pages", "posts", "photos", "files", "feed", "activity", "details", "info",
                                             "view", "show", "create", "update", "delete", "remove", "detail", "orders", "invoices", "events", "groups", "roles", "permissions"]

    /// Where a value after "token=" ends when the key is a query's ("?token=…&user=…"):
    /// at the next parameter, not at the end of the link. Nil when it is no query's or ends there anyway.
    static func queryValueEnd(_ ns: NSString, _ range: Range<Int>) -> Int? {
        guard range.lowerBound >= 2, range.upperBound <= ns.length, ns.character(at: range.lowerBound - 1) == 61 else { return nil }
        var start = range.lowerBound - 1
        while start > 0, let scalar = Unicode.Scalar(ns.character(at: start - 1)), keyCharacters.contains(scalar) { start -= 1 }
        guard start > 0, [63, 38, 59, 35].contains(ns.character(at: start - 1)) else { return nil }
        for index in range where [38, 35].contains(ns.character(at: index)) { return index > range.lowerBound ? index : nil }
        return nil
    }
    private static let keyCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))

    /// The value as it reads: percent-decoded, and in a query "+" read as a space.
    static func decode(_ raw: String, _ part: URLPart) -> String {
        let spaced = part == .query ? raw.replacingOccurrences(of: "+", with: " ") : raw
        return spaced.removingPercentEncoding ?? spaced
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// `value` written as `original` writes its own: what the original left
    /// unencoded stays so ("@" in "?email=odalys@…"), everything else outside
    /// the unreserved characters is percent-encoded, and a space is "+" in a
    /// query that wrote it so.
    static func encode(_ value: String, like original: String, _ part: URLPart) -> String {
        var raw = Set(original.unicodeScalars.filter { !unreserved.contains($0) && $0 != "%" })
        if part == .query { raw.remove("+") }
        let plusForSpace = part == .query && (original.contains("+") || !original.contains("%20"))
        var output = ""
        for scalar in value.unicodeScalars {
            if unreserved.contains(scalar) || raw.contains(scalar) { output.unicodeScalars.append(scalar) }
            else if scalar == " " && plusForSpace { output += "+" }
            else { for byte in String(scalar).utf8 { output += String(format: "%%%02X", byte) } }
        }
        return output
    }
}
