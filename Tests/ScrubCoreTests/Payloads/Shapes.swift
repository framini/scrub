import Foundation
@testable import ScrubCore

/// Payload shapes as APIs send them: flat signups, nested applicants, match
/// results, payments, list pages, form fields, webhooks, audit logs, HR records,
/// FHIR patients, bank accounts and identity checks (see `identity`).
extension PayloadGen {
    static let shapes = ["signup", "applicant", "verification", "payment", "list", "form", "webhook", "audit", "employee", "patient", "bank", "identity"]

    mutating func payload(_ shape: String) -> PNode {
        switch shape {
        case "signup": return signup(person())
        case "applicant": return applicant()
        case "verification": return verification()
        case "payment": return payment()
        case "list": return list()
        case "form": return form()
        case "webhook": return webhook()
        case "audit": return audit()
        case "employee": return employee()
        case "patient": return patient()
        case "identity": return identity()
        default: return bank()
        }
    }

    /// A personal field under one of the names APIs give it, sometimes wrapped
    /// in `{"value": …}` or listed under the plural.
    mutating func field(_ variants: [[String]], _ node: PNode, plural: Bool = false, qualifier: String? = nil) -> (String, PNode) {
        var words = gen.choose(variants)
        // Qualified as APIs qualify fields: "customer_email", "applicant_first_name".
        // The parts of one flat address share their qualifier ("billing_city", "billing_zip").
        if let qualifier { words = qualifier.isEmpty ? words : [qualifier] + words }
        else if gen.int(0...5) == 0, !["name", "address", "login", "handle"].contains(words.last!) || words.count > 1 { words = [gen.choose(["customer", "applicant", "user", "primary", "billing", "home"])] + words }
        var node = node
        // Exports often write names in capitals.
        if case .leaf(var leaf) = node, case .pii(let kind) = leaf.truth, kind.isName, gen.int(0...6) == 0 { leaf.text = leaf.text.uppercased(); node = .leaf(leaf) }
        switch gen.int(0...19) {
        case 0, 1: return (key(words), .object([("value", node), (key(["verified"]), .bool(gen.int(0...1) == 0))]))
        case 2: return (key(words), .object([("data", node)]))
        case 3...5 where plural:
            return (key(words.dropLast() + [self.plural(words.last!)]), .array([node], item: key(words)))
        default: return (key(words), node)
        }
    }

    static let firstKeys = [["first", "name"], ["given", "name"], ["firstname"], ["fname"], ["forename"], ["name", "first"]]
    static let lastKeys = [["last", "name"], ["family", "name"], ["surname"], ["lastname"], ["lname"], ["name", "last"]]
    static let fullKeys = [["full", "name"], ["legal", "name"], ["customer", "name"], ["applicant", "name"], ["account", "holder", "name"], ["contact", "name"], ["display", "name"]]
    static let emailKeys = [["email"], ["email", "address"], ["primary", "email"], ["contact", "email"], ["personal", "email"], ["email", "addr"]]
    static let phoneKeys = [["phone"], ["phone", "number"], ["mobile"], ["mobile", "number"], ["mobile", "phone"], ["cell", "phone"], ["home", "phone"], ["contact", "phone"], ["telephone"]]
    static let ssnKeys = [["ssn"], ["social", "security", "number"], ["ssn", "number"], ["tax", "id"], ["national", "id"], ["tin"]]
    static let dobKeys = [["dob"], ["date", "of", "birth"], ["birth", "date"], ["birthdate"], ["birthday"]]
    static let streetKeys = [["address", "line", "1"], ["address", "line1"], ["line1"], ["street"], ["street", "address"], ["address1"], ["street1"]]
    static let zipKeys = [["zip"], ["zip", "code"], ["postal", "code"], ["postcode"], ["zipcode"], ["postal"]]
    static let ipKeys = [["ip"], ["ip", "address"], ["client", "ip"], ["remote", "addr"], ["source", "ip"], ["device", "ip"]]

    /// A UK nation ("England") names no one and may stay; a state or province is personal.
    mutating func region(_ p: Person) -> PNode {
        p.country == "GB" ? leaf(p.stateName, .ignore) : leaf(gen.int(0...3) == 0 ? p.stateName : p.state, .pii(.region))
    }
    mutating func country(_ p: Person) -> PNode {
        keep(gen.choose(["US": ["US", "USA"], "CA": ["CA", "Canada"], "GB": ["GB", "UK"], "AU": ["AU", "Australia"]][p.country]!))
    }
    mutating func unit() -> String {
        gen.choose(["Apt \(gen.int(2...9))\(gen.choose(["A", "B", "C"]))", "Suite \(gen.int(100...450))", "Unit \(gen.int(2...40))", "#\(gen.int(2...99))", "Apt. \(gen.int(10...30))", "Floor \(gen.int(2...12))"])
    }
    /// An address object: every part comes from one real place, and must still
    /// after scrubbing (the "a…" link), however its keys are written.
    mutating func address(_ p: Person, link: String) -> PNode {
        var pairs: [(String, PNode)] = [field(Self.streetKeys, leaf(p.street, .pii(.street)))]
        if gen.int(0...2) == 0 { pairs.append((key(gen.choose([["address", "line", "2"], ["line2"], ["address2"], ["unit"], ["street2"], ["apartment"], ["extended", "address"], ["address3"]])), leaf(unit(), .pii(.unit)))) }
        pairs.append(field([["city"], ["locality"], ["town"], ["municipality"]], leaf(p.city, .pii(.city))))
        pairs.append((key(gen.choose([["state"], ["region"], ["state", "code"], ["province"], ["state", "or", "province"]])), region(p)))
        pairs.append(field(Self.zipKeys, zip(p)))
        pairs.append((key(gen.choose([["country"], ["country", "code"]])), country(p)))
        if gen.int(0...3) == 0 {
            let (lat, lng) = gen.choose([(["latitude"], ["longitude"]), (["lat"], ["lng"]), (["lat"], ["lon"])])
            let number = gen.int(0...2) > 0
            pairs.append((key(lat), leaf(p.latitude, .pii(.latitude), number: number)))
            pairs.append((key(lng), leaf(p.longitude, .pii(.longitude), number: number)))
        }
        if gen.int(0...4) == 0 { pairs.append((key(gen.choose([["formatted"], ["full", "address"], ["formatted", "address"]])), leaf("\(p.street), \(p.city), \(p.state) \(p.zip)", .pii(.addressLine)))) }
        return linked(.object(gen.shuffled(pairs)), link)
    }

    /// A field that must follow others: linked only when it sits directly in
    /// its record, since a `{"value": …}` wrapper is a record of its own.
    mutating func field(_ variants: [[String]], _ node: PNode, plural: Bool = false, links: [String], qualifier: String? = nil) -> (String, PNode) {
        let (name, value) = field(variants, node, plural: plural, qualifier: qualifier)
        if case .leaf = value { return (name, linked(value, links)) }
        if case .array(let members, _) = value, members.count == 1, case .leaf = members[0] { return (name, linked(value, links)) }
        return (name, value)
    }

    mutating func signup(_ p: Person) -> PNode {
        let place = addressLink()
        var pairs: [(String, PNode)] = [
            (key(["id"]), personID("usr")),
            field(Self.firstKeys, linked(leaf(p.first, .pii(.firstName)), p.link("name"))),
            field(Self.lastKeys, linked(leaf(p.last, .pii(.lastName)), p.link("name"))),
            field(Self.emailKeys, linked(leaf(p.email, .pii(.email)), p.link("name")), plural: true),
            field(Self.phoneKeys, phone(p), plural: true, links: [place]),
            field(Self.dobKeys, dob(p)),
            (key(["status"]), keep(status())),
            (key(["created", "at"]), timestamp()),
        ]
        if gen.int(0...1) == 0 { pairs.append(field(Self.ssnKeys, ssn(p))) }
        if gen.int(0...1) == 0 { pairs.append((key(["address"]), address(p, link: place))) }
        else {
            let qualifier = gen.choose(["", "", "billing", "home", "mailing"])
            pairs.append(field(Self.streetKeys, leaf(p.street, .pii(.street)), links: [place], qualifier: qualifier))
            pairs.append(field([["city"]], leaf(p.city, .pii(.city)), links: [place], qualifier: qualifier))
            pairs.append((key((qualifier.isEmpty ? [] : [qualifier]) + gen.choose([["state"], ["region"], ["province"]])), linked(region(p), place)))
            pairs.append(field(Self.zipKeys, zip(p), links: [place], qualifier: qualifier))
        }
        if gen.int(0...2) == 0 { pairs.append(field(Self.ipKeys, leaf(p.ip, .pii(.ip)))) }
        if gen.int(0...2) == 0 { pairs.append(field([["username"], ["user", "name"], ["login"], ["handle"]], leaf(p.username, .pii(.username)), links: [p.link("name")])) }
        // A time zone is a setting, but beside an address it moves with it.
        if gen.int(0...2) == 0 { pairs.append((key(gen.choose([["timezone"], ["time", "zone"], ["tz"]])), linked(leaf(gen.choose(["America/Chicago", "America/Los_Angeles", "America/New_York", "Europe/Berlin"]), .ignore), place))) }
        if gen.int(0...2) == 0 { pairs.append((key(["locale"]), keep(gen.choose(["en-US", "es-MX", "fr-CA"])))) }
        // Values read off others: the end of the SSN, the birth year and age, the initials.
        if gen.int(0...2) == 0 {
            let last4 = String(p.ssn.filter(\.isNumber).suffix(4))
            pairs.append(gen.int(0...2) == 0
                ? (key(gen.choose([["masked", "ssn"], ["ssn", "masked"]])), linked(leaf("***-**-" + last4, .pii(.lastDigits)), p.link("ssn")))
                : (key(gen.choose([["ssn", "last4"], ["last4", "ssn"], ["ssn", "last", "four"], ["last", "4", "ssn"]])), linked(leaf(last4, .pii(.lastDigits), number: gen.int(0...2) == 0 && last4.first != "0"), p.link("ssn"))))
        }
        if gen.int(0...2) == 0 {
            let number = gen.int(0...1) == 0
            pairs.append((key(gen.choose([["birth", "year"], ["year", "of", "birth"], ["yob"]])), linked(leaf(String(p.dob.year!), .pii(.dobYear), number: number), p.link("dob"))))
            pairs.append((key(["age"]), linked(leaf(String(Self.age(p)), .pii(.age), number: number), p.link("dob"))))
        }
        if gen.int(0...3) == 0 {
            let initials = String(p.first.prefix(1)) + String(p.last.prefix(1))
            pairs.append((key(gen.choose([["initials"], ["name", "initials"]])), linked(leaf(gen.int(0...1) == 0 ? initials : initials.map { "\($0)." }.joined(), .pii(.initials)), p.link("name"))))
        }
        if gen.int(0...2) == 0 {
            pairs.append(gen.int(0...1) == 0
                ? (key(gen.choose([["gender"], ["sex"]])), linked(keep(gen.choose(p.gender == "female" ? ["female", "F", "FEMALE"] : ["male", "M", "MALE"])), p.link("name")))
                : (key(["title"]), linked(keep(p.gender == "female" ? gen.choose(["Ms.", "Mrs."]) : "Mr."), p.link("name"))))
        }
        return .object(gen.shuffled(pairs))
    }

    /// Nested the way identity APIs nest: name parts, a split birth date,
    /// contact lists and typed identifiers.
    mutating func applicant() -> PNode {
        let p = person()
        let name: PNode = gen.int(0...1) == 0
            ? .object([(key(["first"]), linked(leaf(p.first, .pii(.firstName)), p.link("name"))), (key(["middle"]), leaf(p.middle, .pii(.middleName))), (key(["last"]), linked(leaf(p.last, .pii(.lastName)), p.link("name")))])
            : .object([(key(["given", "name"]), linked(leaf(p.first, .pii(.firstName)), p.link("name"))), (key(["family", "name"]), linked(leaf(p.last, .pii(.lastName)), p.link("name")))])
        let birth: PNode = gen.int(0...2) == 0
            ? .object([(key(["day"]), leaf(String(p.dob.day!), .ignore, number: true)), (key(["month"]), leaf(String(p.dob.month!), .ignore, number: true)), (key(["year"]), leaf(String(p.dob.year!), .pii(.dobYear), number: true))])
            : dob(p)
        let emails: PNode = gen.int(0...1) == 0
            ? .array([.object([(key(["type"]), keep("personal")), (key(["address"]), linked(leaf(p.email, .pii(.email)), p.link("name")))])], item: "email")
            : .array([linked(leaf(p.email, .pii(.email)), p.link("name"))], item: "email")
        let phones: PNode = .array([.object([(key(["type"]), keep(gen.choose(["mobile", "home"]))), (key(["number"]), phone(p))])], item: "phone")
        let identifier: (String, PNode) = gen.int(0...1) == 0
            ? (key(["identifiers"]), .array([.object([(key(["type"]), keep(gen.choose(["ssn", "SSN", "us_ssn"]))), (key(["value"]), ssn(p))])], item: "identifier"))
            : (key(["national", "id"]), .object([(key(["type"]), keep("SSN")), (key(["value"]), ssn(p))]))
        let body: PNode = .object([
            (key(["id"]), personID("app")),
            (key(["name"]), name),
            (key(["dob"]), birth),
            (key(["address"]), address(p, link: addressLink())),
            (key(["contact"]), .object([(key(["emails"]), emails), (key(["phones"]), phones)])),
            identifier,
        ])
        return .object([(key(["applicant"]), body), (key(["request", "id"]), keep(id("req"))), (key(["created", "at"]), timestamp())])
    }

    /// A match result: personal keys whose values are statuses and scores.
    mutating func verification() -> PNode {
        let p = person()
        var checks: [(String, PNode)] = []
        for words in [gen.choose(Self.firstKeys), gen.choose(Self.lastKeys), gen.choose(Self.dobKeys), gen.choose(Self.ssnKeys), ["address"], gen.choose(Self.phoneKeys), gen.choose(Self.emailKeys)] {
            checks.append((key(words), gen.int(0...3) == 0 ? keep(String(format: "%.2f", Double(gen.int(0...100)) / 100), number: true) : keep(matchStatus())))
        }
        let input: PNode = .object([
            field(Self.firstKeys, leaf(p.first, .pii(.firstName))),
            field(Self.lastKeys, leaf(p.last, .pii(.lastName))),
            field(Self.dobKeys, dob(p)),
            field(Self.ssnKeys, ssn(p)),
            field(Self.phoneKeys, phone(p)),
        ])
        let codes: PNode = .array((0..<gen.int(1...4)).map { _ in keep(gen.choose(["R", "I"]) + String(gen.int(100...999))) }, item: "code")
        return .object([
            (key(["id"]), keep(id("vrf"))),
            (key(["status"]), keep(status())),
            (key(["decision"]), .object([(key(["value"]), keep(gen.choose(["accept", "reject", "review", "ACCEPT", "REFER"]))), (key(["model", "version"]), keep("v\(gen.int(1...9)).\(gen.int(0...20)).\(gen.int(0...9))"))])),
            (key(["input"]), input),
            (key(["checks"]), .object(checks)),
            (key(["reason", "codes"]), codes),
            // Counts and flags named after personal fields.
            (key(["num", "family", "names"]), keep(String(gen.int(0...4)), number: true)),
            (key(["email", "count"]), keep(String(gen.int(0...4)), number: true)),
            (key(["total", "phone", "numbers"]), keep(String(gen.int(0...4)), number: true)),
            (key(["has", "ssn"]), .bool(true)),
            (key(["first", "name", "match", "score"]), keep(String(gen.int(0...100)), number: true)),
            (key(["dob", "source"]), keep(gen.choose(["credit_header", "DMV", "self_reported"]))),
            (key(["risk", "score"]), keep(String(format: "%.3f", Double(gen.int(0...1000)) / 1000), number: true)),
            (key(["created", "at"]), timestamp()),
        ])
    }

    mutating func payment() -> PNode {
        let p = person()
        let last4 = String(p.card.filter(\.isNumber).suffix(4))
        var card: [(String, PNode)] = [("issuer", keep(gen.choose(["Northwind Visa Sandbox", "Harbor Federal Credit Union", "Bluebird Bank"]))), ("brand", keep(p.card.hasPrefix("4") ? "visa" : "mastercard")), ("last4", linked(leaf(last4, .pii(.lastDigits)), p.link("card"))), ("exp_month", keep(String(gen.int(1...12)), number: true)), ("exp_year", keep(String(gen.int(2026...2031)), number: true)), ("funding", keep("credit"))]
        if gen.int(0...1) == 0 { card.append(("number", linked(leaf(p.card, .pii(.card)), p.link("card")))) }
        let addressPairs: [(String, PNode)] = [("city", leaf(p.city, .pii(.city))), ("country", keep(p.country)), ("line1", leaf(p.street, .pii(.street))), ("line2", .null), ("postal_code", leaf(p.zip, .pii(.zip))), ("state", region(p))]
        let billing: PNode = .object([("address", linked(.object(addressPairs), addressLink())), ("email", linked(leaf(p.email, .pii(.email)), p.link("name"))), ("name", linked(leaf(p.full, .pii(.fullName)), p.link("name"))), ("phone", phone(p))])
        return .object([
            ("id", keep(id("pay"))), ("object", keep("payment")),
            ("amount", keep(String(gen.int(500...250_000)), number: true)), ("currency", keep("usd")),
            ("status", keep(gen.choose(["succeeded", "requires_payment_method", "processing"]))),
            ("state", keep(gen.choose(["open", "paid", "void", "draft"]))),
            ("customer", personID("cus")),
            ("description", keep("Invoice INV-\(gen.int(2022...2026))-\(String(format: "%04d", gen.int(1...9999)))")),
            ("payment_method", .object([("id", keep(id("pm"))), ("type", keep("card")), ("billing_details", billing), ("card", .object(card))])),
            ("metadata", .object([("order_id", leaf(String(gen.int(1_000_000_000...1_999_999_999)), .keepSoft)), ("channel", keep("web"))])),
            // A list named after a secret holds no secret: each authorization's amount, type and network stay.
            ("authorizations", .array((0..<gen.int(1...2)).map { _ in .object([("auth_id", keep(String(gen.int(10000...99999)))), ("amount", keep(String(-gen.int(1...900)), number: true)), ("type", keep(gen.choose(["L", "A", "R"]))), ("network_code", keep(gen.choose(["V", "M"])))]) }, item: "authorization")),
            ("created", keep(String(gen.int(1_650_000_000...1_790_000_000)), number: true)), ("test", .bool(false)),
        ])
    }

    /// A page of flat records: also the source of the CSV rendering.
    mutating func list() -> PNode {
        let count = gen.int(2...4)
        var records: [PNode] = []
        let keys = (first: gen.choose(Self.firstKeys), last: gen.choose(Self.lastKeys), email: gen.choose(Self.emailKeys), phone: gen.choose(Self.phoneKeys), dob: gen.choose(Self.dobKeys), street: gen.choose(Self.streetKeys), zip: gen.choose(Self.zipKeys))
        let format = gen.choose(["yyyy-MM-dd", "MM/dd/yyyy"])
        for _ in 0..<count {
            let p = person()
            let place = addressLink()
            records.append(.object([
                (key(["id"]), personID("cus")),
                (key(keys.first), linked(leaf(p.first, .pii(.firstName)), p.link("name"))),
                (key(keys.last), linked(leaf(p.last, .pii(.lastName)), p.link("name"))),
                (key(keys.email), linked(leaf(p.email, .pii(.email)), p.link("name"))),
                (key(keys.phone), linked(leaf(p.phone, .pii(.phone)), place)),
                (key(keys.dob), leaf(Self.formatDate(p.dob, format), .pii(.dob), dateFormat: format)),
                (key(keys.street), leaf(p.street, .pii(.street))),
                (key(["city"]), linked(leaf(p.city, .pii(.city)), place)),
                (key(["state"]), linked(region(p), place)),
                (key(keys.zip), linked(leaf(p.zip, .pii(.zip)), place)),
                (key(["plan"]), keep(gen.choose(["starter", "pro", "enterprise"]))),
                (key(["balance"]), keep(String(format: "%.2f", Double(gen.int(0...900_000)) / 100), number: true)),
                (key(["created", "at"]), timestamp()),
            ]))
        }
        let envelope = gen.choose([["data"], ["results"], ["items"], ["customers"]])
        return .object([(key(["object"]), keep("list")), (key(envelope), .array(records, item: "record")), (key(["has", "more"]), .bool(false)), (key(["total", "count"]), keep(String(count), number: true))])
    }

    /// Form submissions list fields as name/value pairs.
    mutating func form() -> PNode {
        let p = person()
        let nameKey = gen.choose(["name", "key", "field", "id"])
        func pair(_ fieldName: [String], _ label: String, _ value: PNode) -> PNode {
            .object([(nameKey, keep(key(fieldName))), ("label", keep(label)), ("value", value)])
        }
        let fields: [PNode] = gen.shuffled([
            pair(["first", "name"], "First name", leaf(p.first, .pii(.firstName))),
            pair(["last", "name"], "Last name", leaf(p.last, .pii(.lastName))),
            pair(["email"], "Email", leaf(p.email, .pii(.email))),
            pair(["phone"], "Phone", phone(p)),
            pair(["date", "of", "birth"], "Date of birth", dob(p)),
            pair(["ssn"], "Social Security number", ssn(p)),
            pair(["street", "address"], "Street address", leaf(p.street, .pii(.street))),
            pair(["zip"], "ZIP code", zip(p)),
            pair(["contact", "preference"], "How should we reach you?", keep(gen.choose(["email", "phone", "text"]))),
        ])
        return .object([("form_id", keep(id("frm"))), ("submitted_at", timestamp()), ("fields", .array(fields, item: "field"))])
    }

    mutating func webhook() -> PNode {
        let p = person()
        let old = person()
        return .object([
            (key(["id"]), keep(id("evt"))),
            (key(["type"]), keep(gen.choose(["customer.updated", "applicant.created", "user.signup"]))),
            (key(["created"]), timestamp()),
            (key(["data"]), .object([(key(["object"]), signup(p)), (key(["previous", "attributes"]), .object([field(Self.emailKeys, leaf(old.email, .pii(.email)))]))])),
            (key(["api", "version"]), keep(gen.choose(["2024-06-20", "2025-03-01", "v2"]))),
        ])
    }

    mutating func audit() -> PNode {
        let p = person()
        return .object([
            (key(["timestamp"]), timestamp()),
            (key(["action"]), keep(gen.choose(["user.login", "user.password_reset", "api_key.created", "export.downloaded"]))),
            (key(["actor"]), .object([(key(["id"]), personID("usr")), (key(["email"]), leaf(p.email, .pii(.email))), (key(["name"]), leaf(p.full, .pii(.fullName)))])),
            field(Self.ipKeys, leaf(p.ip, .pii(.ip))),
            (key(["user", "agent"]), keep(gen.choose(Self.userAgents))),
            (key(["location"]), linked(.object([(key(["city"]), leaf(p.city, .pii(.city))), (key(["region"]), region(p)), (key(["country"]), country(p))]
                + (gen.int(0...1) == 0 ? [(key(["coordinates"]), .array([leaf(p.longitude, .pii(.longitude), number: true), leaf(p.latitude, .pii(.latitude), number: true)], item: "coordinate"))] : [])), addressLink())),
            // Settings that share a key with a place or an age.
            (key(["region"]), keep(gen.choose(["us-east-1", "eu-west-2", "ap-southeast-2"]))),
            (key(["cache"]), .object([(key(["max", "age"]), keep("3600", number: true)), (key(["age"]), keep(String(gen.int(10...600)), number: true))])),
            (key(["request", "id"]), keep(id("req"))),
            // A user's ID in a path under "users" is theirs (see URLs); it is judged by URLTests, not here.
            (key(["path"]), leaf("/v1/users/\(id("usr"))/sessions", .ignore)),
            (key(["status", "code"]), keep(String(gen.choose([200, 201, 401, 403])), number: true)),
        ])
    }

    mutating func employee() -> PNode {
        let p = person(), manager = person(), contact = person()
        return .object([(key(["employee"]), .object([
            (key(["employee", "id"]), leaf("E-\(gen.int(10000...99999))", .pii(.recordID))),
            field([["legal", "name"], ["full", "name"], ["name"]], leaf(p.full, .pii(.fullName))),
            (key(["preferred", "name"]), leaf(p.first, .pii(.firstName))),
            (key(["work", "email"]), leaf(p.email, .pii(.email))),
            (key(["job", "title"]), keep(gen.choose(Self.titles))),
            (key(["department"]), keep(gen.choose(Self.departments))),
            (key(["home", "address"]), address(p, link: addressLink())),
            (key(["manager"]), .object([(key(["name"]), leaf(manager.full, .pii(.fullName))), (key(["email"]), leaf(manager.email, .pii(.email)))])),
            (key(["emergency", "contact"]), .object([(key(["name"]), leaf(contact.full, .pii(.fullName))), (key(["relationship"]), keep(gen.choose(["spouse", "parent", "sibling", "partner"]))), (key(["phone"]), phone(contact))])),
            (key(["salary"]), keep(String(gen.int(55...240) * 1000), number: true)),
            (key(["start", "date"]), keep(String(format: "%04d-%02d-%02d", gen.int(2010...2025), gen.int(1...12), gen.int(1...28)))),
            (key(["employer"]), leaf(gen.choose(Self.companies), .keepSoft)),
        ]))])
    }

    /// An HL7 FHIR Patient resource, keys as the standard spells them.
    mutating func patient() -> PNode {
        let p = person()
        let born = PayloadGen.formatDate(p.dob, "yyyy-MM-dd")
        return .object([
            ("resourceType", keep("Patient")), ("id", personID("pat")),
            ("identifier", .array([.object([("system", keep("http://hl7.org/fhir/sid/us-ssn")), ("value", leaf(p.ssn.filter(\.isNumber), .pii(.ssn)))])], item: "identifier")),
            ("name", .array([.object([("use", keep("official")), ("family", leaf(p.last, .pii(.lastName))), ("given", .array([leaf(p.first, .pii(.firstName)), leaf(p.middle, .pii(.middleName))], item: "given"))])], item: "name")),
            ("telecom", .array([
                .object([("system", keep("phone")), ("value", leaf(p.phone, .pii(.phone))), ("use", keep("mobile"))]),
                .object([("system", keep("email")), ("value", leaf(p.email, .pii(.email)))]),
            ], item: "telecom")),
            ("gender", keep(gen.choose(["female", "male", "other"]))),
            ("birthDate", leaf(born, .pii(.dob), dateFormat: "yyyy-MM-dd")),
            ("address", .array([linked(.object([("use", keep("home")), ("line", .array([leaf(p.street, .pii(.street))], item: "line")), ("city", leaf(p.city, .pii(.city))), ("state", region(p)), ("postalCode", leaf(p.zip, .pii(.zip))), ("country", keep(p.country))]), addressLink())], item: "address")),
        ])
    }

    mutating func bank() -> PNode {
        let p = person()
        return .object([
            (key(["account"]), .object([
                (key(["id"]), personID("acct")),
                field([["account", "holder", "name"], ["account", "holder"], ["owner", "name"], ["name", "on", "account"]], leaf(p.full, .pii(.fullName))),
                field([["account", "number"], ["account", "no"], ["acct", "num"]], linked(leaf(p.account, .pii(.account)), p.link("account"))),
                // An account's last four, as aggregators call them.
                (key(["mask"]), linked(leaf(String(p.account.suffix(4)), .pii(.lastDigits)), p.link("account"))),
                (key(["routing", "number"]), leaf(gen.choose(["021000021", "026009593", "121000358"]), .ignore)),
                (key(["type"]), keep(gen.choose(["checking", "savings"]))),
                (key(["currency"]), keep("USD")),
            ])),
            (key(["transactions"]), .array((0..<gen.int(1...3)).map { _ in .object([
                (key(["id"]), keep(id("txn"))),
                (key(["amount"]), keep(String(format: "%.2f", -Double(gen.int(100...90_000)) / 100), number: true)),
                (key(["description"]), keep(gen.choose(["POS PURCHASE GROCERY OUTLET", "ACH DEBIT UTILITY PAYMENT", "ONLINE TRANSFER REF 88213", "ATM WITHDRAWAL"]))),
                (key(["posted", "at"]), timestamp()),
            ]) }, item: "transaction")),
        ])
    }
}
