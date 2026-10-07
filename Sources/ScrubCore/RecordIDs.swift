import Foundation

/// Which record identifiers name someone. An ID that picks out a person or
/// their account (a customer, user, account, patient or member ID, or any ID
/// that spells out a name, an email or a phone number) is as identifying as
/// the name: anyone holding the source system can look it up. It gets a
/// stand-in of the same shape, its prefix kept ("cus_" and the same length
/// and kinds of character), and the same stand-in wherever the same ID is
/// written: in other records, other fields that refer to it, links and prose,
/// so joins still work. A technical identifier (a request or trace ID, a
/// UUID with no person around it, a version hash, a SKU, an order number)
/// names no one and stays as written.
enum RecordIDs {
    /// Who or what an ID can stand for that is a person or their account.
    private static let people: Set<String> = [
        "customer", "customers", "cust", "user", "users", "usr", "account", "accounts", "acct", "patient", "patients", "member", "members", "client", "clients",
        "employee", "employees", "emp", "person", "people", "applicant", "applicants", "subscriber", "subscribers", "student", "students", "contact", "contacts",
        "owner", "buyer", "seller", "driver", "rider", "guest", "guests", "cardholder", "holder", "beneficiary", "profile", "profiles", "candidate", "tenant",
        "resident", "passenger", "traveler", "traveller", "donor", "payee", "payer", "borrower", "policyholder", "insured", "claimant", "lead", "prospect",
        "visitor", "attendee", "author", "assignee", "reporter", "requester", "requestor", "recipient", "sender", "mrn", "uid", "userid", "customerid",
        // A device or a browser a person uses, and the pseudonym a site knows them by.
        "device", "devices", "browser", "anonymous", "social", "socials",
        // A loyalty scheme's or a club's member: "loyalty_number", "frequent_flyer_id".
        "loyalty", "membership", "flyer", "rewards"]
    /// The last word of a key that holds an identifier.
    private static let idWords: Set<String> = ["id", "ids", "number", "no", "num", "ref", "reference", "uid", "guid", "uuid", "identifier",
                                                // What a person's device or account is hashed to: "device_hash", "device_fingerprint".
                                                "hash", "fingerprint", "md5"]
    /// Keys that hold one person's identifier on their own.
    private static let whole: Set<String> = ["uid", "userid", "customerid", "accountid", "patientid", "memberid", "clientid", "mrn", "medicalrecordnumber", "employeeid", "personid", "subscriberid", "studentid",
                                             "deviceid", "visitorid", "globaldeviceid", "devicefingerprint", "linkedid", "browserid", "blackbox", "deviceblackbox",
                                             "loyaltyprogramid", "loyaltyprogramnumber", "frequentflyernumber", "membershipnumber"]

    /// What a person has rather than is: their ID only right before an ID's word ("device_id", "loyalty_number"), never a key alone ("browser": "FIREFOX10").
    private static let belongings: Set<String> = ["device", "devices", "browser", "anonymous", "social", "socials", "loyalty", "membership", "flyer", "rewards"]
    private static let idQualifiers: Set<String> = ["web", "external", "internal", "platform", "app", "portal", "login", "account", "system", "crm", "merchant", "partner", "vendor", "legacy", "global", "unique", "program"]
    /// Whether a collection or key names people ("customers", "patient").
    static func isPersonCollection(_ word: String?) -> Bool { word.map { people.contains($0.lowercased()) && !belongings.contains($0.lowercased()) } ?? false }

    /// Whether `key` names a person's identifier: "customer_id", "patientNumber",
    /// "member_ref", "uid", or a person's own key ("customer": "cus_…") over a value shaped like an ID.
    static func identifying(key: String?, value: String) -> Bool {
        guard let key, shaped(value) else { return false }
        let words = KeyHints.words(key)
        let compact = words.joined()
        if whole.contains(compact) { return true }
        guard let last = words.last else { return false }
        // A device's fingerprint blob under its vendor's name ("acme_blackbox").
        if last == "blackbox" { return true }
        // The person names the ID right before it: "customer_id", "patientNumber", not "applicant_address_country_id".
        if idWords.contains(last), words.count >= 2, people.contains(words[words.count - 2]) { return true }
        // A person's ID in one of their systems: "customer_web_id", "user_external_id".
        if idWords.contains(last), words.count >= 3, people.contains(words[words.count - 3]), idQualifiers.contains(words[words.count - 2]) { return true }
        // "customer": "cus_4TUvJhQkMeNW3t", "owner": "usr_19f3", "created_by": "u_1234": a reference
        // to someone. An ID has a digit: "owner": "platform-team" is a team's slug.
        // A tool's version, a release's tag, a standard or a file is no one's: "agent": "curl8.0", "owner": "release_2026".
        // A client's handle is theirs whatever it ends in: "user": "jdoe42.js".
        guard value.contains(where: \.isNumber), !versioned(value), !isFileName(value) || Detector.clientKey(key) else { return false }
        return words.count == 1 && people.contains(last) && !belongings.contains(last) || KeyHints.isRole(key)
    }

    /// Whether a value under `key` can be a person's ID at all, by the key alone (see `isPersonal`).
    static func keyMayName(_ key: String) -> Bool {
        let words = KeyHints.words(key)
        guard let last = words.last else { return false }
        return whole.contains(words.joined()) || words.count == 1 && people.contains(last) && !belongings.contains(last) || KeyHints.isRole(key)
            || idWords.contains(last) || last == "slug" || last == "handle" || last == "blackbox"
    }

    /// Whether a key names a person's identifier by itself: "customer_id", "patientNumber", "uid".
    static func isPersonKey(_ key: String?) -> Bool {
        let words = KeyHints.words(key)
        if whole.contains(words.joined()) { return true }
        guard words.count >= 2, let last = words.last else { return false }
        return idWords.contains(last) && people.contains(words[words.count - 2])
    }

    /// Whether a key is one an identifier sits under ("id", "ref", "external_id"),
    /// whose value is a person's when it spells one out.
    static func idKey(_ key: String?) -> Bool {
        guard let last = KeyHints.words(key).last else { return false }
        return idWords.contains(last) || last == "slug" || last == "handle"
    }

    /// One token of letters, digits and joiners, long enough to be an identifier.
    static func shaped(_ value: String) -> Bool {
        (3...128).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-.:".contains($0)) } && value.contains(where: { $0.isLetter || $0.isNumber })
    }

    private static let prefix = TextPattern(#"^[A-Za-z]{1,8}[_-](?=[A-Za-z0-9])"#)
    /// "cus_4TUvJh", "usr-19f3", "E-48211": a type prefix before the identifier.
    static func prefixed(_ value: String) -> Bool { shaped(value) && !keptPrefix(value).isEmpty }

    /// The prefix kept by a stand-in, if any: letters before the first "_" or
    /// "-" that read as a type's code, never a name. "odalys-ferriter" and
    /// "pat-ferriter" start with a name, "quillmere_north" with the first word
    /// of a slug: each is replaced whole, so no part of a name stays.
    /// What the document says about who is in it overrides a type's list:
    /// beside Pat Ferriter, "pat-ferriter1987" and "pat_ZqybnpAzukkun" start
    /// with Pat, so a prefix that is a word of `named` (the lowercase words of
    /// the names and handles the document holds) is replaced too.
    static func keptPrefix(_ value: String, named: Set<String> = []) -> String {
        guard let match = TextRanges.matches(prefix, in: value).first else { return "" }
        let kept = TextRanges.substring(value, 0..<NSMaxRange(match.range))
        let letters = String(kept.dropLast())
        guard !named.contains(letters.lowercased()) else { return "" }
        return isType(letters, before: value.dropFirst(kept.count)) ? kept : ""
    }

    /// Whether `letters` name what a record is, before `body`: a type the
    /// lists of people's and things' types hold ("cus", "usr", "ord", "inv"),
    /// or a code in one case ("E", "INV", "acc") or an ordinary word ("tenant")
    /// before a generated body. A first name or surname the lists know is no
    /// type, and a body of words is a slug that starts with one of its words.
    private static func isType(_ letters: String, before body: Substring) -> Bool {
        let lower = letters.lowercased()
        let named = lower.count >= 2 && (NameLists.isFirst(lower) || NameLists.isSurname(lower))
        let listed = personPrefixes.contains(lower) || thingPrefixes.contains(lower)
        let made = generated(body, typed: listed || isCode(letters))
        // Before words, a type that is also a name starts one: "pat-ferriter" is Pat Ferriter.
        if listed { return made || !named }
        // A word that is also a surname ("card", "bill") still names a type before a generated body.
        guard made, !named || NameLists.isOrdinary(lower), letters == lower || letters == letters.uppercased() else { return false }
        return letters.count <= (letters == lower ? 3 : 4) || NameLists.isOrdinary(lower)
    }

    /// Made by a system, not written: a digit in it ("48213177", "4TUvJh"),
    /// or letters in both cases, mixed as no word is ("jwLHzYUsfaqhdNYV").
    /// After a listed type (`typed`), a long unbroken body whose case turns
    /// inside it is enough ("pat_ZqybnpAzukkun"): no written word follows "pat_" so.
    private static func generated(_ body: Substring, typed: Bool = false) -> Bool {
        if body.contains(where: \.isNumber) { return true }
        // Case that changes back and forth, with several capitals ("GWYVaoEXYDXH"), as no camelCase word does.
        let changes = zip(body, body.dropFirst()).filter { $0.isLetter && $1.isLetter && $0.isUppercase != $1.isUppercase }.count
        let capitals = body.filter(\.isUppercase).count
        if typed { return body.count >= 10 && body.allSatisfy(\.isLetter) && capitals >= 2 && changes >= 2 }
        return body.count >= 8 && capitals >= 3 && changes >= 2
    }

    /// Whether an identifier spells out a person the document names: a name
    /// part of four letters or more that is no ordinary word, an email's
    /// local part, or a phone number's digits ("cus_odalys_ferriter", "u-4158672290").
    static func embeds(_ value: String, names: Set<String>, locals: Set<String>, phones: Set<String>) -> Bool {
        guard shaped(value) else { return false }
        let lower = value.lowercased()
        let pieces = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        // A name runs up to a digit as well as a joiner: "pat-ferriter1987".
        if lower.split(whereSeparator: { !$0.isLetter }).contains(where: { names.contains(String($0)) }) { return true }
        // An email's local part, as one piece or several joined ("odalys.ferriter", "odalys_ferriter"):
        // looked up, never searched for, so a file of many emails stays linear.
        if !locals.isEmpty {
            for start in pieces.indices {
                for end in start..<min(pieces.count, start + 3) {
                    let run = pieces[start...end]
                    for joiner in [".", "_", "-", ""] where locals.contains(run.joined(separator: joiner)) { return true }
                }
            }
        }
        // A phone number's digits, written in one run.
        guard !phones.isEmpty else { return false }
        for run in lower.split(whereSeparator: { !$0.isNumber }) where run.count >= 7 {
            let digits = String(run)
            if phones.contains(digits) || digits.count == 11 && digits.first == "1" && phones.contains(String(digits.dropFirst())) { return true }
        }
        return false
    }

    /// Type prefixes of people's and accounts' identifiers.
    private static let personPrefixes: Set<String> = ["cus", "cust", "customer", "usr", "user", "acct", "acc", "account", "pat", "patient", "mem", "member", "emp", "employee",
                                                      "sub", "subscriber", "person", "per", "prof", "profile", "contact", "ctc", "stu", "student", "applicant"]

    /// A person's or account's ID by its type prefix, in any text: "cus_4TUvJhQkMeNW", "usr_19f3a8b2".
    /// One token after the prefix, with a digit or a capital in it: "user_last_name" is a key, not an ID.
    private static let prefixedID = TextPattern(#"(?<![\w-])(?:cus|cust|usr|user|acct|pat|mem|emp|prof|stu)_[A-Za-z0-9]{6,40}(?![\w-])"#)
    private static let idPrefixes: Set<String> = ["cus_", "cust_", "usr_", "user_", "acct_", "pat_", "mem_", "emp_", "prof_", "stu_"]
    /// An ID right after the word for whose it is ("customer odalys-ferriter",
    /// "account Quillmere_Tavish", "user ID pat-ferriter"), made of names and
    /// words no dictionary holds: a name written as an ID, someone's though
    /// nothing else in the document names them. "user kube-system" is made of words.
    /// It fills a gap: where a name was read inside it, the name stands and is learned.
    private static let labelledID = TextPattern(
        #"(?i)\b(?:customer|client|account|user|member|patient|profile|employee|subscriber|student|contact)s?(?:[ _-]?(?:id|ref|number|no\.?))?\s?[:#]?\s+([A-Za-z][A-Za-z0-9]*(?:[_-][A-Za-z0-9]+)+)(?![\w-])"#)
    static func labelled(in text: String) -> [Span] {
        guard text.contains("_") || text.contains("-") else { return [] }
        return TextRanges.matches(labelledID, in: text).compactMap { match in
            let token = match.range(at: 1)
            let value = TextRanges.substring(text, token.location..<NSMaxRange(token))
            let words = value.split(whereSeparator: { $0 == "_" || $0 == "-" }).filter { $0.allSatisfy(\.isLetter) }.map(String.init)
            // Every word a name or no word at all, and one of them no word: "test-account" is two words that are also surnames.
            guard !isUUID(value), words.contains(where: { $0.count >= 3 && !NameLists.isWord($0) }),
                  words.allSatisfy({ NameLists.isFirst($0) || NameLists.isSurname($0) || !NameLists.isWord($0) }) else { return nil }
            return Span(range: token.location..<NSMaxRange(token), entity: "RECORD_ID", score: 0.9)
        }
    }

    /// A word and a number joined as one ID, in either order ("QUILLMERE-0042",
    /// "0042_odalys", "ferriter-tavish-17"): letters of four or more beside digits.
    private static let wordNumberID = TextPattern(
        #"(?<![\w./@#-])(?:[A-Za-z]{4,}(?:[_-][A-Za-z]{2,})*[_-][0-9]{2,}|[0-9]{2,}(?:[_-][A-Za-z]{2,})*[_-][A-Za-z]{4,})(?![\w-]|[.,][0-9A-Za-z])"#)
    /// IDs written in prose with nothing labelling them, made of a word and a
    /// number. A word the name lists hold as a name and not a word ("odalys",
    /// "ferriter") is someone's: the ID is replaced whole. A word no dictionary
    /// holds ("quillmere") may be a surname the lists lack, so the ID is asked
    /// about. Words ("router-0042", "alpha_7") and short codes ("SHA-256",
    /// "RFC-2616") are no one's and stay.
    static func worded(in text: String) -> (named: [Span], unsure: [Span]) {
        // Only a letter or digit beside "_" or "-" can start one.
        guard text.contains(where: { $0 == "_" || $0 == "-" }), text.contains(where: \.isNumber) else { return ([], []) }
        var named: [Span] = [], unsure: [Span] = []
        for match in TextRanges.matches(wordNumberID, in: text) {
            let range = match.range.location..<NSMaxRange(match.range)
            let value = TextRanges.substring(text, range)
            guard !isUUID(value), !fieldName(value), !technical(value) else { continue }
            let words = value.split(whereSeparator: { $0 == "_" || $0 == "-" }).filter { $0.allSatisfy(\.isLetter) }.map(String.init)
            if words.contains(where: { $0.count >= 4 && NameLists.isName($0) && !NameLists.isOrdinary($0) }) {
                named.append(Span(range: range, entity: "RECORD_ID", score: 0.9))
            } else if words.contains(where: { $0.count >= 5 && !NameLists.isWord($0) && !NameLists.isOrdinary($0) }) {
                unsure.append(Span(range: range, entity: "RECORD_ID", score: 0.5))
            }
        }
        return (named, unsure)
    }

    // Each repeated piece starts with its separator: with the separator optional, a long run
    // of letters can be split into pieces in exponentially many ways before the match fails.
    private static let nameNumberID = TextPattern(
        #"(?<![\w./@#-])(?:[A-Za-z]{3,}(?:[_.-][A-Za-z]{2,})*[_.-]?[0-9]{2,}|[0-9]{2,}[_-][A-Za-z]{3,}(?:[_-][A-Za-z]{2,})*)(?![\w-]|[.,][0-9A-Za-z])"#)
    /// IDs in prose built from the name of someone the same text names, and
    /// a number ("pat-1987" or "ferriter07" beside Pat Ferriter): theirs,
    /// however short or unlisted the name. `names` holds the words, of three
    /// letters or more and in lowercase, of every person found in the text.
    static func owned(in text: String, by names: Set<String>) -> [Span] {
        guard !names.isEmpty, text.contains(where: \.isNumber) else { return [] }
        return TextRanges.matches(nameNumberID, in: text).compactMap { match in
            let range = match.range.location..<NSMaxRange(match.range)
            let value = TextRanges.substring(text, range)
            guard !isUUID(value) else { return nil }
            let words = value.split { !$0.isLetter }.map { $0.lowercased() }
            guard words.contains(where: names.contains) else { return nil }
            return Span(range: range, entity: "RECORD_ID", score: 0.9)
        }
    }

    static func spans(in text: String) -> [Span] {
        // Every match has one of the prefixes and its "_": read only around those.
        // One pass: each "_" with a prefix's lowercase letters right before it.
        var anchors: [Int] = []
        var offset = 0
        var recent: [UInt16] = []
        for unit in text.utf16 {
            if unit == 95 {
                for count in 3...4 where count <= recent.count {
                    let prefix = String(decoding: recent.suffix(count), as: UTF16.self) + "_"
                    if idPrefixes.contains(prefix) { anchors.append(offset - count) }
                }
            }
            if (97...122).contains(unit) {
                if recent.count == 4 { recent.removeFirst() }
                recent.append(unit)
            } else if !recent.isEmpty { recent.removeAll(keepingCapacity: true) }
            offset += 1
        }
        guard !anchors.isEmpty else { return [] }
        return TextRanges.matches(prefixedID, in: text, around: anchors, before: 1, after: 48).compactMap { match in
            let range = match.range.location..<NSMaxRange(match.range)
            let value = TextRanges.substring(text, range)
            return idLike(value) && !fieldName(value) ? Span(range: range, entity: "RECORD_ID", score: 0.9) : nil
        }
    }
    /// A prefixed identifier in several parts ("cus_odalys_ferriter", "u-4158672290") anywhere in a value.
    private static let partedID = TextPattern(#"(?<![\w-])[A-Za-z]{1,8}[_-][A-Za-z0-9]+(?:[_.-][A-Za-z0-9]+)*(?![\w-])"#)
    /// The identifiers in `text` that spell out someone the document names.
    static func spelled(in text: String, known: Known) -> [Span] {
        guard !known.names.isEmpty || !known.locals.isEmpty || !known.phones.isEmpty else { return [] }
        // Only a letter right before "_" or "-" can start one: dates and phone numbers have none.
        var previous: UInt16 = 0, joined = false
        for unit in text.utf16 {
            if (unit == 95 || unit == 45) && ((65...90).contains(previous) || (97...122).contains(previous)) { joined = true; break }
            previous = unit
        }
        guard joined else { return [] }
        return TextRanges.matches(partedID, in: text).compactMap { match in
            let range = match.range.location..<NSMaxRange(match.range)
            let token = TextRanges.substring(text, range)
            // A type prefixes an ID: "robert_mitchell_notes" starts with a name, and is a name's to replace;
            // "user_key", "per-user" and "login_name" start with a word, and are no one's.
            let prefix = String(token.prefix { $0.isLetter }).lowercased()
            guard !known.names.contains(prefix), personPrefixes.contains(prefix) || !NameLists.isOrdinary(prefix) else { return nil }
            return embeds(token, names: known.names, locals: known.locals, phones: known.phones) ? Span(range: range, entity: "RECORD_ID", score: 0.9) : nil
        }
    }
    /// Prefixes of identifiers that name a thing, not a person: an order, a charge, an event, a request.
    private static let thingPrefixes: Set<String> = ["card", "crd", "ord", "order", "inv", "invoice", "ch", "charge", "txn", "tx", "trx", "evt", "event", "req", "request", "pay", "pi", "pm", "py",
                                                     "sess", "session", "sk", "pk", "rk", "tok", "src", "prod", "price", "sku", "ver", "build", "job", "task", "run", "trace", "span",
                                                     "msg", "file", "doc", "vrf", "chk", "ref", "re", "dp", "po", "sub_sched", "plan", "coupon", "promo", "batch", "item", "line", "wh", "hook"]
    /// A name and its version ("curl8.0", "name1.2"), a release's or a build's tag ("release_2026",
    /// "build-418", "v2.3.1"), or a standard's name ("RFC4716", "ISO-8601"): the same for everyone who writes it.
    static func versioned(_ value: String) -> Bool {
        !TextRanges.matches(versionTag, in: value).isEmpty || Standards.ranges(in: value) == [0..<value.utf16.count]
    }
    private static let versionTag = TextPattern(#"^(?:[A-Za-z][A-Za-z-]*?[-_]?[vV]?\d+(?:\.\d+)+[A-Za-z]?|(?i:release|build|rc|version|ver|tag|hotfix|snapshot|nightly|beta|alpha|patch|sprint|milestone|stable|v)[-_.]?\d[\d._-]*[A-Za-z]?)$"#)
    /// A file's name: a document's, a script's or a configuration's ("config.ini", "deploy.sh").
    static func isFileName(_ value: String) -> Bool {
        guard let dot = value.lastIndex(of: "."), value.index(after: dot) < value.endIndex else { return false }
        let ext = value[value.index(after: dot)...].lowercased()
        return ContextStage.fileExtensions.contains(ext) || configExtensions.contains(ext)
    }
    private static let configExtensions: Set<String> = ["ini", "cfg", "conf", "config", "env", "lock", "bak", "tmp", "dat", "db", "sql", "plist", "properties", "swift", "php",
                                                        "pl", "lua", "jar", "war", "dll", "so", "bin", "tar", "tgz", "bz2", "xz", "7z", "rar", "svg", "webp", "ico", "bmp", "tif", "tiff",
                                                        "ttf", "otf", "woff", "woff2", "wasm", "map", "scss", "sass", "less", "vue", "ipynb", "cs", "scala", "dart", "tf", "pem", "crt"]
    static func technical(_ value: String) -> Bool { thingPrefixes.contains(keptPrefix(value).dropLast().lowercased()) }
    private static let uuid = TextPattern(#"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#)
    /// A UUID names whatever the system made it for; only what is around it says that was a person.
    static func isUUID(_ value: String) -> Bool { !TextRanges.matches(uuid, in: value).isEmpty }

    /// The names, email local parts and phone numbers a document holds.
    struct Known {
        let names: Set<String>, locals: Set<String>, phones: Set<String>
        init(_ gazetteer: [String: Set<String>]) {
            var names: Set<String> = []
            for entity in ["PERSON", "FIRST_NAME", "LAST_NAME"] {
                for value in gazetteer[entity] ?? [] {
                    for word in value.lowercased().split(whereSeparator: { !$0.isLetter }) where word.count >= 4 && !NameLists.isOrdinary(String(word)) { names.insert(String(word)) }
                }
            }
            self.names = names
            // A local part spells someone only when it is no word: "user@", "info@" and "dest@" spell no one.
            locals = Set((gazetteer["EMAIL_ADDRESS"] ?? []).compactMap { email -> String? in
                guard let local = email.split(separator: "@").first.map({ $0.lowercased() }), local.count >= 5, local.contains(where: \.isLetter),
                      !NameLists.isOrdinary(local.filter(\.isLetter)) else { return nil }
                return local
            })
            phones = Set((gazetteer["PHONE_NUMBER"] ?? []).map { value in
                let digits = value.filter(\.isNumber)
                return digits.count == 11 && digits.first == "1" ? String(digits.dropFirst()) : digits
            }.filter { $0.count >= 7 })
        }
    }

    /// Whether a field's value is a person's identifier: under a key that
    /// names one, an "id" inside a person's object or with a person's prefix,
    /// or any identifier that spells out someone the document names.
    /// Keys whose value says what a record is ("resourceType": "Patient", "object": "customer").
    static let typeKeys: Set<String> = ["resourcetype", "object", "type", "kind", "entity", "entitytype", "objecttype", "recordtype"]
    /// Whether a type field says the record is a person or their account.
    static func namesPersonType(key: String?, value: String) -> Bool {
        typeKeys.contains(KeyHints.words(key).joined()) && people.contains(value.lowercased())
    }
    /// Whether a value can be a plain "id" that names someone: shaped like an
    /// identifier, with a digit in it, and no prefix of a thing's ("ord_", "evt_").
    static func plainID(_ value: String) -> Bool { shaped(value) && idLike(value) && !technical(value) }
    /// Generated rather than written: a digit after any prefix ("48213177", "u_1234"), or letters
    /// in both cases, mixed as no word is ("usr_jwLHzYUsfaqhdNYV"), where "contact_preference",
    /// "lastName" and "FIRST_NAME" are words.
    /// A field's name that happens to start like an ID: an ordinary word numbered
    /// ("user_street1", "user_address2"), as a key or a column is, never an account's ID.
    static func fieldName(_ value: String) -> Bool {
        let body = value.dropFirst(keptPrefix(value).count)
        let word = body.prefix(while: { $0.isASCII && $0.isLowercase })
        let number = body.dropFirst(word.count)
        return word.count >= 3 && number.count <= 2 && number.allSatisfy { $0.isASCII && $0.isNumber } && NameLists.isOrdinary(String(word))
    }
    private static let reference = TextPattern(#"^(?:[A-Z]+(?:_[A-Z]+)*|[a-z]+(?:[A-Z][a-z]+)+)[_-]\d{1,3}$"#)
    /// A label a document gives its own parts so they can point at each other
    /// ("PRIMARYPARTY_1", "BORROWER_1", "proofDoc-2"): words and a small count, no one's ID.
    static func crossReference(_ value: String) -> Bool { !TextRanges.matches(reference, in: value).isEmpty }
    static func idLike(_ value: String) -> Bool {
        let kept = keptPrefix(value)
        let type = kept.dropLast().lowercased()
        return generated(value.dropFirst(kept.count), typed: personPrefixes.contains(type) || thingPrefixes.contains(type) || isCode(String(kept.dropLast())))
    }
    /// A type's short code no list holds, in one case ("app", "APL"): before
    /// a long body whose case turns inside it, as before a listed type, no
    /// written word follows ("app_wvyxnNnadrziFb").
    private static func isCode(_ letters: String) -> Bool {
        (2...3).contains(letters.count) && letters.allSatisfy(\.isLetter) && (letters == letters.lowercased() || letters == letters.uppercased())
    }

    /// A person's type before an identifier's body, however its case runs:
    /// in a person's own record, "usr_xqdcwmeezfMrm" beside her name and email is hers.
    static func personTyped(_ value: String) -> Bool {
        let kept = keptPrefix(value)
        return shaped(value) && personPrefixes.contains(kept.dropLast().lowercased()) && opaque(value.dropFirst(kept.count))
    }

    /// One unbroken run of eight letters or digits that no word or name writes: an identifier's body.
    private static func opaque(_ body: Substring) -> Bool {
        let lower = body.lowercased()
        return body.count >= 8 && body.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            && !NameLists.isOrdinary(lower) && !NameLists.isFirst(lower) && !NameLists.isSurname(lower)
    }

    /// `ownRecord`: the leaf's object holds a person's name or email itself, or says it is a person.
    static func isPersonal(_ leaf: DocumentLeaf, spelled: Known, ownRecord: Bool) -> Bool {
        let key = leaf.rawKey ?? leaf.key
        // An address spelled as an ID ("18_larkspur_ave_tacoma_wa_98402_us", "7_fő_utca_pécs_7621_hu") names where someone lives.
        if idKey(key), leaf.contextWords.contains("address"), !leaf.text.contains(" "), leaf.text.split(separator: "_").count >= 4,
           leaf.text.contains(where: \.isNumber), leaf.text.contains(where: \.isLetter), leaf.text.count <= 128 { return true }
        guard shaped(leaf.text), !crossReference(leaf.text) else { return false }
        // A sample that writes its own field's name ("accountRef": "ACCOUNTREF", "user": "USER_1") holds no one's ID;
        // a number after the field's code is one ("mrn": "MRN-00482913").
        if KeyHints.words(leaf.text).joined() == KeyHints.words(key).joined()
            || leaf.text.lowercased().filter(\.isLetter) == (key ?? "").lowercased().filter(\.isLetter) && leaf.text.filter(\.isNumber).count < 3 { return false }
        if identifying(key: key, value: leaf.text) { return true }
        guard idKey(key) else { return false }
        // A flattened column names its object first ("actor.id"): the field is its last part, as a nested key is.
        let words = KeyHints.words(key?.split(separator: ".").last.map(String.init))
        // Any of a device's identifiers is the person's who uses it: "device": {"signals": {"hashId": …}}, "device": {"fingerprint": …}.
        if leaf.contextWords.contains("device"), ["id", "fingerprint", "hash"].contains(words.last ?? ""), plainID(leaf.text) || isUUID(leaf.text) || leaf.text.count >= 16 && leaf.text.allSatisfy(\.isHexDigit) { return true }
        if words == ["id"] || words == ["uid"] {
            let prefix = keptPrefix(leaf.text).dropLast().lowercased()
            // A person's own object: under a collection of people, beside their name or email, or with a person's prefix.
            // Beside a name or email, a UUID may be a verification's or an event's: it needs a person around it by name.
            let personal = ownRecord && !isUUID(leaf.text) || leaf.contextWords.contains(where: people.contains)
            if personPrefixes.contains(prefix) && idLike(leaf.text) || plainID(leaf.text) && personal { return true }
            if ownRecord, personTyped(leaf.text) { return true }
        }
        return embeds(leaf.text, names: spelled.names, locals: spelled.locals, phones: spelled.phones)
    }
}
