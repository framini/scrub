import Foundation

final class StandIns {
    private static let secretPrefix = TextPattern(#"^(?:(?:sk|pk|rk)_(?:live|test)_|gh[pousr]_|github_pat_|AKIA|ASIA|xox[abposr]-|eyJ|-----BEGIN [A-Z ]*PRIVATE KEY-----)"#)
    let people: People
    private var assigned: [String: String] = [:]
    private var rng: any RandomNumberGenerator
    init(rng: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.people = People(rng: rng)
        self.rng = rng
    }
    private let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private func pick<T>(_ array: [T]) -> T? { array.randomElement(using: &rng) }
    private func digit(_ first: Bool = false) -> String { String(Int.random(in: first ? 1...9 : 0...9, using: &rng)) }
    private func digits(_ length: Int) -> String { guard length > 0 else { return "" }; return digit(true) + (1..<length).map { _ in digit() }.joined() }
    func replace(_ entity: String, _ original: String, persona: Persona? = nil) -> String {
        let actual = entity == "LOCATION" && people.knows(original) ? "PERSON" : entity
        let key = actual + "\u{0}" + original
        let stablePerson = ["PERSON", "FIRST_NAME", "LAST_NAME"].contains(actual)
        let stableEmail = actual == "EMAIL_ADDRESS" && (persona != nil || people.find(email: original) != nil)
        if !stablePerson && !stableEmail, let found = assigned[key] { return found }
        var fake = "[\(actual)]"
        for _ in 0..<3 {
            let candidate = make(actual, original, persona)
            if candidate.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(original.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame {
                fake = candidate; break
            }
        }
        if !stablePerson && !stableEmail { assigned[key] = fake }
        return fake
    }
    func number(_ original: String) -> String {
        let key = "ID_NUMBER\u{0}" + original
        if let found = assigned[key] { return found }
        var fake = original
        while fake == original { fake = digits(original.count) }
        assigned[key] = fake
        return fake
    }
    func numericLexeme(_ original: String, entity: String) -> String {
        let key = entity + "\u{0}" + original
        if let existing = assigned[key] { return existing }
        let digits = original.filter { $0.isASCII && $0.isNumber }
        if digits == original, entity == "CREDIT_CARD" || entity == "DATE_OF_BIRTH" && digits.count == 8 {
            let fake = make(entity, original, nil)
            assigned[key] = fake
            return fake
        }
        // Only the significant digits are personal: the exponent and a plain
        // decimal's fraction stay, so 2128675309 and 2128675309.0 share a stand-in.
        let exponent = original.firstIndex { $0 == "e" || $0 == "E" } ?? original.endIndex
        let point = exponent == original.endIndex ? original.firstIndex(of: ".") ?? exponent : exponent
        let significant = original[..<point].contains(where: { $0.isASCII && $0.isNumber }) ? point : exponent
        var iterator = number(original[..<significant].filter { $0.isASCII && $0.isNumber }).makeIterator()
        let fake = String(original[..<significant].map { character in
            character.isASCII && character.isNumber ? iterator.next() ?? character : character
        }) + original[significant...]
        assigned[key] = fake
        return fake
    }
    private func make(_ entity: String, _ original: String, _ persona: Persona?) -> String {
        switch entity {
        case "PERSON":
            if persona == nil, !original.contains(" "), let separator = original.first(where: { $0 == "." || $0 == "_" }) {
                let parts = original.split(separator: separator)
                if parts.count == 2 {
                    let person = people.registerFull(parts.joined(separator: " ")).0
                    let handle = person.first + String(separator) + person.last
                    return original == original.lowercased() ? handle.lowercased() : handle
                }
            }
            return persona?.full ?? people.name(for: original)
        case "FIRST_NAME": return (persona ?? people.register(original, nil)).first
        case "LAST_NAME": return (persona ?? people.register(nil, original)).last
        case "EMAIL_ADDRESS":
            if let owner = persona ?? people.find(email: original), original.contains("@") { return people.email(for: owner, original: original) }
            return "\(people.unrelatedName(first: true).lowercased()).\(people.unrelatedName(first: false).lowercased())@\(pick(Names.emailDomains) ?? "example.com")"
        case "PHONE_NUMBER": return "+1 \(digits(3))-555-\(digits(4))"
        case "LOCATION": return pick(Names.cities) ?? "Austin"
        case "ADDRESS": return "\(digits(3)) \(pick(Names.streets) ?? "Main") Street"
        case "DATE_OF_BIRTH": return dateLike(original)
        case "US_SSN": return "\(digits(3))-\(digits(2))-\(digits(4))"
        case "CREDIT_CARD": return card(like: original)
        case "IBAN_CODE":
            let body = "GB00BARC" + digits(14)
            for check in 0...98 {
                let candidate = "GB" + String(format: "%02d", check) + String(body.dropFirst(4))
                if Patterns.iban(candidate) { return candidate }
            }
            return "GB82WEST12345698765432"
        case "IP_ADDRESS": return "203.0.113.\(Int.random(in: 1...254, using: &rng))"
        case "US_BANK_NUMBER": return digits(10)
        case "US_DRIVER_LICENSE": return "A" + digits(7)
        case "US_PASSPORT": return digits(9)
        case "US_ITIN": return "9\(digits(2))-\(digits(2))-\(digits(4))"
        case "MEDICAL_LICENSE": return "AB" + digits(6)
        case "CRYPTO": return "bc1q" + (0..<38).map { _ in String(pick(Array("023456789acdefghjklmnpqrstuvwxyz")) ?? "a") }.joined()
        case "USERNAME": return people.unrelatedName(first: true).lowercased() + digits(3)
        case "SECRET":
            // A CVV, PIN or one-time code stays a short number.
            if (1...8).contains(original.count), original.allSatisfy({ $0.isASCII && $0.isNumber }) { return (0..<original.count).map { _ in digit() }.joined() }
            let prefix = TextRanges.matches(Self.secretPrefix, in: original).first.map { TextRanges.substring(original, $0.range.location..<NSMaxRange($0.range)) } ?? ""
            let kept = prefix.utf16.count < original.utf16.count ? prefix : ""
            return kept + (0..<24).map { _ in String(pick(alphabet) ?? "a") }.joined()
        case "ID_NUMBER", "POSTAL_CODE":
            return String(original.map { char in
                if char.isNumber { return Character(digit()) }
                if char.isLowercase { return pick(Array("abcdefghijklmnopqrstuvwxyz")) ?? "a" }
                if char.isUppercase { return pick(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")) ?? "A" }
                return char
            })
        default: return "[\(entity)]"
        }
    }
    /// Keeps the network (the first digit, two for 3x cards like Amex), the
    /// length and the grouping, with a fresh body and a valid check digit.
    private func card(like original: String) -> String {
        let source = original.filter { $0.isASCII && $0.isNumber }
        let length = (13...19).contains(source.count) ? source.count : 16
        let issuer = source.hasPrefix("3") ? String(source.prefix(2)) : source.first.map(String.init) ?? "4"
        let stem = issuer + (0..<(length - issuer.count - 1)).map { _ in digit() }.joined()
        let digits = (0...9).map { stem + String($0) }.first { Patterns.luhn($0.compactMap(\.wholeNumberValue)) } ?? stem + "0"
        guard source.count == length else { return digits }
        var iterator = digits.makeIterator()
        return String(original.map { $0.isASCII && $0.isNumber ? iterator.next() ?? $0 : $0 })
    }
    private func dateLike(_ original: String) -> String {
        let year = Int.random(in: 1940...1999, using: &rng)
        let month = Int.random(in: 1...12, using: &rng)
        let day = Int.random(in: 1...28, using: &rng)
        if original.count == 8, original.allSatisfy({ $0.isASCII && $0.isNumber }) { return String(format: "%04d%02d%02d", year, month, day) }
        let parts = original.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { "-/ .".contains($0) })
        let separator = original.first(where: { "-/.".contains($0) }) ?? "-"
        guard parts.count == 3 else { return String(format: "%04d-%02d-%02d", year, month, day) }
        if parts[0].count == 4 { return "\(year)\(separator)\(String(format: "%0*d", parts[1].count, month))\(separator)\(String(format: "%0*d", parts[2].count, day))" }
        let dayFirst = (Int(parts[0]) ?? 0) > 12
        let a = dayFirst ? day : month, b = dayFirst ? month : day
        return "\(String(format: "%0*d", parts[0].count, a))\(separator)\(String(format: "%0*d", parts[1].count, b))\(separator)\(year)"
    }
}
