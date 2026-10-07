import Foundation
@testable import ScrubCore

/// Identity-verification responses, where every field may be personal: a
/// Social Security number in each way vendors write it beside its last four
/// and its masked form, addresses in the formats of the countries they are
/// in, birth dates whole and in parts with an age, identity documents with
/// their machine-readable zones, and bank, phone, IP and device details, each
/// beside the codes, scores and flags that name no one.
extension PayloadGen {
    static let kycShapes = ["kycSSN", "kycAddress", "kycBirth", "kycDocument", "kycBank"]

    /// A place written out here, with the way its country writes a street line.
    struct KYCPlace { let country: String, city: String, region: String?, postal: String, streets: [String], numberFirst: Bool, countryName: String }
    static let kycPlaces: [KYCPlace] = [
        KYCPlace(country: "US", city: "Tacoma", region: "WA", postal: "98402", streets: ["Juniper Hollow Rd", "Larkspur Ave", "Heron Point Rd"], numberFirst: true, countryName: "United States"),
        KYCPlace(country: "US", city: "Duluth", region: "MN", postal: "55802", streets: ["Tamarack Ln", "Wexford Dr"], numberFirst: true, countryName: "United States"),
        KYCPlace(country: "US", city: "Albuquerque", region: "NM", postal: "87102", streets: ["Cobblestone Ct", "Pinecrest Blvd"], numberFirst: true, countryName: "United States"),
        KYCPlace(country: "CA", city: "Montréal", region: "QC", postal: "H2J 2L3", streets: ["rue Saint-Denis", "avenue du Parc"], numberFirst: true, countryName: "Canada"),
        KYCPlace(country: "CA", city: "Ottawa", region: "ON", postal: "K1P 5G4", streets: ["Bank Street", "Elgin Street"], numberFirst: true, countryName: "Canada"),
        KYCPlace(country: "GB", city: "Leeds", region: nil, postal: "LS6 3HN", streets: ["Kingsley Road", "Brudenell Grove"], numberFirst: true, countryName: "United Kingdom"),
        KYCPlace(country: "GB", city: "Bristol", region: nil, postal: "BS8 1TH", streets: ["Whiteladies Road", "Cotham Hill"], numberFirst: true, countryName: "United Kingdom"),
        KYCPlace(country: "DE", city: "München", region: nil, postal: "80538", streets: ["Am Gries", "Lindenallee", "Goethestraße"], numberFirst: false, countryName: "Germany"),
        KYCPlace(country: "DE", city: "Hamburg", region: nil, postal: "20095", streets: ["Schillerweg", "Am Mühlbach"], numberFirst: false, countryName: "Deutschland"),
        KYCPlace(country: "FR", city: "Lyon", region: nil, postal: "69003", streets: ["rue des Acacias", "avenue Jean Jaurès"], numberFirst: true, countryName: "France"),
        KYCPlace(country: "ES", city: "Sevilla", region: nil, postal: "41004", streets: ["Calle Mayor", "Avenida de la Constitución"], numberFirst: false, countryName: "Spain"),
        KYCPlace(country: "IT", city: "Torino", region: "TO", postal: "10128", streets: ["Via Garibaldi", "Corso Cavour"], numberFirst: false, countryName: "Italy"),
        KYCPlace(country: "NL", city: "Utrecht", region: nil, postal: "3511 LX", streets: ["Oudegracht", "Biltstraat"], numberFirst: false, countryName: "Netherlands"),
        KYCPlace(country: "AU", city: "Geelong", region: "VIC", postal: "3220", streets: ["Moorabool Street", "Pakington Street"], numberFirst: true, countryName: "Australia"),
        KYCPlace(country: "MX", city: "Guadalajara", region: "Jalisco", postal: "44160", streets: ["Avenida Chapultepec", "Calle Morelos"], numberFirst: false, countryName: "Mexico"),
        KYCPlace(country: "BR", city: "Curitiba", region: "PR", postal: "80010-010", streets: ["Rua XV de Novembro", "Avenida Sete de Setembro"], numberFirst: false, countryName: "Brazil"),
    ]

    /// Codes, scores and flags as vendors return them: none names anyone.
    mutating func verdicts(_ fields: [String]) -> [(String, PNode)] {
        var pairs: [(String, PNode)] = fields.map { (key([$0, "match"]), keep(gen.choose(["Y", "N", "MATCH", "NO_MATCH", "PARTIAL", "U"]))) }
        pairs.append((key(["reason", "codes"]), .array((0..<gen.int(1...3)).map { _ in keep(gen.choose(["R", "I", "W"]) + String(gen.int(100...999))) }, item: "code")))
        pairs.append((key(["score"]), keep(String(gen.int(300...990)), number: true)))
        pairs.append((key(["confidence"]), keep(String(format: "%.2f", Double(gen.int(0...100)) / 100), number: true)))
        return pairs
    }

    // MARK: SSN

    /// A Social Security number as identity vendors take and return it: whole
    /// in any spelling, its last four alone or masked, typed in a list of
    /// identifiers, an ITIN beside it, and in a note an agent wrote.
    mutating func kycSSN() -> PNode {
        let p = person()
        let digits = p.ssn.filter(\.isNumber), last4 = String(digits.suffix(4))
        let ssnLink = p.link("ssn")
        func spelled(_ style: Int) -> PNode {
            switch style {
            case 0: return linked(leaf(digits, .pii(.ssn), number: true), ssnLink)
            case 1: return linked(leaf(digits, .pii(.ssn)), ssnLink)
            case 2: return linked(leaf(digits.prefix(3) + " " + digits.dropFirst(3).prefix(2) + " " + digits.suffix(4), .pii(.ssn)), ssnLink)
            default: return linked(leaf(p.ssn, .pii(.ssn)), ssnLink)
            }
        }
        let itinDigits = "9" + String(format: "%02d", gen.int(0...99)) + String(gen.choose([50, 65, 70, 78, 88, 90, 92, 94, 99])) + String(format: "%04d", gen.int(1...9999))
        let itin = gen.int(0...1) == 0 ? itinDigits : itinDigits.prefix(3) + "-" + itinDigits.dropFirst(3).prefix(2) + "-" + itinDigits.suffix(4)
        let lastKey = gen.choose([["ssn", "last4"], ["last4"], ["ssn", "last", "four"], ["last", "4", "ssn"]])
        let masked = gen.choose(["***-**-", "XXX-XX-", "xxx-xx-", "*****"]) + last4
        let subject: PNode = .object([
            (key(["first", "name"]), linked(leaf(p.first, .pii(.firstName)), p.link("name"))),
            (key(["last", "name"]), linked(leaf(p.last, .pii(.lastName)), p.link("name"))),
            (key(gen.choose([["ssn"], ["social", "security", "number"], ["tax", "id"], ["tin"], ["national", "id"]])), spelled(gen.int(0...3))),
            (key(lastKey), linked(leaf(last4, .pii(.lastDigits), number: gen.int(0...3) == 0 && !last4.hasPrefix("0")), ssnLink)),
            (key(gen.choose([["masked", "ssn"], ["ssn", "masked"], ["ssn", "display"]])), linked(leaf(masked, .pii(.lastDigits)), ssnLink)),
            (key(["identifiers"]), .array([
                .object([(key(["type"]), keep(gen.choose(["SSN", "ssn", "US_SSN"]))), (key(["value"]), spelled(gen.int(1...3)))]),
                .object([(key(["type"]), keep("ITIN")), (key(["value"]), leaf(itin, .pii(.itin)))]),
            ], item: "identifier")),
        ])
        let note = gen.choose(["Applicant confirmed SSN \(p.ssn) by phone.", "SSN on file ends in \(last4); customer read back \(p.ssn).", "Called back, ssn \(p.ssn) matches the bureau."])
        return .object([
            (key(["request", "id"]), keep(id("req"))),
            (key(["subject"]), subject),
            (key(["results"]), .object(verdicts(["ssn", "name", "dob"]) + [
                (key(["ssn", "issued", "start", "year"]), keep(String(gen.int(1970...2005)), number: true)),
                (key(["deceased"]), keep(gen.choose(["N", "false"]))),
            ])),
            (key(["notes"]), .array([linked(leaf(note, .pii(.ssn)), ssnLink)], item: "note")),
            (key(["created", "at"]), timestamp()),
        ])
    }

    // MARK: Addresses

    mutating func kycStreet(_ place: KYCPlace, upper: Bool) -> (name: String, number: String, line: String) {
        let name = upper ? gen.choose(place.streets).uppercased() : gen.choose(place.streets)
        let number = gen.int(0...3) == 0 && !["US", "AU"].contains(place.country) ? String(gen.int(1...90)) + gen.choose(["a", "b"]) : String(gen.int(2...980))
        let line: String
        switch place.country {
        case "FR", "CA" where place.city == "Montréal": line = "\(number) \(name)"
        case "ES", "MX", "BR": line = "\(name) \(number)"
        case "IT": line = "\(name) \(number)"
        default: line = place.numberFirst ? "\(number) \(name)" : "\(name) \(number)"
        }
        return (name, number, line)
    }
    /// A unit as each country writes one: "Apt 4B", "App. 3", "Flat 2", "3º B".
    mutating func kycUnit(_ place: KYCPlace) -> String {
        switch place.country {
        case "CA" where place.city == "Montréal": return "App. \(gen.int(1...30))"
        case "GB": return gen.choose(["Flat \(gen.int(1...9))", "Flat \(gen.int(1...9))\(gen.choose(["A", "B"]))"])
        case "ES": return "\(gen.int(1...8))º \(gen.choose(["A", "B", "C"]))"
        case "DE": return "\(gen.int(1...4)). OG"
        case "FR": return "Bât. \(gen.choose(["A", "B", "C"]))"
        default: return gen.choose(["Apt \(gen.int(2...9))\(gen.choose(["A", "B"]))", "Suite \(gen.int(100...450))", "Unit \(gen.int(2...40))", "Apt. \(gen.int(10...30))"])
        }
    }
    /// An address split into parts, its joined line and, at times, the whole
    /// address written once more on one line, all one place (the "a…" link).
    mutating func kycAddressObject(_ place: KYCPlace) -> PNode {
        let link = addressLink()
        let upper = gen.int(0...4) == 0
        func cased(_ s: String) -> String { upper ? s.uppercased() : s }
        let street = kycStreet(place, upper: upper)
        var pairs: [(String, PNode)] = []
        let split = gen.int(0...1) == 0
        if split {
            pairs.append((key(gen.choose([["street"], ["street", "name"], ["thoroughfare"]])), leaf(street.name, .pii(.streetName))))
            pairs.append((key(gen.choose([["street", "number"], ["building", "number"], ["house", "number"]])), leaf(street.number, .pii(.houseNumber), number: street.number.allSatisfy(\.isNumber) && gen.int(0...3) == 0)))
        } else {
            pairs.append((key(gen.choose([["line1"], ["address", "line1"], ["street", "address"], ["address1"]])), leaf(street.line, .pii(.street))))
        }
        if gen.int(0...2) == 0 { pairs.append((key(gen.choose([["line2"], ["address2"], ["unit"], ["apt"]])), leaf(cased(kycUnit(place)), .pii(.unit)))) }
        pairs.append((key(gen.choose([["city"], ["locality"], ["town"]])), leaf(cased(place.city), .pii(.city))))
        if let region = place.region { pairs.append((key(gen.choose([["state"], ["region"], ["province"], ["state", "code"]])), leaf(region, .pii(place.country == "US" || place.country == "CA" || place.country == "AU" ? .region : .province)))) }
        var postal = place.postal
        if place.country == "US", gen.int(0...2) == 0 {
            pairs.append((key(gen.choose([["zip"], ["postal", "code"], ["zip", "code"]])), leaf(postal, .pii(.zip))))
            pairs.append((key(gen.choose([["zip4"], ["zip", "plus4"], ["plus4"]])), leaf(String(format: "%04d", gen.int(1000...9899)), .pii(.zip4))))
        } else {
            if place.country == "US", gen.int(0...2) == 0 { postal += "-" + String(gen.int(1000...9899)) }
            pairs.append((key(gen.choose([["postal", "code"], ["postcode"], ["zip"], ["zip", "code"]])), leaf(postal, .pii(.zip))))
        }
        pairs.append((key(gen.choose([["country"], ["country", "code"]])), keep(gen.choose([place.country, place.country, Self.alpha3[place.country] ?? place.country]))))
        if gen.int(0...1) == 0 {
            let local: String
            switch place.country {
            case "US", "CA", "AU": local = "\(street.line), \(cased(place.city)), \(place.region!) \(postal)"
            case "GB": local = "\(street.line), \(cased(place.city)) \(postal)"
            case "IT": local = "\(street.line), \(postal) \(cased(place.city)) \(place.region!)"
            case "MX", "BR": local = "\(street.line), \(postal) \(cased(place.city)), \(place.region!)"
            default: local = "\(street.line), \(postal) \(cased(place.city))"
            }
            pairs.append((key(gen.choose([["formatted"], ["full", "address"], ["single", "line"]])), leaf(local + (gen.int(0...1) == 0 ? ", " + place.countryName : ""), .pii(.fullAddress))))
        }
        return linked(.object(pairs), link)
    }
    static let alpha3 = ["US": "USA", "CA": "CAN", "GB": "GBR", "DE": "DEU", "FR": "FRA", "ES": "ESP", "IT": "ITA", "NL": "NLD", "AU": "AUS", "MX": "MEX", "BR": "BRA"]

    /// A person's current address and the ones before it, as an identity
    /// check returns them, with the vendor's verdict on each.
    mutating func kycAddress() -> PNode {
        let p = person()
        let home = gen.choose(Self.kycPlaces)
        let before = (0..<gen.int(1...2)).map { _ in gen.int(0...1) == 0 ? gen.choose(Self.kycPlaces.filter { $0.country == home.country }) : gen.choose(Self.kycPlaces) }
        var current = kycAddressObject(home)
        if gen.int(0...2) == 0, case .object(let pairs) = current { current = .object(pairs + [(key(["since"]), keep(String(gen.int(2001...2024)) + "-0" + String(gen.int(1...9))))]) }
        return .object([
            (key(["id"]), keep(id("chk"))),
            (key(gen.choose([["full", "name"], ["legal", "name"]])), linked(leaf(p.full, .pii(.fullName)), p.link("name"))),
            (key(["address"]), current),
            (key(["previous", "addresses"]), .array(before.map { kycAddressObject($0) }, item: "address")),
            (key(["address", "verification"]), .object(verdicts(["street", "city", "postal"]) + [(key(["deliverable"]), .bool(true)), (key(["type"]), keep(gen.choose(["residential", "RESIDENTIAL", "commercial"])))])),
            (key(["country", "code"]), keep(home.country)),
        ])
    }

    // MARK: Birth dates

    /// A birth date whole in a vendor's format, again in parts as numbers or
    /// strings, and an age; the dates beside it (a check's, a document's
    /// expiry) are no one's.
    mutating func kycBirth() -> PNode {
        let p = person()
        let dobLink = p.link("dob")
        let format = gen.choose(["yyyy-MM-dd", "MM/dd/yyyy", "dd.MM.yyyy", "yyyyMMdd", "dd/MM/yyyy", "yyyy/MM/dd"])
        let number = gen.int(0...1) == 0
        func part(_ value: Int, _ kind: Kind, pad: Bool) -> PNode {
            linked(leaf(pad && !number ? String(format: "%02d", value) : String(value), .pii(kind), number: number), dobLink)
        }
        let pad = gen.int(0...1) == 0
        let parts: PNode = .object([
            (key(["day"]), part(p.dob.day!, .dobDay, pad: pad)),
            (key(["month"]), part(p.dob.month!, .dobMonth, pad: pad)),
            (key(["year"]), part(p.dob.year!, .dobYear, pad: false)),
        ])
        var subject: [(String, PNode)] = [
            (key(["full", "name"]), linked(leaf(p.full, .pii(.fullName)), p.link("name"))),
            (key(gen.choose([["dob"], ["date", "of", "birth"], ["birth", "date"]])), linked(leaf(Self.formatDate(p.dob, format), .pii(.dob), dateFormat: format), dobLink)),
        ]
        switch gen.int(0...2) {
        case 0: subject.append((key(gen.choose([["dob", "parts"], ["birth"], ["date", "of", "birth", "parts"]])), parts))
        case 1: subject += [(key(["birth", "year"]), part(p.dob.year!, .dobYear, pad: false)), (key(["birth", "month"]), part(p.dob.month!, .dobMonth, pad: pad))]
        default: subject.append((key(["dob", "year"]), linked(leaf(String(p.dob.year!), .pii(.dobYear)), dobLink)))
        }
        subject.append((key(["age"]), linked(leaf(String(Self.age(p)), .pii(.age), number: gen.int(0...2) > 0), dobLink)))
        return .object([
            (key(["transaction", "id"]), keep(id("txn"))),
            (key(["subject"]), .object(subject)),
            (key(["checked", "on"]), keep(String(format: "%04d-%02d-%02d", gen.int(2024...2026), gen.int(1...12), gen.int(1...28)))),
            (key(["dob", "verification"]), .object(verdicts(["dob", "year", "age"]) + [(key(["over", "18"]), .bool(true)), (key(["min", "age"]), keep("18", number: true))])),
        ])
    }

    // MARK: Documents

    /// A national number of one of the countries identity checks cover, valid
    /// by its own rule, with the name vendors type it by.
    mutating func nationalNumber() -> (country: String, type: String, scheme: String, value: String) {
        func digits(_ n: Int) -> [Int] { (0..<n).map { _ in gen.int(0...9) } }
        switch gen.int(0...9) {
        case 0:
            var first = gen.choose(Array("ABCEGHJKLMNPRSTWXYZ")), second = gen.choose(Array("ABCEGHJKLMNPRSTWXYZ"))
            // Prefixes never issued.
            while ["BG", "GB", "KN", "NK", "NT", "TN", "ZZ"].contains("\(first)\(second)") { first = gen.choose(Array("ACEHJLMPRSW")); second = gen.choose(Array("ACEHJLMPRSW")) }
            let body = digits(6).map(String.init).joined()
            let spaced = gen.int(0...1) == 0
            let text = spaced ? "\(first)\(second) \(body.prefix(2)) \(body.dropFirst(2).prefix(2)) \(body.suffix(2)) \(gen.choose(["A", "B", "C", "D"]))" : "\(first)\(second)\(body)\(gen.choose(["A", "B", "C", "D"]))"
            return ("GB", "NINO", "nino", text)
        case 1:
            var d = [gen.int(1...7)] + digits(7)
            d.append((0...9).first { Patterns.luhn(d + [$0]) }!)
            let s = d.map(String.init).joined()
            return ("CA", "SIN", "sin", gen.int(0...1) == 0 ? "\(s.prefix(3)) \(s.dropFirst(3).prefix(3)) \(s.suffix(3))" : s)
        case 2:
            let n = gen.int(10_000_000...99_999_999)
            return ("ES", "DNI", "dni", String(n) + String(Array("TRWAGMYFPDXBNJZSQVHLCKE")[n % 23]))
        case 3:
            return ("IT", "CF", "cf", KYCChecks.codiceFiscale(&gen))
        case 4:
            var d = digits(9)
            while Set(d).count == 1 { d = digits(9) }
            for _ in 0..<2 {
                let weights = (2...(d.count + 1)).reversed()
                let sum = Swift.zip(d, weights).reduce(0) { $0 + $1.0 * $1.1 }
                d.append(sum % 11 < 2 ? 0 : 11 - sum % 11)
            }
            let s = d.map(String.init).joined()
            return ("BR", "CPF", "cpf", "\(s.prefix(3)).\(s.dropFirst(3).prefix(3)).\(s.dropFirst(6).prefix(3))-\(s.suffix(2))")
        case 5:
            return ("MX", "CURP", "curp", KYCChecks.curp(&gen))
        case 6:
            let sex = gen.int(1...2), year = gen.int(50...99), month = gen.int(1...12), dept = gen.int(1...95), town = gen.int(1...989), order = gen.int(1...999)
            let body = String(format: "%d%02d%02d%02d%03d%03d", sex, year, month, dept, town, order)
            let key = 97 - Int(body)! % 97
            return ("FR", "NIR", "nir", gen.int(0...1) == 0 ? body + String(format: "%02d", key)
                    : String(format: "%d %02d %02d %02d %03d %03d %02d", sex, year, month, dept, town, order, key))
        case 7:
            var d: [Int]
            repeat { d = [gen.int(1...9)] + digits(8) } while (Swift.zip(d.prefix(8), (2...9).reversed()).reduce(0) { $0 + $1.0 * $1.1 } - d[8]) % 11 != 0
            return ("NL", "BSN", "bsn", d.map(String.init).joined())
        case 8:
            var d: [Int]
            repeat { d = digits(9) } while Swift.zip(d, [1, 4, 3, 7, 5, 8, 6, 9, 10]).reduce(0, { $0 + $1.0 * $1.1 }) % 11 != 0
            let s = d.map(String.init).joined()
            return ("AU", "TFN", "tfn", gen.int(0...1) == 0 ? "\(s.prefix(3)) \(s.dropFirst(3).prefix(3)) \(s.suffix(3))" : s)
        default:
            let body = String(gen.choose(Array("CFGHJKLMNPRTVWXYZ"))) + gen.string("CFGHJKLMNPRTVWXYZ0123456789", count: 8)
            return ("DE", "ID_CARD", "deid", body + String(MRZ.check(body)))
        }
    }

    /// A document check: a passport with its zone, an ID card's three-line
    /// zone, a driver's licence and its state, and national numbers of
    /// several countries, each typed and with its issuing country, which stays.
    mutating func kycDocument() -> PNode {
        let p = person()
        let female = p.gender == "female"
        var expiry = DateComponents(); expiry.year = gen.int(2027...2034); expiry.month = gen.int(1...12); expiry.day = gen.int(10...28)
        let issuer = gen.choose(["USA", "GBR", "CAN", "ESP", "FRA", "ITA", "NLD"])
        let passportNumber = gen.choose(["C", "K", "X", "P"]) + String(gen.int(10_000_000...99_999_999))
        let passportLink = p.link("passport")
        let (line1, line2) = MRZ.passport(issuer: issuer, last: p.last, first: p.first, number: passportNumber, nationality: issuer, birth: p.dob, sex: female ? "F" : "M", expiry: expiry)
        let zone: PNode = gen.int(0...1) == 0
            ? .array([linked(leaf(line1, .pii(.mrz)), p.link("name")), linked(leaf(line2, .pii(.mrz)), p.link("dob"), passportLink)], item: "line")
            : linked(leaf(line1 + "\n" + line2, .pii(.mrz)), p.link("name"), p.link("dob"), passportLink)
        let expiryText = String(format: "%04d-%02d-%02d", expiry.year!, expiry.month!, expiry.day!)
        let passport: PNode = .object([
            (key(["type"]), keep(gen.choose(["PASSPORT", "passport", "P"]))),
            (key(["number"]), linked(leaf(passportNumber, .pii(.passport)), passportLink)),
            (key(["issuing", "country"]), keep(issuer)),
            (key(["date", "of", "birth"]), linked(leaf(Self.formatDate(p.dob, "yyyy-MM-dd"), .pii(.dob), dateFormat: "yyyy-MM-dd"), p.link("dob"))),
            // A document's expiry is its holder's, as a card's is.
            (key(["expiry", "date"]), leaf(expiryText, .pii(.expiry))),
            (key(["mrz"]), zone),
        ])
        // A card's number since 2010: a letter, then letters and digits, digits among them.
        let cardNumber = String(gen.choose(Array("CFGHJKLMNPRTVWXYZ"))) + gen.string("CFGHJKLMNPRTVWXYZ0123456789", count: 4) + gen.string("0123456789", count: 4)
        var cardExpiry = DateComponents(); cardExpiry.year = gen.int(2028...2033); cardExpiry.month = gen.int(1...12); cardExpiry.day = gen.int(10...28)
        let cardLines = MRZ.card(issuer: "D<<", last: p.last, first: p.first, number: cardNumber, nationality: "D<<", birth: p.dob, sex: female ? "F" : "M", expiry: cardExpiry)
        let card: PNode = .object([
            (key(["type"]), keep("ID_CARD")),
            (key(["document", "number"]), leaf(cardNumber, .pii(.passport))),
            (key(["issuing", "country"]), keep("DEU")),
            (key(["mrz"]), .array(cardLines.map { linked(leaf($0, .pii(.mrz)), p.link("name"), p.link("dob")) }, item: "line")),
        ])
        let licenceNumber = gen.choose(["D", "S", "W", "K", "F"]) + String(gen.int(1_000_000...9_999_999))
        let licence: PNode = .object([
            (key(["number"]), leaf(licenceNumber, .pii(.license))),
            // The state that issued it is the authority's: either reading holds.
            (key(gen.choose([["state"], ["issuing", "state"], ["jurisdiction"]])), leaf(p.country == "US" ? p.state : "WA", .ignore)),
            (key(["class"]), keep(gen.choose(["C", "D", "M"]))),
            (key(["expiration", "date"]), leaf(String(format: "%02d/%02d/%04d", gen.int(1...12), gen.int(1...28), gen.int(2027...2032)), .pii(.expiry))),
        ])
        let nationals: [PNode] = (0..<gen.int(2...4)).map { _ in
            let n = nationalNumber()
            var node = PLeaf(text: n.value, truth: .pii(.nationalID))
            node.scheme = n.scheme
            return .object([(key(["country"]), keep(n.country)), (key(["type"]), keep(n.type)), (key(gen.choose([["number"], ["value"], ["id", "number"]])), .leaf(node))])
        }
        var documents: [(String, PNode)] = [(key(["passport"]), passport), (key(["drivers", "license"]), licence), (key(["national", "ids"]), .array(nationals, item: "id"))]
        if gen.int(0...1) == 0 { documents.append((key(["id", "card"]), card)) }
        return .object([
            (key(["verification", "id"]), keep(id("dv"))),
            (key(["status"]), keep(status())),
            (key(["documents"]), .object(gen.shuffled(documents))),
            (key(["checks"]), .object(verdicts(["mrz", "face", "expiry"]) + [(key(["mrz", "checksum", "valid"]), .bool(true)), (key(["document", "expired"]), .bool(false))])),
            (key(["issued", "at"]), timestamp()),
        ])
    }

    // MARK: Bank, phones, IPs and devices

    mutating func kycBank() -> PNode {
        let p = person()
        let place = addressLink()
        var routing = [0, gen.int(1...9)] + (0..<6).map { _ in gen.int(0...9) }
        routing.append((0...9).first { d in let r = routing + [d]; return (3 * (r[0] + r[3] + r[6]) + 7 * (r[1] + r[4] + r[7]) + r[2] + r[5] + r[8]) % 10 == 0 }!)
        let ibanCountry = gen.choose(["DE", "GB", "FR", "NL", "ES", "IT"])
        let iban = KYCChecks.iban(ibanCountry, &gen)
        let ibanText = gen.int(0...1) == 0 ? iban : stride(from: 0, to: iban.count, by: 4).map { i in String(iban.dropFirst(i).prefix(4)) }.joined(separator: " ")
        let sortCode = String(format: "%02d-%02d-%02d", gen.int(10...99), gen.int(0...99), gen.int(0...99))
        let deviceID = UUID(uuid: (0..<16).reduce(into: [UInt8]()) { a, _ in a.append(UInt8(gen.int(0...255))) }.withUnsafeBytes { $0.load(as: uuid_t.self) }).uuidString
        let fingerprint = gen.string("0123456789abcdef", count: gen.choose([32, 40, 64]))
        let national = "(\(p.phoneDigits.prefix(3))) \(p.phoneDigits.dropFirst(3).prefix(3))-\(p.phoneDigits.suffix(4))"
        let phones: [PNode] = [
            .object([(key(["number"]), linked(leaf("+1" + p.phoneDigits, .pii(.phone)), p.link("phone"))), (key(["type"]), keep("mobile")), (key(["carrier"]), keep(gen.choose(["Northwind Wireless", "Bluebird Mobile"]))), (key(["line", "type"]), keep("MOBILE"))]),
            .object([(key(["number"]), linked(leaf(national, .pii(.phone)), p.link("phone"))), (key(["type"]), keep("home")), (key(["valid"]), .bool(true))]),
        ]
        let abroadPhone = gen.choose(["+44 20 7946 \(gen.int(1000...9999))", "+49 30 \(gen.int(1_000_000...9_999_999))", "+33 6 \(gen.int(10...99)) \(gen.int(10...99)) \(gen.int(10...99)) \(gen.int(10...99))", "+52 55 \(gen.int(1000...9999)) \(gen.int(1000...9999))"])
        return .object([
            (key(["request", "id"]), keep(id("req"))),
            (key(["account"]), .object([
                (key(["holder", "name"]), linked(leaf(p.full, .pii(.fullName)), p.link("name"))),
                (key(["routing", "number"]), leaf(routing.map(String.init).joined(), .pii(.routing))),
                (key(["account", "number"]), linked(leaf(p.account, .pii(.account)), p.link("account"))),
                (key(["account", "mask"]), linked(leaf(String(p.account.suffix(4)), .pii(.lastDigits)), p.link("account"))),
                (key(["iban"]), leaf(ibanText, .pii(.iban))),
                (key(["sort", "code"]), leaf(sortCode, .pii(.sortCode))),
                (key(["bic"]), keep(gen.choose(["EXMPGB2L", "QLMRDEFF", "NRTHFRPP"]))),
                (key(["currency"]), keep(gen.choose(["USD", "EUR", "GBP"]))),
                (key(["balance"]), keep(String(format: "%.2f", Double(gen.int(100...900_000)) / 100), number: true)),
                (key(["ownership", "match"]), keep(gen.choose(["MATCH", "Y", "PARTIAL"]))),
            ])),
            (key(["phones"]), .array(phones, item: "phone")),
            (key(["alternate", "phone"]), leaf(abroadPhone, .pii(.phone))),
            (key(["address"]), linked(.object([
                (key(["line1"]), leaf(p.street, .pii(.street))),
                (key(["city"]), leaf(p.city, .pii(.city))),
                (key(["state"]), region(p)),
                (key(["postal", "code"]), leaf(p.zip, .pii(.zip))),
                (key(["country"]), country(p)),
            ]), place)),
            (key(["device"]), .object([
                (key(["ip", "address"]), leaf(p.ip, .pii(.ip))),
                (key(["device", "id"]), leaf(gen.int(0...1) == 0 ? deviceID : deviceID.lowercased(), .pii(.deviceID))),
                (key(["fingerprint"]), leaf(fingerprint, .pii(.deviceID))),
                (key(["user", "agent"]), keep(gen.choose(Self.userAgents))),
                (key(["ip", "risk"]), .object([(key(["proxy"]), .bool(false)), (key(["vpn"]), .bool(false)), (key(["country"]), keep(p.country)), (key(["score"]), keep(String(gen.int(0...100)), number: true))])),
            ])),
            (key(["decision"]), .object(verdicts(["account", "phone", "ip"]) + [(key(["outcome"]), keep(gen.choose(["ACCEPT", "REVIEW", "DECLINE"]))), (key(["amount"]), keep(String(format: "%.2f", Double(gen.int(500...500_000)) / 100), number: true))])),
            (key(["created", "at"]), timestamp()),
        ])
    }
}

/// Checks and makers for the identifiers above, written from each scheme's
/// published rule rather than taken from the scrubber's recognizers.
enum KYCChecks {
    static func ssn(_ value: String) -> Bool {
        let d = value.filter(\.isNumber)
        guard d.count == 9, let area = Int(d.prefix(3)), let group = Int(d.dropFirst(3).prefix(2)), let serial = Int(d.suffix(4)) else { return false }
        return area != 0 && area != 666 && area < 900 && group != 0 && serial != 0
    }
    static func itin(_ value: String) -> Bool {
        let d = value.filter(\.isNumber)
        guard d.count == 9, d.first == "9", let group = Int(d.dropFirst(3).prefix(2)) else { return false }
        return (50...65).contains(group) || (70...88).contains(group) || (90...92).contains(group) || (94...99).contains(group)
    }
    static func aba(_ value: String) -> Bool {
        let r = value.compactMap(\.wholeNumberValue)
        return r.count == 9 && (3 * (r[0] + r[3] + r[6]) + 7 * (r[1] + r[4] + r[7]) + r[2] + r[5] + r[8]) % 10 == 0
    }
    static func ibanValid(_ value: String) -> Bool {
        let s = value.filter { $0 != " " }.uppercased()
        guard s.count >= 15, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        return mod97(String(s.dropFirst(4) + s.prefix(4))) == 1
    }
    static func mod97(_ s: String) -> Int {
        s.reduce(0) { r, c in
            let n = c.isNumber ? String(c) : String(Int(c.asciiValue!) - 55)
            return n.reduce(r) { ($0 * 10 + $1.wholeNumberValue!) % 97 }
        }
    }
    static let ibanLengths = ["DE": 22, "GB": 22, "FR": 27, "NL": 18, "ES": 24, "IT": 27]
    static func iban(_ country: String, _ gen: inout Gen) -> String {
        let length = ibanLengths[country]!
        var bban: String
        switch country {
        case "GB": bban = gen.string("ABCDEFGHIJKLMNOPQRSTUVWXYZ", count: 4) + gen.string("0123456789", count: 14)
        case "NL": bban = gen.string("ABCDEFGHIJKLMNOPQRSTUVWXYZ", count: 4) + gen.string("0123456789", count: 10)
        case "IT": bban = gen.string("ABCDEFGHIJKLMNOPQRSTUVWXYZ", count: 1) + gen.string("0123456789", count: 22)
        default: bban = gen.string("0123456789", count: length - 4)
        }
        let check = 98 - mod97(bban + country + "00")
        return country + String(format: "%02d", check) + bban
    }
    static func nino(_ value: String) -> Bool {
        let s = value.filter { $0 != " " }.uppercased()
        guard s.range(of: #"^[A-CEGHJ-PR-TW-Z][A-CEGHJ-NPR-TW-Z]\d{6}[A-D]$"#, options: .regularExpression) != nil else { return false }
        return !["BG", "GB", "KN", "NK", "NT", "TN", "ZZ"].contains(String(s.prefix(2)))
    }
    static func dni(_ value: String) -> Bool {
        guard value.count == 9, let n = Int(value.prefix(8)), let letter = value.last else { return false }
        return Array("TRWAGMYFPDXBNJZSQVHLCKE")[n % 23] == letter
    }
    static func cpf(_ value: String) -> Bool {
        let d = value.compactMap(\.wholeNumberValue)
        guard d.count == 11, Set(d).count > 1 else { return false }
        for n in [9, 10] {
            let sum = zip(d.prefix(n), (2...(n + 1)).reversed()).reduce(0) { $0 + $1.0 * $1.1 }
            if d[n] != (sum % 11 < 2 ? 0 : 11 - sum % 11) { return false }
        }
        return true
    }
    static func nir(_ value: String) -> Bool {
        let d = value.filter(\.isNumber)
        guard d.count == 15, let body = Int(d.prefix(13)), let key = Int(d.suffix(2)), let month = Int(d.dropFirst(3).prefix(2)) else { return false }
        return ["1", "2"].contains(d.first!) && (1...12).contains(month) && key == 97 - body % 97
    }
    static func bsn(_ value: String) -> Bool {
        let d = value.compactMap(\.wholeNumberValue)
        return d.count == 9 && (zip(d.prefix(8), (2...9).reversed()).reduce(0) { $0 + $1.0 * $1.1 } - d[8]) % 11 == 0
    }
    static func tfn(_ value: String) -> Bool {
        let d = value.compactMap(\.wholeNumberValue)
        return d.count == 9 && zip(d, [1, 4, 3, 7, 5, 8, 6, 9, 10]).reduce(0, { $0 + $1.0 * $1.1 }) % 11 == 0
    }
    static func deID(_ value: String) -> Bool {
        value.count == 10 && value.allSatisfy { "CFGHJKLMNPRTVWXYZ0123456789".contains($0) } && MRZ.check(value.prefix(9)) == value.last
    }

    // The codice fiscale's check letter: odd places (counted from one) and even ones weigh differently.
    static let cfOdd: [Character: Int] = {
        let values = [1, 0, 5, 7, 9, 13, 15, 17, 19, 21, 2, 4, 18, 20, 11, 3, 6, 8, 12, 14, 16, 10, 22, 25, 24, 23]
        var map: [Character: Int] = [:]
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { map[c] = values[i] }
        for (i, c) in "0123456789".enumerated() { map[c] = values[i] }
        return map
    }()
    static func cfCheck(_ body: String) -> Character {
        let sum = body.enumerated().reduce(0) { total, item in
            let c = item.element
            if item.offset % 2 == 0 { return total + cfOdd[c]! }
            return total + (c.wholeNumberValue ?? Int(c.asciiValue! - 65))
        }
        return Character(UnicodeScalar(UInt8(65 + sum % 26)))
    }
    static func cf(_ value: String) -> Bool {
        let s = value.uppercased()
        guard s.range(of: #"^[A-Z]{6}\d{2}[ABCDEHLMPRST]\d{2}[A-Z]\d{3}[A-Z]$"#, options: .regularExpression) != nil else { return false }
        return cfCheck(String(s.prefix(15))) == s.last
    }
    static func codiceFiscale(_ gen: inout Gen) -> String {
        let consonants = "BCDFGHLMNPRSTVZ"
        let day = gen.int(1...28) + (gen.int(0...1) == 0 ? 0 : 40)
        let body = gen.string(consonants, count: 6) + String(format: "%02d", gen.int(50...99)) + String(gen.choose(Array("ABCDEHLMPRST"))) + String(format: "%02d", day)
            + String(gen.choose(Array("ABCDEFGHL"))) + String(format: "%03d", gen.int(100...999))
        return body + String(cfCheck(body))
    }

    static let curpAlphabet = Array("0123456789ABCDEFGHIJKLMNÑOPQRSTUVWXYZ")
    static func curpCheck(_ body: String) -> Int {
        let sum = body.enumerated().reduce(0) { $0 + (curpAlphabet.firstIndex(of: $1.element) ?? 0) * (18 - $1.offset) }
        return (10 - sum % 10) % 10
    }
    static func curp(_ value: String) -> Bool {
        guard value.range(of: #"^[A-Z][AEIOUX][A-Z]{2}\d{2}(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])[HM][A-Z]{2}[B-DF-HJ-NP-TV-Z]{3}[A-Z\d]\d$"#, options: .regularExpression) != nil else { return false }
        return curpCheck(String(value.prefix(17))) == value.last!.wholeNumberValue
    }
    static func curp(_ gen: inout Gen) -> String {
        let body = gen.string("BCDFGJLMPRSTV", count: 1) + gen.string("AEIOU", count: 1) + gen.string("BCDFGJLMPRSTV", count: 2)
            + String(format: "%02d%02d%02d", gen.int(50...99), gen.int(1...12), gen.int(1...28)) + gen.choose(["H", "M"]) + gen.choose(["DF", "JC", "NL", "PL", "GT"])
            + gen.string("BCDFGJLMNPRSTVZ", count: 3) + "0"
        return body + String(curpCheck(body))
    }

    /// Whether `value` is valid under the scheme a generated national number was made by.
    static func valid(_ scheme: String, _ value: String) -> Bool {
        switch scheme {
        case "nino": return nino(value)
        case "sin": return Patterns.luhn(value.compactMap(\.wholeNumberValue)) && value.filter(\.isNumber).count == 9
        case "dni": return dni(value)
        case "cf": return cf(value)
        case "cpf": return cpf(value)
        case "curp": return curp(value)
        case "nir": return nir(value)
        case "bsn": return bsn(value)
        case "tfn": return tfn(value)
        case "deid": return deID(value)
        default: return true
        }
    }
}
