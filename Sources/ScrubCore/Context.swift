import Foundation

enum Context {
    static let birth: Set<String> = ["born", "bear", "dob", "birth", "birthday", "birthdate"]
    static let name: Set<String> = ["called", "named", "mr", "mrs", "ms", "dr", "contact", "owner", "customer", "patient", "employee", "its", "it's", "im", "i'm", "with", "w", "spoke", "ask", "tell", "cc"]
    static func before(_ range: Range<Int>, in text: String, limit: Int) -> Set<String> {
        let prefix = TextRanges.substring(text, 0..<range.lowerBound)
        let words = TextRanges.matches("[A-Za-z]+", in: prefix).suffix(limit)
        return Set(words.map { TextRanges.substring(prefix, $0.range.location..<NSMaxRange($0.range)).lowercased() })
    }
    static func after(_ range: Range<Int>, in text: String, limit: Int) -> Set<String> {
        let suffix = TextRanges.substring(text, range.upperBound..<(text as NSString).length)
        let words = TextRanges.matches("[A-Za-z]+", in: suffix).prefix(limit)
        return Set(words.map { TextRanges.substring(suffix, $0.range.location..<NSMaxRange($0.range)).lowercased() })
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
    public static func hint(_ key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        let compact = key.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return groups.first { $0.0.split(separator: " ").contains(Substring(compact)) }?.1
    }
    public static func words(_ key: String?) -> [String] {
        guard let key else { return [] }
        let spaced = key.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        return spaced.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
