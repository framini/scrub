import Foundation

enum Context {
    static let birth: Set<String> = ["born", "bear", "dob", "birth", "birthday", "birthdate"]
    static let name: Set<String> = ["called", "named", "mr", "mrs", "ms", "dr", "contact", "owner", "customer", "patient", "employee", "its", "it's", "im", "i'm", "with", "w", "spoke", "ask", "tell", "cc"]
    private static let word = TextPattern("[A-Za-z]+(?:['][A-Za-z]+)?")
    static func before(_ range: Range<Int>, in text: String, limit: Int) -> Set<String> {
        Set(words(before: range.lowerBound, in: text, limit: limit).map { $0.lowercased() })
    }
    static func after(_ range: Range<Int>, in text: String, limit: Int) -> Set<String> {
        Set(words(after: range.upperBound, in: text, limit: limit).map { $0.lowercased() })
    }
    // Reads a window that doubles until it holds more words than needed, so a
    // word cut by the window edge is never among those returned; scanning the
    // whole prefix or suffix instead makes long texts quadratic.
    static func words(before end: Int, in text: String, limit: Int, pattern: TextPattern = word) -> [String] {
        var width = 64
        while true {
            let start = max(0, end - width)
            let found = wordsIn(start..<end, of: text, pattern: pattern)
            if start == 0 || found.count > limit { return Array(found.suffix(limit)) }
            width *= 2
        }
    }
    static func words(after start: Int, in text: String, limit: Int, pattern: TextPattern = word) -> [String] {
        let length = (text as NSString).length
        var width = 64
        while true {
            let end = min(length, start + width)
            let found = wordsIn(start..<end, of: text, pattern: pattern)
            if end == length || found.count > limit { return Array(found.prefix(limit)) }
            width *= 2
        }
    }
    private static func wordsIn(_ range: Range<Int>, of text: String, pattern: TextPattern) -> [String] {
        let window = TextRanges.substring(text, range)
        return TextRanges.matches(pattern, in: window).map { TextRanges.substring(window, $0.range.location..<NSMaxRange($0.range)) }
    }
    static func enhanced(_ base: Double, words: Set<String>, range: Range<Int>, text: String) -> Double {
        before(range, in: text, limit: 5).isDisjoint(with: words) ? base : min(1, max(0.4, base + 0.35))
    }
}

public enum KeyHints {
    private static let groups: [(String, String)] = [
        ("name fullname contactname customername displayname ownername managername authorname reportername assigneename requestername sendername recipientname holdername cardholder cardholdername accountholder accountholdername patientname employeename legalname callername nameoncard nameonaccount payeename beneficiaryname billingname shippingname insuredname guarantorname subscribername policyholdername", "PERSON"),
        ("firstname givenname middlename fname forename preferredname", "FIRST_NAME"),
        ("lastname surname familyname lname maidenname", "LAST_NAME"),
        ("email emailaddress emailaddr mail", "EMAIL_ADDRESS"),
        ("phone phonenumber mobile cell telephone tel fax mobilenumber mobilephone cellphone cellnumber phoneno telno telephonenumber contactnumber msisdn", "PHONE_NUMBER"),
        ("ssn socialsecuritynumber socialsecurity ssnnumber", "US_SSN"),
        ("address streetaddress street addressline1 addressline2 addressline line1 line2 addr address1 street1 addr1 streetline1 street2 address2 addr2 streetline2 addressline3 line3 aptsuite apartmentnumber aptnumber suitenumber unitnumber unit apt apartment formattedaddress fulladdress physicaladdress mailingaddress homeaddress residentialaddress billingaddress shippingaddress", "ADDRESS"),
        ("dob dateofbirth birthdate birthday birthyear yearofbirth yob", "DATE_OF_BIRTH"),
        ("age ageyears currentage", "AGE"),
        ("initials nameinitials monogram", "INITIALS"),
        ("latitude lat geolat", "LATITUDE"),
        ("longitude lng lon long geolng geolon", "LONGITUDE"),
        ("coordinates coords latlng latlong latlon geolocation geopoint geocoordinates", "COORDINATES"),
        ("ip ipaddress ipaddr clientip remoteip remoteaddr xforwardedfor", "IP_ADDRESS"),
        ("city town locality", "LOCATION"),
        ("zip zipcode postcode postalcode zip5 zipplus4", "POSTAL_CODE"),
        ("state stateprovince stateorprovince province provincestate region addressregion administrativearea administrativearealevel1 statecode provincecode regioncode stateabbr stateabbreviation countrysubdivision", "REGION"),
        ("password passwd pwd passphrase secret clientsecret apisecret apikey accesskey secretkey privatekey token accesstoken refreshtoken idtoken authtoken sessiontoken bearertoken authorization cookie sessionid otp credential credentials cvv cvc cvv2 securitycode pin", "SECRET"),
        ("username login handle screenname nickname", "USERNAME"),
        ("nationalid nationalidnumber nationalidentifier nationalinsurancenumber nino personalnumber personalidnumber personnummer idnumber identitynumber identitycard idcard idcardnumber governmentid passport passportnumber passportno passportid taxid taxnumber taxpayerid tin sin socialinsurancenumber driverlicense driverslicense driverlicensenumber licensenumber nif nie dni cpf curp pesel bsn aadhaar documentnumber accountnumber bankaccountnumber acctnumber accountno acctno acctnum routingnumber ein creditfilenumber", "ID_NUMBER")
    ]
    private static let hints = Dictionary(uniqueKeysWithValues: groups.flatMap { names, entity in
        names.split(separator: " ").map { (String($0), entity) }
    })
    // Real keys qualify the field ("db_password", "webhook_secret"), so the last
    // word decides. "max_tokens" or "sort_key" name no secret and stay as they are.
    private static let secretLast: Set<String> = ["password", "passwd", "pwd", "passphrase", "secret", "token", "credential", "credentials", "cvv", "cvc", "otp"]
    private static let secretPairs: Set<String> = ["apikey", "accesskey", "secretkey", "privatekey", "encryptionkey", "masterkey", "signingkey", "sshkey", "licensekey", "clientkey", "authkey", "passwordhash", "otpcode", "securitycode", "verificationcode", "recoverycode", "recoverycodes", "backupcodes", "sessionid", "sessioncookie", "authcookie"]
    public static func hint(_ key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        let compact = key.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if let exact = hints[compact] { return exact }
        // Lists of one field ("names", "phone_numbers", "email_addresses") hint like the field.
        if let singular = singular(compact), !unpluralised.contains(singular), let plural = hints[singular] { return plural }
        // "ssn_last4", "card.last4", "last_four_digits": the end of a number, not a count.
        if compact.contains("last4") || compact.contains("lastfour") || compact == "ssn4" { return "LAST_DIGITS" }
        // "ssn_masked": "***-**-7784" still shows the real last digits.
        if compact.contains("masked") || compact.contains("redacted") || compact.contains("obfuscated") { return words(key).contains(where: { ["ssn", "card", "pan", "phone", "account", "acct", "number", "tin", "taxid"].contains($0) }) ? "LAST_DIGITS" : nil }
        let parts = words(key)
        guard let last = parts.last else { return nil }
        if secretLast.contains(last) || parts.count >= 2 && secretPairs.contains(parts[parts.count - 2] + last) { return "SECRET" }
        return qualified(parts)
    }
    /// A field named with a qualifier in front ("billing_email", "home_phone",
    /// "applicant_dob") hints like the field. Only fields that mean the same
    /// whatever qualifies them: a "company_name" is no person and a "mac_address"
    /// no street, so "name" and "address" count only after a personal qualifier.
    private static func qualified(_ parts: [String]) -> String? {
        // A field name runs a few words; a longer "key" is text, and trying every split of it costs its square.
        guard parts.count >= 2, parts.count <= 8 else { return nil }
        for start in 1..<parts.count {
            // "num_family_names", "has_email", "is_phone_verified" describe the field; they don't hold it.
            if parts[..<start].contains(where: countWords.contains) { return nil }
            let suffix = parts[start...].joined()
            let field = hints[suffix] != nil ? suffix : singular(suffix).flatMap { hints[$0] != nil && !unpluralised.contains($0) ? $0 : nil }
            guard let field, let entity = hints[field] else { continue }
            let qualifier = parts[start - 1]
            switch field {
            case "name": if people.contains(qualifier) || roles.contains(qualifier) { return entity }
            case "address", "addr": if addressQualifiers.contains(qualifier) { return entity }
            // "primary_mobile", "customer_cell": a phone, as "is_mobile" and "mobile_app" are not.
            case "mobile", "cell", "tel": if people.contains(qualifier) || roles.contains(qualifier) || addressQualifiers.contains(qualifier) || phoneQualifiers.contains(qualifier) { return entity }
            case "mail", "handle", "login", "pin", "otp", "cookie", "authorization", "passport", "credential", "credentials", "secret", "token": continue
            default: return entity
            }
        }
        return nil
    }
    private static let phoneQualifiers: Set<String> = ["secondary", "alternate", "alt", "other", "personal", "private", "business", "emergency", "direct", "day", "evening", "night"]
    private static let countWords: Set<String> = ["num", "number", "count", "counts", "total", "has", "is", "max", "min", "avg", "sum", "qty", "len", "length", "size", "match", "matches", "score", "verified", "valid", "exists", "present", "changed", "updated", "type", "status", "source", "flag", "enabled", "required", "last4", "hash", "hashed", "format", "domain", "risk"]
    static let addressQualifiers: Set<String> = ["home", "mailing", "billing", "shipping", "residential", "street", "physical", "postal", "current", "previous", "permanent", "primary", "customer", "user", "applicant", "contact", "work", "residence", "legal", "delivery", "registered"]
    // Plurals that name something else: spreadsheet "cells", event "logins".
    private static let unpluralised: Set<String> = ["cell", "tel", "mail", "handle", "login"]
    private static func singular(_ compact: String) -> String? {
        if compact.hasSuffix("ies") { return String(compact.dropLast(3)) + "y" }
        if compact.hasSuffix("sses") { return String(compact.dropLast(2)) }
        if compact.hasSuffix("s") && !compact.hasSuffix("ss") { return String(compact.dropLast()) }
        return nil
    }
    /// The key a value is read under, given the key its container is read under.
    /// A key naming nothing takes its parent's meaning when anything under a
    /// secret is secret ("credentials": {"user": …}) or it only holds the parent's
    /// value ("id_number": {"value": …}, "emails": [{"data": …}]). Parts of a
    /// field are read as the part: "name": {"first": …}, "phones": [{"number": …}],
    /// "emails": [{"address": …}], "address": {"line": […]}, "dob": {"year": …}.
    static func resolve(_ key: String?, parent: String?) -> String? {
        guard let parentHint = hint(parent) else { return key }
        let own = hint(key)
        let compact = words(key).joined()
        switch parentHint {
        case "SECRET" where own == nil: return parent
        case "PERSON":
            if ["first", "given", "givennames", "forenames", "firstnames"].contains(compact) { return "first_name" }
            if ["middle", "middlenames", "middles"].contains(compact) { return "middle_name" }
            if ["last", "family", "familynames", "lastnames", "surnames"].contains(compact) { return "last_name" }
            if ["full", "display", "formatted", "text"].contains(compact) { return "full_name" }
        case "PHONE_NUMBER" where ["number", "digits", "e164", "national", "nationalnumber", "international", "internationalnumber", "formatted", "raw", "full"].contains(compact): return parent
        case "EMAIL_ADDRESS" where ["address", "addr"].contains(compact): return parent
        case "ADDRESS" where ["line", "lines", "text", "formatted", "full"].contains(compact): return parent
        case "DATE_OF_BIRTH" where ["year", "month", "day", "yyyy", "mm", "dd"].contains(compact): return parent
        default: break
        }
        return own == nil && valueKeys.contains(compact) ? parent : key
    }
    private static let valueKeys: Set<String> = ["value", "data"]
    /// An object that only wraps a field's value with notes about it
    /// (`{"value": …, "verified": true}`), and so is part of the record around it.
    static func isWrapper(_ keys: [String]) -> Bool {
        let compact = keys.map { words($0).joined() }
        return (1...4).contains(compact.count) && compact.contains(where: valueKeys.contains)
            && compact.allSatisfy { valueKeys.contains($0) || wrapperNotes.contains($0) }
    }
    private static let wrapperNotes: Set<String> = ["verified", "isverified", "confirmed", "type", "source", "status", "primary", "isprimary", "label", "updatedat", "confidence", "valid"]
    /// Keys whose sibling says what the value is: form fields, typed identifiers
    /// and FHIR contact points (`{"name": "ssn", "value": …}`, `{"system": "phone", "value": …}`).
    static let fieldValueKeys: Set<String> = ["value", "data", "answer", "response"]
    static let fieldNameKeys: Set<String> = ["name", "key", "field", "fieldname", "fieldid", "fieldkey", "id", "label", "type", "system", "attribute", "property", "question", "code"]
    /// The field a record's value-holding key stands for, from its naming sibling.
    static func namedField(_ key: String, siblings: [(String, String)]) -> String? {
        guard fieldValueKeys.contains(words(key).joined()), hint(key) == nil else { return nil }
        for (name, value) in siblings where name != key && fieldNameKeys.contains(words(name).joined()) && value.utf16.count <= 80 && !isToken(value) {
            if let field = header(value) { return field }
        }
        return nil
    }
    private static let tokenPart = TextPattern(#"\d[A-Za-z]"#)
    /// A record's own ID ("evt_xNptjX29KGaePinQ"), not a field's name: a digit
    /// runs into letters, as no field name writes it ("address1" and "us-ssn"
    /// do not). Read as words, an ID can spell anything ("Pin").
    static func isToken(_ value: String) -> Bool {
        value.split(whereSeparator: { "_-.:/ ".contains($0) }).contains { !TextRanges.matches(tokenPart, in: String($0)).isEmpty }
    }
    /// The key a flattened or spoken field name stands for, as CSV headers and
    /// form fields write them: "billing_details.address.city", "Applicant Name
    /// First", "Contact Phones 0 Number", "http://hl7.org/fhir/sid/us-ssn".
    static func header(_ name: String) -> String? {
        let found = headerKey(name)
        // "location.coordinates.0": a GeoJSON point's first number is its longitude.
        if hint(found) == "COORDINATES", let position = words(name).last, position == "0" || position == "1" {
            let latitudeFirst = words(found).joined().hasPrefix("lat")
            return (position == "0") == latitudeFirst ? "latitude" : "longitude"
        }
        return found
    }
    private static func headerKey(_ name: String) -> String? {
        if hint(name) != nil { return name }
        let parts = words(name).filter { !$0.allSatisfy(\.isNumber) }
        guard !parts.isEmpty, parts.count <= 12, !countWords.contains(parts[0]) || parts.count == 1 else { return nil }
        var parent: String?
        var resolved: String?
        for index in parts.indices {
            let part = parts[index]
            // The longest run of words ending here that names a field ("postal code").
            var here: String? = nil
            for start in stride(from: max(0, index - 3), through: index, by: 1) {
                let run = parts[start...index].joined(separator: "_")
                let joined = parts[start...index].joined()
                if hint(run) != nil, start == index || hints[joined] != nil || singular(joined).map({ hints[$0] != nil }) == true { here = run; break }
            }
            // "Company Name" and "Plan Name" hold no person; "Billing Details Name" does.
            if isBareName(here ?? part), index > 0, parent == nil,
               notPeople.contains(parts[index - 1]) || !parts[..<index].contains(where: { people.contains($0) || roles.contains($0) || ["billing", "shipping"].contains($0) }) {
                resolved = nil
                continue
            }
            let next = resolve(here ?? part, parent: parent)
            resolved = hint(next) != nil ? next : nil
            if let resolved { parent = resolved }
        }
        return resolved
    }
    /// Keys whose values are timestamps, identifiers, codes and settings: what
    /// they hold is read as written, so a date there is no birth date, a
    /// ten-digit time no phone number and "America/Chicago" no place.
    static func isStructural(_ key: String?) -> Bool {
        guard let key, hint(key) == nil, let last = words(key).last else { return false }
        return structuralWords.contains(last)
    }
    private static let structuralWords: Set<String> = ["at", "time", "timestamp", "date", "created", "updated", "modified", "expires", "expiry", "timezone", "tz", "zone", "locale", "id", "uuid", "guid", "status", "type", "kind", "version", "agent", "useragent", "url", "uri", "href", "path", "method", "currency", "hash", "checksum", "signature", "fingerprint", "sku", "code", "codes", "scope", "role", "plan", "tier", "channel", "format", "encoding", "mime", "mimetype", "algorithm", "country", "nationality"]
    private static let needsDigit: Set<String> = ["DATE_OF_BIRTH", "POSTAL_CODE", "US_SSN", "ID_NUMBER", "PHONE_NUMBER", "IP_ADDRESS", "ADDRESS"]
    private static let statusWords: Set<String> = ["match", "mismatch", "matched", "success", "successful", "fail", "failed", "failure", "pass", "passed", "pending", "verified", "unverified", "valid", "invalid", "yes", "no", "true", "false", "null", "nil", "none", "unknown", "active", "inactive", "expired", "redacted", "completed", "canceled", "cancelled", "skipped", "error", "ok", "approved", "rejected", "declined", "missing", "present", "absent", "partial", "exact", "high", "medium", "low", "required", "optional", "enabled", "disabled", "unavailable", "available", "found", "notfound", "nomatch", "fuzzy", "inconclusive", "indeterminate", "review", "accept", "accepted", "reject", "refer", "referred", "flagged", "clear", "cleared", "blocked", "allowed", "confirmed", "unconfirmed", "hit", "nohit", "consider", "manual", "mixed", "masked", "suppressed", "withheld", "na", "n/a"]
    /// Whether a value can be what its key names. Result fields reuse personal
    /// keys for statuses ("first_name": "match", "date_of_birth": "no_match")
    /// and sources ("address": ["USPS"], "firstName": ["Government"]), which are
    /// left to detection instead of becoming names, dates and streets.
    static func fits(_ key: String?, _ value: String) -> Bool {
        guard let entity = hint(key), entity != "SECRET" else { return true }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if typeWords.contains(trimmed.lowercased()) { return false }
        if entity == "USERNAME" { return true }
        // A second address line is a unit ("Apt 4B", "Suite 210", "#12"), not a measure.
        if entity == "ADDRESS", unitKeys.contains(compactKey(key)) || unitKeys.contains(words(key).last ?? "") || unitKeys.contains(words(key).suffix(2).joined()) {
            let first = trimmed.split(whereSeparator: { $0 == " " || $0 == "." }).first.map { $0.lowercased() } ?? ""
            return trimmed.contains(where: \.isNumber) && (["apt", "apartment", "suite", "ste", "unit", "floor", "fl", "room", "rm", "bldg", "building", "po", "p", "box"].contains(first) || trimmed.hasPrefix("#") || !trimmed.contains(" ") && trimmed.count <= 6)
        }
        if needsDigit.contains(entity) {
            // A score ("0.74") rates the field; a phone number has at least seven digits.
            let unsigned = trimmed.first == "-" || trimmed.first == "+" ? trimmed.dropFirst() : Substring(trimmed)
            if let point = unsigned.firstIndex(of: "."), point < unsigned.index(before: unsigned.endIndex),
               unsigned.allSatisfy({ $0 == "." || $0.isASCII && $0.isNumber }), unsigned.filter({ $0 == "." }).count == 1 { return false }
            if entity == "PHONE_NUMBER" { return trimmed.filter(\.isNumber).count >= 7 }
            return trimmed.contains(where: \.isNumber)
        }
        if entity == "EMAIL_ADDRESS" { return trimmed.contains("@") }
        // "state": "open" and "region": "us-east-1" hold no place.
        if entity == "REGION" { return Places.region(trimmed) != nil }
        if entity == "LATITUDE" || entity == "LONGITUDE" { return coordinate(trimmed, limit: entity == "LATITUDE" ? 90 : 180) }
        if entity == "COORDINATES" {
            let pair = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return pair.count == 2 && coordinate(pair[0], limit: 180) && coordinate(pair[1], limit: 180)
        }
        if entity == "AGE" { return Int(trimmed).map { (0...120).contains($0) } ?? false }
        // "OB", "O.B.", "O. A. B."
        if entity == "INITIALS" {
            let letters = trimmed.filter { $0 != "." && $0 != " " }
            return (1...4).contains(letters.count) && letters.allSatisfy { $0.isLetter && $0.isUppercase }
        }
        // "7784", "***-**-7784", "•••• 1111"
        if entity == "LAST_DIGITS" {
            return trimmed.filter(\.isNumber).count == 4 && trimmed.allSatisfy { $0.isNumber || "*•xX#- .".contains($0) }
        }
        // A score ("0.86") or a count rates the field; a name has letters.
        if ["PERSON", "FIRST_NAME", "LAST_NAME", "LOCATION"].contains(entity), !trimmed.contains(where: \.isLetter) { return false }
        if ["PERSON", "FIRST_NAME", "LAST_NAME"].contains(entity), NameTagger.namesOrganisation(trimmed) { return false }
        // Statuses are words joined by underscores ("partial_match", "NO_MATCH"),
        // lowercase or in capitals.
        let folded = trimmed == trimmed.uppercased() ? trimmed.lowercased() : trimmed
        let status = !folded.isEmpty && folded.first != "_" && folded.last != "_" && !folded.contains("__")
            && folded.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || $0 == "_" }
        return !status || !folded.contains("_") && !statusWords.contains(folded)
    }
    private static let unitKeys: Set<String> = ["unit", "apt", "apartment", "street2", "address2", "addr2", "line2", "addressline2", "streetline2", "aptsuite", "apartmentnumber", "aptnumber", "suitenumber", "unitnumber", "addressline3", "line3"]
    private static func compactKey(_ key: String?) -> String { (key ?? "").lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) } }
    /// A coordinate written to at least two decimals ("47.2529"); a bare 47 is a count.
    private static func coordinate(_ text: String, limit: Double) -> Bool {
        guard let value = Double(text), abs(value) <= limit, let point = text.firstIndex(of: ".") else { return false }
        return text[text.index(after: point)...].count >= 2 && text[text.index(after: point)...].allSatisfy(\.isNumber)
    }
    // Code declares fields with their types (`email: string`, `first_name: str`).
    private static let typeWords: Set<String> = ["string", "str", "number", "int", "integer", "bool", "boolean", "float", "double", "decimal", "date", "datetime", "object", "any", "unknown", "void", "undefined", "none", "null", "nil", "text", "varchar", "char", "uuid", "list", "dict", "array", "optional", "string?", "string | null", "str | none", "optional[str]"]
    /// A bare "name" key, which names accounts, products and plans as often as people.
    static func isBareName(_ key: String?) -> Bool {
        words(key) == ["name"]
    }
    private static let personalSiblings: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME", "EMAIL_ADDRESS", "PHONE_NUMBER", "DATE_OF_BIRTH", "US_SSN", "ID_NUMBER", "USERNAME"]
    private static let people: Set<String> = ["user", "customer", "contact", "employee", "patient", "person", "people", "member", "owner", "student", "applicant", "candidate", "passenger", "traveler", "traveller", "signer", "signatory", "holder", "accountholder", "cardholder", "author", "profile", "individual", "borrower", "tenant", "buyer", "seller", "payee", "payer", "driver", "worker", "staff", "teammate", "actor"]
    private static let notPeople: Set<String> = ["business", "company", "organization", "organisation", "merchant", "employer", "vendor", "institution", "bank", "product", "plan", "model", "account", "app", "application", "project", "team", "workflow", "enrichment", "template", "school"]
    /// Whether a bare "name" holds a person: its record also holds personal details,
    /// its parent is about people ("customers", "manager"), or the value uses a known
    /// first or last name. Otherwise, as for "Everyday Checking", detection decides.
    static func bareNameIsPerson(_ value: String, siblings: [String], parent: String?) -> Bool {
        let parts = value.split(whereSeparator: { !$0.isLetter })
        let known = parts.contains { Names.firstFolded.contains($0.lowercased()) || Names.lastFolded.contains($0.lowercased()) }
        // One unknown word ("NORTHWIND") names a business or product more often than a person.
        if parts.count < 2 && !known { return false }
        if let parent, notPeople.contains(words(parent).last.map { singular($0) ?? $0 } ?? "") { return false }
        if siblings.contains(where: { !isBareName($0) && hint($0).map(personalSiblings.contains) == true }) { return true }
        if let parent {
            let compact = parent.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            let last = words(parent).last ?? ""
            if isRole(parent) || [compact, last, singular(compact) ?? "", singular(last) ?? ""].contains(where: people.contains) { return true }
        }
        return known
    }
    // Keys naming a person's role ("assigned_to", "manager") often hold an ID
    // or an email, so they only mark a value that is written like a name.
    private static let roles: Set<String> = ["manager", "approver", "reporter", "author", "assignee", "assignedto", "owner", "requester", "requestedby", "reviewer", "reviewedby", "sender", "recipient", "createdby", "updatedby", "modifiedby", "submittedby", "approvedby", "contact", "contactperson", "agent", "rep", "salesrep", "accountmanager", "supervisor", "signedby", "attendee", "guest", "beneficiary", "emergencycontact", "nextofkin", "spouse", "parent", "guardian", "customer", "client", "patient", "applicant", "employee", "member", "guest", "tenant", "borrower", "insured", "policyholder", "passenger", "traveler", "traveller", "attn", "attention", "shipto", "billto", "soldto", "deliverto", "addressee", "cardholder", "accountholder", "signer", "witness", "caller", "visitor", "student", "candidate"]
    static func isRole(_ key: String?) -> Bool {
        guard let key else { return false }
        let parts = words(key)
        guard let last = parts.last else { return false }
        return roles.contains(parts.joined()) || roles.contains(last) || parts.count >= 2 && roles.contains(parts[parts.count - 2] + last)
    }
    /// The words of a key: "billing_details.postalCode" → billing, details, postal, code.
    public static func words(_ key: String?) -> [String] {
        guard let key else { return [] }
        var result: [String] = []
        var current = ""
        var previous: Character?
        for character in key {
            if character.isLetter || character.isNumber {
                // camelCase: a capital after a lowercase letter or a digit starts a word.
                if let previous, ("a"..."z").contains(previous) || ("0"..."9").contains(previous), ("A"..."Z").contains(character), !current.isEmpty {
                    result.append(current.lowercased())
                    current = ""
                }
                current.append(character)
            } else if !current.isEmpty {
                result.append(current.lowercased())
                current = ""
            }
            previous = character
        }
        if !current.isEmpty { result.append(current.lowercased()) }
        return result
    }
}
