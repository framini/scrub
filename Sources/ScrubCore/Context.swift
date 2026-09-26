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
        ("name fullname contactname customername displayname ownername managername authorname reportername assigneename requestername sendername recipientname holdername cardholder cardholdername accountholder accountholdername patientname employeename", "PERSON"),
        ("firstname givenname middlename", "FIRST_NAME"),
        ("lastname surname familyname", "LAST_NAME"),
        ("email emailaddress mail", "EMAIL_ADDRESS"),
        ("phone phonenumber mobile cell telephone tel fax", "PHONE_NUMBER"),
        ("ssn socialsecuritynumber socialsecurity", "US_SSN"),
        ("address streetaddress street addressline1 addressline2 addr", "ADDRESS"),
        ("dob dateofbirth birthdate birthday", "DATE_OF_BIRTH"),
        ("ip ipaddress clientip remoteip", "IP_ADDRESS"),
        ("city town", "LOCATION"),
        ("zip zipcode postcode postalcode", "POSTAL_CODE"),
        ("password passwd pwd passphrase secret clientsecret apisecret apikey accesskey secretkey privatekey token accesstoken refreshtoken idtoken authtoken sessiontoken bearertoken authorization cookie sessionid otp credential credentials cvv cvc cvv2 securitycode pin", "SECRET"),
        ("username login handle screenname nickname", "USERNAME"),
        ("nationalid nationalidnumber nationalidentifier nationalinsurancenumber nino personalnumber personalidnumber personnummer idnumber identitynumber identitycard idcard idcardnumber governmentid passport passportnumber passportno passportid taxid taxnumber taxpayerid tin sin socialinsurancenumber driverlicense driverslicense driverlicensenumber licensenumber nif nie dni cpf curp pesel bsn aadhaar", "ID_NUMBER")
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
        let parts = words(key)
        guard let last = parts.last else { return nil }
        if secretLast.contains(last) || parts.count >= 2 && secretPairs.contains(parts[parts.count - 2] + last) { return "SECRET" }
        return nil
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
