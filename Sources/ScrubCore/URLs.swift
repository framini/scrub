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
/// `/u/12345`, `/~odalys`, `/@odalys`), and the user name before the host. A
/// fragment that is a route reads as a path with its own query
/// (`#/search?email=…`), and a collection written encoded (`/%75sers/…`) as
/// it reads. Those are read decoded, replaced with the stand-in the same
/// value takes elsewhere, and written back encoded as the original was, so
/// the link stays valid. A link with none of these (a page, a short link, a
/// host) stays as written.
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
        let bang: UInt16 = 33
        var result: [Component] = []
        func string(_ range: Range<Int>) -> String { String(decoding: units[range], as: UTF16.self) }
        // A segment or key as it reads: "%75sers" is "users", "%65mail" is "email".
        func name(_ range: Range<Int>) -> String { let raw = string(range); return raw.removingPercentEncoding ?? raw }
        func path(_ range: Range<Int>) {
            var previous: String?
            var start = range.lowerBound
            for index in range.lowerBound...range.upperBound where index == range.upperBound || units[index] == slash {
                if index > start {
                    result.append(Component(range: start..<index, part: .path, key: previous))
                    previous = name(start..<index).lowercased()
                }
                start = index + 1
            }
        }
        func pairs(_ range: Range<Int>) {
            var pairStart = range.lowerBound
            for at in range.lowerBound...range.upperBound where at == range.upperBound || units[at] == amp || units[at] == semicolon {
                if let equal = (pairStart..<at).first(where: { units[$0] == equals }), equal + 1 < at {
                    result.append(Component(range: (equal + 1)..<at, part: .query, key: name(pairStart..<equal)))
                }
                pairStart = at + 1
            }
        }
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
        path(cursor..<queryStart)
        // Query and fragment parameters ("?a=1&b=2", "#a=1"). A fragment that is a route
        // ("#/users/odalys", "#!/users/odalys") reads as a path, and its own query
        // ("#/search?email=…") as a query.
        var index = queryStart
        while index < units.count {
            let section = index + 1
            let sectionEnd = (section..<units.count).first { units[$0] == hash } ?? units.count
            // The slash a route's path starts at.
            var route: Int?
            if units[index] == hash, section < sectionEnd {
                if units[section] == slash { route = section }
                else if units[section] == bang, section + 1 < sectionEnd, units[section + 1] == slash { route = section + 1 }
            }
            if let route {
                let routeEnd = (route..<sectionEnd).first { units[$0] == question } ?? sectionEnd
                path((route + 1)..<routeEnd)
                if routeEnd < sectionEnd { pairs((routeEnd + 1)..<sectionEnd) }
            } else {
                pairs(section..<sectionEnd)
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
            // "/~odalys" keeps its tilde, as "@odalys" keeps its at sign (see `StandIns`): only the handle is replaced.
            let tilde = component.part == .path && entity == "USERNAME" && raw.hasPrefix("~") ? 1 : 0
            spans.append(Span(range: (component.range.lowerBound + tilde)..<component.range.upperBound, entity: entity, score: 1, url: component.part))
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
            // "/@odalysferriter" and "/~odalys" are someone's handle wherever they sit, the first segment too.
            let bare = value.hasPrefix("~") || value.hasPrefix("@")
            guard let key = component.key ?? (bare ? "" : nil) else { return nil }
            // An avatar's address is the hash of its owner's email ("/avatar/3b7e0c19…").
            if ["avatar", "avatars"].contains(key), KeyHints.isDigest(value) { return "RECORD_ID" }
            guard bare || collections.contains(key) else { return RecordIDs.prefixed(value) && RecordIDs.isPersonCollection(key) ? "RECORD_ID" : nil }
            if value.allSatisfy(\.isNumber) { return value.count >= 3 ? "RECORD_ID" : nil }
            if RecordIDs.prefixed(value) { return "RECORD_ID" }
            // A page under a person ("/users/sign_in", "/profile/settings") is no one.
            // Nor is a word for a part of the site ("/authors/id/T/TOMC"), and a
            // two-letter handle is too likely a word to replace wherever it is written.
            if pages.contains(value.lowercased()) || value.count < 3 && !bare || isFileName(value) { return nil }
            return TextRanges.matches(handle, in: value).isEmpty ? nil : "USERNAME"
        }
    }
    /// Extensions of the files a site serves: "/user/default.asp" and
    /// "/users/index.html" are pages, not people.
    private static let fileExtensions: Set<String> = ["html", "htm", "shtml", "xhtml", "asp", "aspx", "ashx", "asmx", "php", "php3", "php5", "phtml", "jsp", "jspx",
                                                      "do", "action", "cgi", "pl", "py", "rb", "cfm", "cfml", "nsf", "dll", "exe", "js", "mjs", "css", "json",
                                                      "xml", "rss", "atom", "txt", "md", "csv", "pdf", "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "zip"]
    static func isFileName(_ value: String) -> Bool {
        guard let dot = value.lastIndex(of: "."), dot != value.startIndex else { return false }
        return fileExtensions.contains(value[value.index(after: dot)...].lowercased())
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
        // After a ";" only in a link's query: a connection string's pairs end at theirs, an "&" inside a password ("Password=Tr0ub4dor&3x!").
        if ns.character(at: start - 1) == 59 {
            var at = start - 1
            while at > 0, let scalar = Unicode.Scalar(ns.character(at: at - 1)), !CharacterSet.whitespacesAndNewlines.contains(scalar), ![63, 35].contains(ns.character(at: at - 1)) { at -= 1 }
            guard at > 0, [63, 35].contains(ns.character(at: at - 1)) else { return nil }
        }
        for index in range where [38, 35].contains(ns.character(at: index)) { return index > range.lowerBound ? index : nil }
        return nil
    }
    private static let keyCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))

    /// The value as it reads: percent-decoded, and in a query "+" read as a space.
    static func decode(_ raw: String, _ part: URLPart) -> String {
        let spaced = part == .query ? raw.replacingOccurrences(of: "+", with: " ") : raw
        return spaced.removingPercentEncoding ?? spaced
    }

    /// A link's part as it reads, percent-decoded and in a query with "+" a
    /// space (as `URLs.decode` reads it), with the range of the part each
    /// UTF-16 unit is read from; nil when it reads as written or is no UTF-8.
    static func decoded(_ raw: String, _ part: URLPart) -> (text: String, sources: [Range<Int>])? {
        let units = Array(raw.utf16)
        func hex(_ unit: UInt16) -> UInt8? {
            switch unit {
            case 48...57: UInt8(unit - 48)
            case 65...70: UInt8(unit - 55)
            case 97...102: UInt8(unit - 87)
            default: nil
            }
        }
        var bytes: [(byte: UInt8, from: Range<Int>)] = []
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit == 37, index + 2 < units.count, let high = hex(units[index + 1]), let low = hex(units[index + 2]) {
                bytes.append((high << 4 | low, index..<(index + 3)))
                index += 3
            } else if unit == 43, part == .query {
                bytes.append((32, index..<(index + 1)))
                index += 1
            } else {
                // A character written as itself: each of its bytes is read from it.
                let width = UTF16.isLeadSurrogate(unit) && index + 1 < units.count ? 2 : 1
                let from = index..<(index + width)
                for byte in String(decoding: units[from], as: UTF16.self).utf8 { bytes.append((byte, from)) }
                index += width
            }
        }
        var text: [UInt16] = [], sources: [Range<Int>] = []
        var at = 0
        while at < bytes.count {
            let lead = bytes[at].byte
            let width = lead < 0x80 ? 1 : lead >> 5 == 0b110 ? 2 : lead >> 4 == 0b1110 ? 3 : lead >> 3 == 0b11110 ? 4 : 0
            guard width > 0, at + width <= bytes.count, let scalar = String(bytes: bytes[at..<(at + width)].map(\.byte), encoding: .utf8), scalar.unicodeScalars.count == 1 else { return nil }
            let from = bytes[at].from.lowerBound..<bytes[at + width - 1].from.upperBound
            for unit in scalar.utf16 {
                text.append(unit)
                sources.append(from)
            }
            at += width
        }
        let read = String(decoding: text, as: UTF16.self)
        return read == raw ? nil : (read, sources)
    }

    /// A link's part as a reader reads it: decoded as `decoded` reads it, and
    /// without the characters no one sees (see `Visible`), so "%51uill%E2%80%8Bmere"
    /// reads "Quillmere". Each UTF-16 unit maps to the range of the part it is
    /// read from; nil when the part reads as written.
    static func reading(_ raw: String, _ part: URLPart) -> (text: String, sources: [Range<Int>])? {
        let read = decoded(raw, part) ?? (raw, (0..<(raw as NSString).length).map { $0..<($0 + 1) })
        guard let view = Visible(read.text) else { return read.text == raw ? nil : read }
        let clean = view.clean as NSString
        let sources = (0..<clean.length).map { index -> Range<Int> in
            let from = view.raw(index..<(index + 1))
            return read.sources[from.lowerBound].lowerBound..<read.sources[from.upperBound - 1].upperBound
        }
        return (view.clean, sources)
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
