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
        ("name fullname contactname customername displayname", "PERSON"),
        ("firstname givenname middlename", "FIRST_NAME"),
        ("lastname surname familyname", "LAST_NAME"),
        ("email emailaddress mail", "EMAIL_ADDRESS"),
        ("phone phonenumber mobile cell telephone tel fax", "PHONE_NUMBER"),
        ("ssn socialsecuritynumber socialsecurity", "US_SSN"),
        ("address streetaddress street addressline1 addressline2 addr", "ADDRESS"),
        ("dob dateofbirth birthdate birthday", "DATE_OF_BIRTH"),
        ("ip ipaddress clientip remoteip", "IP_ADDRESS"),
        ("city town", "LOCATION"),
        ("password passwd pwd passphrase secret clientsecret apisecret apikey accesskey secretkey privatekey token accesstoken refreshtoken idtoken authtoken sessiontoken bearertoken authorization cookie sessionid otp", "SECRET"),
        ("username login handle screenname nickname", "USERNAME"),
        ("nationalid nationalidnumber nationalidentifier nationalinsurancenumber nino personalnumber personalidnumber personnummer idnumber identitynumber identitycard idcard idcardnumber governmentid passport passportnumber passportno passportid taxid taxnumber taxpayerid tin sin socialinsurancenumber driverlicense driverslicense driverlicensenumber licensenumber nif nie dni cpf curp pesel bsn aadhaar", "ID_NUMBER")
    ]
    private static let hints = Dictionary(uniqueKeysWithValues: groups.flatMap { names, entity in
        names.split(separator: " ").map { (String($0), entity) }
    })
    public static func hint(_ key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        let compact = key.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return hints[compact]
    }
    public static func words(_ key: String?) -> [String] {
        guard let key else { return [] }
        let spaced = key.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        return spaced.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
