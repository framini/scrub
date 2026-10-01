import Foundation

final class Persona {
    var realFirst: String?
    var realLast: String?
    var realMiddle: String?
    let first: String
    let last: String
    private var firstEmail: (original: String, fake: String)?
    private var otherEmails: [String: String] = [:]
    func email(for original: String) -> String? {
        if firstEmail?.original == original { return firstEmail?.fake }
        return otherEmails[original]
    }
    func rememberEmail(_ fake: String, for original: String) {
        if firstEmail == nil { firstEmail = (original, fake) }
        else { otherEmails[original] = fake }
    }
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
    private enum Candidates {
        case one(Persona)
        case many([Persona])
        var people: [Persona] {
            switch self {
            case .one(let person): [person]
            case .many(let people): people
            }
        }
        mutating func append(_ person: Persona) {
            switch self {
            case .one(let previous): self = .many([previous, person])
            case .many(var people): people.append(person); self = .many(people)
            }
        }
    }
    private struct Key: Hashable { let first: String?; let last: String?; var middle: String? = nil }
    private struct Bucket {
        private var sole: Persona?
        private var members: [ObjectIdentifier: Persona]?
        var count: Int { members?.count ?? (sole == nil ? 0 : 1) }
        var first: Persona? { sole ?? members?.values.first }
        var people: [Persona] { members.map { Array($0.values) } ?? sole.map { [$0] } ?? [] }
        mutating func add(_ person: Persona) {
            if members != nil {
                members?[ObjectIdentifier(person)] = person
            } else if let sole {
                members = [ObjectIdentifier(sole): sole, ObjectIdentifier(person): person]
                self.sole = nil
            } else { sole = person }
        }
        mutating func remove(_ person: Persona) {
            if members != nil {
                members?.removeValue(forKey: ObjectIdentifier(person))
                if members?.count == 1 {
                    sole = members?.values.first
                    members = nil
                }
            } else if sole === person { sole = nil }
        }
    }
    private static let locale = Locale(identifier: "en_US_POSIX")
    private static func fold(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: locale).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static let firstChoices = Names.first.map { ($0, fold($0)) }
    private static let lastChoices = Names.last.map { ($0, fold($0)) }
    private var exact: [Key: Persona] = [:]
    private var fullBuckets: [Key: Bucket] = [:]
    private var firstBuckets: [String: Bucket] = [:]
    private var lastBuckets: [String: Bucket] = [:]
    private var firstOnly: [String: Persona] = [:]
    private var lastOnly: [String: Persona] = [:]
    private var missingFirst = Bucket()
    private var missingLast = Bucket()
    private var joined: [UInt64: Candidates]?
    private var domains: [String: String] = [:]
    private var associatedEmails: [String: Persona] = [:]
    private var rng: any RandomNumberGenerator = SystemRandomNumberGenerator()
    init(rng: any RandomNumberGenerator = SystemRandomNumberGenerator()) { self.rng = rng }
    private static func joinedHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }
    private func fold(_ value: String) -> String { Self.fold(value) }
    private func add(_ person: Persona) {
        let f = person.realFirst, l = person.realLast
        exact[Key(first: f, last: l, middle: person.realMiddle)] = person
        if f != nil && l != nil { fullBuckets[Key(first: f, last: l), default: Bucket()].add(person) }
        if let f { firstBuckets[f, default: Bucket()].add(person) } else { missingFirst.add(person) }
        if let l { lastBuckets[l, default: Bucket()].add(person) } else { missingLast.add(person) }
        if let f, let l {
            if joined != nil { addJoined(person, first: f, last: l) }
        } else if let f { firstOnly[f] = person }
        else if let l { lastOnly[l] = person }
    }
    private func addJoined(_ person: Persona, first: String, last: String) {
        for key in [first + last, last + first, String(first.prefix(1)) + last, last + String(first.prefix(1))] {
            let hash = Self.joinedHash(key)
            if var candidates = joined?[hash] {
                candidates.append(person)
                joined?[hash] = candidates
            } else { joined?[hash] = .one(person) }
        }
    }
    private func ensureJoined() {
        guard joined == nil else { return }
        joined = [:]
        for person in exact.values {
            if let first = person.realFirst, let last = person.realLast {
                addJoined(person, first: first, last: last)
            }
        }
    }
    private func remove(_ person: Persona) {
        let f = person.realFirst, l = person.realLast
        exact.removeValue(forKey: Key(first: f, last: l, middle: person.realMiddle))
        fullBuckets[Key(first: f, last: l)]?.remove(person)
        if let f { firstBuckets[f]?.remove(person) } else { missingFirst.remove(person) }
        if let l { lastBuckets[l]?.remove(person) } else { missingLast.remove(person) }
        if let f, l == nil { firstOnly.removeValue(forKey: f) }
        if let l, f == nil { lastOnly.removeValue(forKey: l) }
    }
    private func compatible(_ f: String?, _ l: String?, _ middle: String?) -> (Int, Persona?) {
        if let f, let l {
            let full = (fullBuckets[Key(first: f, last: l)]?.people ?? []).filter {
                middle == nil || $0.realMiddle == nil || $0.realMiddle == middle
            }
            let first = firstOnly[f], last = lastOnly[l]
            let both = exact[Key(first: nil, last: nil)]
            return (full.count + [first, last, both].compactMap { $0 }.count, full.first ?? first ?? last ?? both)
        }
        if let f {
            let bucket = firstBuckets[f] ?? Bucket()
            return (bucket.count + missingFirst.count, bucket.first ?? missingFirst.first)
        }
        if let l {
            let bucket = lastBuckets[l] ?? Bucket()
            return (bucket.count + missingLast.count, bucket.first ?? missingLast.first)
        }
        return (exact.count, exact.values.first)
    }
    private var reserved: Set<String> = []
    private var blockedChoices: Set<String> = []
    private var usedFullNames: Set<String> = []
    // A stand-in that matches a real name elsewhere in the document reads as a
    // leak, so every real name part is reserved before any stand-in is drawn.
    func reserve(_ names: [String]) {
        for name in names {
            for part in name.split(whereSeparator: { !$0.isLetter }) { reserved.insert(fold(String(part))) }
        }
        guard !reserved.isEmpty else { return }
        blockedChoices = Set((Self.firstChoices + Self.lastChoices).compactMap { choice in
            // Initials and two-letter parts would block most of the pool, so
            // they only block an identical stand-in.
            if reserved.contains(choice.1) { return choice.1 }
            let letters = Array(choice.1)
            for start in letters.indices where letters.count - start >= 3 {
                for end in (start + 3)...letters.count where reserved.contains(String(letters[start..<end])) { return choice.1 }
            }
            return nil
        })
    }
    func unrelatedName(first: Bool) -> String {
        pick(first ? Self.firstChoices : Self.lastChoices, originals: [], emailSafe: true)
    }
    private func pick(_ choices: [(String, String)], originals: [String], emailSafe: Bool) -> String {
        func allowed(_ choice: (String, String)) -> Bool {
            !blockedChoices.contains(choice.1) && !originals.contains(where: { choice.1.contains($0) })
                && (!emailSafe || choice.0.allSatisfy({ $0.isASCII && $0.isLetter }))
        }
        for _ in 0..<64 {
            guard let choice = choices.randomElement(using: &rng) else { break }
            if allowed(choice) { return choice.0 }
        }
        return choices.first(where: allowed)?.0 ?? "Alex"
    }
    /// "female" or "male" when a record says so ("gender", "sex", "title", "Ms."),
    /// so the stand-in first name fits it.
    static func gender(_ value: String) -> String? {
        switch value.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted) {
        case "f", "female", "woman", "w", "girl", "ms", "mrs", "miss", "madam", "she", "she/her", "mother", "wife", "sister", "daughter": "female"
        case "m", "male", "man", "boy", "mr", "sir", "he", "he/him", "father", "husband", "brother", "son": "male"
        default: nil
        }
    }
    func register(_ first: String?, _ last: String?, emailSafe: Bool = false, middle: String? = nil, gender: String? = nil) -> Persona {
        let f = first.map(fold), l = last.map(fold), m = middle.map(fold)
        if let found = exact[Key(first: f, last: l, middle: m)] { return found }
        let (count, candidate) = compatible(f, l, m)
        if count == 1, let found = candidate {
            if (found.realFirst == nil && f != nil) || (found.realLast == nil && l != nil) || (found.realMiddle == nil && m != nil) {
                remove(found)
                found.realFirst = found.realFirst ?? f
                found.realLast = found.realLast ?? l
                found.realMiddle = found.realMiddle ?? m
                add(found)
            }
            return found
        }
        let originals = [f, l].compactMap { $0 }.filter { $0.count >= 3 }
        let (first, last) = freshName(originals: originals, emailSafe: emailSafe, gender: gender)
        let person = Persona(realFirst: f, realLast: l, first: first, last: last)
        person.realMiddle = m
        add(person)
        return person
    }
    private static let femaleChoices = firstChoices.filter { Names.female.contains($0.1) }
    private static let maleChoices = firstChoices.filter { Names.male.contains($0.1) }
    private func freshName(originals: [String], emailSafe: Bool, gender: String? = nil) -> (String, String) {
        var attempt = 0
        let firsts = gender == "female" ? Self.femaleChoices : gender == "male" ? Self.maleChoices : Self.firstChoices
        while true {
            let first = pick(firsts, originals: originals, emailSafe: false)
            var last = pick(Self.lastChoices, originals: originals, emailSafe: emailSafe)
            // A suffix also handles documents that exhaust the finite name pool.
            if attempt >= 64 { last += String(attempt) }
            if usedFullNames.insert(fold(first + " " + last)).inserted { return (first, last) }
            attempt += 1
        }
    }
    /// "Raghunathan, Priya" written first name first, or nil when the value isn't in that form.
    static func naturalOrder(_ value: String) -> String? {
        let halves = value.split(separator: ",", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let last = halves[0].trimmingCharacters(in: .whitespaces), rest = halves[1].trimmingCharacters(in: .whitespaces)
        guard !last.isEmpty, !rest.isEmpty, !last.contains(where: \.isWhitespace) else { return nil }
        return rest + " " + last
    }
    private static let titles: Set<String> = ["mr", "mrs", "ms", "miss", "mx", "dr", "prof", "sir", "dame", "madam"]
    private static func isInitials(_ word: String) -> Bool { word.count >= 2 && word.allSatisfy { $0 == "." || $0.isUppercase } && word.hasSuffix(".") }
    static func isTitle(_ word: String) -> Bool { titles.contains(word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
    func registerFull(_ value: String, emailSafe: Bool = false, gender: String? = nil) -> (Persona, Int) {
        var tokens = (Self.naturalOrder(value) ?? value).split { $0.isWhitespace || $0 == "," }.map(String.init)
        var gender = gender
        var titled = false
        while let first = tokens.first, Self.titles.contains(first.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            gender = gender ?? Self.gender(first)
            tokens.removeFirst()
            titled = true
        }
        // "Ms. Okafor": a title comes before a surname.
        if titled, tokens.count == 1 { return (register(nil, tokens[0], emailSafe: emailSafe, gender: gender), -1) }
        if tokens.count >= 2 { return (register(tokens.first, tokens.last, emailSafe: emailSafe, middle: tokens.count > 2 ? tokens.dropFirst().dropLast().joined(separator: " ") : nil, gender: gender), 2) }
        if let token = tokens.first {
            let last = lastBuckets[fold(token)] ?? Bucket()
            if last.count == 1, let found = last.first { return (found, -1) }
            return (register(token, nil, emailSafe: emailSafe, gender: gender), 1)
        }
        return (register(nil, nil, emailSafe: emailSafe), 2)
    }
    func knows(_ value: String) -> Bool {
        let tokens = value.split(separator: " ")
        guard tokens.count >= 2, let first = tokens.first, let last = tokens.last else { return false }
        let middle = tokens.count > 2 ? fold(tokens.dropFirst().dropLast().joined(separator: " ")) : nil
        return (fullBuckets[Key(first: fold(String(first)), last: fold(String(last)))]?.people ?? []).contains {
            middle == nil || $0.realMiddle == nil || $0.realMiddle == middle
        }
    }
    func name(for value: String) -> String {
        let (person, parts) = registerFull(value)
        // "Ms. Siobhan Okafor" keeps its title, which the stand-in name fits.
        let title = value.split(separator: " ").first.map(String.init).flatMap { Self.titles.contains($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) ? $0 + " " : nil } ?? ""
        if parts == 2, Self.naturalOrder(value) != nil { return person.last + ", " + person.first }
        // "Ms E. Okafor" and "Mrs H.S. Lind" keep their initials, and a surname in capitals its capitals.
        let named = value.split(separator: " ").map(String.init).drop { Self.isTitle($0) }
        if parts == 2, named.count >= 2, named.dropLast().allSatisfy(Self.isInitials) {
            // Read off the stand-in, so the same person keeps the same initials everywhere.
            var seed = person.full.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
            let alphabet = Array("ABCDEFGHJKLMNPRSTW")
            var letters = ([person.first.first ?? "A"] + (0..<8).map { _ in
                seed = seed &* 1_103_515_245 &+ 12345
                return alphabet[Int(seed >> 16) % alphabet.count]
            }).makeIterator()
            let initials = named.dropLast().map { word in String(word.map { $0.isLetter ? letters.next() ?? $0 : $0 }) }
            let last = named.last.map { $0 == $0.uppercased() && $0.count > 1 } == true ? person.last.uppercased() : person.last
            return title + (initials + [last]).joined(separator: " ")
        }
        return title + (parts == 1 ? person.first : parts == -1 ? person.last : person.full)
    }
    func find(email: String) -> Persona? {
        if let associated = associatedEmails[fold(email)] { return associated }
        let local = String(email.split(separator: "@", maxSplits: 1).first ?? "")
        let parts = Set(local.lowercased().split { !$0.isLetter }.map(String.init))
        let key = local.lowercased().filter(\.isLetter)
        var candidates: [ObjectIdentifier: Persona] = [:]
        func collect(_ person: Persona?) { if let person { candidates[ObjectIdentifier(person)] = person } }
        ensureJoined()
        for person in joined?[Self.joinedHash(key)]?.people ?? [] { collect(person) }
        for part in parts {
            collect(lastOnly[part])
            if parts.count == 1 { collect(firstOnly[part]) }
            if let bucket = firstBuckets[part], bucket.count > 0 {
                for other in parts {
                    for person in fullBuckets[Key(first: part, last: other)]?.people ?? [] { collect(person) }
                }
            }
        }
        let matches = candidates.values.filter { $0.matches(local: local) }
        return matches.count == 1 ? matches.first : nil
    }
    func associate(_ person: Persona, email: String?) {
        if let email { associatedEmails[fold(email)] = person }
    }
    func associate(first: String?, last: String?, email: String?) {
        guard first != nil || last != nil else { return }
        let person = register(first, last, emailSafe: email != nil)
        associate(person, email: email)
    }
    /// A username built from the stand-in name the way the original is built
    /// from the real one ("obrightwater74" → "jguerrero31"), or nil when it
    /// isn't built from the name.
    func handle(for person: Persona, original: String, digits: (Int) -> String) -> String? {
        guard let f = person.realFirst?.filter(\.isLetter), let l = person.realLast?.filter(\.isLetter) else { return nil }
        let letters = original.lowercased().filter(\.isLetter)
        let separator = original.first { "._-".contains($0) }.map(String.init) ?? ""
        let first = fold(person.first).filter(\.isLetter), last = fold(person.last).filter(\.isLetter)
        let initial = String(first.prefix(1))
        let body: String
        switch letters {
        case f + l: body = first + separator + last
        case String(f.prefix(1)) + l: body = initial + separator + last
        case l + f: body = last + separator + first
        case l + String(f.prefix(1)): body = last + separator + initial
        case f: body = first
        case l: body = last
        default: return nil
        }
        let count = original.reversed().prefix(while: \.isNumber).count
        let handle = body + (count > 0 ? digits(count) : "")
        return original.first?.isUppercase == true ? handle.prefix(1).uppercased() + handle.dropFirst() : handle
    }
    func email(for person: Persona, original: String) -> String {
        let key = fold(original)
        if let existing = person.email(for: key) { return existing }
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
        person.rememberEmail(email, for: key)
        return email
    }
}
