import Foundation
@testable import ScrubCore

/// A machine-readable zone as ICAO 9303 writes it, built and checked here
/// rather than with the scrubber's own reader.
enum MRZ {
    static func value(_ c: Character) -> Int {
        if let digit = c.wholeNumberValue, c.isASCII { return digit }
        if let ascii = c.asciiValue, (65...90).contains(ascii) { return Int(ascii) - 55 }
        return 0
    }
    static func check<S: StringProtocol>(_ s: S) -> Character {
        let weights = [7, 3, 1]
        let sum = s.enumerated().reduce(0) { $0 + value($1.element) * weights[$1.offset % 3] }
        return Character(String(sum % 10))
    }
    /// A field's text in capitals, padded with fillers or cut to its length.
    static func field(_ s: String, _ length: Int) -> String {
        let text = String(s.uppercased().prefix(length))
        return text + String(repeating: "<", count: length - text.count)
    }
    /// A name part as the zone writes it: capitals without accents, apostrophes
    /// dropped, spaces and hyphens as fillers.
    static func fold(_ s: String) -> String {
        String(s.folding(options: .diacriticInsensitive, locale: nil).uppercased().compactMap { c -> Character? in
            if c == " " || c == "-" { return "<" }
            return c.isASCII && c.isLetter ? c : nil
        })
    }
    static func names(_ last: String, _ first: String, _ length: Int) -> String { field(fold(last) + "<<" + fold(first), length) }
    static func yymmdd(_ date: DateComponents) -> String { String(format: "%02d%02d%02d", date.year! % 100, date.month!, date.day!) }

    /// A passport's two lines (TD3, 44 characters each).
    static func passport(issuer: String, last: String, first: String, number: String, nationality: String, birth: DateComponents, sex: String, expiry: DateComponents) -> (String, String) {
        let line1 = "P<" + issuer + names(last, first, 39)
        let doc = field(number, 9), dob = yymmdd(birth), exp = yymmdd(expiry), personal = field("", 14)
        let parts = [doc + String(check(doc)), dob + String(check(dob)), exp + String(check(exp)), personal + "0"]
        let line2 = parts[0] + nationality + parts[1] + sex + parts[2] + parts[3]
        return (line1, line2 + String(check(parts[0] + parts[1] + parts[2] + parts[3])))
    }
    /// An identity card's three lines (TD1, 30 characters each).
    static func card(issuer: String, last: String, first: String, number: String, nationality: String, birth: DateComponents, sex: String, expiry: DateComponents) -> [String] {
        let doc = field(number, 9), dob = yymmdd(birth), exp = yymmdd(expiry)
        let line1 = "I<" + issuer + doc + String(check(doc)) + field("", 15)
        let head = dob + String(check(dob)) + sex + exp + String(check(exp)) + nationality + field("", 11)
        let composite = check(String(line1.dropFirst(5)) + String(head.prefix(7)) + String(head.dropFirst(8).prefix(7)) + String(head.dropFirst(18)))
        return [line1, head + String(composite), names(last, first, 30)]
    }

    /// The lines of a zone value, however it was written.
    static func lines(_ value: String) -> [String] { value.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) } }
    /// Why the output can't pass for a zone like the original, or nil when it can.
    static func misfit(_ original: String, _ output: String) -> String? {
        let before = lines(original), after = lines(output)
        guard before.map(\.count) == after.map(\.count) else { return "line lengths \(before.map(\.count)) → \(after.map(\.count))" }
        for line in after where !line.allSatisfy({ $0 == "<" || $0.isASCII && ($0.isNumber || $0.isUppercase) }) { return "not zone characters: \(line)" }
        for (index, line) in after.enumerated() { if let broken = badCheck(line, at: index, among: after) { return broken } }
        return nil
    }
    /// A data line whose check digits no longer add up.
    static func badCheck(_ line: String, at index: Int, among all: [String]) -> String? {
        let c = Array(line)
        func ok(_ range: Range<Int>, _ at: Int) -> Bool { c[at] == check(String(c[range])) || c[range].allSatisfy { $0 == "<" } && (c[at] == "<" || c[at] == "0") }
        if c.count == 44, c[0].isNumber || c[9].isNumber, !line.hasPrefix("P<") {
            let composite = String(c[0..<10]) + String(c[13..<20]) + String(c[21..<43])
            return ok(0..<9, 9) && ok(13..<19, 19) && ok(21..<27, 27) && ok(28..<42, 42) && c[43] == check(composite) ? nil : "check digits broken: \(line)"
        }
        if c.count == 30, all.count == 3, index == 0 {
            return ok(5..<14, 14) ? nil : "check digit broken: \(line)"
        }
        if c.count == 30, all.count == 3, index == 1, let first = all.first {
            let head = Array(first)
            let composite = String(head[5..<30]) + String(c[0..<7]) + String(c[8..<15]) + String(c[18..<29])
            return ok(0..<6, 6) && ok(8..<14, 14) && c[29] == check(composite) ? nil : "check digits broken: \(line)"
        }
        return nil
    }
    /// The surname and given name a zone's name line writes, as letters.
    static func writtenName(_ value: String) -> (last: String, first: String)? {
        for line in lines(value) {
            let text = line.count == 44 && line.first?.isLetter == true && !line.dropFirst(5).contains(where: \.isNumber) ? String(line.dropFirst(5))
                : line.count == 30 && !line.contains(where: \.isNumber) ? line : nil
            guard let text, let split = text.range(of: "<<") else { continue }
            let last = text[..<split.lowerBound], first = text[split.upperBound...].split(separator: "<").first ?? ""
            return (String(last.filter(\.isLetter)), String(first))
        }
        return nil
    }
    /// The birth date (YYMMDD) and document number a zone's data lines write.
    static func data(_ value: String) -> (birth: String?, number: String?) {
        var birth: String?, number: String?
        let all = lines(value)
        for line in all {
            let c = Array(line)
            if c.count == 44, !line.hasPrefix("P<"), line.first.map({ $0.isNumber || $0.isUppercase }) == true, c[13..<19].allSatisfy(\.isNumber) {
                number = String(c[0..<9]).replacingOccurrences(of: "<", with: ""); birth = String(c[13..<19])
            } else if c.count == 30, all.count == 3, line == all[0] {
                number = String(c[5..<14]).replacingOccurrences(of: "<", with: "")
            } else if c.count == 30, all.count == 3, line == all[1] {
                birth = String(c[0..<6])
            }
        }
        return (birth, number)
    }
}

/// An identity check request as verification APIs take one: a person's name
/// and birth date in parts, an address split into house number, street and
/// unit beside the line joining them, a licence, national IDs and a passport
/// with its machine-readable zone, and the country written once at the top.
extension PayloadGen {
    /// Cities outside the four countries Scrub has full places for, written
    /// out here: name, province code (where the country writes one), postcode.
    struct Town { let country: String, city: String, province: String?, postal: String }
    static let towns = [Town(country: "IT", city: "Torino", province: "TO", postal: "10128"), Town(country: "IT", city: "Bologna", province: "BO", postal: "40126"),
                        Town(country: "IT", city: "Palermo", province: "PA", postal: "90133"), Town(country: "IT", city: "Genova", province: "GE", postal: "16121"),
                        Town(country: "DE", city: "Leipzig", province: nil, postal: "04109"), Town(country: "DE", city: "Hamburg", province: nil, postal: "20095"),
                        Town(country: "FR", city: "Lyon", province: nil, postal: "69003"), Town(country: "FR", city: "Nantes", province: nil, postal: "44000"),
                        Town(country: "ES", city: "Sevilla", province: nil, postal: "41004"), Town(country: "ES", city: "Valencia", province: nil, postal: "46002")]
    static let localStreets: [String: [String]] = [
        "IT": ["Via Garibaldi", "Corso Cavour", "Viale Mazzini", "Via San Biagio", "Vicolo del Pozzo", "Via dei Serpenti"],
        "DE": ["Lindenallee", "Goethestraße", "Am Mühlbach", "Schillerweg", "Bergstraße"],
        "FR": ["Rue des Acacias", "Avenue Jean Jaurès", "Boulevard Voltaire", "Impasse du Moulin"],
        "ES": ["Calle Mayor", "Avenida de la Constitución", "Paseo del Prado", "Calle de Alcalá"],
    ]
    static let phonePrefixes = ["IT": "+39 3", "DE": "+49 15", "FR": "+33 6", "ES": "+34 6"]
    static let nations = ["US": "USA", "CA": "CAN", "GB": "GBR", "AU": "AUS", "IT": "ITA", "DE": "D<<", "FR": "FRA", "ES": "ESP"]
    static let birthTowns = ["Matera", "Cremona", "Lucca", "Siena", "Trento", "Ancona"]

    mutating func identity() -> PNode {
        let p = person()
        let abroad = gen.int(0...2) > 0
        let town = gen.choose(Self.towns)
        let country = abroad ? town.country : p.country
        let place = addressLink()
        let upper = gen.int(0...2) == 0
        func cased(_ s: String) -> String { upper ? s.uppercased() : s }

        // The street's name and the house number, apart and joined, as each country writes them.
        let house = String(gen.int(1...240)), unit = String(gen.int(1...9))
        let streetName: String, line: String
        if abroad {
            streetName = cased(gen.choose(Self.localStreets[country]!))
            switch country {
            case "IT": line = gen.int(0...1) == 0 ? "\(streetName) \(house)/\(unit)" : "\(streetName) \(house)"
            case "FR": line = "\(house) \(streetName)"
            case "ES": line = "\(streetName) \(house)"
            default: line = "\(streetName) \(house)"
            }
        } else {
            streetName = cased(p.streetName)
            line = "\(house) \(streetName)"
        }
        let numbered = gen.int(0...3) == 0
        var location: [(String, PNode)] = [
            (key(gen.choose([["building", "number"], ["house", "number"], ["street", "number"], ["civic", "number"]])), leaf(house, .pii(.houseNumber), number: numbered)),
        ]
        if line.contains("/") || gen.int(0...1) == 0 { location.append((key(gen.choose([["unit", "number"], ["apartment"], ["flat", "number"]])), leaf(unit, .pii(.unit), number: numbered))) }
        location.append((key(gen.choose([["street", "name"], ["street"], ["thoroughfare"]])), leaf(streetName, .pii(.streetName))))
        if abroad {
            location.append((key(gen.choose([["city"], ["town"], ["locality"]])), leaf(cased(town.city), .pii(.city))))
            if let province = town.province { location.append((key(gen.choose([["state", "province", "code"], ["province"], ["province", "code"]])), leaf(province, .pii(.province)))) }
            location.append((key(gen.choose([["postal", "code"], ["zip", "code"], ["postcode"]])), leaf(town.postal, .pii(.zip))))
            // A point beside an address abroad, where no table of places has its coordinates.
            if gen.int(0...3) == 0 {
                location.append((key(["latitude"]), leaf(String(format: "%.4f", Double(gen.int(380_000...530_000)) / 10_000), .pii(.latitude), number: true)))
                location.append((key(["longitude"]), leaf(String(format: "%.4f", Double(gen.int(-40_000...150_000)) / 10_000), .pii(.longitude), number: true)))
            }
        } else {
            location.append((key(gen.choose([["city"], ["town"]])), leaf(cased(p.city), .pii(.city))))
            location.append((key(gen.choose([["state", "province", "code"], ["state"], ["province"]])), region(p)))
            location.append(field(Self.zipKeys, zip(p), qualifier: ""))
        }
        // The joined line sits deeper, under fields the request adds.
        location.append((key(["additional", "fields"]), .object([(key(gen.choose([["address1"], ["address", "line", "1"], ["full", "address"]])), leaf(line, .pii(.street)))])))

        let birthDay: PNode = .object([
            (key(gen.choose([["day", "of", "birth"], ["birth", "day"], ["dob", "day"]])), linked(leaf(String(p.dob.day!), .pii(.dobDay), number: true), p.link("dob"))),
            (key(gen.choose([["month", "of", "birth"], ["birth", "month"], ["dob", "month"]])), linked(leaf(String(p.dob.month!), .pii(.dobMonth), number: true), p.link("dob"))),
            (key(gen.choose([["year", "of", "birth"], ["birth", "year"], ["dob", "year"]])), linked(leaf(String(p.dob.year!), .pii(.dobYear), number: true), p.link("dob"))),
        ])
        guard case .object(let birthParts) = birthDay else { fatalError() }
        let female = p.gender == "female"
        let person: PNode = .object([
            (key(gen.choose([["first", "given", "name"], ["given", "names"], ["first", "name"]])), linked(leaf(cased(p.first), .pii(.firstName)), p.link("name"))),
            (key(gen.choose([["first", "sur", "name"], ["surname"], ["family", "name"]])), linked(leaf(cased(p.last), .pii(.lastName)), p.link("name"))),
        ] + birthParts + [(key(["gender"]), linked(keep(female ? "F" : "M"), p.link("name")))])

        let phone: PNode = abroad
            ? leaf(Self.phonePrefixes[country]! + String(gen.int(10...99)) + " " + String(gen.int(1_000_000...9_999_999)), .pii(.phone))
            : linked(self.phone(p), place)

        // Documents: each holds its number under a bare "number".
        var expiry = DateComponents(); expiry.year = gen.int(2027...2034); expiry.month = gen.int(1...12); expiry.day = gen.int(10...28)
        let passportNumber = gen.int(0...1) == 0 ? gen.choose(["C", "Y", "K"]) + String(gen.int(10_000_000...99_999_999)) : String(gen.int(100_000_000...599_999_999))
        let documentLink = "p\(p.id).passport"
        let nation = Self.nations[country]!
        let (mrz1, mrz2) = MRZ.passport(issuer: nation, last: p.last, first: p.first, number: passportNumber, nationality: nation, birth: p.dob, sex: female ? "F" : "M", expiry: expiry)
        let expiryParts: [(String, PNode)] = [(key(["day", "of", "expiry"]), keep(String(expiry.day!), number: true)), (key(["month", "of", "expiry"]), keep(String(expiry.month!), number: true)), (key(["year", "of", "expiry"]), keep(String(expiry.year!), number: true))]
        var passport: [(String, PNode)]
        if gen.int(0...3) == 0 {
            passport = [(key(["mrz"]), linked(leaf(mrz1 + "\n" + mrz2, .pii(.mrz)), p.link("name"), p.link("dob"), documentLink))]
        } else {
            passport = [(key(gen.choose([["mrz1"], ["mrz", "line", "1"], ["mrz", "line1"]])), linked(leaf(mrz1, .pii(.mrz)), p.link("name"))),
                        (key(gen.choose([["mrz2"], ["mrz", "line", "2"], ["mrz", "line2"]])), linked(leaf(mrz2, .pii(.mrz)), p.link("dob"), documentLink))]
        }
        passport.append((key(["number"]), linked(leaf(passportNumber, .pii(.passport)), documentLink)))
        passport += expiryParts

        let nationalNumber = abroad ? String((0..<6).map { _ in gen.choose(Array("BCDFGHLMNPRSTVZ")) }) + String(gen.int(10...99)) + String(gen.choose(Array("ABCDEHLMPRST"))) + String(gen.int(10...71)) + String(gen.choose(Array("ABCDEFGHLM"))) + String(gen.int(100...999)) + String(gen.choose(Array("ABCDEFGHJKLMNPQRSTUVWXYZ")))
            : p.ssn.filter(\.isNumber)
        var card = DateComponents(); card.year = gen.int(2028...2033); card.month = gen.int(1...12); card.day = gen.int(10...28)
        let cardNumber = String(gen.choose(Array("ACDEFHKL"))) + String(gen.choose(Array("ACDEFHKL"))) + String(gen.int(1_000_000...9_999_999))
        var ids: [PNode] = [.object([(key(["number"]), leaf(nationalNumber, abroad ? .pii(.taxID) : .pii(.ssn))), (key(["type"]), keep(abroad ? "NationalID" : "SocialService"))])]
        if gen.int(0...2) == 0 {
            let lines = MRZ.card(issuer: nation, last: p.last, first: p.first, number: cardNumber, nationality: nation, birth: p.dob, sex: female ? "F" : "M", expiry: card)
            ids.append(.object([(key(["number"]), leaf(cardNumber, .pii(.passport))), (key(["type"]), keep("IdentityCard")), (key(["mrz"]), linked(leaf(lines.joined(separator: "\n"), .pii(.mrz)), p.link("name"), p.link("dob")))]))
        }
        let licence: PNode = .object([(key(["number"]), leaf(p.license, .pii(.license)))] + (abroad ? [] : [(key(gen.choose([["state"], ["issuing", "state"]])), region(p))]) + expiryParts)

        var fields: [(String, PNode)] = [
            (key(gen.choose([["person", "info"], ["personal", "info"], ["individual"]])), person),
            (key(gen.choose([["location"], ["address"], ["residence"]])), linked(.object(location), place)),
            (key(gen.choose([["communication"], ["contact"]])), .object([(key(gen.choose([["telephone"], ["mobile", "number"], ["phone"], ["national", "format"]])), phone)])),
            (key(gen.choose([["driver", "licence"], ["drivers", "license"], ["driving", "licence"]])), licence),
            (key(gen.choose([["national", "ids"], ["identity", "documents"], ["government", "ids"]])), .array(ids, item: key(["national", "id"]))),
            (key(["passport"]), .object(passport)),
        ]
        if abroad && gen.int(0...1) == 0 {
            fields.append((key(["country", "specific"]), .object([(country, .object([
                (key(["city", "of", "birth"]), leaf(cased(gen.choose(Self.birthTowns)), .pii(.city))),
                (key(["country", "of", "birth"]), keep(country)),
                (key(["document", "number"]), leaf(String(gen.choose(Array("ACDEFHKL"))) + String(gen.choose(Array("ACDEFHKL"))) + String(gen.int(10_000_000...99_999_999)), .pii(.passport))),
                (key(["document", "type"]), keep("Identity Card")),
            ]))])))
        }
        // How a decisioning platform answers: its own objects' references, named "tokens",
        // and the captured documents described by kind, none of which names anyone.
        let reference = { (prefix: String, gen: inout Gen) in prefix + "-" + gen.string("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789", count: 20) }
        let platform: PNode = .object([
            (key(["entity", "token"]), keep(reference("P", &gen))),
            (key(["evaluation", "token"]), keep(reference("L", &gen))),
            // Not run yet: nothing in its place, which a pattern for secrets must not take with the brackets after it.
            (key(["review", "token"]), .null),
            (key(["journey", "application", "token"]), keep(reference("JA", &gen))),
            (key(["credentials"]), .array([.object([(key(["category"]), keep("ID")), (key(["id"]), keep(id("cred"))), (key(["status"]), keep("unavailable"))]),
                                           .object([(key(["category"]), keep("FACEMAP")), (key(["classifier"]), keep("FACE"))])], item: "credential")),
            (key(["front", "image"]), leaf("data:image/png;base64," + gen.string("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", count: 320) + "==", .ignore)),
        ])
        return .object([
            (key(["verification", "type"]), keep(gen.choose(["Live", "Test"]))),
            (key(["platform"]), platform),
            (key(["consent", "for", "data", "sources"]), .array([keep("Credit Bureau"), keep("Mobile Carrier")], item: "source")),
            (key(["country", "code"]), keep(country)),
            (key(["request", "metadata"]), .array([.object([(key(["channel"]), keep("CustomerReference")), (key(["value"]), leaf("REF-\(gen.int(10000...99999))", .keepSoft))])], item: "entry")),
            (key(["data", "fields"]), .object(fields)),
            (key(["verbose", "mode"]), .bool(false)),
        ])
    }
}
