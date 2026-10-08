import Foundation

final class Persona {
    var realFirst: String?
    var realLast: String?
    var realMiddle: String?
    private var drawnFirst: String
    /// Whether the stand-in first name has been written anywhere; from then on
    /// it stays, whatever the document says about the person later.
    private(set) var shown = false
    var first: String { shown = true; return drawnFirst }
    /// The first name drawn so far, read without fixing it.
    var drawn: String { drawnFirst }
    func redraw(_ first: String) { if !shown { drawnFirst = first } }
    /// What a title or a gender field says the person is: "female", "male",
    /// or "either" once two of them disagree (see `People.fit`).
    var gender: String?
    let last: String
    /// The person of the same first name whose stand-in first name this one took (see `People.resolve`).
    var namesake: Persona?
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
        self.realFirst = realFirst; self.realLast = realLast; self.drawnFirst = first; self.last = last
    }
    /// A name part as an address writes it: no apostrophe or hyphen, so
    /// "O’Sullivan" is "osullivan" and "Smith-Jones" "smithjones", whichever apostrophe it had.
    static func letters(_ part: String) -> String { part.lowercased().filter { !joiners.contains($0) } }
    private static let joiners: Set<Character> = ["'", "’", "‘", "ʼ", "′", "`", "＇", "-", "‐", "‑", "‒", "–"]
    /// Whether a part is in an address's words: whole ("osullivan", "smithjones")
    /// or with its own pieces apart ("smith.jones", "o'sullivan" read as "o", "sullivan").
    private static func written(_ part: String, in parts: Set<String>) -> Bool {
        if parts.contains(letters(part)) { return true }
        let pieces = part.lowercased().split(whereSeparator: joiners.contains).map(String.init)
        return pieces.count > 1 && pieces.allSatisfy(parts.contains)
    }
    func matches(local: String) -> Bool {
        let parts = Set(local.lowercased().split { !$0.isLetter }.map(String.init))
        let joined = local.lowercased().filter(\.isLetter)
        if let realFirst, let realLast {
            let first = Self.letters(realFirst), last = Self.letters(realLast)
            return (Self.written(realFirst, in: parts) && Self.written(realLast, in: parts)) || [first + last, last + first, String(first.prefix(1)) + last, last + String(first.prefix(1))].contains(joined)
                // "odalys.f", "odalysf": a first name no shorter than four letters and the surname's initial.
                || first.count >= 4 && joined == first + String(last.prefix(1))
                // "clem.abernathy", "bob.lind": the surname with a short form of the first name.
                || Self.written(realLast, in: parts) && parts.contains { part in
                    part.count >= 3 && part != last && (first.hasPrefix(part) && first.count >= part.count + 2 || Nicknames.variants(of: first).contains(part))
                }
        }
        return (realLast.map { Self.written($0, in: parts) } ?? false) || (realFirst.map { parts == [Self.letters($0)] } ?? false)
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
    private struct Key: Hashable { let first: String?; let last: String?; var middle: String? = nil; var title: String? = nil }
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
    /// A name part as one person's, whatever its accents, capitals or apostrophes: "O'Neill" is "ONEILL", "Weiß" "WEISS".
    private static func fold(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: locale).filter { !apostrophes.contains($0) }.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static let apostrophes: Set<Character> = ["'", "’", "‘", "ʼ", "′", "`", "＇"]
    /// A folded name's words, a hyphen's halves apart: "bello-okafor" is "bello" and "okafor".
    private static func words(_ folded: String) -> [String] {
        folded.split { $0.isWhitespace || $0 == "-" || $0 == "‐" || $0 == "‑" || $0 == "." || $0 == "," }.map(String.init)
    }
    private static let firstChoices = Names.first.map { ($0, fold($0)) }
    private static let lastChoices = Names.last.map { ($0, fold($0)) }
    private var exact: [Key: Persona] = [:]
    private var fullBuckets: [Key: Bucket] = [:]
    private var firstBuckets: [String: Bucket] = [:]
    private var lastBuckets: [String: Bucket] = [:]
    private var firstOnly: [String: Persona] = [:]
    private var lastOnly: [String: Persona] = [:]
    /// The same people by that part as an address writes it (see `Persona.letters`).
    private var firstOnlyLetters: [String: Persona] = [:]
    private var lastOnlyLetters: [String: Persona] = [:]
    /// The people by each word of their surname and middle names ("garcia", "lindqvist").
    private var byWord: [String: Bucket] = [:]
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
        for word in Set(Self.words(l ?? "") + Self.words(person.realMiddle ?? "")) { byWord[word, default: Bucket()].add(person) }
        if let f, let l {
            if joined != nil { addJoined(person, first: f, last: l) }
        } else if let f { firstOnly[f] = person; firstOnlyLetters[Persona.letters(f)] = person }
        else if let l { lastOnly[l] = person; lastOnlyLetters[Persona.letters(l)] = person }
    }
    private func addJoined(_ person: Persona, first realFirst: String, last realLast: String) {
        let first = Persona.letters(realFirst), last = Persona.letters(realLast)
        for key in [first + last, last + first, String(first.prefix(1)) + last, last + String(first.prefix(1))] + (first.count >= 4 ? [first + String(last.prefix(1))] : []) {
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
        for word in Set(Self.words(l ?? "") + Self.words(person.realMiddle ?? "")) { byWord[word]?.remove(person) }
        if let f, l == nil { firstOnly.removeValue(forKey: f); firstOnlyLetters.removeValue(forKey: Persona.letters(f)) }
        if let l, f == nil { lastOnly.removeValue(forKey: l); lastOnlyLetters.removeValue(forKey: Persona.letters(l)) }
    }
    private func compatible(_ f: String?, _ l: String?, _ middle: String?, gender: String? = nil) -> (Int, Persona?) {
        if let f, let l {
            let full = (fullBuckets[Key(first: f, last: l)]?.people ?? []).filter {
                Self.sameMiddle(middle, $0.realMiddle)
            }
            // "Mateus Okafor" is not the "Ms Okafor" met before him.
            let first = firstOnly[f], last = lastOnly[l].flatMap { Self.opposite($0.gender, NameLists.gender(ofFirst: f) ?? gender) ? nil : $0 }
            let both = exact[Key(first: nil, last: nil)]
            return (full.count + [first, last, both].compactMap { $0 }.count, full.first ?? first ?? last ?? both)
        }
        // "Odalys" alone is the Odalys the document names, not "Mr Okonjo",
        // whose first name it doesn't give; only when no one has that part
        // can it be one of those.
        if let f {
            if let bucket = firstBuckets[f], bucket.count > 0 { return (bucket.count, bucket.first) }
            return (missingFirst.count, missingFirst.first)
        }
        if let l {
            if let bucket = lastBuckets[l], bucket.count > 0 {
                // "Ms Okafor" is not Mateus Okafor: a title never joins a first name clearly of the other sex.
                if let gender {
                    let fitting = bucket.people.filter { !Self.opposite(gender, $0.realFirst.flatMap(NameLists.gender(ofFirst:))) }
                    if fitting.count < bucket.count { return (fitting.count, fitting.first) }
                }
                return (bucket.count, bucket.first)
            }
            // Nor the one person known only by a first name, when that name is of the other sex.
            if let gender, missingLast.count == 1, let only = missingLast.first, Self.opposite(gender, only.realFirst.flatMap(NameLists.gender(ofFirst:))) { return (0, nil) }
            return (missingLast.count, missingLast.first)
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
    /// Given names a person's record holds beside their first name, by the name as folded.
    private var otherGiven: [String: String] = [:]
    /// The stand-in for a given name of `person`'s that is not their first name ("middle_name":
    /// "Rose" beside "first_name": "Cordelia"): the first name of the one person the document
    /// knows by it, else a first name of its own, never `person`'s, the same wherever it is written.
    /// Nil where `name` is their first name, a short form of it, or none is known.
    func otherGiven(_ name: String, of person: Persona) -> String? {
        // A first name known only by its initial ("J.") may be this one.
        guard let real = person.realFirst.map(fold), real.filter(\.isLetter).count > 1 else { return nil }
        let given = fold(name)
        // A name written family first ("Yoshida Haruto" beside "given": "Haruto") holds the first name last.
        guard !given.isEmpty, given != real, given != person.realLast.map(fold), !Nicknames.variants(of: real).contains(given),
              !real.split(separator: " ").contains(Substring(given)) else { return nil }
        if let known = firstBuckets[given], known.count == 1, let other = known.first, other !== person { return other.first }
        if let drawn = otherGiven[given] { return drawn }
        let sex = NameLists.gender(ofFirst: given)
        var drawn = pick(Self.choices(for: sex), originals: [given], emailSafe: false)
        for _ in 0..<8 where fold(drawn) == fold(person.drawn) || fold(drawn) == fold(person.last) {
            drawn = pick(Self.choices(for: sex), originals: [given], emailSafe: false)
        }
        otherGiven[given] = drawn
        return drawn
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
        case "f", "female", "woman", "w", "girl", "ms", "mrs", "miss", "madam", "dame", "lady", "she", "she/her", "mother", "wife", "sister", "daughter": "female"
        case "m", "male", "man", "boy", "mr", "sir", "he", "he/him", "father", "husband", "brother", "son": "male"
        default: nil
        }
    }
    private static let eitherChoices = firstChoices.filter { !Names.female.contains($0.1) && !Names.male.contains($0.1) }
    /// Each list's names folded, to ask whether a stand-in is among them in one lookup.
    private static let femaleFolded = Set(femaleChoices.map(\.1)), maleFolded = Set(maleChoices.map(\.1))
    private static let eitherFolded = Set(eitherChoices.map(\.1)), firstFolded = Set(firstChoices.map(\.1))
    private static func folded(for gender: String?) -> Set<String> {
        switch gender {
        case "female": femaleFolded
        case "male": maleFolded
        case "either": eitherFolded
        default: firstFolded
        }
    }
    private static func choices(for gender: String?) -> [(String, String)] {
        switch gender {
        case "female": femaleChoices
        case "male": maleChoices
        case "either": eitherChoices
        default: firstChoices
        }
    }
    /// A title or gender field says what a person is, wherever in the document
    /// it comes: "Odalys" first, then "Ms Ferriter" for the same person, makes
    /// her stand-in first name a woman's. Two that disagree ("Mr Ferriter" and
    /// "Mrs Ferriter", taken for one person) make it a name given to either,
    /// so no title beside it reads wrong; the disagreement then stays, whatever
    /// else the document says. A name already written stays as written, since
    /// one person keeps one stand-in.
    private func fit(_ person: Persona, _ gender: String) {
        let wanted = person.gender.map { $0 == gender ? $0 : "either" } ?? gender
        person.gender = wanted
        guard !person.shown, !Self.folded(for: wanted).contains(fold(person.drawn)) else { return }
        let originals = [person.realFirst, person.realLast].compactMap { $0 }.filter { $0.count >= 3 }
        for _ in 0..<64 {
            let first = pick(Self.choices(for: wanted), originals: originals, emailSafe: false)
            if fold(first) != fold(person.last), usedFullNames.insert(fold(first + " " + person.last)).inserted {
                usedFullNames.remove(fold(person.drawn + " " + person.last))
                person.redraw(first)
                return
            }
        }
    }
    /// Who each name, as written, was taken for. A person's key changes when a
    /// later name fills in a part ("Odalys", then "Ms Ferriter" or "Odalys
    /// Ferriter"), and how many people a part could be grows as the document
    /// names more; neither may give the same name a second person.
    private var resolved: [Key: Persona] = [:]
    func register(_ first: String?, _ last: String?, emailSafe: Bool = false, middle: String? = nil, gender: String? = nil) -> Persona {
        let f = first.map(fold), l = last.map(fold), m = middle.map(fold)
        // "Ms Okafor" and "Mr Okafor" may be two people, so a title is part of what was written.
        let key = Key(first: f, last: l, middle: m, title: f == nil ? gender : nil)
        let person = resolved[key] ?? resolve(f, l, m, emailSafe: emailSafe, gender: gender)
        resolved[key] = person
        // A first name clearly of one sex says as much as a title: "Mateus" gets a man's stand-in.
        if let sex = gender ?? f.flatMap(NameLists.gender(ofFirst:)) { fit(person, sex) }
        return person
    }
    private func resolve(_ f: String?, _ l: String?, _ m: String?, emailSafe: Bool, gender: String?) -> Persona {
        // "Mr Okafor" beside Mateus Okafor and a "Ms Okafor": the one whose first name fits the title.
        if f == nil, let l, let gender, gender != "either" {
            let fitting = (lastBuckets[l]?.people ?? []).filter { $0.realFirst.flatMap(NameLists.gender(ofFirst:)) == gender && Self.sameMiddle(m, $0.realMiddle) }
            if fitting.count == 1 { return fitting[0] }
            // "Hi Odalys", then "Mr Ferriter" (someone else), then "Mrs Ferriter": she is Odalys.
            if fitting.isEmpty, missingLast.count == 1, let only = missingLast.first, only.realFirst.flatMap(NameLists.gender(ofFirst:)) == gender,
               (lastBuckets[l]?.people ?? []).allSatisfy({ $0.realFirst == nil && Self.opposite($0.gender, gender) }) {
                remove(only)
                only.realLast = l
                only.realMiddle = only.realMiddle ?? m
                add(only)
                return only
            }
        }
        if let found = exact[Key(first: f, last: l, middle: m)] { return found }
        var (count, candidate) = compatible(f, l, m, gender: gender)
        // "J. Okafor" or "Bob Lind" after "Ama Okafor" and "Robert Lind": the one
        // person whose first name the initial or short form stands for.
        if count == 0, let f, let shared = sameFirst(f, last: l) { return shared }
        if count == 0, let l, let found = fuller(f, l, m) { return found }
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
        // Kept apart from someone of the same surname only by sex ("Ms Okafor" and
        // Mateus Okafor), a person is of that family: same stand-in surname.
        let sex = f.flatMap(NameLists.gender(ofFirst:)) ?? gender
        // With no one of that surname yet, the one person known by a first name
        // alone ("Hi Odalys" before "Mr Ferriter") may still take it later.
        let unsurnamed = missingLast.count == 1 ? missingLast.first : nil
        // So is someone of a surname others in the document already have with first names of their own
        // (a patient and their contact, "Clementine Abernathy" and "Ezra Abernathy"): one family, one stand-in surname.
        let relative = l.flatMap { l in f == nil
            ? ((lastBuckets[l]?.people).flatMap { $0.isEmpty ? nil : $0 } ?? unsurnamed.map { [$0] } ?? []).filter { Self.opposite(sex, $0.realFirst.flatMap(NameLists.gender(ofFirst:))) }.min { $0.last < $1.last }
            : lastOnly[l].flatMap { Self.opposite(sex, $0.gender) ? $0 : nil } ?? (lastBuckets[l]?.people ?? []).filter { $0.realFirst != nil }.min { $0.last < $1.last }
                ?? doubled(l) }
        // Someone of a first name another person in the document has, with a surname of their own ("Ruoxi Huang",
        // then "Ruoxi Zeodaström" as a prior name): that first name has one stand-in.
        let namesake = relative == nil && l != nil ? f.flatMap { f in (firstBuckets[f]?.people ?? []).filter { $0.realLast != nil }.min { $0.drawn < $1.drawn } } : nil
        let (first, last) = relative.flatMap { freshFirst(last: $0.last, originals: originals, gender: sex) }.map { ($0, relative!.last) }
            ?? namesake.flatMap { freshLast(first: $0.drawn, originals: originals, emailSafe: emailSafe) }.map { (namesake!.drawn, $0) }
            ?? freshName(originals: originals, emailSafe: emailSafe, gender: sex)
        let person = Persona(realFirst: f, realLast: l, first: first, last: last)
        person.realMiddle = m
        if let namesake, fold(first) == fold(namesake.drawn) { person.namesake = namesake }
        add(person)
        return person
    }
    /// Whether two middle names may be one person's: either unknown, the same, or one the other's
    /// initials ("r" and "robert", "a. m." and "anne marie").
    private static func sameMiddle(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, a != b else { return true }
        let x = words(a), y = words(b)
        guard x.count == y.count else { return false }
        return zip(x, y).allSatisfy { $0 == $1 || $0.count == 1 && $1.hasPrefix($0) || $1.count == 1 && $0.hasPrefix($1) }
    }
    /// Someone with a first name whose double surname holds `last` ("Aisha Bello-Okafor" for "Chidi Okafor"): one family.
    private func doubled(_ last: String) -> Persona? {
        guard last.count >= 3, Self.words(last) == [last] else { return nil }
        let family = (byWord[last]?.people ?? []).filter { $0.realFirst != nil && Self.words($0.realLast ?? "").contains(last) }
        return family.min { $0.last < $1.last }
    }
    /// The one person known whose names hold every word of these, read in full elsewhere: "Maria Lindqvist" or
    /// "García Lindqvist, María José" for María José García Lindqvist, "A Bello Okafor" for Aisha Bello-Okafor.
    /// Their first word given is the person's, or its initial; only someone of three names or more may be
    /// written opening with another of them, as in "García Lindqvist, María José", since "Lee Kim" and "Kim Lee" may be two people.
    private func fuller(_ f: String?, _ l: String, _ m: String?) -> Persona? {
        let given = Self.words(f ?? ""), rest = Array(given.dropFirst()) + Self.words(m ?? "") + Self.words(l)
        guard let lead = given.first, let key = Self.words(l).last else { return nil }
        let found = (byWord[key]?.people ?? []).filter { person in
            guard let realFirst = person.realFirst, let realLast = person.realLast, let own = Self.words(realFirst).first else { return false }
            let theirs = Set(Self.words(realFirst) + Self.words(realLast) + Self.words(person.realMiddle ?? ""))
            // A middle initial stands for a name of theirs as the first does ("J. R. Gutiérrez" for José Ramón Gutiérrez Peña).
            return (own == lead || lead.count == 1 && own.hasPrefix(lead) || theirs.count >= 3 && theirs.contains(lead))
                && rest.allSatisfy { word in theirs.contains(word) || word.count == 1 && theirs.contains { $0.hasPrefix(word) } }
        }
        return found.count == 1 ? found[0] : nil
    }
    /// The one person whose double surname these words are, written apart ("Bello Okafor" for Aisha
    /// Bello-Okafor) where no one has the first of them as a first name.
    private func surname(_ tokens: [String]) -> Persona? {
        let words = tokens.flatMap { Self.words(fold($0)) }
        guard words.count >= 2, let key = words.last, firstBuckets[words[0]] == nil || firstBuckets[words[0]]?.count == 0 else { return nil }
        let found = (byWord[key]?.people ?? []).filter { $0.realFirst != nil && Self.words($0.realLast ?? "") == words }
        return found.count == 1 ? found[0] : nil
    }
    /// "García Lindqvist, María José": a surname of more than one word, then the given names.
    static func surnameFirst(_ value: String) -> (surname: String, given: String)? {
        let halves = value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard halves.count == 2, !halves[0].isEmpty, !halves[1].isEmpty, halves.allSatisfy({ $0.split(separator: " ").count <= 3 }) else { return nil }
        return (halves[0], halves[1])
    }
    /// Two people in one value, "Aisha Bello-Okafor & Chidi Okafor" or "AISHA AND CHIDI OKAFOR":
    /// each name, and what joins it to the next.
    static func joint(_ value: String) -> [(name: String, joiner: String)]? {
        let words = value.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var result: [(name: String, joiner: String)] = []
        var current: [String] = []
        var foreign = false
        for (index, word) in words.enumerated() {
            // "Inês Moura e Rui Tavares", "Ana Ruiz y Luis Gil": another language's "and" joins two names of two
            // words or more, so "Ortega y Gasset" and "Silva e Souza" stay one surname.
            let joins = ["&", "+", "and"].contains(word.lowercased())
                || otherAnds.contains(word) && current.count >= 2 && index + 2 < words.count && words[index + 1].first?.isUppercase == true
            if joins {
                guard !current.isEmpty else { return nil }
                foreign = foreign || otherAnds.contains(word)
                result.append((current.joined(separator: " "), " " + word + " "))
                current = []
            } else { current.append(word) }
        }
        guard !result.isEmpty, !current.isEmpty, !foreign || current.count >= 2 else { return nil }
        result.append((current.joined(separator: " "), ""))
        return result.allSatisfy({ $0.name.contains(where: \.isLetter) && $0.name.split(separator: " ").count <= 4 }) ? result : nil
    }
    /// "And" in the languages a joint account's holders are written in.
    private static let otherAnds: Set<String> = ["e", "y", "et", "und", "en", "i", "och", "og", "ve", "u"]
    /// Each name of a joint value in full, a first name alone taking the surname after it
    /// ("AISHA & CHIDI OKAFOR"), with what joins it to the next and whether it was alone.
    private static func jointNames(_ value: String) -> [(name: String, joiner: String, alone: Bool)]? {
        guard let parts = joint(value) else { return nil }
        let surname = parts.last.flatMap { $0.name.split(separator: " ").count >= 2 ? $0.name.split(separator: " ").last.map(String.init) : nil }
        return parts.map { part in
            guard let surname, !part.name.contains(" ") else { return (part.name, part.joiner, false) }
            return (part.name + " " + surname, part.joiner, true)
        }
    }
    /// Each of two people named in one value written as their own; nil when the value names one.
    func jointName(for value: String) -> String? {
        Self.jointNames(value)?.map { part in
            let made = name(for: part.name)
            return (part.alone ? String(made.prefix { $0 != " " }) : made) + part.joiner
        }.joined()
    }
    /// The one person already known whose first name `first` abbreviates
    /// ("j.", "j"), shortens ("bob" for "robert") or clips ("bart" for
    /// "bartholomew"), with the same surname when one is given; nil when there
    /// is none or more than one.
    private func sameFirst(_ first: String, last: String?) -> Persona? {
        let letters = first.filter(\.isLetter)
        guard !letters.isEmpty else { return nil }
        let initial = letters.count == 1 && first.allSatisfy { $0.isLetter || $0 == "." }
        let forms = initial ? [] : Nicknames.variants(of: letters)
        // A clipped first name keeps three letters or more and leaves two or more off, of a name of the same sex.
        let clipped = !initial && forms.isEmpty && letters.count >= 3 && letters == first
        guard initial || !forms.isEmpty || clipped else { return nil }
        func clips(_ real: String) -> Bool {
            real.hasPrefix(letters) && real.count >= letters.count + 2 && !Self.opposite(NameLists.gender(ofFirst: letters), NameLists.gender(ofFirst: real))
        }
        let pool = last.map { lastBuckets[$0]?.people ?? [] }
            ?? (clipped ? firstBuckets.filter { clips($0.key) }.flatMap { $0.value.people } : forms.flatMap { firstBuckets[$0]?.people ?? [] })
        let matching = pool.filter { person in
            guard let real = person.realFirst else { return false }
            return initial ? real.hasPrefix(letters) && real.count > 1 : clipped ? clips(real) : forms.contains(real)
        }
        let distinct = Set(matching.map(ObjectIdentifier.init))
        return distinct.count == 1 ? matching.first : nil
    }
    /// Whether two genders are each clearly one sex, and not the same.
    private static func opposite(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, a != "either", b != "either" else { return false }
        return a != b
    }
    /// A first name for a stand-in surname already drawn, so the full name is
    /// still no one else's; nil when the pool has none left.
    private func freshFirst(last: String, originals: [String], gender: String?) -> String? {
        for _ in 0..<64 {
            let first = pick(Self.choices(for: gender), originals: originals, emailSafe: false)
            // "Hudson Hudson" reads as no one's name.
            if fold(first) != fold(last), usedFullNames.insert(fold(first + " " + last)).inserted { return first }
        }
        return nil
    }
    /// A surname for a stand-in first name already drawn, so the full name is still no one else's.
    private func freshLast(first: String, originals: [String], emailSafe: Bool) -> String? {
        for _ in 0..<64 {
            let last = pick(Self.lastChoices, originals: originals, emailSafe: emailSafe)
            if fold(first) != fold(last), usedFullNames.insert(fold(first + " " + last)).inserted { return last }
        }
        return nil
    }
    private static let femaleChoices = firstChoices.filter { Names.female.contains($0.1) }
    private static let maleChoices = firstChoices.filter { Names.male.contains($0.1) }
    private func freshName(originals: [String], emailSafe: Bool, gender: String? = nil) -> (String, String) {
        var attempt = 0
        let firsts = Self.choices(for: gender)
        while true {
            let first = pick(firsts, originals: originals, emailSafe: false)
            var last = pick(Self.lastChoices, originals: originals, emailSafe: emailSafe)
            // A suffix also handles documents that exhaust the finite name pool.
            if attempt >= 64 { last += String(attempt) }
            if fold(first) != fold(last), usedFullNames.insert(fold(first + " " + last)).inserted { return (first, last) }
            attempt += 1
        }
    }
    /// "Raghunathan, Priya" written first name first, or nil when the value isn't in that form.
    static func naturalOrder(_ value: String) -> String? {
        let halves = value.split(separator: ",", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let last = halves[0].trimmingCharacters(in: .whitespaces), rest = halves[1].trimmingCharacters(in: .whitespaces)
        // "Bowen Jr., Raymond": a suffix after the surname belongs at the end.
        let surname = suffixed(last)
        guard !last.isEmpty, !rest.isEmpty, !surname.name.contains(where: \.isWhitespace) else { return nil }
        return rest + " " + surname.name
    }
    private static let suffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv"]
    static func isSuffix(_ word: String) -> Bool { suffixes.contains(word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,"))) }
    /// "Bowen Jr." as the surname and the suffix after it.
    private static func suffixed(_ last: String) -> (name: String, suffix: String?) {
        let words = last.split(separator: " ").map(String.init)
        guard words.count == 2, isSuffix(words[1]) else { return (last, nil) }
        return (words[0], words[1])
    }
    /// Titles, and the ranks written as one ("Corporal Haddleton" keeps "Corporal").
    /// The forms of address other languages write before a name, too ("Mme Odile Marchetti" is Odile Marchetti); not
    /// those that are also a first name or an initial ("Don", "M.").
    private static let titles: Set<String> = Set(["mr", "mrs", "ms", "miss", "mx", "dr", "prof", "sir", "dame", "lady", "madam"]).union(WrittenNames.ranks)
        .union(["herr", "herrn", "frau", "sra", "srta", "señor", "señora", "señorita", "senhor", "senhora", "mme", "mlle", "monsieur", "madame",
                "mademoiselle", "dhr", "mevr", "mevrouw", "meneer", "signor", "signora", "signorina", "dott", "dottor", "dottoressa", "pani", "dra"])
    private static func isInitials(_ word: String) -> Bool {
        word.count == 1 && word.first?.isUppercase == true || word.count >= 2 && word.allSatisfy { $0 == "." || $0 == "-" || $0.isUppercase } && word.hasSuffix(".") && word.first?.isUppercase == true
    }
    static func isTitle(_ word: String) -> Bool { titles.contains(word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
    func registerFull(_ value: String, emailSafe: Bool = false, gender: String? = nil) -> (Persona, Int) {
        if let names = Self.jointNames(value) { return (names.map { registerFull($0.name, emailSafe: emailSafe).0 }[0], 2) }
        if Self.naturalOrder(value) == nil, let (surname, given) = Self.surnameFirst(value) {
            let names = given.split(separator: " ").map(String.init)
            if let found = fuller(fold(names[0]), fold(surname), names.count > 1 ? fold(names.dropFirst().joined(separator: " ")) : nil) { return (found, 3) }
        }
        var tokens = (Self.naturalOrder(value) ?? value).split { $0.isWhitespace || $0 == "," }.map(String.init)
        // A suffix says which of a family it is, not who: "Raymond Bowen Jr." is Raymond Bowen.
        if tokens.count > 2, let last = tokens.last, Self.isSuffix(last) { tokens.removeLast() }
        var gender = gender
        var titled = false
        while let first = tokens.first, Self.titles.contains(first.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            gender = gender ?? Self.gender(first)
            tokens.removeFirst()
            titled = true
        }
        // "Ms. Okafor": a title comes before a surname.
        if titled, tokens.count == 1 { return (register(nil, tokens[0], emailSafe: emailSafe, gender: gender), -1) }
        if !titled, let found = surname(tokens) { return (found, -1) }
        if tokens.count >= 2 {
            let person = register(tokens.first, tokens.last, emailSafe: emailSafe, middle: tokens.count > 2 ? tokens.dropFirst().dropLast().joined(separator: " ") : nil, gender: gender)
            // "María José" and "García Lindqvist" for María José García Lindqvist are her given names
            // and her surname, written as her stand-in's.
            if !titled, let realFirst = person.realFirst, let realLast = person.realLast, let lead = Self.words(realFirst).first, let end = Self.words(realLast).last {
                let words = tokens.flatMap { Self.words(fold($0)) }, middle = Self.words(person.realMiddle ?? "")
                let given = Set(Self.words(realFirst) + middle), surname = Set(Self.words(realLast) + middle)
                if words.contains(lead), words.allSatisfy(given.contains), !words.contains(where: Self.words(realLast).contains) { return (person, 1) }
                if words.contains(end), words.allSatisfy(surname.contains), !words.contains(where: Self.words(realFirst).contains) { return (person, -1) }
            }
            return (person, 2)
        }
        if let token = tokens.first {
            let last = lastBuckets[fold(token)] ?? Bucket()
            if last.count == 1, let found = last.first {
                if let gender { fit(found, gender) }
                return (found, -1)
            }
            // "Okafor" alone, where Mateus Okafor and Ms Okafor share one stand-in surname.
            // Any of them reads the same; the one picked is fixed, not a dictionary's first.
            if last.count > 1, gender == nil, let found = last.people.min(by: { ($0.realFirst ?? "", $0.drawn) < ($1.realFirst ?? "", $1.drawn) }),
               last.people.allSatisfy({ $0.last == found.last }) { return (found, -1) }
            return (register(token, nil, emailSafe: emailSafe, gender: gender), 1)
        }
        return (register(nil, nil, emailSafe: emailSafe), 2)
    }
    func knows(_ value: String) -> Bool {
        let tokens = value.split(separator: " ")
        guard tokens.count >= 2, let first = tokens.first, let last = tokens.last else { return false }
        let middle = tokens.count > 2 ? fold(tokens.dropFirst().dropLast().joined(separator: " ")) : nil
        return (fullBuckets[Key(first: fold(String(first)), last: fold(String(last)))]?.people ?? []).contains {
            Self.sameMiddle(middle, $0.realMiddle)
        }
    }
    /// A name written the same way is written for the same person each time,
    /// whoever the document names after it.
    private var written: [String: String] = [:]
    /// Who each name written so was taken for, and who the last name drawn was.
    private var writers: [String: Persona] = [:]
    private(set) var lastNamed: Persona?
    func name(for value: String) -> String {
        if let known = written[value] {
            lastNamed = writers[value]
            return known
        }
        if let joint = jointName(for: value) {
            written[value] = joint
            return joint
        }
        let name = writtenName(for: value)
        writers[value] = lastNamed
        // "thanks odalys" stays lowercase, and "FERRITER" in capitals.
        let letters = value.filter(\.isLetter)
        var result = value.contains(where: \.isLowercase) && value == value.lowercased() ? name.lowercased()
            : letters.count >= 4 && letters == letters.uppercased() && letters != letters.lowercased() ? name.uppercased() : name
        // "Julie BEET": a word in capitals keeps them, word for word.
        let words = value.split(separator: " "), made = result.split(separator: " ")
        if result == name, words.count == made.count, words.count > 1 {
            let shouted = words.map { $0.count >= 2 && $0 == $0.uppercased() && $0 != $0.lowercased() && !People.isTitle(String($0)) }
            if shouted.contains(true) { result = zip(made, shouted).map { $1 ? $0.uppercased() : String($0) }.joined(separator: " ") }
        }
        written[value] = result
        return result
    }
    private func writtenName(for value: String) -> String {
        let (person, parts) = registerFull(value)
        lastNamed = person
        // "Ms. Siobhan Okafor" keeps its title, which the stand-in name fits.
        let title = value.split(separator: " ").first.map(String.init).flatMap { Self.titles.contains($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) ? $0 + " " : nil } ?? ""
        if parts == 3 || parts == 2 && Self.naturalOrder(value) != nil {
            let halves = value.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let (surname, suffix) = Self.suffixed(halves[0])
            // "FERRITER, O." keeps its capitals and its initial.
            let last = surname.count > 1 && surname == surname.uppercased() ? person.last.uppercased() : person.last
            let first = halves.count > 1 && Self.isInitials(halves[1]) ? String(person.first.prefix(1)) + (halves[1].hasSuffix(".") ? "." : "") : person.first
            return last + (suffix.map { " " + $0 } ?? "") + ", " + first
        }
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
        // A surname whose pieces are written apart ("smith.jones") is found whole too.
        for part in parts.union([key]) {
            collect(lastOnlyLetters[part])
            if parts.count == 1 { collect(firstOnlyLetters[part]) }
            // A family's few members, each by their own first name ("clem.abernathy" beside Ezra Abernathy).
            if parts.count > 1, let bucket = lastBuckets[part], (1...16).contains(bucket.count) { for person in bucket.people { collect(person) } }
            if let bucket = firstBuckets[part], bucket.count > 0 {
                for other in parts {
                    for person in fullBuckets[Key(first: part, last: other)]?.people ?? [] { collect(person) }
                }
            }
        }
        let matches = candidates.values.filter { $0.matches(local: local) }
        return matches.count == 1 ? matches.first : nil
    }
    /// The one person a username is built from: as an email's local part is
    /// ("odalys.f", "oferriter"), or from a surname or first name only one
    /// person in the document has ("ferriter99").
    func find(handle: String) -> Persona? {
        let bare = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
        if let person = find(email: bare) { return person }
        var candidates: [ObjectIdentifier: Persona] = [:]
        for part in bare.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init) where part.count >= 4 {
            for bucket in [lastBuckets[part], firstBuckets[part]] {
                if let bucket, bucket.count == 1, let person = bucket.first { candidates[ObjectIdentifier(person)] = person }
            }
        }
        return candidates.count == 1 ? candidates.values.first : nil
    }
    /// Whether someone known has either word as a first name or a surname, and a
    /// part that is not `first` `last`'s: the words name them, written another way.
    func namesOtherwise(first: String, last: String) -> Bool {
        let f = Self.fold(first), l = Self.fold(last)
        return [firstBuckets[f], firstBuckets[l], lastBuckets[f], lastBuckets[l]].contains { bucket in
            (bucket?.people ?? []).contains { ($0.realFirst ?? f) != f || ($0.realLast ?? l) != l }
        }
    }
    /// Whether someone known has `first` as a first name or `last` as a surname.
    func knowsAsWritten(first: String, last: String) -> Bool {
        (firstBuckets[Self.fold(first)]?.count ?? 0) > 0 || (lastBuckets[Self.fold(last)]?.count ?? 0) > 0
    }
    func associate(_ person: Persona, email: String?) {
        guard let email else { return }
        associatedEmails[fold(email)] = person
        // Two people of one first name, each with an email of their own (an applicant's record and
        // a spouse's), are no one person under two surnames: the one who took the other's stand-in
        // first name draws one of their own, as two people of one first name otherwise do.
        let pairs = person.namesake.map { [(person, $0)] } ?? []
        for (later, earlier) in pairs + namesakes(of: person).map({ ($0, person) }) {
            let other = later === person ? earlier : later
            guard associatedEmails.contains(where: { $0.key != fold(email) && $0.value === other }) else { continue }
            later.namesake = nil
            let originals = [later.realFirst, later.realLast].compactMap { $0 }.filter { $0.count >= 3 }
            let sex = later.gender ?? later.realFirst.flatMap(NameLists.gender(ofFirst:))
            for _ in 0..<8 {
                guard let first = freshFirst(last: later.last, originals: originals, gender: sex) else { break }
                if fold(first) != fold(earlier.drawn) {
                    usedFullNames.remove(fold(later.drawn + " " + later.last))
                    later.redraw(first)
                    break
                }
            }
        }
    }
    private func namesakes(of person: Persona) -> [Persona] {
        (person.realFirst.flatMap { firstBuckets[$0]?.people } ?? []).filter { $0.namesake === person }
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
        case f + String(l.prefix(1)) where f.count >= 4: body = first + separator + String(last.prefix(1))
        default: return nil
        }
        let count = original.reversed().prefix(while: \.isNumber).count
        let handle = body + (count > 0 ? digits(count) : "")
        return original.first?.isUppercase == true ? handle.prefix(1).uppercased() + handle.dropFirst() : handle
    }
    /// The stand-in for an email's domain: one for each domain, whoever's address it is.
    func domain(of original: String) -> String {
        let pieces = original.split(separator: "@", maxSplits: 1).map(String.init)
        let domain = pieces.count > 1 ? fold(pieces[1]) : ""
        if domains[domain] == nil { domains[domain] = Names.emailDomains[domains.count % Names.emailDomains.count] }
        return domains[domain] ?? "example.com"
    }
    /// Words a shared mailbox is named with: a team, a list or a role, not a person.
    private static let roleWords: Set<String> = [
        "team", "teams", "ops", "operations", "support", "help", "helpdesk", "servicedesk", "service", "services", "noreply", "no", "reply", "donotreply", "do", "not",
        "list", "lists", "listserv", "mailing", "info", "information", "sales", "billing", "invoices", "invoice", "accounts", "account", "accounting", "finance",
        "payments", "payroll", "admin", "admins", "administrator", "hello", "contact", "contacts", "enquiries", "inquiries", "feedback", "office", "reception",
        "frontdesk", "front", "desk", "hr", "careers", "jobs", "recruiting", "talent", "press", "media", "pr", "marketing", "news", "newsletter", "announce",
        "announcements", "updates", "alerts", "notifications", "notify", "security", "abuse", "postmaster", "webmaster", "hostmaster", "privacy", "legal",
        "compliance", "dev", "devs", "devops", "engineering", "eng", "it", "infra", "sre", "oncall", "on", "call", "data", "qa", "product", "design", "all",
        "everyone", "staff", "group", "board", "members", "orders", "shipping", "returns", "customer", "customers", "care", "success", "partners", "events",
        "community", "root", "mailer", "daemon", "bounce", "bounces", "bot", "system", "ci", "builds", "deploy", "release", "releases", "school", "clinic",
        "general", "global", "emea", "apac", "amer", "uk", "us", "eu", "de", "fr", "intl", "internal", "external", "dpo", "gdpr", "tickets", "ticket",
    ]
    /// A shared mailbox, which names no one: "ops-team@…", "billing@…",
    /// "no-reply@…". Every word of its local part is a role's, digits aside.
    static func isRoleMailbox(_ email: String) -> Bool {
        guard let at = email.firstIndex(of: "@") else { return false }
        let words = email[..<at].lowercased().split { !$0.isLetter }
        return !words.isEmpty && words.allSatisfy { roleWords.contains(String($0)) }
    }
    func email(for person: Persona, original: String) -> String {
        let key = fold(original)
        if let existing = person.email(for: key) { return existing }
        let pieces = original.split(separator: "@", maxSplits: 1).map(String.init)
        let standInDomain = domain(of: original)
        let first = fold(person.first).filter(\.isLetter), last = fold(person.last).filter(\.isLetter)
        let local = pieces.first ?? ""
        let joined = local.lowercased().filter(\.isLetter)
        // Read as letters, as the address writes the name: "o’sullivan" is "osullivan".
        let f = person.realFirst.map(Persona.letters), l = person.realLast.map(Persona.letters)
        let fakeLocal: String
        if let f, let l, joined == String(f.prefix(1)) + l { fakeLocal = String(first.prefix(1)) + last }
        else if let f, let l, joined == l + String(f.prefix(1)) { fakeLocal = last + String(first.prefix(1)) }
        else if let f, let l, joined == f + l, !local.contains(where: { "._-+".contains($0) }) { fakeLocal = first + last }
        else if let f, let l, f.count >= 4, joined == f + String(l.prefix(1)) {
            fakeLocal = first + (local.first(where: { "._-".contains($0) }).map(String.init) ?? "") + String(last.prefix(1))
        }
        else { fakeLocal = first + String(local.first(where: { "._-".contains($0) }) ?? ".") + last }
        let email = fakeLocal + "@" + standInDomain
        person.rememberEmail(email, for: key)
        return email
    }
}
