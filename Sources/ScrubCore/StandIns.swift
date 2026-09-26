import Foundation

final class StandIns {
    let people = People()
    private var assigned: [String: String] = [:]
    private var rng = SystemRandomNumberGenerator()
    private let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private func pick<T>(_ array: [T]) -> T? { array.randomElement(using: &rng) }
    private func digit(_ first: Bool = false) -> String { String(Int.random(in: first ? 1...9 : 0...9, using: &rng)) }
    private func digits(_ length: Int) -> String { guard length > 0 else { return "" }; return digit(true) + (1..<length).map { _ in digit() }.joined() }
    func replace(_ entity: String, _ original: String, persona: Persona? = nil) -> String {
        let actual = entity == "LOCATION" && people.knows(original) ? "PERSON" : entity
        let key = actual + "\u{0}" + original
        if let found = assigned[key] { return found }
        var fake = "[\(actual)]"
        for _ in 0..<3 {
            let candidate = make(actual, original, persona)
            if candidate.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(original.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame {
                fake = candidate; break
            }
        }
        assigned[key] = fake
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
    private func make(_ entity: String, _ original: String, _ persona: Persona?) -> String {
        switch entity {
        case "PERSON": return persona?.full ?? people.name(for: original)
        case "FIRST_NAME": return (persona ?? people.register(original, nil)).first
        case "LAST_NAME": return (persona ?? people.register(nil, original)).last
        case "EMAIL_ADDRESS":
            if let owner = persona ?? people.find(email: original), original.contains("@") { return people.email(for: owner, original: original) }
            return "\(pick(Names.first)?.lowercased() ?? "alex").\(pick(Names.last)?.lowercased() ?? "smith")@\(pick(Names.emailDomains) ?? "example.com")"
        case "PHONE_NUMBER": return "+1 \(digits(3))-555-\(digits(4))"
        case "LOCATION": return pick(Names.cities) ?? "Austin"
        case "ADDRESS": return "\(digits(3)) \(pick(Names.streets) ?? "Main") Street"
        case "DATE_OF_BIRTH": return dateLike(original)
        case "US_SSN": return "\(digits(3))-\(digits(2))-\(digits(4))"
        case "CREDIT_CARD":
            let stem = "4111" + (0..<11).map { _ in digit() }.joined()
            for check in 0...9 where Patterns.luhn((stem + String(check)).compactMap(\.wholeNumberValue)) { return stem + String(check) }
            return "4111111111111111"
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
        case "USERNAME": return (pick(Names.first)?.lowercased() ?? "alex") + digits(3)
        case "SECRET":
            let prefix = TextRanges.matches(#"^(?:(?:sk|pk|rk)_(?:live|test)_|gh[pousr]_|github_pat_|AKIA|ASIA|xox[abposr]-|eyJ|-----BEGIN [A-Z ]*PRIVATE KEY-----)"#, in: original).first.map { TextRanges.substring(original, $0.range.location..<NSMaxRange($0.range)) } ?? ""
            let kept = prefix.utf16.count < original.utf16.count ? prefix : ""
            return kept + (0..<24).map { _ in String(pick(alphabet) ?? "a") }.joined()
        case "ID_NUMBER":
            return String(original.map { char in
                if char.isNumber { return Character(digit()) }
                if char.isLowercase { return pick(Array("abcdefghijklmnopqrstuvwxyz")) ?? "a" }
                if char.isUppercase { return pick(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")) ?? "A" }
                return char
            })
        default: return "[\(entity)]"
        }
    }
    private func dateLike(_ original: String) -> String {
        let year = Int.random(in: 1940...1999, using: &rng)
        let month = Int.random(in: 1...12, using: &rng)
        let day = Int.random(in: 1...28, using: &rng)
        let parts = original.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { "-/ .".contains($0) })
        let separator = original.first(where: { "-/.".contains($0) }) ?? "-"
        guard parts.count == 3 else { return String(format: "%04d-%02d-%02d", year, month, day) }
        if parts[0].count == 4 { return "\(year)\(separator)\(String(format: "%0*d", parts[1].count, month))\(separator)\(String(format: "%0*d", parts[2].count, day))" }
        let dayFirst = (Int(parts[0]) ?? 0) > 12
        let a = dayFirst ? day : month, b = dayFirst ? month : day
        return "\(String(format: "%0*d", parts[0].count, a))\(separator)\(String(format: "%0*d", parts[1].count, b))\(separator)\(year)"
    }
}
