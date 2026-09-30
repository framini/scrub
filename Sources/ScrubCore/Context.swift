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
        ("name fullname contactname customername displayname ownername managername authorname reportername assigneename requestername sendername recipientname holdername cardholder cardholdername accountholder accountholdername patientname employeename legalname callername", "PERSON"),
        ("firstname givenname middlename", "FIRST_NAME"),
        ("lastname surname familyname", "LAST_NAME"),
        ("email emailaddress mail", "EMAIL_ADDRESS"),
        ("phone phonenumber mobile cell telephone tel fax", "PHONE_NUMBER"),
        ("ssn socialsecuritynumber socialsecurity", "US_SSN"),
        ("address streetaddress street addressline1 addressline2 addressline line1 line2 addr physicaladdress mailingaddress homeaddress residentialaddress billingaddress shippingaddress", "ADDRESS"),
        ("dob dateofbirth birthdate birthday", "DATE_OF_BIRTH"),
        ("ip ipaddress clientip remoteip", "IP_ADDRESS"),
        ("city town locality", "LOCATION"),
        ("zip zipcode postcode postalcode", "POSTAL_CODE"),
        ("password passwd pwd passphrase secret clientsecret apisecret apikey accesskey secretkey privatekey token accesstoken refreshtoken idtoken authtoken sessiontoken bearertoken authorization cookie sessionid otp credential credentials cvv cvc cvv2 securitycode pin", "SECRET"),
        ("username login handle screenname nickname", "USERNAME"),
        ("nationalid nationalidnumber nationalidentifier nationalinsurancenumber nino personalnumber personalidnumber personnummer idnumber identitynumber identitycard idcard idcardnumber governmentid passport passportnumber passportno passportid taxid taxnumber taxpayerid tin sin socialinsurancenumber driverlicense driverslicense driverlicensenumber licensenumber nif nie dni cpf curp pesel bsn aadhaar documentnumber accountnumber bankaccountnumber acctnumber routingnumber ein creditfilenumber", "ID_NUMBER")
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
        let parts = words(key)
        guard let last = parts.last else { return nil }
        if secretLast.contains(last) || parts.count >= 2 && secretPairs.contains(parts[parts.count - 2] + last) { return "SECRET" }
        return nil
    }
    // Plurals that name something else: spreadsheet "cells", event "logins".
    private static let unpluralised: Set<String> = ["cell", "tel", "mail", "handle", "login"]
    private static func singular(_ compact: String) -> String? {
        if compact.hasSuffix("ies") { return String(compact.dropLast(3)) + "y" }
        if compact.hasSuffix("sses") { return String(compact.dropLast(2)) }
        if compact.hasSuffix("s") && !compact.hasSuffix("ss") { return String(compact.dropLast()) }
        return nil
    }
    /// Whether a key naming nothing is read as its parent: anything under a secret
    /// ("credentials": {"user": …}), and a plain "value" or "data" under any hinted
    /// field ("id_number": {"value": "123456789"}, "emails": [{"data": "a@b.co"}]).
    static func inherits(_ key: String?, from parent: String?) -> Bool {
        guard hint(key) == nil, let parentHint = hint(parent) else { return false }
        return parentHint == "SECRET" || ["value", "data"].contains(words(key))
    }
    private static let needsDigit: Set<String> = ["DATE_OF_BIRTH", "POSTAL_CODE", "US_SSN", "ID_NUMBER", "PHONE_NUMBER", "IP_ADDRESS", "ADDRESS"]
    private static let statusWords: Set<String> = ["match", "mismatch", "matched", "success", "successful", "fail", "failed", "failure", "pass", "passed", "pending", "verified", "unverified", "valid", "invalid", "yes", "no", "true", "false", "null", "nil", "none", "unknown", "active", "inactive", "expired", "redacted", "completed", "canceled", "cancelled", "skipped", "error", "ok", "approved", "rejected", "declined", "missing", "present", "absent", "partial", "exact", "high", "medium", "low", "required", "optional", "enabled", "disabled"]
    /// Whether a value can be what its key names. Result fields reuse personal
    /// keys for statuses ("first_name": "match", "date_of_birth": "no_match")
    /// and sources ("address": ["USPS"], "firstName": ["Government"]), which are
    /// left to detection instead of becoming names, dates and streets.
    static func fits(_ key: String?, _ value: String) -> Bool {
        guard let entity = hint(key), entity != "SECRET", entity != "USERNAME" else { return true }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if needsDigit.contains(entity) { return trimmed.contains(where: \.isNumber) }
        if ["PERSON", "FIRST_NAME", "LAST_NAME"].contains(entity), NameTagger.namesOrganisation(trimmed) { return false }
        // Statuses are lowercase words, joined by underscores ("partial_match").
        let status = !trimmed.isEmpty && trimmed.first != "_" && trimmed.last != "_" && !trimmed.contains("__")
            && trimmed.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || $0 == "_" }
        return !status || !trimmed.contains("_") && !statusWords.contains(trimmed)
    }
    /// A bare "name" key, which names accounts, products and plans as often as people.
    static func isBareName(_ key: String?) -> Bool {
        words(key) == ["name"]
    }
    private static let personalSiblings: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME", "EMAIL_ADDRESS", "PHONE_NUMBER", "DATE_OF_BIRTH", "US_SSN", "ID_NUMBER", "USERNAME"]
    private static let people: Set<String> = ["user", "customer", "contact", "employee", "patient", "person", "people", "member", "owner", "student", "applicant", "candidate", "passenger", "traveler", "traveller", "signer", "signatory", "holder", "accountholder", "cardholder", "author", "profile", "individual", "borrower", "tenant", "buyer", "seller", "payee", "payer", "driver", "worker", "staff", "teammate"]
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
    private static let roles: Set<String> = ["manager", "approver", "reporter", "author", "assignee", "assignedto", "owner", "requester", "requestedby", "reviewer", "reviewedby", "sender", "recipient", "createdby", "updatedby", "modifiedby", "submittedby", "approvedby", "contact", "contactperson", "agent", "rep", "salesrep", "accountmanager", "supervisor", "signedby", "attendee", "guest", "beneficiary", "emergencycontact", "nextofkin", "spouse", "parent", "guardian"]
    static func isRole(_ key: String?) -> Bool {
        guard let key else { return false }
        let parts = words(key)
        guard let last = parts.last else { return false }
        return roles.contains(parts.joined()) || roles.contains(last) || parts.count >= 2 && roles.contains(parts[parts.count - 2] + last)
    }
    public static func words(_ key: String?) -> [String] {
        guard let key else { return [] }
        let spaced = key.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        return spaced.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
