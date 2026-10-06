import Foundation

final class StandIns {
    private static let secretPrefix = TextPattern(#"^(?:(?:sk|pk|rk)_(?:live|test)_|gh[pousr]_|github_pat_|AKIA|ASIA|xox[abposr]-|eyJ|-----BEGIN [A-Z ]*PRIVATE KEY-----)"#)
    let people: People
    private var assigned: [String: String] = [:]
    /// Every value found in the document: a stand-in never repeats one, or a
    /// fake date could put another person's real birth date back.
    private var originals: Set<String> = []
    /// The last four digits of every long number found, which no stand-in year may spell.
    private var originalEndings: Set<String> = []
    func avoid(_ original: String) {
        originals.insert(original.lowercased())
        let digits = original.filter { $0.isASCII && $0.isNumber }
        if digits.count >= 7 { originalEndings.insert(String(digits.suffix(4))) }
        // "Denver, Colorado 80205" also names Denver, which no other place may become.
        guard original.contains(","), original.utf16.count <= 160, let parts = AddressParts.line(original)?.parts else { return }
        for part in [parts.city, parts.region].compactMap({ $0 }) { originals.insert(part.lowercased()) }
    }
    private func unused(_ candidate: String, _ original: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.caseInsensitiveCompare(original.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame && !originals.contains(trimmed.lowercased())
    }
    /// A stand-in number never ends as the real one does: its last four digits
    /// would show the real ones, and "last4" beside it would have none to take.
    private func keepsEnding(_ entity: String, _ candidate: String, _ original: String) -> Bool {
        let real = original.filter { $0.isASCII && $0.isNumber }, made = candidate.filter { $0.isASCII && $0.isNumber }
        return Self.numbered.contains(entity) && real.count >= 7 && made.count >= 4 && real.suffix(4) == made.suffix(4)
    }
    /// Nor does it end in another value the document holds: "last4_ssn" beside
    /// a tax ID repeats its stand-in's last four digits, and a stand-in ending
    /// "1973" would write a real birth year back (and, refused as one, leave no stand-in at all).
    private func endsAsAnOriginal(_ entity: String, _ candidate: String) -> Bool {
        let made = candidate.filter { $0.isASCII && $0.isNumber }
        return Self.numbered.contains(entity) && made.count >= 7 && originals.contains(String(made.suffix(4)))
    }
    private var rng: any RandomNumberGenerator
    init(rng: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.people = People(rng: rng)
        self.rng = rng
    }
    private let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private func pick<T>(_ array: [T]) -> T? { array.randomElement(using: &rng) }
    private func digit(_ first: Bool = false) -> String { String(Int.random(in: first ? 1...9 : 0...9, using: &rng)) }
    private func digits(_ length: Int) -> String {
        guard length > 0 else { return "" }
        func draw() -> String { digit(true) + (1..<length).map { _ in digit() }.joined() }
        var made = draw()
        // Four digits alone (a house number, a short code) never spell a real number's ending or another real value.
        for _ in 0..<8 where length == 4 && (originalEndings.contains(made) || originals.contains(made)) { made = draw() }
        return made
    }
    /// Parts of an address take their stand-ins from one real place; so do
    /// its coordinates.
    static let placed: Set<String> = ["LOCATION", "REGION", "POSTAL_CODE", "ADDRESS", "LATITUDE", "LONGITUDE", "COORDINATES"]
    /// A phone number's area code and a time zone follow the address beside them.
    static let local: Set<String> = ["PHONE_NUMBER", "TIME_ZONE"]
    /// Read off other stand-ins, so drawn after them: an age from its birth
    /// year, the last four digits from the number they end.
    static let derived: Set<String> = ["AGE", "LAST_DIGITS"]
    /// Kinds that are read off another value, or that others are read off:
    /// their stand-ins depend on where they sit (see `scopes`).
    static func anchored(_ entity: String) -> Bool { derived.contains(entity) || numbered.contains(entity) || entity == "DATE_OF_BIRTH" }
    /// The person the last stand-in was drawn from: a name, or an email,
    /// username or initials built from one. Nil for anything else.
    private(set) var owner: Persona?
    func replace(_ entity: String, _ original: String, persona: Persona? = nil, address: AddressParts? = nil) -> String {
        owner = nil
        let fake = drawn(entity, original, persona: persona, address: address)
        noteSource(entity, original, fake)
        // "ODALYS@KESTREL.EXAMPLE" is the same address as in lowercase, and keeps its capitals.
        if entity == "EMAIL_ADDRESS", original.contains(where: \.isLetter), original == original.uppercased() { return fake.uppercased() }
        return fake
    }
    /// A username or an email's local part, and the stand-in each took: "user
    /// quillpen77" beside "quillpen77@marrowmail.example" is one account.
    private var handles: [String: String] = [:]
    /// The lowercase words of every name and handle the document holds, noted
    /// before anything is drawn: a record ID's prefix that is one of them is
    /// someone's name, not a type (see `RecordIDs.keptPrefix`).
    private var namedWords: Set<String> = []
    func noteName(_ value: String) {
        for word in value.lowercased().split(whereSeparator: { !$0.isLetter }) where word.count >= 2 { namedWords.insert(String(word)) }
    }
    private func drawn(_ entity: String, _ original: String, persona: Persona?, address: AddressParts?) -> String {
        let actual = entity == "LOCATION" && people.knows(original) ? "PERSON" : entity
        if actual == "AGE" { return age(original) }
        // A team's or a list's mailbox ("ops-team@…") names no one: it keeps its name, and only its domain is another.
        if actual == "EMAIL_ADDRESS", original.contains("@"), People.isRoleMailbox(original) { return String(original.prefix { $0 != "@" }) + "@" + people.domain(of: original) }
        // A birth date's month or day alone follows the date of its own record.
        if actual == "DATE_OF_BIRTH", let part = birthPart(original) { return part }
        // A zone is written from its holder's parts, each drawn once: two people's alike zone lines are each their own.
        if actual == "MRZ" { return zone(original, persona: persona) }
        // Read off the number nearest it every time, never from a table of
        // its own: two people's "ssn_last4" can read the same and end two numbers.
        if actual == "LAST_DIGITS" || Self.numbered.contains(actual) && Self.isMasked(original) {
            if let derived = masked(original) ?? (actual == "LAST_DIGITS" ? lastDigits(original) : nil), derived != original { return derived }
        }
        // An email is the same address however it is capitalised.
        let plain = actual + "\u{0}" + (actual == "EMAIL_ADDRESS" ? original.lowercased() : original)
        let placed = Self.placed.contains(actual) && (actual != "ADDRESS" || AddressParts.line(original) != nil)
        // Found again elsewhere, a part keeps the stand-in its address gave it.
        if address == nil, placed || Self.local.contains(actual), let found = assigned[plain] { return found }
        // One line wherever it is written: a number takes the area code of the
        // first address it is near, and an extension too short to have one
        // ("x81656") stays the same beside the next.
        if actual == "PHONE_NUMBER", let found = assigned[plain] { return found }
        // A one-line address is placed by its own parts: the city it names, not a state beside it.
        var parts = address ?? Self.lone(actual, original)
        if ["ADDRESS", "LOCATION"].contains(actual), let own = AddressParts.line(original)?.parts, own.city != nil {
            parts = AddressParts(city: own.city, region: own.region, postal: own.postal, country: own.country ?? address?.country, coordinates: nil)
        }
        // A city, region or postcode of a country Scrub has no full places for
        // ("TORINO", "TO", "10128" beside "country_code": "IT") becomes one of
        // that country's cities, every part of one address the same city.
        if ["LOCATION", "REGION", "POSTAL_CODE"].contains(actual), !original.contains(","), let country = Self.abroadCountry(parts),
           let city = abroadCity(country: country, original: parts.city ?? parts.postal ?? original, bare: parts.postal.map { $0.allSatisfy(\.isNumber) && $0.first != "0" } ?? false) {
            return abroadPart(actual, original, city)
        }
        streetAddress = parts
        defer { streetAddress = nil }
        let place = placed ? self.place(for: parts)
            : Self.local.contains(actual) ? address.flatMap { $0.isEmpty ? nil : self.place(for: $0) } : nil
        // A time zone is a setting; only an address beside it makes it personal.
        if actual == "TIME_ZONE" && (place == nil || place?.timeZone == original) { return original }
        // "England" stays England: the stand-in place is in the same nation or another, and neither names anyone.
        if actual == "REGION", let place, Places.write(place, like: original).caseInsensitiveCompare(original) == .orderedSame { return original }
        let key = plain + (place.map { "\u{0}" + $0.city + "\u{0}" + $0.region } ?? "")
        let stablePerson = ["PERSON", "FIRST_NAME", "LAST_NAME"].contains(actual)
        let stableEmail = actual == "EMAIL_ADDRESS" && (persona != nil || people.find(email: original) != nil)
        if !stablePerson && !stableEmail, let found = assigned[key] { return found }
        // One identifier written two ways ("11774270-H", "11774270h") keeps one stand-in, each in its own layout.
        let identity = Recognizers.drawn.contains(actual) ? identifier(original) : nil
        if let identity, let written = reused(identity, original) {
            assigned[key] = written
            return written
        }
        defer { if let identity, let made = assigned[key], identity.recognizer.passes(made) { assigned[identity.key] = String(identity.recognizer.kept(made)) } }
        var fake = "[\(actual)]"
        // A bare number that the document also writes as a phone number
        // ("4158672290" beside "(415) 867-2290") is that phone, and takes its stand-in.
        let digitKind = actual == "ID_NUMBER" && phones.contains(normalized("PHONE_NUMBER", original)) ? "PHONE_NUMBER" : actual
        let sameDigits = digitKey(digitKind, original).flatMap { assigned[$0] }.flatMap { pour($0, into: original) }.flatMap { checked($0, identity) }
        for attempt in 0..<8 {
            // A number a bare "last4" ends keeps its fourth-last digit off zero, before
            // it is judged: the ending it is judged by is the one written.
            let candidate = barelyEnding(actual, original, attempt == 0 ? sameDigits ?? make(digitKind, original, persona, place) : make(digitKind, original, persona, place))
            // A persona's name is fixed; only a fresh value can be drawn again.
            // A part of a stand-in place may match someone else's real one: a state code or ZIP names no one.
            let free = place != nil && ["REGION", "POSTAL_CODE", "TIME_ZONE", "LATITUDE", "LONGITUDE"].contains(actual) && candidate.caseInsensitiveCompare(original) != .orderedSame
                // Initials read off the stand-in name are right even where they happen to match.
                || actual == "INITIALS" && persona != nil
            if keepsEnding(actual, candidate, original) { continue }
            // Digits the same number already has elsewhere stay as they are.
            if attempt > 0 || sameDigits == nil, endsAsAnOriginal(actual, candidate) { continue }
            if free || unused(candidate, original) || attempt >= 2 && stablePerson && candidate.caseInsensitiveCompare(original) != .orderedSame {
                fake = candidate; break
            }
        }
        // A birth date's month or day alone, for a zone's birth date to follow.
        if actual == "DATE_OF_BIRTH", (1...2).contains(original.count), let real = Int(original), let made = Int(fake) { _ = follow("lone", real, made) }
        if !stablePerson && !stableEmail {
            assigned[key] = fake
            if assigned[plain] == nil { assigned[plain] = fake }
        }
        if let digitKey = digitKey(digitKind, original), assigned[digitKey] == nil { assigned[digitKey] = normalized(digitKind, fake) }
        if !original.contains("@"), ["USERNAME", "EMAIL_ADDRESS"].contains(actual), let local = handleKey(original), handles[local] == nil {
            handles[local] = fake
        } else if actual == "EMAIL_ADDRESS", let local = handleKey(String(original.prefix { $0 != "@" })), handles[local] == nil, let made = fake.split(separator: "@").first {
            handles[local] = String(made)
        }
        return fake
    }
    /// A handle worth matching between a username and an email: four letters
    /// or digits or more, and at least one letter.
    private func handleKey(_ value: String) -> String? {
        let key = value.lowercased()
        return key.filter({ $0.isLetter || $0.isNumber }).count >= 4 && key.contains(where: \.isLetter) ? key : nil
    }
    /// The digits of every phone number found, as `normalized` writes them.
    private var phones: Set<String> = []
    func notePhone(_ original: String) {
        let digits = normalized("PHONE_NUMBER", original)
        if digits.count >= 10, !Self.isMasked(original) { phones.insert(digits) }
    }
    /// One number written two ways ("536-21-7784", "536217784", 536217784)
    /// keeps one stand-in, each in its own layout.
    private static let numbered: Set<String> = ["US_SSN", "CREDIT_CARD", "US_BANK_NUMBER", "ID_NUMBER", "PHONE_NUMBER", "US_ITIN", "US_PASSPORT"]
    private func normalized(_ entity: String, _ value: String) -> String {
        let digits = value.filter { $0.isASCII && $0.isNumber }
        return entity == "PHONE_NUMBER" && digits.count == 11 && digits.first == "1" ? String(digits.dropFirst()) : digits
    }
    private func digitKey(_ entity: String, _ original: String) -> String? {
        guard Self.numbered.contains(entity), !Self.isMasked(original) else { return nil }
        let digits = normalized(entity, original)
        return digits.count >= 7 ? "DIGITS\u{0}" + (entity == "PHONE_NUMBER" ? entity : "NUMBER") + "\u{0}" + digits : nil
    }
    private func pour(_ digits: String, into original: String) -> String? {
        let count = original.filter { $0.isASCII && $0.isNumber }.count
        let source = count == digits.count + 1 ? "1" + digits : digits
        guard source.count == count else { return nil }
        var iterator = source.makeIterator()
        return String(original.map { $0.isASCII && $0.isNumber ? iterator.next() ?? $0 : $0 })
    }
    /// Birth years already replaced, so "birth_year" and "age" can agree with
    /// the stand-ins they come from.
    private var years: [Int: Int] = [:]
    /// The birth years in `years`, in the order first met, so an age as close
    /// to two of them goes by the first, whatever order a dictionary keeps.
    private var yearOrder: [Int] = []
    /// The year a job runs in, read once: a job that runs over New Year moves
    /// every birth year and age by the same rule.
    private let now = Calendar(identifier: .gregorian).component(.year, from: Date())

    // MARK: Values read off another

    /// Where the value being drawn sits, innermost first: in prose its
    /// sentence, paragraph and value, then the records around it, the
    /// innermost led by the object a flattened header names in it
    /// ("r3/applicant" before "r3", see `Job.enter`). An age, last digits, a
    /// masked number or a birth date's month follows the value it is read
    /// off in the nearest of these that holds one, not just any in the
    /// document: two people's SSNs can end alike, and two birth years can
    /// both fit an age.
    var scopes: [String] = []
    /// The words naming the value being drawn (see `Job.enter`).
    var naming: Set<String> = []
    /// Set by a draw read off another value when the nearest scope holding
    /// one holds several that disagree: it takes the first, and review asks.
    var unclear = false
    /// A number's last four digits and its stand-in's, and whether it is a
    /// phone's: "last4" beside a card and a phone ending alike is the card's.
    private struct Ending: Equatable { let fake: String; let phone: Bool }
    private var endings: [String: [Ending]] = [:]
    private var scopedEndings: [String: [String: [Ending]]] = [:]
    private var scopedYears: [String: [Int]] = [:]
    /// Birth dates by their day: one date written two ways ("1987-03-14",
    /// "March 14, 1987") keeps one stand-in day, and a month or day written
    /// alone follows the date of its own record.
    private struct Day: Hashable { let year: Int; let month: Int; let day: Int }
    private var days: [Day: Day] = [:]
    private struct DayPair: Equatable { let real: Day; let fake: Day }
    private var scopedDays: [String: [DayPair]] = [:]
    /// Endings with no number to follow, drawn once each.
    private var freshEndings: [String: String] = [:]
    /// Last four digits written as a bare number ("ssn_last4": 7784) can't
    /// start with a zero, so a number they end keeps its stand-in's fourth-last
    /// digit off zero (and a card its check digit valid).
    private var bareEndings: Set<String> = []
    /// Last digits that may be written bare, noted before any number is drawn.
    func noteEnding(_ original: String) {
        if original.count == 4, original.first != "0", original.allSatisfy({ $0.isASCII && $0.isNumber }) { bareEndings.insert(original) }
    }
    private func barelyEnding(_ entity: String, _ original: String, _ fake: String) -> String {
        let real = original.filter { $0.isASCII && $0.isNumber }, made = fake.filter { $0.isASCII && $0.isNumber }
        guard real.count >= 7, made.count >= 4, bareEndings.contains(String(real.suffix(4))), made.dropLast(3).last == "0" else { return fake }
        var digits = Array(made)
        digits[digits.count - 4] = Character(digit(true))
        if entity == "CREDIT_CARD" {
            let stem = digits.dropLast().compactMap(\.wholeNumberValue)
            digits[digits.count - 1] = Character(String((0...9).first { Patterns.luhn(stem + [$0]) } ?? 0))
        }
        var iterator = digits.makeIterator()
        let ending = String(fake.map { $0.isASCII && $0.isNumber ? iterator.next() ?? $0 : $0 })
        // An identifier's check outranks its ending: a stand-in drawn for it stays one (see `identifierStandIn`, which draws around the ending).
        if let recognizer = Recognizers.recognizing(original), recognizer.passes(fake), !recognizer.passes(ending) { return fake }
        return ending
    }
    /// Notes a value others may be read off, under every scope it sits in:
    /// a number's ending, and a birth date's year and day. Called for every
    /// draw, including one that repeats a stand-in already drawn, since the
    /// same number can sit in another record.
    private func noteSource(_ entity: String, _ original: String, _ fake: String) {
        if Self.numbered.contains(entity) {
            let real = original.filter { $0.isASCII && $0.isNumber }, made = fake.filter { $0.isASCII && $0.isNumber }
            guard real.count >= 7, made.count >= 4, !original.contains(where: { Self.maskCharacters.contains($0) }) else { return }
            let ending = Ending(fake: String(made.suffix(4)), phone: entity == "PHONE_NUMBER"), key = String(real.suffix(4))
            if !(endings[key]?.contains(ending) ?? false) { endings[key, default: []].append(ending) }
            for scope in scopes where !(scopedEndings[scope]?[key]?.contains(ending) ?? false) { scopedEndings[scope, default: [:]][key, default: []].append(ending) }
        } else if entity == "DATE_OF_BIRTH" {
            guard let real = Self.dateParts(original), years[real.year] != nil else { return }
            for scope in scopes where !(scopedYears[scope]?.contains(real.year) ?? false) { scopedYears[scope, default: []].append(real.year) }
            guard let month = real.month, let day = real.day, let made = Self.dateParts(fake), let fakeMonth = made.month, let fakeDay = made.day else { return }
            let pair = DayPair(real: Day(year: real.year, month: month, day: day), fake: Day(year: made.year, month: fakeMonth, day: fakeDay))
            if days[pair.real] == nil { days[pair.real] = pair.fake }
            for scope in scopes where !(scopedDays[scope]?.contains { $0.real == pair.real } ?? false) { scopedDays[scope, default: []].append(pair) }
        }
    }
    /// The candidates a derived value takes from: those of the nearest scope
    /// holding any, else the document's. `unclear` when they disagree.
    private func nearest<T: Equatable>(_ scoped: (String) -> [T], document: [T]) -> [T] {
        for scope in scopes {
            let found = scoped(scope)
            if !found.isEmpty { return found }
        }
        return document
    }
    /// The stand-in ending for a number's last four digits, from the number
    /// nearest it that ends so; nil when the document holds none.
    private func knownEnding(_ visible: String) -> String? {
        guard visible.count == 4 else { return nil }
        let found = nearest({ self.scopedEndings[$0]?[visible] ?? [] }, document: endings[visible] ?? [])
        guard !found.isEmpty else { return nil }
        let preferred = found.contains { !$0.phone } ? found.filter { !$0.phone } : found
        var distinct: [String] = []
        for ending in preferred where !distinct.contains(ending.fake) { distinct.append(ending.fake) }
        if distinct.count > 1 { unclear = true }
        return distinct.first
    }
    /// A birth year moves one to eight years: enough that the date names no
    /// one, close enough that an age bracket or age estimate beside it still reads true.
    private func year(for original: Int) -> Int {
        if let known = years[original] { return known }
        func draw() -> Int {
            let shift = Int.random(in: 1...8, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
            return (1900...now).contains(original + shift) ? original + shift : original - shift
        }
        var fake = draw()
        // Nor any year the document holds: one person's stand-in year is never another's real one.
        // Nor the last four digits of a number it holds: "1962" beside an SSN ending 1962 would give them away.
        for _ in 0..<12 where fake == original || years.values.contains(fake) || originals.contains(String(fake)) || originalEndings.contains(String(fake)) || bareEndings.contains(String(fake)) { fake = draw() }
        years[original] = fake
        yearOrder.append(original)
        return fake
    }
    /// An age moved by as many years as the birth year it fits (within a
    /// year, for a birthday still to come), from the nearest scope that holds
    /// a birth date. In its own record, sentence or paragraph, an age may
    /// have been written years before the scrub ("1994-11-02" beside 30 in a
    /// file from 2024), so there it moves with a birth date it could have been
    /// the age at, up to 30 years ago. Where that scope's birth dates fit
    /// none, or the document holds none, it tells nothing and stays.
    private func age(_ original: String) -> String {
        guard let age = Int(original.trimmingCharacters(in: .whitespaces)) else { return original }
        let distance = { (year: Int) in abs((self.now - year) - age) }
        let scope = scopes.first { !(self.scopedYears[$0] ?? []).isEmpty }
        let found = scope.flatMap { self.scopedYears[$0] } ?? yearOrder
        var fitting = found.filter { distance($0) <= 1 }
        // A record ("r3"), or a sentence or paragraph of a value ("v0s2", "v0p1"); not a whole text.
        let own = scope.map { $0.first == "r" || $0.dropFirst().contains { $0 == "s" || $0 == "p" } } ?? false
        if fitting.isEmpty, own { fitting = found.filter { (0...30).contains((self.now - $0) - age) } }
        if fitting.count > 1 { unclear = true }
        // The first-met of the closest: `min` keeps the first of equals.
        guard let real = fitting.min(by: { distance($0) < distance($1) }), let fake = years[real] else { return original }
        return original.replacingOccurrences(of: String(age), with: String(max(0, min(120, age + real - fake))))
    }
    /// The last four digits of a number the document also holds in full take
    /// that number's stand-in's; any others are drawn fresh, once each.
    private func lastDigits(_ original: String) -> String {
        let visible = original.filter(\.isNumber)
        let ending = knownEnding(visible) ?? fresh(visible) { index in Character(self.digit(index == 0 && visible.first != "0")) }
        var digits = ending.makeIterator()
        return String(original.map { $0.isNumber ? digits.next() ?? $0 : $0 })
    }
    private func fresh(_ visible: String, _ draw: (Int) -> Character) -> String {
        if let known = freshEndings[visible] { return known }
        // Drawn fresh, it gains no leading zero: it may be a bare number. Nor does it spell another real value.
        var made = String((0..<visible.count).map(draw))
        for _ in 0..<8 where made == visible || originalEndings.contains(made) || originals.contains(made) { made = String((0..<visible.count).map(draw)) }
        freshEndings[visible] = made
        return made
    }
    private static let maskCharacters: Set<Character> = ["*", "•", "●", "X", "x", "#"]
    static func isMasked(_ value: String) -> Bool { value.filter { maskCharacters.contains($0) }.count >= 2 && value.contains(where: \.isNumber) }
    /// "***-**-7784" stays masked; only the digits it shows change, to those
    /// of the number nearest it that ends so.
    private func masked(_ original: String) -> String? {
        guard original.filter({ Self.maskCharacters.contains($0) }).count >= 2, original.contains(where: \.isNumber) else { return nil }
        let shown = String(original.reversed().prefix { !Self.maskCharacters.contains($0) }.reversed())
        let visible = shown.filter(\.isNumber)
        guard !visible.isEmpty else { return nil }
        var digits = (knownEnding(visible) ?? fresh(visible) { _ in Character(self.digit()) }).makeIterator()
        let rewritten = String(shown.map { $0.isNumber ? digits.next() ?? $0 : $0 })
        return String(original.dropLast(shown.count)) + rewritten
    }
    /// The part of a birth date the value being drawn is, as its key says
    /// (see `Job.enter`); nil where no key names one.
    var part: KeyHints.DatePart?
    /// A birth date's month or day written alone, as its key says it is
    /// ("birth_month": 3, "dob": {"day": "03"}, "birth_month": "March"),
    /// takes that part of the stand-in birth date beside it in its own record,
    /// written as the original was: so the parts and the date agree, and a
    /// month is never taken for a day. Where no date is near, the parts of one
    /// record still make one date, each drawn once for the record. With no key
    /// to say which part it is, a lone number is matched against the date beside
    /// it, month first; nil where none is near. A year is drawn as any other.
    /// The record the value being replaced sits in: a row, or an object of a file's.
    private var currentRecord: String? { scopes.first { $0.first == "r" }.map { String($0.prefix { $0 != "/" }) } }
    private func birthPart(_ original: String) -> String? {
        let trimmed = original.trimmingCharacters(in: .whitespaces)
        let number = (1...2).contains(trimmed.count) && trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int(trimmed) : nil
        func written(_ value: Int) -> String {
            // "03" stays padded; "11" is a plain number, and a JSON number can't lead with a zero.
            guard number == nil else { return trimmed.first == "0" ? String(format: "%02d", value) : String(value) }
            return Self.monthName(value, like: trimmed)
        }
        let found = nearest({ self.scopedDays[$0] ?? [] }, document: [])
        // A part that is no part of any date near takes its own record's date, never a neighbour's:
        // within a row of flattened objects, its own object's first ("applicant.dob"), then the row's.
        let record = currentRecord.map { Substring($0) }
        let own = scopes.lazy.filter { $0.first == "r" && $0.prefix { $0 != "/" } == record }.compactMap { self.scopedDays[$0] }.first ?? []
        func agreed(_ pairs: [DayPair], _ part: (Day) -> Int) -> Int? {
            guard let first = pairs.first else { return nil }
            if Set(pairs.map { part($0.fake) }).count > 1 { unclear = true }
            return part(first.fake)
        }
        switch part {
        case .month?:
            guard let value = number ?? Self.month(trimmed), (1...12).contains(value) else { return nil }
            let matching = found.filter { $0.real.month == value }
            return written(follow("month", value, agreed(matching.isEmpty ? own : matching, \.month) ?? drawnPart(month: true, besides: value)))
        case .day?:
            guard let value = number, (1...31).contains(value) else { return nil }
            let matching = found.filter { $0.real.day == value }
            return written(follow("day", value, agreed(matching.isEmpty ? own : matching, \.day) ?? drawnPart(month: false, besides: value)))
        case .year?:
            return nil
        case nil:
            guard let value = number else { return nil }
            return (agreed(found.filter { $0.real.month == value }, \.month) ?? agreed(found.filter { $0.real.day == value }, \.day)).map(written)
        }
    }
    /// A month and a day drawn for each record whose birth date is written
    /// only in parts, by its innermost scope.
    private var partDays: [String: (month: Int?, day: Int?)] = [:]
    /// The stand-ins birth dates' months and days written alone took, by their real value (see `follow`).
    fileprivate var follows: [String: [Int: Int]] = [:]
    /// The same, by the record they were written in: a zone takes its own holder's parts first.
    fileprivate var ownFollows: [String: [Int: Int]] = [:]
    /// How much each ID card's first zone line, rewritten as a value of its own,
    /// moved the sum its second line's last check digit covers, with the records
    /// it sits in: the first lines are rewritten before the second, and each
    /// second line takes the shift of a first line in its own record (see `zone`).
    fileprivate var cardShifts: [(record: String?, shift: Int)] = []
    private func drawnPart(month: Bool, besides original: Int) -> Int {
        let scope = scopes.first { $0.first == "r" } ?? scopes.first ?? ""
        var drawn = partDays[scope] ?? (nil, nil)
        if let known = month ? drawn.month : drawn.day { return known }
        var value = original
        for _ in 0..<8 where value == original { value = Int.random(in: 1...(month ? 12 : 28), using: &rng) }
        if month { drawn.month = value } else { drawn.day = value }
        partDays[scope] = drawn
        return value
    }
    /// The year, and where the format says so the month and day, of a date
    /// as written: "1987-03-14", "03/14/1987", "14 March 1987", "19870314".
    /// A day and month that could be either way round ("11/07/1984") give the year alone.
    static func dateParts(_ written: String) -> (year: Int, month: Int?, day: Int?)? {
        let trimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 8, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }), let head = Int(trimmed.prefix(4)), let tail = Int(trimmed.suffix(4)) {
            let middle = Int(trimmed.dropFirst(4).prefix(2)), first = Int(trimmed.prefix(2)), second = Int(trimmed.dropFirst(2).prefix(2))
            if (1900...2100).contains(head), let middle, let day = Int(trimmed.suffix(2)) { return (head, middle, day) }
            if (1900...2100).contains(tail), let first, let second { return first > 12 ? (tail, second, first) : second > 12 ? (tail, first, second) : (tail, nil, nil) }
            return nil
        }
        var runs: [String] = []
        for character in trimmed {
            let kind = character.isNumber ? 0 : character.isLetter ? 1 : 2
            if let last = runs.last?.last, (last.isNumber ? 0 : last.isLetter ? 1 : 2) == kind { runs[runs.count - 1].append(character) } else { runs.append(String(character)) }
        }
        let numbers = runs.compactMap { run in run.first?.isNumber == true ? Int(run).map { (run.count, $0) } : nil }
        guard let year = numbers.first(where: { $0.0 == 4 })?.1, (1900...2100).contains(year) else { return nil }
        let rest = numbers.filter { $0.0 != 4 }.map(\.1)
        let month = runs.lazy.compactMap { run -> Int? in
            let word = run.lowercased()
            return monthNames.firstIndex { word == $0 || word.count >= 3 && $0.hasPrefix(word) }.map { $0 + 1 }
        }.first
        if let month { return rest.count == 1 ? (year, month, rest[0]) : (year, month, nil) }
        guard rest.count == 2 else { return (year, nil, nil) }
        let yearFirst = numbers.first?.0 == 4
        if yearFirst { return (year, rest[0], rest[1]) }
        return rest[0] > 12 ? (year, rest[1], rest[0]) : rest[1] > 12 ? (year, rest[0], rest[1]) : (year, nil, nil)
    }
    private static let monthNames = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    /// The month a word names, in full or cut to three letters or more ("March", "MAR", "Sept.").
    static func month(_ word: String) -> Int? {
        let word = word.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        guard word.count >= 3, word.allSatisfy(\.isLetter) else { return nil }
        return monthNames.firstIndex { $0.hasPrefix(word) }.map { $0 + 1 }
    }
    /// A month's name written as `word` writes one: in full or short, and in its case.
    static func monthName(_ month: Int, like word: String) -> String {
        let letters = word.filter(\.isLetter)
        let full = letters.count > 3 && letters.lowercased() != "sept"
        let whole = monthNames[max(1, min(12, month)) - 1].capitalized
        let name = full ? whole : String(whole.prefix(3))
        let cased = letters == letters.uppercased() ? name.uppercased() : letters == letters.lowercased() ? name.lowercased() : name
        return word.hasSuffix(".") && !full ? cased + "." : cased
    }
    private static func lone(_ entity: String, _ original: String) -> AddressParts {
        switch entity {
        case "LOCATION": return AddressParts.line(original)?.parts ?? AddressParts(city: original)
        case "REGION": return AddressParts(region: original)
        case "POSTAL_CODE": return AddressParts(postal: original)
        case "LATITUDE", "LONGITUDE", "COORDINATES": return AddressParts(coordinates: original)
        default: return AddressParts.line(original)?.parts ?? AddressParts()
        }
    }
    /// One stand-in place per address: the same original city (or, without
    /// one, region or postal area) always becomes the same place, a different
    /// one a different place, and never one in the original's own region.
    private var places: [String: Place] = [:]
    private var usedPlaces: Set<String> = []
    private var regionPlaces: [String: Place] = [:]
    private var claimed: Set<String> = []
    private var districtPlaces: [String: Place] = [:]
    func place(for parts: AddressParts) -> Place? {
        guard !parts.isEmpty, let country = Places.country(city: parts.city, region: parts.region, postal: parts.postal, country: parts.country, coordinates: parts.coordinates) else { return nil }
        let anchor: String
        if let city = parts.city { anchor = "city:" + city.lowercased() }
        else if let region = parts.region { anchor = "region:" + (Places.region(region)?.code ?? region.lowercased()) }
        else if let postal = parts.postal { anchor = "postal:" + String(postal.filter { $0.isLetter || $0.isNumber }.prefix(3)).lowercased() }
        else { anchor = "point:" + (parts.coordinates ?? "") }
        let key = country + "\u{0}" + anchor
        if let known = places[key] { return known }
        // The UK's nations name no one; a US state, province or Australian state does, so it changes.
        let ownRegion = country == "GB" ? nil : parts.region.flatMap { Places.region($0, in: country) }?.code
        // One state stays one state: a lone "state": "NY" and an address in New York share a place,
        // whichever comes first, unless another city already took it.
        let regionKey = ownRegion.map { country + "\u{0}" + $0 }
        // One postcode stays one place too: "postalCodes": ["80302"] beside "Boulder, 80302".
        let districtKey = parts.postal.map { country + "\u{0}" + Self.district($0) }
        // A place taken for the same state or postal area is shared only if this address's postcode can be written in it.
        let writable = { (place: Place) in parts.postal.map { self.canWrite(place, like: $0) } ?? true }
        if let districtKey, let known = districtPlaces[districtKey], ownRegion == nil || Places.region(known.region, in: country)?.code != ownRegion,
           parts.city == nil || !claimed.contains(known.city + known.region), writable(known) {
            places[key] = known
            if parts.city != nil { claimed.insert(known.city + known.region) }
            if let regionKey, regionPlaces[regionKey] == nil { regionPlaces[regionKey] = known }
            return known
        }
        if let regionKey, let known = regionPlaces[regionKey], parts.city == nil || !claimed.contains(known.city + known.region), writable(known) {
            places[key] = known
            if parts.city != nil { claimed.insert(known.city + known.region) }
            if let districtKey, districtPlaces[districtKey] == nil { districtPlaces[districtKey] = known }
            return known
        }
        // A UK district of the original's shape other than its own will do, in any place (see `canWrite`).
        let inCountry = Places.all.filter { place in
            place.country == country && Places.region(place.region, in: country)?.code != ownRegion && !originals.contains(place.city.lowercased())
        }
        let writing = inCountry.filter { place in parts.postal.map { canWrite(place, like: $0) } ?? true }
        let elsewhere = writing.filter { place in parts.postal.map { !place.postal.contains(Self.district($0)) } ?? true }
        // Best a place outside the original's district; a UK shape only its own place writes stays there.
        // Never another country for want of a postcode's shape: a place of its own country, its code drawn in the shape.
        let candidates = !elsewhere.isEmpty ? elsewhere : country == "GB" && !writing.isEmpty ? writing : inCountry
        // Best a place no other address became, in a region no one in the document is from.
        let fresh = candidates.filter { place in
            let region = Places.region(place.region, in: country)
            return !originals.contains(place.region.lowercased()) && !originals.contains((region?.code ?? "").lowercased()) && !originals.contains((region?.name ?? "").lowercased())
        }
        guard let chosen = pick(fresh.filter { !usedPlaces.contains($0.city + $0.region) }) ?? pick(candidates.filter { !usedPlaces.contains($0.city + $0.region) }) ?? pick(fresh) ?? pick(candidates) else { return nil }
        usedPlaces.insert(chosen.city + chosen.region)
        places[key] = chosen
        if let regionKey, regionPlaces[regionKey] == nil { regionPlaces[regionKey] = chosen }
        if let districtKey, districtPlaces[districtKey] == nil { districtPlaces[districtKey] = chosen }
        if parts.city != nil { claimed.insert(chosen.city + chosen.region) }
        return chosen
    }
    /// Whether the place has a postcode written like the original: no new
    /// leading zero on a bare number, a UK district of the same shape.
    private func canWrite(_ place: Place, like original: String) -> Bool {
        let trimmed = original.trimmingCharacters(in: .whitespaces)
        switch place.country {
        case "US", "AU": return !(trimmed.allSatisfy(\.isNumber) && trimmed.first != "0") || place.postal.contains { $0.first != "0" }
        case "GB":
            let outward = (trimmed.contains(" ") ? String(trimmed.prefix { $0 != " " }) : String(trimmed.dropLast(3))).uppercased()
            return place.postal.contains { $0 != outward && Self.shape($0) == Self.shape(outward) }
        default: return true
        }
    }
    /// A postcode of the place, written as the original is, or nil where no
    /// code of the place has its shape.
    private func postal(of place: Place, like original: String, bare: Bool? = nil) -> String? {
        let trimmed = original.trimmingCharacters(in: .whitespaces)
        let candidate: String?
        switch place.country {
        case "US", "AU":
            let digits = trimmed.filter(\.isNumber)
            // A bare number gains no leading zero, or pasted JSON stops parsing; "83702-5317" may.
            let bare = bare ?? (trimmed.allSatisfy(\.isNumber) && trimmed.first != "0")
            // A code that spells a real number's ending or another real value gives way to another of the place's.
            let shaped = place.postal.filter { !bare || $0.first != "0" }
            let unspoken = shaped.filter { !originalEndings.contains($0) && !originals.contains($0) }
            let codes = unspoken.isEmpty ? shaped : unspoken
            // "55802" and "55802-8468" are one ZIP code, with one stand-in.
            let base = "ZIP\u{0}" + String(digits.prefix(5)) + "\u{0}" + place.city + place.region
            let known = assigned[base].flatMap { codes.contains($0) ? $0 : nil }
            guard let code = known ?? pick(codes) else { return nil }
            if known == nil, place.country == "US" { assigned[base] = code }
            if digits.count == 9, place.country == "US" {
                // Its four extra digits spell no other value the document holds (a birth year, an ending).
                var plus = String(Int.random(in: 1000...9999, using: &rng))
                for _ in 0..<8 where originals.contains(plus) || originalEndings.contains(plus) { plus = String(Int.random(in: 1000...9999, using: &rng)) }
                candidate = trimmed.contains("-") ? code + "-" + plus : trimmed.contains(" ") ? code + " " + plus : code + plus
            } else { candidate = code }
        case "CA":
            let letters = Array("ABCEGHJKLMNPRSTVWXYZ")
            let local = digit() + String(pick(letters) ?? "A") + digit()
            candidate = pick(place.postal).map { $0 + (trimmed.contains(" ") ? " " : "") + local }
        case "GB":
            let letters = Array("ABDEFGHJLNPQRSTUWXYZ")
            let outward = trimmed.contains(" ") ? String(trimmed.prefix { $0 != " " }) : String(trimmed.dropLast(3))
            let inward = digit() + String(pick(letters) ?? "A") + String(pick(letters) ?? "B")
            // A district of the original's shape, else any of the place's own: "SW1A 1AA" in Bristol is "BS1 4XY", not a district no one has.
            let others = place.postal.filter { $0 != outward.uppercased() }
            let district = pick(others.filter { Self.shape($0) == Self.shape(outward.uppercased()) }) ?? pick(others)
            candidate = district.map { $0 + (trimmed.contains(" ") ? " " : "") + inward }
            guard var candidate, candidate.uppercased() != trimmed.uppercased() else { return nil }
            if trimmed == trimmed.lowercased() { candidate = candidate.lowercased() }
            return candidate
        default: candidate = nil
        }
        guard var candidate, Self.shape(candidate) == Self.shape(trimmed.uppercased()) else { return nil }
        if trimmed == trimmed.lowercased() { candidate = candidate.lowercased() }
        return candidate
    }
    /// The postcode a place gives an original, the same on its own line and in a full address.
    private func placedPostal(_ place: Place, _ original: String, bare: Bool? = nil) -> String {
        let key = "POSTAL_CODE\u{0}" + original + "\u{0}" + place.city + "\u{0}" + place.region
        if let known = assigned[key] { return known }
        let fake = postal(of: place, like: original, bare: bare) ?? idLike(original)
        assigned[key] = fake
        return fake
    }
    /// The part of a postcode that names the area: a ZIP's five digits, a UK outward code, a Canadian FSA.
    static func district(_ postal: String) -> String {
        let upper = postal.uppercased().trimmingCharacters(in: .whitespaces)
        if upper.allSatisfy({ $0.isNumber || $0 == "-" || $0 == " " }) { return String(upper.filter(\.isNumber).prefix(upper.filter(\.isNumber).count == 4 ? 4 : 5)) }
        if upper.contains(" ") { return String(upper.prefix { $0 != " " }) }
        return String(upper.prefix(upper.count > 3 ? upper.count - 3 : upper.count))
    }
    private static func shape(_ text: String) -> String { String(text.map { $0.isNumber ? "9" : $0.isLetter ? "A" : $0 }) }
    private func city(of place: Place, like original: String) -> String {
        original == original.uppercased() && original.contains(where: \.isLetter) ? place.city.uppercased() : original == original.lowercased() ? place.city.lowercased() : place.city
    }
    /// A one-line address rewritten piece by piece, all from one place:
    /// "4821 Juniper Hollow Rd, Apt 2B, Tacoma, WA 98402" → "512 Oak Street, Apt 7C, Denver, CO 80205".
    private func line(_ original: String, _ parsed: (parts: AddressParts, pieces: [String], separators: [String]), _ place: Place) -> String {
        let parts = parsed.parts
        var separators = parsed.separators.makeIterator()
        return parsed.pieces.enumerated().map { index, piece in
            let written: String
            if piece == parts.city { written = city(of: place, like: piece) }
            else if piece == parts.country { written = piece }
            else if piece == parts.region { written = Places.write(place, like: piece) }
            else if piece == parts.postal { written = placedPostal(place, piece, bare: false) }
            // "TX  78701" keeps the gap it was written with.
            else if let region = parts.region, let code = parts.postal, piece.hasPrefix(region), piece.hasSuffix(code),
                    piece.dropFirst(region.count).dropLast(code.count).allSatisfy({ $0 == " " || $0 == "\t" }), piece.count > region.count + code.count {
                written = Places.write(place, like: region) + piece.dropFirst(region.count).dropLast(code.count) + placedPostal(place, code, bare: false)
            }
            // A mail stop or room code beside the street ("EB3880D") keeps its shape.
            else if !piece.contains(" "), piece.contains(where: \.isNumber), piece.contains(where: \.isLetter) { written = unit(piece) ?? idLike(piece) }
            // "624, chemin des Chênes": a house number on its own, a street named as another language does.
            else if piece.allSatisfy(\.isNumber) { written = addressNumbered(piece) }
            else if AddressBlock.isStreet(piece), !piece.first!.isNumber { written = foreignStreet(like: piece, country: parts.country.flatMap(AddressBlock.countryName) ?? Places.country(city: parts.city, region: parts.region, postal: parts.postal, country: nil)) }
            else { written = unit(piece) ?? (AddressBlock.isUnit(piece) ? renumbered(piece) : street(like: piece)) }
            return written + (index < parsed.pieces.count - 1 ? separators.next() ?? ", " : "")
        }.joined() + (original.hasSuffix(".") ? "." : "")
    }
    /// An address `AddressParts.line` cannot read, rewritten piece by piece in
    /// its own layout (see `AddressBlock`). Its locality comes from one real
    /// place: in the US, Canada, the UK and Australia from `Places`, so the
    /// city, region and postcode agree; elsewhere from a short list of cities
    /// of the same country. Where no country is clear, the city is drawn as
    /// any other place's and the postcode keeps its shape.
    private func block(_ original: String, _ parsed: AddressBlock) -> String {
        let main = parsed.main
        var place: Place?
        if let country = parsed.country, ["US", "CA", "GB", "AU"].contains(country), let main {
            // A postcode no stand-in place can be written like still leaves the city and region to place it.
            place = self.place(for: AddressParts(city: main.city, region: main.region, postal: main.postal, country: country))
                ?? self.place(for: AddressParts(city: main.city ?? main.postal, region: main.region, postal: nil, country: country))
        }
        let cities = parsed.localities.compactMap(\.locality.city)
        let abroad = place == nil ? parsed.country.flatMap { abroadCity(country: $0, original: main?.city ?? main?.postal ?? original, besides: cities) } : nil
        let localities = Dictionary(uniqueKeysWithValues: parsed.localities.map { ($0.index, $0.locality) })
        var separators = parsed.separators.makeIterator()
        return parsed.pieces.enumerated().map { index, piece in
            let written: String
            switch parsed.roles[index] {
            case .country: written = piece
            // "Apt 4B" takes another number; "Ground Floor" or "bajo" names no one and stays.
            case .unit: written = unit(piece) ?? renumbered(piece)
            case .street:
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                written = trimmed.allSatisfy(\.isNumber) ? addressNumbered(piece)
                    : Self.english(parsed.country) && trimmed.first?.isNumber == true ? street(like: piece) : foreignStreet(like: piece, country: parsed.country)
            case .locality: written = locality(piece, localities[index] ?? AddressBlock.Locality(), place: place, abroad: abroad)
            case .place:
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                // A region's code on a line of its own ("CDMX") stays, or takes the stand-in city's.
                written = trimmed.count <= 4 && trimmed == trimmed.uppercased() ? (abroad?.region ?? piece) : placeName(like: piece, country: parsed.country)
            }
            return written + (index < parsed.pieces.count - 1 ? separators.next() ?? ", " : "")
        }.joined()
    }

    private static func english(_ country: String?) -> Bool { country.map { ["US", "CA", "GB", "AU", "NZ", "IE", "ZA", "IN", "SG"].contains($0) } ?? true }

    /// Its digits drawn afresh, the rest as written: "3º Esq." → "7º Esq.".
    private func renumbered(_ original: String) -> String {
        // "12th Floor" → "7th Floor": an ordinal keeps its ending.
        if let match = original.range(of: #"^\d+(?=th\b)"#, options: .regularExpression) {
            return String(Int.random(in: 4...19, using: &rng)) + original[match.upperBound...]
        }
        if original.range(of: #"^\d+(?:st|nd|rd)\b"#, options: .regularExpression) != nil { return String(Int.random(in: 4...19, using: &rng)) + "th" + original.drop { $0.isNumber }.dropFirst(2) }
        let lead = original.firstIndex(where: \.isNumber)
        func draw() -> String { String(original.indices.map { index in original[index].isNumber ? Character(digit(index == lead)) : original[index] }) }
        var made = draw()
        // Like `digits`: four digits never spell a real number's ending or another real value.
        for _ in 0..<8 where made.filter(\.isNumber).count == 4 && (originalEndings.contains(made.filter(\.isNumber)) || originals.contains(made.filter(\.isNumber))) { made = draw() }
        return made
    }

    /// One address's house and unit numbers, each run of digits always the same
    /// stand-in: "12" alone, "12" in "Via Garibaldi 12/2" and in "12 Main St" agree.
    private var addressNumbers: [String: String] = [:]
    /// Street names by their own words ("garibaldi", "juniper hollow"), and the stand-in each takes.
    private var streetRuns: [String: String] = [:]
    /// The address the value being drawn belongs to, for a street's language.
    private var streetAddress: AddressParts?
    func addressNumber(_ digits: String) -> String {
        if let known = addressNumbers[digits] { return known }
        var made = digits
        for _ in 0..<16 where made == digits || originals.contains(made) || addressNumbers.values.contains(made) {
            made = String(digits.indices.map { Character(digit($0 == digits.startIndex && digits.first != "0")) })
        }
        addressNumbers[digits] = made
        return made
    }
    /// Every run of digits rewritten by `addressNumber`, the rest as written; an ordinal keeps a fitting ending ("21st" → "43rd").
    func addressNumbered(_ text: String) -> String {
        var result = "", run = ""
        func flush() { if !run.isEmpty { result += addressNumber(run); run = "" } }
        for character in text {
            if character.isASCII && character.isNumber { run.append(character) } else { flush(); result.append(character) }
        }
        flush()
        guard let match = result.range(of: #"(\d+)(st|nd|rd|th)\b"#, options: [.regularExpression, .caseInsensitive]) else { return result }
        let number = Int(result[match].prefix { $0.isNumber }) ?? 0
        let ending = (11...13).contains(number % 100) ? "th" : ["th", "st", "nd", "rd", "th", "th", "th", "th", "th", "th"][number % 10]
        let old = result[match].drop { $0.isNumber }
        return result.replacingCharacters(in: match, with: String(number) + (old.first?.isUppercase == true ? ending.uppercased() : ending))
    }

    /// The country of an address Scrub has no full places for: from its
    /// country ("IT", "ITA", "Italy"), else its city or region; nil where it
    /// is one of the four countries `Places` covers, or unknown.
    static func abroadCountry(_ parts: AddressParts) -> String? {
        let placedCountries: Set<String> = ["US", "CA", "GB", "AU"]
        if let written = parts.country, let code = Places.code(written) { return placedCountries.contains(code) || !Places.abroad.contains { $0.country == code } ? nil : code }
        if let city = parts.city, let code = AddressBlock.knownCountry(city: city.trimmingCharacters(in: .whitespaces)), !placedCountries.contains(code) { return code }
        if let region = parts.region, let code = Places.regionAbroad(region) { return code }
        return nil
    }
    /// A city, region or postcode written as the original is, from one city abroad.
    private func abroadPart(_ entity: String, _ original: String, _ city: Places.Abroad) -> String {
        let key = "ABROAD\u{0}" + entity + "\u{0}" + city.city + "\u{0}" + original
        if let known = assigned[key] { return known }
        let trimmed = original.trimmingCharacters(in: .whitespaces)
        let fake: String
        switch entity {
        case "LOCATION": fake = trimmed == trimmed.uppercased() ? city.city.uppercased() : trimmed == trimmed.lowercased() ? city.city.lowercased() : city.city
        case "POSTAL_CODE": fake = city.postal(like: trimmed, digit: { self.digit() }, letter: { self.pick(Array("ACDEFHKNPRTVWXY")) ?? "A" })
        default:
            // A province's code takes the city's ("NA" → "TO"); a name it has none for stays.
            guard let region = city.region, (trimmed.count <= 3) == (region.count <= 3) else { fake = original; break }
            fake = trimmed == trimmed.lowercased() ? region.lowercased() : region
        }
        assigned[key] = fake
        return fake
    }

    /// A locality piece with its postcode, city and region rewritten where they stand.
    private func locality(_ piece: String, _ parts: AddressBlock.Locality, place: Place?, abroad: Places.Abroad?) -> String {
        var result = piece
        func swap(_ old: String?, _ new: String?) {
            guard let old, let new, let range = result.range(of: old) else { return }
            result.replaceSubrange(range, with: new)
        }
        if let place {
            swap(parts.postal, parts.postal.map { postal(of: place, like: $0, bare: false) != nil ? placedPostal(place, $0, bare: false) : anyPostal(of: place, like: $0) })
            swap(parts.region, parts.region.map { Places.write(place, like: $0) })
            swap(parts.city, parts.city.map { city(of: place, like: $0) })
        } else if let abroad {
            swap(parts.postal, parts.postal.map { postal in
                abroad.postal(like: postal, digit: { self.digit() }, letter: { self.pick(Array("ACDEFHKNPRTVWXY")) ?? "A" })
            })
            swap(parts.region, parts.region.map { abroad.region ?? $0 })
            swap(parts.city, parts.city.map { $0 == $0.uppercased() ? abroad.city.uppercased() : abroad.city })
        } else {
            swap(parts.postal, parts.postal.map { idLike($0) })
            swap(parts.city, parts.city.map { city in
                let fake = pick(Names.cities.filter { !originals.contains($0.lowercased()) }) ?? "Austin"
                return city == city.uppercased() ? fake.uppercased() : fake
            })
        }
        return result
    }

    /// A postcode of the place in its own country's layout, for an original
    /// no code of the place shares a shape with ("CF10 1EP" when the place has only "LS6").
    private func anyPostal(of place: Place, like original: String) -> String {
        let code = pick(place.postal) ?? ""
        let spaced = original.contains(" ")
        switch place.country {
        case "GB": return code + (spaced ? " " : "") + digit() + String(pick(Array("ABDEFGHJLNPQRSTUWXYZ")) ?? "A") + String(pick(Array("ABDEFGHJLNPQRSTUWXYZ")) ?? "B")
        case "CA": return code + (spaced ? " " : "") + digit() + String(pick(Array("ABCEGHJKLMNPRSTVWXYZ")) ?? "A") + digit()
        default: return code
        }
    }

    /// One city per original locality, of the same country.
    private var abroadCities: [String: Places.Abroad] = [:]
    /// A postcode written as a bare number ("postcode": 40126) gains no leading zero, or pasted
    /// JSON stops parsing: its city is one whose postcodes have none.
    private func abroadCity(country: String, original: String, besides: [String] = [], bare: Bool = false) -> Places.Abroad? {
        let key = country + "\u{0}" + original.lowercased()
        if let known = abroadCities[key] { return known }
        let taken = Set(abroadCities.values.map(\.city))
        // Not the same city under another district: "København N" never becomes "København K", nor "Dublin 24" "Dublin".
        let stems = ([original] + besides).map { $0.lowercased().split(separator: " ").first.map(String.init) ?? $0.lowercased() }
        let candidates = Places.abroad.filter { place in
            place.country == country && (!bare || place.postal.first != "0") && !originals.contains(place.city.lowercased()) && !original.lowercased().hasPrefix(place.city.lowercased())
                && !stems.contains { place.city.lowercased().hasPrefix($0) }
        }
        // A city that is its country ("Singapore") stays itself; its postcode still changes.
        let own = Places.abroad.first { $0.country == country && original.lowercased().hasPrefix($0.city.lowercased()) && Places.abroad.filter { $0.country == country }.count == 1 }
        guard let chosen = pick(candidates.filter { !taken.contains($0.city) }) ?? pick(candidates) ?? own else { return nil }
        abroadCities[key] = chosen
        return chosen
    }

    /// The words a stand-in street or district of a country is named with, or
    /// nil where English ones read right.
    private func names(for country: String?) -> [String] {
        let pool = country.flatMap { Places.streetWords[$0] } ?? Names.streets
        return pool.filter { !originals.contains($0.lowercased()) }
    }

    /// A street in a layout of its own country, "Lindenhofer Straße 48a" →
    /// "Ahorner Straße 12", "Calle de las Hiedras 27" → "Calle de las Rosales 61":
    /// its numbers keep their length, its kind of street and every lowercase
    /// word ("de la", "ul.", "m.") stay, and its capitalised name becomes another.
    private func foreignStreet(like original: String, country: String?) -> String {
        let key = "STREET\u{0}" + original.lowercased()
        if let known = assigned[key] { return known }
        let pool = names(for: country).filter { !original.lowercased().contains($0.lowercased()) }
        // "de l'Ardoise": the elided article stays, the name after it is the name.
        var words: [String] = []
        for word in original.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
            if let match = word.range(of: #"^\p{Ll}{1,2}['’](?=\p{Lu})"#, options: .regularExpression) {
                words.append(String(word[match])); words.append("\u{1}" + String(word[match.upperBound...]))
            } else { words.append(word) }
        }
        func bare(_ word: String) -> String { word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,\u{1}")) }
        func capital(_ word: String) -> Bool {
            let text = word.trimmingCharacters(in: CharacterSet(charactersIn: "\u{1}"))
            return text.first.map { $0.isLetter && $0.isUppercase } == true && !text.contains(where: \.isNumber) && !AddressBlock.streetKinds.contains(bare(text)) && !AddressBlock.englishKinds.contains(bare(text))
        }
        // Each name is a run of capitalised words with the small joining words inside it
        // ("Calçada do Mirante"); every run takes another name.
        var index = 0, used: [String] = []
        while index < words.count {
            guard capital(words[index]) else { index += 1; continue }
            var last = index, next = index + 1
            while next < words.count, !words[next].contains(where: \.isNumber), !AddressBlock.streetKinds.contains(bare(words[next])), !AddressBlock.englishKinds.contains(bare(words[next])) {
                if capital(words[next]) { last = next } else if words[next].first?.isLowercase != true { break }
                next += 1
            }
            // The same street's name becomes the same name wherever it is written: alone, or in a line with its number.
            let run = words[index...last].map(bare).joined(separator: " ")
            let name = streetRuns[run] ?? pick(pool.filter { !used.contains($0) }) ?? pick(pool) ?? "Linden"
            streetRuns[run] = name
            used.append(name)
            let ending = bare(words[last])
            var made = name
            if let suffix = AddressBlock.streetSuffixes.first(where: { ending.hasSuffix($0) && ending.count > $0.count + 2 }) {
                made += String(words[last].suffix(suffix.count))
            } else if last + 1 < words.count, ["straße", "strasse", "weg", "platz", "allee", "gasse", "ring", "damm"].contains(bare(words[last + 1])), ["DE", "AT", "CH"].contains(country ?? "") {
                // "Lindenhofer Straße" → "Ahornstraße".
                made += words[last + 1].lowercased()
                words.remove(at: last + 1)
            }
            let first = words[index].trimmingCharacters(in: CharacterSet(charactersIn: "\u{1}"))
            if first == first.uppercased() && first.count > 1 { made = made.uppercased() }
            words.replaceSubrange(index...last, with: [(words[index].hasPrefix("\u{1}") ? "\u{1}" : "") + made])
            index += 1
        }
        var fake = ""
        for word in words {
            let text = word.contains(where: \.isNumber) ? addressNumbered(word) : word
            if text.hasPrefix("\u{1}") { fake += String(text.dropFirst()) } else { fake += (fake.isEmpty || fake.hasSuffix("'") || fake.hasSuffix("’") && false ? "" : " ") + text }
        }
        fake = fake.hasPrefix(" ") ? String(fake.dropFirst()) : fake
        assigned[key] = fake
        return fake
    }

    /// A district, county, building or street name without a number: another
    /// of the same kind ("Corrib House" → "Maple House", "Wexley Lane" → "Cedar Lane").
    private func placeName(like original: String, country: String?) -> String {
        let key = "PLACE\u{0}" + original.lowercased()
        if let known = assigned[key] { return known }
        let trimmed = original.trimmingCharacters(in: .whitespaces)
        let words = trimmed.split(separator: " ").map(String.init)
        let name = pick(names(for: country).filter { !trimmed.lowercased().contains($0.lowercased()) }) ?? "Linden"
        let fake: String
        if let home = AddressBlock.knownCountry(city: trimmed), !["US", "CA", "GB", "AU"].contains(home), let city = abroadCity(country: home, original: trimmed) {
            // A city Scrub knows, on its own in an address with no postcode ("Via Garibaldi, Torino"): another of its country.
            fake = city.city
        } else if AddressBlock.isStreet(trimmed) {
            fake = foreignStreet(like: trimmed, country: country)
        } else if let last = words.last, words.count > 1, Self.buildingWords.contains(last.lowercased()) || Self.suffixes.contains(last.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            fake = (words.first?.lowercased() == "the" ? "The " : "") + name + " " + last
        } else if let first = words.first, words.count > 1, ["co.", "co", "county"].contains(first.lowercased()) {
            fake = first + " " + (pick(Self.counties.filter { !trimmed.contains($0) }) ?? "Clare")
        } else if let first = words.first, words.count > 1, first.hasSuffix("."), first.count <= 5 {
            fake = first + " " + name
        } else if words.first?.lowercased() == "the" {
            fake = "The " + name + " " + (pick(["House", "Lodge", "Cottage", "Barn"]) ?? "House")
        } else if Self.english(country) {
            fake = name + (pick(["field", "wood", "ford", "dale", "brook", "ton", "bury", "ley"]) ?? "field")
        } else {
            fake = name
        }
        let written = trimmed == trimmed.uppercased() && trimmed.count > 1 ? fake.uppercased() : fake
        assigned[key] = written
        return written
    }
    private static let buildingWords: Set<String> = ["house", "court", "lodge", "cottage", "mansions", "building", "point", "tower", "hall", "barn", "farm", "works", "mill", "place", "wharf",
                                                     "apartments", "residency", "towers", "enclave", "heights", "complex", "plaza", "centre", "center", "hub", "residences", "suites", "yard",
                                                     "forge", "granary", "rectory", "chambers", "studios", "park"]
    private static let counties = ["Clare", "Kerry", "Mayo", "Sligo", "Wexford", "Kildare", "Meath", "Offaly", "Laois", "Louth"]
    private static let suffixes: Set<String> = ["st", "street", "rd", "road", "ave", "av", "avenue", "blvd", "boulevard", "dr", "drive", "ln", "lane", "ct", "court", "way", "pl", "place", "pkwy", "parkway", "ter", "terrace", "cir", "circle", "hwy", "highway", "trl", "trail", "loop", "sq", "square",
                                                "close", "cl", "crescent", "cres", "gardens", "gdns", "grove", "gr", "mews", "rise", "row", "walk", "parade", "pde", "tce", "view", "green", "vale", "hill",
                                                "fields", "meadows", "gate", "end", "chase", "wharf", "esplanade", "esp", "circuit", "cct", "quay", "yard", "path", "pike", "run", "alley", "bvd"]
    /// A street written as the original is: its house number's length and its
    /// kind of street, "4821 Juniper Hollow Rd" → "3907 Maple Rd". The same
    /// street gets the same stand-in, on its own line or in a full address.
    private func street(like original: String) -> String {
        let key = "STREET\u{0}" + original.lowercased()
        if let known = assigned[key] { return known }
        // A unit before the house number stays one: "1406 - 2280 Kessler Crescent", "4/12 Smith St".
        if let match = original.range(of: #"^\d+[A-Za-z]?\s*[-/]\s*(?=\d)"#, options: .regularExpression) {
            let fake = addressNumbered(String(original[match])) + street(like: String(original[match.upperBound...]))
            assigned[key] = fake
            return fake
        }
        let words = original.split(separator: " ")
        // "5th Cross Road" → "7th Maple Road".
        if let first = words.first, first.range(of: #"^\d+(?:st|nd|rd|th)$"#, options: .regularExpression) != nil, words.count > 1 {
            let kind = Self.suffixes.contains(words.last!.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) ? String(words.last!) : "Street"
            let name = pick(Names.streets.filter { !originals.contains($0.lowercased()) && !original.lowercased().contains($0.lowercased()) }) ?? "Main"
            let fake = renumbered(String(first)) + " " + name + " " + kind
            assigned[key] = fake
            return fake
        }
        let numbered = words.first.map { $0.allSatisfy(\.isNumber) } ?? false
        let number = numbered ? words.first!.count : 0
        let last = words.count > 1 ? words.last.map(String.init) : nil
        let kind = last.flatMap { Self.suffixes.contains($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) ? $0 : nil } ?? "Street"
        // No street named after someone in the document ("Valley Street" for a Ms. Valley);
        // the same street's name always the same stand-in, as `foreignStreet` names it alone.
        let run = words.dropFirst(numbered ? 1 : 0).dropLast(kind == last ? 1 : 0).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,")) }.joined(separator: " ")
        let name = streetRuns[run] ?? pick(Names.streets.filter { !originals.contains($0.lowercased()) && !original.lowercased().contains($0.lowercased()) }) ?? "Main"
        if !run.isEmpty { streetRuns[run] = name }
        let shouted = original == original.uppercased() && original.contains(where: \.isLetter)
        func written(_ number: String) -> String { let made = "\(number) \(name) \(kind)"; return shouted ? made.uppercased() : made }
        var fake = written(numbered ? addressNumber(String(words.first!)) : digits(3))
        for _ in 0..<8 where !unused(fake, original) { fake = written(digits(number > 0 ? min(number, 5) : 3)) }
        assigned[key] = fake
        return fake
    }
    /// A number in the original's own layout: a real area code (the address's,
    /// when there is one) and a line from the fictional 555-0100 to 0199 range.
    /// A number from outside North America keeps its country code.
    private func phone(_ original: String, _ place: Place?) -> String {
        let digits = original.filter { $0.isASCII && $0.isNumber }
        let plus = original.trimmingCharacters(in: .whitespaces).hasPrefix("+")
        let trunk = digits.count == 11 && digits.first == "1"
        let fresh: String
        if digits.count == 10 && digits.first != "0" && digits.first != "1" && !plus || trunk {
            let area = place.flatMap { ["US", "CA"].contains($0.country) ? $0.areaCode : nil } ?? pick(Places.all.filter { $0.country == "US" }.map(\.areaCode)) ?? "303"
            fresh = (trunk ? "1" : "") + area + "5550" + "1" + String(format: "%02d", Int.random(in: 0...99, using: &rng))
        } else if plus, let code = original.split(whereSeparator: { !$0.isNumber && $0 != "+" }).first, code.count >= 2 {
            let country = code.dropFirst()
            fresh = country + (country.count..<digits.count).map { index in index == country.count ? digit(true) : digit() }.joined()
        } else if digits.count >= 7 {
            fresh = self.digits(digits.count)
        } else if digits.count >= 4, !plus {
            // An extension ("x41872", "ext. 5-3310") stays one, in its own layout.
            fresh = self.digits(digits.count)
        } else {
            return "+1 \(pick(Places.all.filter { $0.country == "US" }.map(\.areaCode)) ?? "303")-555-01\(String(format: "%02d", Int.random(in: 0...99, using: &rng)))"
        }
        var iterator = fresh.makeIterator()
        return String(original.map { $0.isASCII && $0.isNumber ? iterator.next() ?? $0 : $0 })
    }
    /// A phone number's digits, the same however the number is written ("2128675309", "2128675309.0").
    private func phoneDigits(_ digits: String, _ place: Place?) -> String {
        let key = "PHONE_DIGITS\u{0}" + digits + "\u{0}" + (place.map { $0.city + $0.region } ?? "")
        if let known = assigned[key] { return known }
        var fake = phone(digits, place)
        for _ in 0..<8 where fake == digits || originals.contains(fake) { fake = phone(digits, place) }
        assigned[key] = fake
        return fake
    }
    /// A point near the place's centre, to the original's precision.
    private func coordinate(_ original: String, of place: Place, latitude: Bool) -> String {
        let text = original.trimmingCharacters(in: .whitespaces)
        let decimals = text.firstIndex(of: ".").map { text.distance(from: $0, to: text.endIndex) - 1 } ?? 4
        let value = (latitude ? place.latitude : place.longitude) + Double.random(in: -0.03...0.03, using: &rng)
        return String(format: "%.\(max(1, min(decimals, 8)))f", value)
    }
    /// A coordinate's whole degrees with its decimals drawn afresh, as many as it had: about as near as a city is.
    private func jittered(_ original: String) -> String {
        guard let point = original.firstIndex(of: "."), original[original.index(after: point)...].allSatisfy(\.isNumber) else { return original }
        let decimals = original.distance(from: point, to: original.endIndex) - 1
        var made = original
        for _ in 0..<8 where made == original { made = String(original[...point]) + (0..<decimals).map { _ in digit() }.joined() }
        return made
    }
    /// A second address line stays one: "Apt 2B" → "Apt 7C", "Suite 400" → "Suite 213", "#12" → "#48".
    private func unit(_ original: String) -> String? {
        let key = "UNIT\u{0}" + original.lowercased()
        if let known = assigned[key] { return known }
        // Shared by every mention, so drawn clear of all real values up front.
        var made = freshUnit(original)
        for _ in 0..<16 { guard let current = made, !unused(current, original) else { break }; made = freshUnit(original) }
        if let made { assigned[key] = made }
        return made
    }
    private func freshUnit(_ original: String) -> String? {
        let trimmed = original.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#"), trimmed.count <= 6 { return "#" + idLike(String(trimmed.dropFirst())) }
        let words = trimmed.split(whereSeparator: { $0 == " " || $0 == "." })
        // "Apt 2B", "Suite B", "Flat 3"; not "Top Floor", whose last word is no number.
        if let first = words.first, Self.units.contains(first.lowercased()), words.count <= 3, trimmed.contains(where: \.isNumber) || words.count == 1 || words.last!.count <= 2 {
            let number = words.count > 1 ? idLike(String(words.last!)) : digits(2)
            return String(trimmed.prefix(trimmed.count - (words.count > 1 ? words.last!.count : 0))) + (words.count > 1 ? number : " " + number)
        }
        if Self.boxes.contains(where: trimmed.lowercased().hasPrefix) {
            // The box's own number, not the postcode after it ("PO Box 4324, Halifax NS B3J 2K9");
            // all of it where it is written in groups ("Postfach 12 03 44").
            guard let number = trimmed.range(of: #"\d[\d ]*\d|\d"#, options: .regularExpression) else { return nil }
            let lead = trimmed[number].first.map { $0 != "0" } ?? true
            return trimmed.replacingCharacters(in: number, with: String(trimmed[number].enumerated().map { index, char in char.isNumber ? Character(digit(index == 0 && lead)) : char }))
        }
        return nil
    }
    /// The same shape with fresh characters: "2B" → "7C", "400" → "213".
    private func idLike(_ original: String) -> String {
        let lead = original.firstIndex(where: \.isNumber)
        return String(original.indices.map { index in
            let char = original[index]
            if char.isNumber { return Character(digit(index == lead && char != "0")) }
            if char.isLowercase { return pick(Array("abcdefghijklmnopqrstuvwxyz")) ?? "a" }
            if char.isUppercase { return pick(Array("ABCDEFGHJKLMNPRSTUVWXYZ")) ?? "A" }
            return char
        })
    }
    func number(_ original: String) -> String {
        let key = "ID_NUMBER\u{0}" + original
        if let found = assigned[key] { return found }
        let identity = identifier(original)
        // A number can't start with a zero its original didn't.
        let lead: (String) -> Bool = { original.first == "0" || $0.first != "0" }
        var fake = original
        if let identity, let written = reused(identity, original) { fake = written }
        if fake == original {
            for _ in 0..<16 {
                guard let made = identifierStandIn(original) else { break }
                if lead(made) { fake = made; break }
            }
        }
        var attempts = 0
        while fake == original || !lead(fake) || attempts < 16 && originals.contains(fake) { fake = digits(original.count); attempts += 1 }
        assigned[key] = fake
        if let identity, identity.recognizer.passes(fake), assigned[identity.key] == nil { assigned[identity.key] = String(identity.recognizer.kept(fake)) }
        return fake
    }
    /// A fresh identifier of `original`'s kind whose last four digits can be written as a
    /// number where its original's are ("last4": 4725): no zero leads them.
    private func identifierStandIn(_ original: String) -> String? {
        let real = original.filter { $0.isASCII && $0.isNumber }
        let bare = real.count >= 7 && bareEndings.contains(String(real.suffix(4)))
        var made: String?
        for _ in 0..<16 {
            made = Recognizers.standIn(for: original, preferring: identifier(original)?.recognizer, using: &rng)
            guard bare, let drawn = made, drawn.filter({ $0.isASCII && $0.isNumber }).dropLast(3).last == "0" else { break }
        }
        return made
    }
    /// Another number's stand-in digits poured into an identifier, where they still make one of its
    /// kind: "S1234567D" and "T1234567J" share digits, not a check letter. Digits alone sharing
    /// digits ("536-21-7784", 536217784) are one number written two ways, whatever kind they pass by chance.
    private func checked(_ poured: String, _ identity: (recognizer: Recognizer, key: String)?) -> String? {
        guard let recognizer = identity?.recognizer, poured.contains(where: \.isLetter) else { return poured }
        return recognizer.passes(poured) && recognizer.writes(poured.trimmingCharacters(in: .whitespaces)) ? poured : nil
    }
    /// The stand-in the same identifier took written another way, in this one's layout.
    private func reused(_ identity: (recognizer: Recognizer, key: String), _ original: String) -> String? {
        guard let found = assigned[identity.key], found.count == identity.recognizer.kept(original.trimmingCharacters(in: .whitespaces)).count else { return nil }
        return Recognizers.write(Array(found), like: original, identity.recognizer)
    }
    /// The kind an identifier is and its characters without separators, the same however it is written.
    private func identifier(_ original: String) -> (recognizer: Recognizer, key: String)? {
        // Of the kinds whose checks it passes, the one the words around it name ("routing_number": a bank's, not a tax file's).
        let kinds = Recognizers.candidates(original).filter { Recognizers.drawn.contains($0.entity) }
        guard let recognizer = kinds.first(where: { Recognizers.named($0.context, among: naming) || $0.keys.contains(naming.sorted().joined()) }) ?? kinds.first else { return nil }
        // By its characters alone: "23332969-K" may pass two kinds' checks where "23332969K" passes one.
        return (recognizer, "IDENTIFIER\u{0}" + String(recognizer.kept(original.trimmingCharacters(in: .whitespaces))))
    }
    func numericLexeme(_ original: String, entity: String, address: AddressParts? = nil) -> String {
        let key = entity + "\u{0}" + original
        let digits = original.filter { $0.isASCII && $0.isNumber }
        // A postcode abroad written as a number takes its stand-in city's, as its city and province do.
        if entity == "POSTAL_CODE", digits == original, let address, let country = Self.abroadCountry(address),
           let city = abroadCity(country: country, original: address.city ?? address.postal ?? original, bare: original.first != "0") {
            return abroadPart(entity, original, city)
        }
        // A ZIP code written as a number takes its place's code like any other.
        if entity == "POSTAL_CODE", digits == original, let address, let place = place(for: address) {
            let placed = key + "\u{0}" + place.city + "\u{0}" + place.region
            if let existing = assigned[placed] { return existing }
            if postal(of: place, like: original) != nil, case let fake = placedPostal(place, original), fake != original {
                assigned[placed] = fake
                if assigned[key] == nil { assigned[key] = fake }
                return fake
            }
        }
        defer { if let made = assigned[key] { noteSource(entity, original, made) } }
        if entity == "AGE" { return age(original) }
        if entity == "LAST_DIGITS" {
            bareEndings.insert(digits)
            let fake = lastDigits(original)
            // Still a number: a zero can't lead it.
            return fake.first == "0" ? digit(true) + fake.dropFirst() : fake
        }
        if entity == "LATITUDE" || entity == "LONGITUDE" { return replace(entity, original, address: address) }
        // A house or unit number written as a bare number: the number the street line beside it takes.
        if entity == "ADDRESS", digits == original { return addressNumber(digits) }
        // A birth date's month or day follows the date of its own record, never another's "3".
        if digits == original, entity == "DATE_OF_BIRTH", digits.count <= 2, let part = birthPart(original) { return part }
        if let existing = assigned[key] { return existing }
        // A birth date split into numbers ("year": 1987, "month": 4) keeps each part plausible.
        if digits == original, entity == "DATE_OF_BIRTH", let value = Int(digits), digits.count <= 4 {
            let fake = digits.count == 4 ? String(year(for: value)) : String(follow("lone", value, Int.random(in: 1...(value <= 12 ? 12 : 28), using: &rng)))
            assigned[key] = fake
            return fake
        }
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
        let whole = original[..<significant].filter { $0.isASCII && $0.isNumber }
        // A phone number keeps a real area code and a fictional 555-01xx line.
        let shared = digitKey(entity, whole).flatMap { assigned[$0] }.flatMap { pour($0, into: whole) }.flatMap { checked($0, identifier(whole)) }
        let drawn = shared ?? (entity == "PHONE_NUMBER" && [10, 11].contains(whole.count) ? phoneDigits(whole, address.flatMap { $0.isEmpty ? nil : place(for: $0) }) : number(whole))
        var iterator = drawn.makeIterator()
        let fake = String(original[..<significant].map { character in
            character.isASCII && character.isNumber ? iterator.next() ?? character : character
        }) + original[significant...]
        let kept = barelyEnding(entity, original, fake)
        if let digitKey = digitKey(entity, whole), assigned[digitKey] == nil { assigned[digitKey] = normalized(entity, kept) }
        assigned[key] = kept
        return kept
    }
    /// A post office box keeps its kind and the length of its number.
    private static let boxes = ["po box", "p.o. box", "p.o.box", "p o box", "post office box", "postfach", "apartado", "private bag", "gpo box", "locked bag", "postbus", "postboks",
                                "bp ", "b.p. ", "cs ", "casella postale", "caixa postal", "box ", "c.p. ", "cp "]
    private static let units: Set<String> = ["apt", "apartment", "suite", "ste", "unit", "floor", "fl", "room", "rm", "bldg", "building", "#", "flat", "level", "lvl", "shop", "lot",
                                             "pmb", "blk", "block", "top", "wohnung", "appt", "apto", "piso", "bureau", "sala", "bloco", "depto", "int", "escalier", "bâtiment", "plot"]
    private static let digitsOnly: Set<String> = ["PHONE_NUMBER", "US_SSN", "ID_NUMBER", "POSTAL_CODE", "US_BANK_NUMBER", "US_PASSPORT", "US_DRIVER_LICENSE", "US_ITIN", "MEDICAL_LICENSE"]
    private func make(_ entity: String, _ original: String, _ persona: Persona?, _ place: Place? = nil) -> String {
        // An identifier the registry knows takes a fresh one passing the same check, as a form validating it would ask.
        if Recognizers.drawn.contains(entity), let made = identifierStandIn(original) { return made }
        // An address typed all in lowercase is read and rewritten as if cased, and lowercased again.
        if entity == "ADDRESS", let cased = AddressBlock.cased(original) { return make(entity, cased, persona, place).lowercased() }
        if let masked = ["US_SSN", "CREDIT_CARD", "PHONE_NUMBER", "US_BANK_NUMBER", "ID_NUMBER", "LAST_DIGITS"].contains(entity) ? masked(original) : nil { return masked }
        if entity == "LAST_DIGITS" { return lastDigits(original) }
        if entity == "PHONE_NUMBER" { return phone(original, place) }
        if let place {
            switch entity {
            case "TIME_ZONE": return place.timeZone
            case "LATITUDE", "LONGITUDE": return coordinate(original, of: place, latitude: entity == "LATITUDE")
            case "COORDINATES":
                let pair = original.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard pair.count == 2 else { break }
                // Longitude first when the first number could not be a latitude.
                let longitudeFirst = abs(Double(pair[0].trimmingCharacters(in: .whitespaces)) ?? 0) > 90
                let lead = String(pair[1].prefix { $0 == " " })
                return coordinate(pair[0], of: place, latitude: !longitudeFirst) + "," + lead + coordinate(pair[1].trimmingCharacters(in: .whitespaces), of: place, latitude: longitudeFirst)
            case "LOCATION":
                if let parsed = AddressParts.line(original) { return line(original, parsed, place) }
                return city(of: place, like: original)
            case "REGION": return Places.write(place, like: original)
            case "POSTAL_CODE": if postal(of: place, like: original) != nil { return placedPostal(place, original) }
            case "ADDRESS": if let parsed = AddressParts.line(original) { return line(original, parsed, place) }
            default: break
            }
        }
        // A number stays a number of the same length, so a JSON body pasted as
        // text still parses and a column of IDs keeps its width.
        if Self.digitsOnly.contains(entity), !original.isEmpty, original.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return original.first == "0" ? (0..<original.count).map { _ in digit() }.joined() : digits(original.count)
        }
        switch entity {
        // A point with no place to come from (an address abroad): the same degrees, the rest drawn afresh.
        case "LATITUDE", "LONGITUDE": return jittered(original)
        case "COORDINATES":
            let pair = original.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard pair.count == 2 else { return original }
            return jittered(pair[0]) + "," + String(pair[1].prefix { $0 == " " }) + jittered(pair[1].trimmingCharacters(in: .whitespaces))
        case "PERSON":
            if persona == nil, !original.contains(" "), let separator = original.first(where: { $0 == "." || $0 == "_" }) {
                let parts = original.split(separator: separator)
                if parts.count == 2 {
                    let person = people.registerFull(parts.joined(separator: " ")).0
                    owner = person
                    let handle = person.first + String(separator) + person.last
                    return original == original.lowercased() ? handle.lowercased() : handle
                }
            }
            if let persona {
                owner = persona
                return persona.full
            }
            let name = people.name(for: original)
            owner = people.lastNamed
            return name
        case "FIRST_NAME":
            let person = persona ?? people.register(original, nil)
            owner = person
            return person.first
        case "LAST_NAME":
            let person = persona ?? people.register(nil, original)
            owner = person
            return person.last
        case "EMAIL_ADDRESS":
            if let owner = persona ?? people.find(email: original), original.contains("@") {
                self.owner = owner
                return people.email(for: owner, original: original)
            }
            if let local = handleKey(String(original.prefix { $0 != "@" })), let handle = handles[local], original.contains("@") {
                return handle.lowercased() + "@" + (pick(Names.emailDomains) ?? "example.com")
            }
            return "\(people.unrelatedName(first: true).lowercased()).\(people.unrelatedName(first: false).lowercased())@\(pick(Names.emailDomains) ?? "example.com")"
        case "LOCATION": return pick(Names.cities.filter { !originals.contains($0.lowercased()) }) ?? "Austin"
        case "REGION": return pick(Places.regions.filter { $0.country == "US" && !originals.contains($0.code.lowercased()) && !originals.contains($0.name.lowercased()) }).map { original.count > 3 ? $0.name : $0.code } ?? "TX"
        case "ADDRESS":
            // "PO Box 7712, Halifax NS B3K 5M2" is a box and a locality, each rewritten.
            if let parsed = AddressBlock.read(original), parsed.pieces.count > 1 { return block(original, parsed) }
            if let unit = unit(original) { return unit }
            // A house or unit number on its own ("12", "4B", "12/2", "12 bis") takes the
            // number the same digits take in any street line beside it.
            if original.range(of: #"^\d{1,5}[A-Za-z]?(?:\s*[-/]\s*\d{1,5}[A-Za-z]?)?(?:\s?(?:bis|ter))?$"#, options: .regularExpression) != nil { return addressNumbered(original) }
            // A short code on its own ("B4") keeps its shape.
            if !original.contains(" "), original.count <= 6, original.contains(where: \.isNumber) { return idLike(original) }
            // A street's or a building's name with no number ("Via Garibaldi", "Hauptstraße",
            // "Kestrel House"): another of its kind, named as the same street is in any line beside it.
            if !original.contains(where: \.isNumber), !original.contains(","), original.split(separator: " ").count <= 6 {
                let country = streetAddress?.country.flatMap(Places.code) ?? AddressBlock.read(original)?.country
                if let last = original.split(separator: " ").last, original.split(separator: " ").count > 1, Self.buildingWords.contains(last.lowercased()) { return placeName(like: original, country: country) }
                return foreignStreet(like: original, country: country)
            }
            // A street with its number, in a country that writes streets its own way ("LINDENALLEE 190").
            if let country = streetAddress?.country.flatMap(Places.code), !Self.english(country), !original.contains(","), original.split(separator: " ").count <= 8 {
                return foreignStreet(like: original, country: country)
            }
            // A street written as another country writes one keeps its layout.
            if let parsed = AddressBlock.read(original), !Self.english(parsed.country) { return block(original, parsed) }
            return street(like: original)
        case "INITIALS":
            owner = persona
            let letters = persona.map { [$0.first.first, $0.last.first].compactMap { $0 } } ?? []
            let count = original.filter(\.isLetter).count
            var drawn = (count == letters.count ? letters : count == 3 && letters.count == 2 ? [letters[0], pick(Array("ABCDEFGHJKLMNPRSTW")) ?? "A", letters[1]] : (0..<count).map { _ in pick(Array("ABCDEFGHJKLMNPRSTW")) ?? "A" }).makeIterator()
            return String(original.map { $0.isLetter ? drawn.next() ?? $0 : $0 })
        case "DATE_OF_BIRTH": return dateLike(original)
        case "MRZ": return zone(original, persona: persona)
        case "EMPLOYER": return company(like: original)
        case "US_SSN":
            // In the original's grouping: "123-45-6789", "123 45 6789".
            let separator = original.first { !$0.isNumber } ?? "-"
            return "\(digits(3))\(separator)\(digits(2))\(separator)\(digits(4))"
        case "CREDIT_CARD": return card(like: original)
        case "IBAN_CODE":
            let body = "GB00BARC" + digits(14)
            for check in 0...98 {
                let candidate = "GB" + String(format: "%02d", check) + String(body.dropFirst(4))
                if Patterns.iban(candidate) { return candidate }
            }
            return "GB82WEST12345698765432"
        case "IP_ADDRESS":
            // A documentation address, never the one written nor one spelling it ("203.0.113.106" holds "203.0.113.10").
            var made = original
            for _ in 0..<16 where made.lowercased().contains(original.lowercased()) || original.lowercased().contains(made.lowercased()) {
                made = original.contains(":") ? "2001:db8::" + String(Int.random(in: 0x100...0xffff, using: &rng), radix: 16) : "203.0.113.\(Int.random(in: 1...254, using: &rng))"
            }
            return made
        case "US_BANK_NUMBER": return digits(10)
        case "US_DRIVER_LICENSE": return "A" + digits(7)
        case "US_PASSPORT": return digits(9)
        case "US_ITIN": return "9\(digits(2))-\(digits(2))-\(digits(4))"
        case "MEDICAL_LICENSE": return "AB" + digits(6)
        case "CRYPTO": return "bc1q" + (0..<38).map { _ in String(pick(Array("023456789acdefghjklmnpqrstuvwxyz")) ?? "a") }.joined()
        case "USERNAME":
            // "@odalysf" keeps its at sign.
            if original.hasPrefix("@"), original.count > 1 { return "@" + make(entity, String(original.dropFirst()), persona, place) }
            if let owner = persona ?? people.find(handle: original), let handle = people.handle(for: owner, original: original, digits: { self.digits($0) }) {
                self.owner = owner
                return handle
            }
            if let key = handleKey(original), let handle = handles[key] { return handle }
            return people.unrelatedName(first: true).lowercased() + digits(3)
        case "SECRET":
            // A CVV, PIN or one-time code stays a short number.
            if (1...8).contains(original.count), original.allSatisfy({ $0.isASCII && $0.isNumber }) { return (0..<original.count).map { _ in digit() }.joined() }
            let prefix = TextRanges.matches(Self.secretPrefix, in: original).first.map { TextRanges.substring(original, $0.range.location..<NSMaxRange($0.range)) } ?? ""
            let kept = prefix.utf16.count < original.utf16.count ? prefix : ""
            return kept + (0..<24).map { _ in String(pick(alphabet) ?? "a") }.joined()
        case "RECORD_ID": return recordID(like: original)
        case "ID_NUMBER", "POSTAL_CODE":
            let lead = original.firstIndex(where: \.isNumber)
            return String(original.indices.map { index in
                let char = original[index]
                if char.isNumber { return Character(digit(index == lead && char != "0")) }
                if char.isLowercase { return pick(Array("abcdefghijklmnopqrstuvwxyz")) ?? "a" }
                if char.isUppercase { return pick(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")) ?? "A" }
                return char
            })
        default: return "[\(entity)]"
        }
    }
    /// A person's record ID in its own shape: its type prefix kept ("cus_")
    /// unless the document names someone so ("pat_" beside Pat Ferriter),
    /// then a fresh character of the same kind for each: a digit for a digit
    /// (none leading with a zero that had none), a letter of the same case,
    /// hex for hex, and every joiner where it was. So "cus_odalys_ferriter"
    /// becomes "cus_" and 15 letters around one underscore, and joins still work.
    private func recordID(like original: String) -> String {
        let prefix = RecordIDs.keptPrefix(original, named: namedWords)
        let rest = original.dropFirst(prefix.count)
        let hex = rest.allSatisfy { $0.isHexDigit || $0 == "-" } && rest.contains(where: \.isNumber) && rest.contains(where: \.isLetter)
        let lead = rest.firstIndex(where: { $0.isLetter || $0.isNumber })
        return prefix + String(rest.indices.map { index -> Character in
            let character = rest[index]
            if character.isNumber { return Character(digit(index == lead && character != "0")) }
            if hex && character.isLetter { return (character.isUppercase ? Array("ABCDEF") : Array("abcdef")).randomElement(using: &rng) ?? "a" }
            if character.isLowercase { return pick(Array("abcdefghijklmnopqrstuvwxyz")) ?? "a" }
            if character.isUppercase { return pick(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")) ?? "A" }
            return character
        })
    }
    /// Invented companies: a stand-in employer names no real one.
    private static let companyHeads = ["Corvane", "Tallowmere", "Quillfen", "Marrowby", "Pellingham", "Ostrevan", "Wexmoor", "Halvercroft", "Dunmarrow", "Fenwyck",
                                       "Lowmarch", "Carrowind", "Elsinby", "Thornquist", "Varrowden", "Kestrelby", "Ambermoor", "Glimmerton", "Sorrelby", "Ravenmoss"]
    private static let companyKinds = ["Logistics", "Health", "Partners", "Systems", "Foods", "Supply", "Studio", "Clinic", "Group", "Services", "Consulting",
                                       "Works", "Labs", "Trading", "Dental", "Freight", "Academy", "Care", "Insurance", "Engineering"]
    private static let legalForms: Set<String> = ["inc", "inc.", "ltd", "ltd.", "llc", "plc", "gmbh", "co.", "corp", "corp.", "s.a.", "bv", "ag", "llp", "pty"]
    /// An invented company in the original's case, keeping its legal form ("Ltd", "GmbH").
    private func company(like original: String) -> String {
        let trimmed = original.trimmingCharacters(in: .whitespaces)
        let legal = trimmed.split(separator: " ").last.map(String.init).flatMap { Self.legalForms.contains($0.lowercased()) && trimmed.contains(" ") ? $0 : nil }
        let name = [pick(Self.companyHeads) ?? "Corvane", pick(Self.companyKinds) ?? "Group", legal].compactMap { $0 }.joined(separator: " ")
        return trimmed == trimmed.uppercased() && trimmed != trimmed.lowercased() ? name.uppercased() : name
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
    /// A date in the original's own format: its order, separators, padding and
    /// month names ("1987-04-12", "04/12/1987", "April 12, 1987", "12 APR 1987").
    /// The same birth year always moves to the same stand-in year, so a
    /// "birth_year" or "age" beside the date still agrees with it.
    private func dateLike(_ original: String) -> String {
        var year = Int.random(in: 1940...1999, using: &rng)
        var month = Int.random(in: 1...12, using: &rng)
        var day = Int.random(in: 1...28, using: &rng)
        // A day already written another way keeps its stand-in day.
        if let real = Self.dateParts(original), let realMonth = real.month, let realDay = real.day {
            if let known = days[Day(year: real.year, month: realMonth, day: realDay)] {
                (month, day) = (known.month, known.day)
            } else {
                // Nor its real month or day: a "birth_month" or "birth_day" read off it would write that back.
                for _ in 0..<8 where month == realMonth { month = Int.random(in: 1...12, using: &rng) }
                for _ in 0..<8 where day == realDay { day = Int.random(in: 1...28, using: &rng) }
            }
        }
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = trimmed.count == 8 && trimmed.allSatisfy({ $0.isASCII && $0.isNumber })
        if compact, let head = Int(trimmed.prefix(4)), let tail = Int(trimmed.suffix(4)) {
            let yearFirst = (1900...2030).contains(head)
            year = self.year(for: yearFirst ? head : tail)
            return yearFirst ? String(format: "%04d%02d%02d", year, month, day) : String(format: "%02d%02d%04d", month, day, year)
        }
        if trimmed.count == 4, let real = Int(trimmed), trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) { return String(self.year(for: real)) }
        if (1...2).contains(trimmed.count), let part = Int(trimmed) { return String(part <= 12 ? month : day) }
        // Runs of digits, of letters and of anything else, rewritten one by one.
        var runs: [String] = []
        for character in original {
            let kind = character.isNumber ? 0 : character.isLetter ? 1 : 2
            if let last = runs.last?.last, (last.isNumber ? 0 : last.isLetter ? 1 : 2) == kind { runs[runs.count - 1].append(character) }
            else { runs.append(String(character)) }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let full = formatter.monthSymbols.map { $0.lowercased() }, short = formatter.shortMonthSymbols.map { $0.lowercased() }
        let numbers = runs.indices.filter { runs[$0].first?.isNumber == true }
        let named = runs.indices.first { index in
            let word = runs[index].lowercased()
            return full.contains(word) || short.contains(word) || word == "sept"
        }
        func padded(_ value: Int, like run: String) -> String { run.count >= 2 ? String(format: "%0*d", run.count, value) : String(value) }
        func monthWord(like word: String) -> String {
            let name = word.count > 3 && word.lowercased() != "sept" ? formatter.monthSymbols[month - 1] : formatter.shortMonthSymbols[month - 1]
            return word == word.uppercased() ? name.uppercased() : word == word.lowercased() ? name.lowercased() : name
        }
        // A month with only its year or only its day: "October 1958", "March 3".
        if let named, numbers.count == 1 {
            var output = runs
            let only = numbers[0]
            if runs[only].count == 4, let real = Int(runs[only]) { output[only] = String(self.year(for: real)) }
            else { output[only] = padded(day, like: runs[only]) }
            output[named] = monthWord(like: runs[named])
            return output.joined()
        }
        guard let yearIndex = numbers.first(where: { runs[$0].count == 4 }), numbers.count == (named == nil ? 3 : 2) else {
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        let rest = numbers.filter { $0 != yearIndex }
        var output = runs
        if let real = Int(runs[yearIndex]) { year = self.year(for: real) }
        output[yearIndex] = String(year)
        if let named {
            output[named] = monthWord(like: runs[named])
            output[rest[0]] = padded(day, like: runs[rest[0]])
        } else if yearIndex < rest[0] {
            output[rest[0]] = padded(month, like: runs[rest[0]])
            output[rest[1]] = padded(day, like: runs[rest[1]])
        } else {
            let (a, b) = (Int(runs[rest[0]]) ?? 0, Int(runs[rest[1]]) ?? 0)
            let dayFirst = a > 12
            // "11/07/1984" reads either way, so its stand-in must too.
            let day = a <= 12 && b <= 12 ? Int.random(in: 1...12, using: &rng) : day
            output[rest[0]] = padded(dayFirst ? day : month, like: runs[rest[0]])
            output[rest[1]] = padded(dayFirst ? month : day, like: runs[rest[1]])
        }
        return output.joined()
    }

}

// MARK: Machine-readable zones

extension StandIns {
    /// Notes the stand-in a birth date's month or day written alone took
    /// ("month", "day", or "lone" where nothing says which), so a zone's birth
    /// date elsewhere can write the same; returns it.
    fileprivate func follow(_ part: String, _ real: Int, _ fake: Int) -> Int {
        if follows[part]?[real] == nil { follows[part, default: [:]][real] = fake }
        if let record = currentRecord { ownFollows[record + "\u{0}" + part, default: [:]][real] = fake }
        return fake
    }

    /// A machine-readable zone rewritten for its stand-in holder: the names
    /// are the person's stand-in name, the document and optional numbers take
    /// the stand-ins the same numbers take elsewhere, the birth date the
    /// stand-in date of the parts written beside it, and every check digit
    /// is computed again. The issuer, nationality, sex and expiry stay.
    func zone(_ original: String, persona: Persona?) -> String {
        let (lines, separators) = MachineZone.split(original)
        guard let layout = MachineZone.layout(lines) else { return idLike(original) }
        var out = lines.map(Array.init)
        var firstCard: [Character]?
        for index in lines.indices {
            var c = out[index]
            switch layout[index] {
            case .names(var from):
                // A line written without its issuer's code ("P<OKAFOR<<AMA") names from the third character.
                if from == 5, let real = persona?.realLast.map(MachineZone.fold), real.count >= 3, lines[index].dropFirst(2).hasPrefix(real), !lines[index].dropFirst(5).hasPrefix(real) { from = 2 }
                let written = MachineZone.names(lines[index].dropFirst(from))
                func cased(_ word: String) -> String { word.lowercased().capitalized }
                guard !written.last.isEmpty else { break }
                let person = persona ?? people.register(written.given.first.map(cased), cased(written.last))
                let field = MachineZone.fold(person.last) + (written.given.isEmpty ? "" : "<<" + MachineZone.fold(person.first))
                c = Array(lines[index].prefix(from)) + Array(MachineZone.fit(field, lines[index].count - from))
            case .data:
                c.replaceSubrange(0..<9, with: zoneNumber(c[0..<9]))
                c.replaceSubrange(13..<19, with: zoneDate(c[13..<19]))
                let optional = c.count == 44 ? 28..<42 : 28..<35
                c.replaceSubrange(optional, with: zoneNumber(c[optional]))
                c = MachineZone.rechecked(c, kind: .data)
            case .cardFirst:
                c.replaceSubrange(5..<14, with: zoneNumber(c[5..<14]))
                c.replaceSubrange(15..<30, with: zoneNumber(c[15..<30]))
                c = MachineZone.rechecked(c, kind: .cardFirst)
                firstCard = c
                if lines.count == 1 { cardShifts.append((currentRecord, MachineZone.weighted(c[5..<30]) - MachineZone.weighted(Array(lines[index])[5..<30]))) }
            case .cardSecond:
                let before = c
                c.replaceSubrange(0..<6, with: zoneDate(c[0..<6]))
                c.replaceSubrange(18..<29, with: zoneNumber(c[18..<29]))
                c = MachineZone.rechecked(c, kind: .cardSecond, first: firstCard)
                // A card's lines stored apart ("mrz1", "mrz2"): the check over both is the
                // old one moved by what changed in each line, the first's as it was rewritten.
                if firstCard == nil {
                    // Its own record's first line: the innermost record around both, never a neighbour's card.
                    let record = currentRecord
                    let shift = cardShifts.firstIndex { $0.record == record }.map { cardShifts.remove(at: $0).shift } ?? 0
                    c[29] = MachineZone.moved(before[29], by: shift + MachineZone.cardSum(c) - MachineZone.cardSum(before))
                }
            }
            out[index] = c
        }
        var result = ""
        for index in out.indices { result += String(out[index]) + (index < separators.count ? separators[index] : "") }
        return result
    }
    /// A number field of a zone: the stand-in the same number takes as an ID
    /// anywhere else in the document, in capitals and filled to the width.
    private func zoneNumber(_ field: ArraySlice<Character>) -> [Character] {
        let text = String(field).replacingOccurrences(of: "<", with: "")
        guard !text.isEmpty else { return Array(field) }
        var fake = String(drawn("ID_NUMBER", text, persona: nil, address: nil).uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
        if fake.isEmpty || fake == text { fake = idLike(text) }
        return Array(MachineZone.fit(fake, field.count))
    }
    /// A zone's birth date (YYMMDD): the stand-in year of the same birth year,
    /// and the month and day the same date's parts took beside it.
    private func zoneDate(_ field: ArraySlice<Character>) -> [Character] {
        let text = String(field)
        guard text.count == 6, let yy = Int(text.prefix(2)), let mm = Int(text.dropFirst(2).prefix(2)), let dd = Int(text.suffix(2)), (1...12).contains(mm), (1...31).contains(dd) else { return Array(field) }
        let realYear = yy + (yy > now % 100 ? 1900 : 2000)
        let real = Day(year: realYear, month: mm, day: dd)
        let fake: Day
        // The holder's own parts, written beside the zone, before a date anyone else has.
        let ownMonth = scopes.lazy.filter { $0.first == "r" && !$0.contains("/") }.compactMap { self.ownFollows[$0 + "\u{0}month"]?[mm] }.first
        let ownDay = scopes.lazy.filter { $0.first == "r" && !$0.contains("/") }.compactMap { self.ownFollows[$0 + "\u{0}day"]?[dd] }.first
        if let ownMonth, let ownDay { fake = Day(year: year(for: realYear), month: ownMonth, day: ownDay) }
        else if let known = days[real] { fake = known } else {
            func other(_ value: Int, _ top: Int) -> Int {
                var made = value
                for _ in 0..<8 where made == value { made = Int.random(in: 1...top, using: &rng) }
                return made
            }
            // The innermost record around the zone that wrote this part: the holder's, not a neighbour's.
            func followed(_ part: String, _ value: Int) -> Int? {
                scopes.lazy.filter { $0.first == "r" && !$0.contains("/") }.compactMap { self.ownFollows[$0 + "\u{0}" + part]?[value] }.first ?? follows[part]?[value]
            }
            fake = Day(year: year(for: realYear), month: followed("month", mm) ?? followed("lone", mm) ?? other(mm, 12), day: followed("day", dd) ?? followed("lone", dd) ?? other(dd, 28))
            days[real] = fake
        }
        return Array(String(format: "%02d%02d%02d", fake.year % 100, fake.month, fake.day))
    }
}
