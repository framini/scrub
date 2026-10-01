import Foundation

final class StandIns {
    private static let secretPrefix = TextPattern(#"^(?:(?:sk|pk|rk)_(?:live|test)_|gh[pousr]_|github_pat_|AKIA|ASIA|xox[abposr]-|eyJ|-----BEGIN [A-Z ]*PRIVATE KEY-----)"#)
    let people: People
    private var assigned: [String: String] = [:]
    /// Every value found in the document: a stand-in never repeats one, or a
    /// fake date could put another person's real birth date back.
    private var originals: Set<String> = []
    func avoid(_ original: String) { originals.insert(original.lowercased()) }
    private func unused(_ candidate: String, _ original: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.caseInsensitiveCompare(original.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame && !originals.contains(trimmed.lowercased())
    }
    private var rng: any RandomNumberGenerator
    init(rng: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.people = People(rng: rng)
        self.rng = rng
    }
    private let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private func pick<T>(_ array: [T]) -> T? { array.randomElement(using: &rng) }
    private func digit(_ first: Bool = false) -> String { String(Int.random(in: first ? 1...9 : 0...9, using: &rng)) }
    private func digits(_ length: Int) -> String { guard length > 0 else { return "" }; return digit(true) + (1..<length).map { _ in digit() }.joined() }
    /// Parts of an address take their stand-ins from one real place; so do
    /// its coordinates.
    static let placed: Set<String> = ["LOCATION", "REGION", "POSTAL_CODE", "ADDRESS", "LATITUDE", "LONGITUDE", "COORDINATES"]
    /// A phone number's area code and a time zone follow the address beside them.
    static let local: Set<String> = ["PHONE_NUMBER", "TIME_ZONE"]
    /// Read off other stand-ins, so drawn after them: an age from its birth
    /// year, the last four digits from the number they end.
    static let derived: Set<String> = ["AGE", "LAST_DIGITS"]
    func replace(_ entity: String, _ original: String, persona: Persona? = nil, address: AddressParts? = nil) -> String {
        let actual = entity == "LOCATION" && people.knows(original) ? "PERSON" : entity
        if actual == "AGE" { return age(original) }
        let plain = actual + "\u{0}" + original
        let placed = Self.placed.contains(actual) && (actual != "ADDRESS" || AddressParts.line(original) != nil)
        // Found again elsewhere, a part keeps the stand-in its address gave it.
        if address == nil, placed || Self.local.contains(actual), let found = assigned[plain] { return found }
        // A one-line address is placed by its own parts: the city it names, not a state beside it.
        var parts = address ?? Self.lone(actual, original)
        if ["ADDRESS", "LOCATION"].contains(actual), let own = AddressParts.line(original)?.parts, own.city != nil {
            parts = AddressParts(city: own.city, region: own.region, postal: own.postal, country: own.country ?? address?.country, coordinates: nil)
        }
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
        var fake = "[\(actual)]"
        let sameDigits = digitKey(actual, original).flatMap { assigned[$0] }.flatMap { pour($0, into: original) }
        for attempt in 0..<8 {
            let candidate = attempt == 0 ? sameDigits ?? make(actual, original, persona, place) : make(actual, original, persona, place)
            // A persona's name is fixed; only a fresh value can be drawn again.
            // A part of a stand-in place may match someone else's real one: a state code or ZIP names no one.
            let free = place != nil && ["REGION", "POSTAL_CODE", "TIME_ZONE", "LATITUDE", "LONGITUDE"].contains(actual) && candidate.caseInsensitiveCompare(original) != .orderedSame
                // Initials read off the stand-in name are right even where they happen to match.
                || actual == "INITIALS" && persona != nil
            if free || unused(candidate, original) || attempt >= 2 && stablePerson && candidate.caseInsensitiveCompare(original) != .orderedSame {
                fake = candidate; break
            }
        }
        fake = barelyEnding(actual, original, fake)
        if !stablePerson && !stableEmail {
            assigned[key] = fake
            if assigned[plain] == nil { assigned[plain] = fake }
        }
        remember(original, fake)
        if let digitKey = digitKey(actual, original), assigned[digitKey] == nil { assigned[digitKey] = normalized(actual, fake) }
        return fake
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
    /// Birth years and number endings already replaced, so "birth_year",
    /// "age" and "ssn_last4" can agree with the stand-ins they come from.
    private var years: [Int: Int] = [:]
    private var endings: [String: String] = [:]
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
        return String(fake.map { $0.isASCII && $0.isNumber ? iterator.next() ?? $0 : $0 })
    }
    private func remember(_ original: String, _ fake: String) {
        let real = original.filter { $0.isASCII && $0.isNumber }, made = fake.filter { $0.isASCII && $0.isNumber }
        guard real.count >= 7, made.count >= 4, !original.contains(where: { Self.maskCharacters.contains($0) }) else { return }
        if endings[String(real.suffix(4))] == nil { endings[String(real.suffix(4))] = String(made.suffix(4)) }
    }
    /// A birth year moves one to eight years: enough that the date names no
    /// one, close enough that an age bracket or age estimate beside it still reads true.
    private func year(for original: Int) -> Int {
        if let known = years[original] { return known }
        let now = Calendar(identifier: .gregorian).component(.year, from: Date())
        func draw() -> Int {
            let shift = Int.random(in: 1...8, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
            return (1900...now).contains(original + shift) ? original + shift : original - shift
        }
        var fake = draw()
        for _ in 0..<8 where fake == original || years.values.contains(fake) { fake = draw() }
        years[original] = fake
        return fake
    }
    /// An age moved by as many years as the birth year it matches. With no
    /// birth date in the document it tells nothing and stays.
    private func age(_ original: String) -> String {
        guard let age = Int(original.trimmingCharacters(in: .whitespaces)) else { return original }
        let now = Calendar(identifier: .gregorian).component(.year, from: Date())
        let matches = years.filter { abs((now - $0.key) - age) <= 1 }
        guard let (real, fake) = matches.min(by: { abs((now - $0.key) - age) < abs((now - $1.key) - age) }) else { return original }
        return original.replacingOccurrences(of: String(age), with: String(max(0, min(120, age + real - fake))))
    }
    /// The last four digits of a number the document also holds in full take
    /// that number's stand-in's; any others are drawn fresh.
    private func lastDigits(_ original: String) -> String {
        let visible = original.filter(\.isNumber)
        // Drawn fresh, it gains no leading zero: it may be a bare number.
        var fresh = (endings[visible].map(Array.init) ?? (0..<visible.count).map { index in Character(digit(index == 0 && visible.first != "0")) }).makeIterator()
        return String(original.map { $0.isNumber ? fresh.next() ?? $0 : $0 })
    }
    private static let maskCharacters: Set<Character> = ["*", "•", "●", "X", "x", "#"]
    static func isMasked(_ value: String) -> Bool { value.filter { maskCharacters.contains($0) }.count >= 2 && value.contains(where: \.isNumber) }
    /// "***-**-7784" stays masked; only the digits it shows change.
    private func masked(_ original: String) -> String? {
        guard original.filter({ Self.maskCharacters.contains($0) }).count >= 2, original.contains(where: \.isNumber) else { return nil }
        let shown = String(original.reversed().prefix { !Self.maskCharacters.contains($0) }.reversed())
        let visible = shown.filter(\.isNumber)
        guard !visible.isEmpty else { return nil }
        let known: [Character]? = visible.count == 4 ? endings[visible].map(Array.init) : nil
        var fresh = known?.makeIterator()
        var drawn = (0..<visible.count).map { _ in Character(digit()) }.makeIterator()
        let rewritten = String(shown.map { $0.isNumber ? fresh?.next() ?? drawn.next() ?? $0 : $0 })
        return String(original.dropLast(shown.count)) + rewritten
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
        if let districtKey, let known = districtPlaces[districtKey], ownRegion == nil || Places.region(known.region, in: country)?.code != ownRegion,
           parts.city == nil || !claimed.contains(known.city + known.region) {
            places[key] = known
            if parts.city != nil { claimed.insert(known.city + known.region) }
            if let regionKey, regionPlaces[regionKey] == nil { regionPlaces[regionKey] = known }
            return known
        }
        if let regionKey, let known = regionPlaces[regionKey], parts.city == nil || !claimed.contains(known.city + known.region) {
            places[key] = known
            if parts.city != nil { claimed.insert(known.city + known.region) }
            if let districtKey, districtPlaces[districtKey] == nil { districtPlaces[districtKey] = known }
            return known
        }
        let candidates = Places.all.filter { place in
            place.country == country && Places.region(place.region, in: country)?.code != ownRegion && !originals.contains(place.city.lowercased())
                && (parts.postal.map { canWrite(place, like: $0) && !place.postal.contains(Self.district($0)) } ?? true)
        }
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
            let outward = trimmed.contains(" ") ? String(trimmed.prefix { $0 != " " }) : String(trimmed.dropLast(3))
            return place.postal.contains { Self.shape($0) == Self.shape(outward.uppercased()) }
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
            let codes = place.postal.filter { !bare || $0.first != "0" }
            // "55802" and "55802-8468" are one ZIP code, with one stand-in.
            let base = "ZIP\u{0}" + String(digits.prefix(5)) + "\u{0}" + place.city + place.region
            let known = assigned[base].flatMap { codes.contains($0) ? $0 : nil }
            guard let code = known ?? pick(codes) else { return nil }
            if known == nil, place.country == "US" { assigned[base] = code }
            if digits.count == 9, place.country == "US" {
                let plus = String(Int.random(in: 1000...9999, using: &rng))
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
            candidate = pick(place.postal.filter { Self.shape($0) == Self.shape(outward) }).map { $0 + (trimmed.contains(" ") ? " " : "") + inward }
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
    private func line(_ original: String, _ parsed: (parts: AddressParts, pieces: [String]), _ place: Place) -> String {
        let parts = parsed.parts
        return parsed.pieces.enumerated().map { index, piece in
            if piece == parts.city { return city(of: place, like: piece) }
            if piece == parts.country { return piece }
            if piece == parts.region { return Places.write(place, like: piece) }
            if piece == parts.postal { return placedPostal(place, piece, bare: false) }
            if let region = parts.region, let code = parts.postal, piece == region + " " + code {
                return Places.write(place, like: region) + " " + placedPostal(place, code, bare: false)
            }
            return unit(piece) ?? street(like: piece)
        }.joined(separator: ", ") + (original.hasSuffix(".") ? "." : "")
    }
    private static let suffixes: Set<String> = ["st", "street", "rd", "road", "ave", "av", "avenue", "blvd", "boulevard", "dr", "drive", "ln", "lane", "ct", "court", "way", "pl", "place", "pkwy", "parkway", "ter", "terrace", "cir", "circle", "hwy", "highway", "trl", "trail", "loop", "sq", "square"]
    /// A street written as the original is: its house number's length and its
    /// kind of street, "4821 Juniper Hollow Rd" → "3907 Maple Rd". The same
    /// street gets the same stand-in, on its own line or in a full address.
    private func street(like original: String) -> String {
        let key = "STREET\u{0}" + original.lowercased()
        if let known = assigned[key] { return known }
        let words = original.split(separator: " ")
        let number = words.first.map { $0.allSatisfy(\.isNumber) ? $0.count : 0 } ?? 0
        let last = words.count > 1 ? words.last.map(String.init) : nil
        let kind = last.flatMap { Self.suffixes.contains($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) ? $0 : nil } ?? "Street"
        // No street named after someone in the document ("Valley Street" for a Ms. Valley).
        let name = pick(Names.streets.filter { !originals.contains($0.lowercased()) && !original.lowercased().contains($0.lowercased()) }) ?? "Main"
        var fake = "\(digits(number > 0 ? min(number, 5) : 3)) \(name) \(kind)"
        for _ in 0..<8 where !unused(fake, original) { fake = "\(digits(number > 0 ? min(number, 5) : 3)) \(name) \(kind)" }
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
        if let first = words.first, Self.units.contains(first.lowercased()), words.count <= 3 {
            let number = words.count > 1 ? idLike(String(words.last!)) : digits(2)
            return String(trimmed.prefix(trimmed.count - (words.count > 1 ? words.last!.count : 0))) + (words.count > 1 ? number : " " + number)
        }
        if trimmed.lowercased().hasPrefix("po box") || trimmed.lowercased().hasPrefix("p.o. box") {
            let number = trimmed.reversed().prefix { $0.isNumber }.count
            return number > 0 ? String(trimmed.dropLast(number)) + digits(number) : nil
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
        var fake = original
        var attempts = 0
        while fake == original || attempts < 16 && originals.contains(fake) { fake = digits(original.count); attempts += 1 }
        assigned[key] = fake
        return fake
    }
    func numericLexeme(_ original: String, entity: String, address: AddressParts? = nil) -> String {
        let key = entity + "\u{0}" + original
        let digits = original.filter { $0.isASCII && $0.isNumber }
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
        if entity == "AGE" { return age(original) }
        if entity == "LAST_DIGITS" {
            bareEndings.insert(digits)
            let fake = lastDigits(original)
            // Still a number: a zero can't lead it.
            return fake.first == "0" ? digit(true) + fake.dropFirst() : fake
        }
        if entity == "LATITUDE" || entity == "LONGITUDE" { return replace(entity, original, address: address) }
        if let existing = assigned[key] { return existing }
        // A birth date split into numbers ("year": 1987, "month": 4) keeps each part plausible.
        if digits == original, entity == "DATE_OF_BIRTH", let value = Int(digits), digits.count <= 4 {
            let fake = digits.count == 4 ? String(year(for: value)) : String(Int.random(in: 1...(value <= 12 ? 12 : 28), using: &rng))
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
        let shared = digitKey(entity, whole).flatMap { assigned[$0] }.flatMap { pour($0, into: whole) }
        let drawn = shared ?? (entity == "PHONE_NUMBER" && [10, 11].contains(whole.count) ? phoneDigits(whole, address.flatMap { $0.isEmpty ? nil : place(for: $0) }) : number(whole))
        var iterator = drawn.makeIterator()
        let fake = String(original[..<significant].map { character in
            character.isASCII && character.isNumber ? iterator.next() ?? character : character
        }) + original[significant...]
        let kept = barelyEnding(entity, original, fake)
        if let digitKey = digitKey(entity, whole), assigned[digitKey] == nil { assigned[digitKey] = normalized(entity, kept) }
        assigned[key] = kept
        remember(original, kept)
        return kept
    }
    private static let units: Set<String> = ["apt", "apartment", "suite", "ste", "unit", "floor", "fl", "room", "rm", "bldg", "building", "#"]
    private static let digitsOnly: Set<String> = ["PHONE_NUMBER", "US_SSN", "ID_NUMBER", "POSTAL_CODE", "US_BANK_NUMBER", "US_PASSPORT", "US_DRIVER_LICENSE", "US_ITIN", "MEDICAL_LICENSE"]
    private func make(_ entity: String, _ original: String, _ persona: Persona?, _ place: Place? = nil) -> String {
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
        case "LOCATION": return pick(Names.cities.filter { !originals.contains($0.lowercased()) }) ?? "Austin"
        case "REGION": return pick(Places.regions.filter { $0.country == "US" && !originals.contains($0.code.lowercased()) && !originals.contains($0.name.lowercased()) }).map { original.count > 3 ? $0.name : $0.code } ?? "TX"
        case "ADDRESS":
            if let unit = unit(original) { return unit }
            // A short code on its own ("4B", "12") keeps its shape.
            if !original.contains(" "), original.count <= 6, original.contains(where: \.isNumber) { return idLike(original) }
            return street(like: original)
        case "INITIALS":
            let letters = persona.map { [$0.first.first, $0.last.first].compactMap { $0 } } ?? []
            let count = original.filter(\.isLetter).count
            var drawn = (count == letters.count ? letters : count == 3 && letters.count == 2 ? [letters[0], pick(Array("ABCDEFGHJKLMNPRSTW")) ?? "A", letters[1]] : (0..<count).map { _ in pick(Array("ABCDEFGHJKLMNPRSTW")) ?? "A" }).makeIterator()
            return String(original.map { $0.isLetter ? drawn.next() ?? $0 : $0 })
        case "DATE_OF_BIRTH": return dateLike(original)
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
            if original.contains(":") { return "2001:db8::" + String(Int.random(in: 0x100...0xffff, using: &rng), radix: 16) }
            return "203.0.113.\(Int.random(in: 1...254, using: &rng))"
        case "US_BANK_NUMBER": return digits(10)
        case "US_DRIVER_LICENSE": return "A" + digits(7)
        case "US_PASSPORT": return digits(9)
        case "US_ITIN": return "9\(digits(2))-\(digits(2))-\(digits(4))"
        case "MEDICAL_LICENSE": return "AB" + digits(6)
        case "CRYPTO": return "bc1q" + (0..<38).map { _ in String(pick(Array("023456789acdefghjklmnpqrstuvwxyz")) ?? "a") }.joined()
        case "USERNAME":
            if let persona, let handle = people.handle(for: persona, original: original, digits: { self.digits($0) }) { return handle }
            return people.unrelatedName(first: true).lowercased() + digits(3)
        case "SECRET":
            // A CVV, PIN or one-time code stays a short number.
            if (1...8).contains(original.count), original.allSatisfy({ $0.isASCII && $0.isNumber }) { return (0..<original.count).map { _ in digit() }.joined() }
            let prefix = TextRanges.matches(Self.secretPrefix, in: original).first.map { TextRanges.substring(original, $0.range.location..<NSMaxRange($0.range)) } ?? ""
            let kept = prefix.utf16.count < original.utf16.count ? prefix : ""
            return kept + (0..<24).map { _ in String(pick(alphabet) ?? "a") }.joined()
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
        let month = Int.random(in: 1...12, using: &rng)
        let day = Int.random(in: 1...28, using: &rng)
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
        guard let yearIndex = numbers.first(where: { runs[$0].count == 4 }), numbers.count == (named == nil ? 3 : 2) else {
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        let rest = numbers.filter { $0 != yearIndex }
        var output = runs
        func padded(_ value: Int, like run: String) -> String { run.count >= 2 ? String(format: "%0*d", run.count, value) : String(value) }
        if let real = Int(runs[yearIndex]) { year = self.year(for: real) }
        output[yearIndex] = String(year)
        if let named {
            let word = runs[named]
            let name = word.count > 3 && word.lowercased() != "sept" ? formatter.monthSymbols[month - 1] : formatter.shortMonthSymbols[month - 1]
            output[named] = word == word.uppercased() ? name.uppercased() : word == word.lowercased() ? name.lowercased() : name
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
