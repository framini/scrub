import Foundation

final class Persona {
    var realFirst: String?
    var realLast: String?
    let first: String
    let last: String
    var emails: [String: String] = [:]
    var full: String { "\(first) \(last)" }
    init(realFirst: String?, realLast: String?, first: String, last: String) {
        self.realFirst = realFirst; self.realLast = realLast; self.first = first; self.last = last
    }
    func matches(local: String) -> Bool {
        let parts = Set(local.lowercased().split { !$0.isLetter }.map(String.init))
        let joined = local.lowercased().filter(\.isLetter)
        if let first = realFirst, let last = realLast {
            return (parts.contains(first) && parts.contains(last)) || [first + last, last + first, String(first.prefix(1)) + last, last + String(first.prefix(1))].contains(joined)
        }
        return (realLast.map { parts.contains($0) } ?? false) || (realFirst.map { parts == [$0] } ?? false)
    }
}

final class People {
    private var personas: [Persona] = []
    private var domains: [String: String] = [:]
    private var associatedEmails: [String: Persona] = [:]
    private var rng = SystemRandomNumberGenerator()
    private func fold(_ value: String) -> String { value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).trimmingCharacters(in: .whitespacesAndNewlines) }
    private func pick(_ values: [String]) -> String { values.randomElement(using: &rng) ?? "Alex" }
    func register(_ first: String?, _ last: String?) -> Persona {
        let f = first.map(fold), l = last.map(fold)
        if let found = personas.first(where: { $0.realFirst == f && $0.realLast == l }) { return found }
        let candidates = personas.filter { (f == nil || $0.realFirst == nil || $0.realFirst == f) && (l == nil || $0.realLast == nil || $0.realLast == l) }
        if candidates.count == 1, let found = candidates.first {
            found.realFirst = found.realFirst ?? f; found.realLast = found.realLast ?? l
            return found
        }
        let firstChoices = Names.first.filter { fold($0) != f }
        let lastChoices = Names.last.filter { fold($0) != l }
        let person = Persona(realFirst: f, realLast: l, first: pick(firstChoices), last: pick(lastChoices))
        personas.append(person)
        return person
    }
    func registerFull(_ value: String) -> (Persona, Int) {
        var tokens = value.split { $0.isWhitespace || $0 == "," }.map(String.init)
        while let first = tokens.first, ["mr", "mrs", "ms", "miss", "mx", "dr", "prof", "sir", "madam"].contains(first.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) { tokens.removeFirst() }
        if tokens.count >= 2 { return (register(tokens.first, tokens.last), 2) }
        if let token = tokens.first {
            let last = personas.filter { $0.realLast == fold(token) }
            if last.count == 1, let found = last.first { return (found, -1) }
            return (register(token, nil), 1)
        }
        return (register(nil, nil), 2)
    }
    func knows(_ value: String) -> Bool {
        let tokens = value.split(separator: " ")
        guard tokens.count >= 2, let first = tokens.first, let last = tokens.last else { return false }
        return personas.contains { $0.realFirst == fold(String(first)) && $0.realLast == fold(String(last)) }
    }
    func name(for value: String) -> String {
        let (person, parts) = registerFull(value)
        return parts == 1 ? person.first : parts == -1 ? person.last : person.full
    }
    func find(email: String) -> Persona? {
        if let associated = associatedEmails[fold(email)] { return associated }
        let local = String(email.split(separator: "@", maxSplits: 1).first ?? "")
        let matches = personas.filter { $0.matches(local: local) }
        return matches.count == 1 ? matches.first : nil
    }
    func associate(first: String?, last: String?, email: String?) {
        guard first != nil || last != nil else { return }
        let person = register(first, last)
        if let email { associatedEmails[fold(email)] = person }
    }
    func email(for person: Persona, original: String) -> String {
        let key = fold(original)
        if let existing = person.emails[key] { return existing }
        let pieces = original.split(separator: "@", maxSplits: 1).map(String.init)
        let domain = pieces.count > 1 ? fold(pieces[1]) : ""
        if domains[domain] == nil { domains[domain] = Names.emailDomains[domains.count % Names.emailDomains.count] }
        let first = fold(person.first).filter(\.isLetter), last = fold(person.last).filter(\.isLetter)
        let local = pieces.first ?? ""
        let joined = local.lowercased().filter(\.isLetter)
        let fakeLocal: String
        if let f = person.realFirst, let l = person.realLast, joined == String(f.prefix(1)) + l { fakeLocal = String(first.prefix(1)) + last }
        else if let f = person.realFirst, let l = person.realLast, joined == l + String(f.prefix(1)) { fakeLocal = last + String(first.prefix(1)) }
        else if let f = person.realFirst, let l = person.realLast, joined == f + l, !local.contains(where: { "._-+".contains($0) }) { fakeLocal = first + last }
        else { fakeLocal = first + String(local.first(where: { "._-".contains($0) }) ?? ".") + last }
        let email = fakeLocal + "@" + (domains[domain] ?? "example.com")
        person.emails[key] = email
        return email
    }
}
