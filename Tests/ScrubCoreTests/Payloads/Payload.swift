import Foundation
@testable import ScrubCore

/// What a generated value is, decided when it is made, never by asking the
/// scrubber's own key table. The payload tests hold the scrubber to this.
enum Kind: String {
    case fullName, firstName, lastName, middleName, email, phone, ssn, ssnLast4, taxID, dob, dobYear
    case street, city, zip, ip, card, account, license, passport, username
    case region, unit, addressLine, latitude, longitude, lastDigits, age, initials
    var isName: Bool { [.fullName, .firstName, .lastName, .middleName].contains(self) }
}

enum Truth: Equatable {
    case pii(Kind)
    /// Must come out byte for byte: IDs, statuses, timestamps, amounts, enums, URLs.
    case keep
    /// Should come out unchanged, but a reader could take it either way on its
    /// own (a company name, a ten-digit order number). Measured, not failed.
    case keepSoft
    case ignore
}

struct PLeaf {
    var text: String
    var number = false
    var truth: Truth
    var dateFormat: String? = nil
    /// Values that must agree after scrubbing: one person's name, email,
    /// username and initials ("p1.name"), a birth date and its year and age
    /// ("p1.dob"), a number and its last digits ("p1.ssn"), or one address's
    /// parts with the time zone and phone number beside it ("a3").
    var links: [String] = []
}

enum PNode {
    indirect case object([(String, PNode)])
    /// `item` is the element name an XML rendering gives each member.
    indirect case array([PNode], item: String)
    case leaf(PLeaf)
    case bool(Bool)
    case null
}

struct PathLeaf {
    let path: [Int]
    let keys: [String]
    let leaf: PLeaf
    var key: String { keys.last ?? "" }
}

extension PNode {
    func leaves(path: [Int] = [], keys: [String] = []) -> [PathLeaf] {
        switch self {
        case .object(let pairs):
            return pairs.enumerated().flatMap { index, pair in pair.1.leaves(path: path + [index], keys: keys + [pair.0]) }
        case .array(let members, _):
            return members.enumerated().flatMap { index, member in member.leaves(path: path + [index], keys: keys) }
        case .leaf(let leaf): return [PathLeaf(path: path, keys: keys, leaf: leaf)]
        default: return []
        }
    }
}

struct Person {
    var id: Int, gender: String
    var first: String, middle: String, last: String
    var email: String, phone: String, phoneDigits: String
    var ssn: String, dob: DateComponents, street: String, streetName: String
    var city: String, state: String, stateName: String, country: String, latitude: String, longitude: String
    var zip: String, ip: String, username: String
    var card: String, account: String, license: String, passport: String
    var full: String { first + " " + last }
    func link(_ what: String) -> String { "p\(id).\(what)" }
}

enum KeyStyle { case snake, camel, pascal, kebab, upper }

struct PayloadGen {
    var gen: Gen
    var style: KeyStyle
    var used: Set<String> = []
    init(seed: UInt64) {
        gen = Gen(seed: seed)
        style = .snake
        style = [KeyStyle.snake, .snake, .snake, .camel, .camel, .camel, .pascal, .kebab, .upper][gen.int(0...8)]
    }

    // Given and family names from many places, common and rare. Most are
    // missing from the scrubber's name lists on purpose.
    // f, m, or either.
    static let firsts: [(String, String)] = [("Oluwaseun", "x"), ("Siobhan", "f"), ("Thandiwe", "f"), ("Mateo", "m"), ("Priyanka", "f"), ("Jiwon", "x"), ("Aurelio", "m"), ("Nkechi", "f"), ("Ingrid", "f"), ("Tomasz", "m"), ("Farah", "f"), ("Declan", "m"), ("Yuki", "x"), ("Rosalind", "f"), ("Bartholomew", "m"), ("Esperanza", "f"), ("Kwame", "m"), ("Linnea", "f"), ("Anneliese", "f"), ("Joaquín", "m"), ("Jennifer", "f"), ("Michael", "m"), ("Maria", "f"), ("Deshawn", "m"), ("Marisol", "f"), ("Callum", "m"), ("Ifeoma", "f"), ("Rasmus", "m"), ("Leilani", "f"), ("Anouk", "f")]
    static let middles = ["Adaeze", "Louise", "Tobias", "Marguerite", "Ximena", "Emeka"]
    static let lasts = ["Adeyemi", "Nguyen", "Okafor", "Castellanos", "Venkataraman", "Brightwater", "Kowalczyk", "Haddad", "O'Sullivan", "Abernathy", "Lindqvist", "Montgomery-Reyes", "Takahashi", "Delacroix", "Smith", "Garcia", "Oyelaran", "Szymanski", "Achterberg", "Mbeki", "Quispe", "Thorsdottir"]
    static let streets = ["Juniper Hollow Rd", "Tamarack Ln", "Cobblestone Ct", "Larkspur Ave", "Wexford Dr", "Pinecrest Blvd", "Ashbury Way", "Heron Point Rd"]
    /// Real places with their region, postcode and centre, written out here
    /// rather than taken from the scrubber's own table.
    struct City { let name: String, region: String, regionName: String, postal: String, latitude: String, longitude: String, country: String }
    static let usCities = [City(name: "Tacoma", region: "WA", regionName: "Washington", postal: "98402", latitude: "47.2529", longitude: "-122.4443", country: "US"),
                           City(name: "Boise", region: "ID", regionName: "Idaho", postal: "83702", latitude: "43.6187", longitude: "-116.2146", country: "US"),
                           City(name: "Duluth", region: "MN", regionName: "Minnesota", postal: "55802", latitude: "46.7867", longitude: "-92.1005", country: "US"),
                           City(name: "Chattanooga", region: "TN", regionName: "Tennessee", postal: "37402", latitude: "35.0456", longitude: "-85.3097", country: "US"),
                           City(name: "Bakersfield", region: "CA", regionName: "California", postal: "93301", latitude: "35.3733", longitude: "-119.0187", country: "US"),
                           City(name: "Worcester", region: "MA", regionName: "Massachusetts", postal: "01608", latitude: "42.2626", longitude: "-71.8023", country: "US"),
                           City(name: "Albuquerque", region: "NM", regionName: "New Mexico", postal: "87102", latitude: "35.0844", longitude: "-106.6504", country: "US"),
                           City(name: "Spokane", region: "WA", regionName: "Washington", postal: "99201", latitude: "47.6588", longitude: "-117.4260", country: "US")]
    static let otherCities = [City(name: "Mississauga", region: "ON", regionName: "Ontario", postal: "L5B 3C2", latitude: "43.5890", longitude: "-79.6441", country: "CA"),
                              City(name: "Surrey", region: "BC", regionName: "British Columbia", postal: "V3T 0A3", latitude: "49.1913", longitude: "-122.8490", country: "CA"),
                              City(name: "Sheffield", region: "England", regionName: "England", postal: "S1 2HE", latitude: "53.3811", longitude: "-1.4701", country: "GB"),
                              City(name: "Liverpool", region: "England", regionName: "England", postal: "L1 8JQ", latitude: "53.4084", longitude: "-2.9916", country: "GB"),
                              City(name: "Geelong", region: "VIC", regionName: "Victoria", postal: "3220", latitude: "-38.1499", longitude: "144.3617", country: "AU"),
                              City(name: "Newcastle", region: "NSW", regionName: "New South Wales", postal: "2300", latitude: "-32.9283", longitude: "151.7817", country: "AU")]
    static let areaCodes = ["206", "312", "646", "512", "719", "404", "971", "615"]

    mutating func unique(_ make: (inout PayloadGen) -> String) -> String {
        for _ in 0..<50 {
            let value = make(&self)
            if used.insert(value).inserted { return value }
        }
        return make(&self)
    }

    var nextPerson = 0
    var nextAddress = 0
    mutating func addressLink() -> String { nextAddress += 1; return "a\(nextAddress)" }
    mutating func person() -> Person {
        let first = unique { $0.gen.choose(Self.firsts.map(\.0)) }
        let marked = Self.firsts.first { $0.0 == first }?.1 ?? "x"
        let gender = marked == "f" ? "female" : marked == "m" ? "male" : gen.choose(["female", "male"])
        nextPerson += 1
        let last = unique { $0.gen.choose(Self.lasts) }
        let middle = gen.choose(Self.middles)
        let ascii = { (s: String) in s.folding(options: .diacriticInsensitive, locale: nil).lowercased().filter { $0.isLetter } }
        let domain = gen.choose(["gmail.com", "outlook.com", "icloud.com", "proton.me", "fastmail.com"])
        let email = [ascii(first) + "." + ascii(last), String(ascii(first).prefix(1)) + ascii(last) + String(gen.int(10...99)), ascii(last) + "_" + ascii(first)][gen.int(0...2)] + "@" + domain
        let area = gen.choose(Self.areaCodes)
        let exchange = String(gen.int(234...987)), line = String(format: "%04d", gen.int(1000...9899))
        let phoneDigits = area + exchange + line
        let international = ["+44 20 7946 \(String(format: "%04d", gen.int(1000...9999)))", "+49 30 \(gen.int(1_000_000...9_999_999))", "+61 2 \(gen.int(1000...9999)) \(gen.int(1000...9999))", "+52 55 \(gen.int(1000...9999)) \(gen.int(1000...9999))"]
        let phone = ["(\(area)) \(exchange)-\(line)", "\(area)-\(exchange)-\(line)", "+1 \(area) \(exchange) \(line)", "+1\(phoneDigits)", "\(area).\(exchange).\(line)", gen.choose(international)][gen.int(0...5)]
        let ssnArea = gen.int(101...665), group = gen.int(10...99), serial = gen.int(1000...9999)
        let ssn = String(format: "%03d-%02d-%04d", ssnArea, group, serial)
        var dob = DateComponents()
        dob.year = gen.int(1950...2004); dob.month = gen.int(1...12); dob.day = gen.int(10...28)
        let city = gen.int(0...4) == 0 ? gen.choose(Self.otherCities) : gen.choose(Self.usCities)
        let streetName = gen.choose(Self.streets)
        let street = "\(gen.int(1200...9899)) \(streetName)"
        let ip = gen.int(0...3) == 0 ? "2600:1700:\(String(gen.int(4096...65535), radix: 16)):\(String(gen.int(4096...65535), radix: 16))::\(String(gen.int(16...255), radix: 16))"
            : "\(gen.choose([73, 98, 174, 24, 68])).\(gen.int(10...250)).\(gen.int(10...250)).\(gen.int(10...250))"
        let username = String(ascii(first).prefix(1)) + ascii(last) + String(gen.int(70...99))
        var cardDigits = [gen.choose([4, 5])] + (0..<14).map { _ in gen.int(0...9) }
        cardDigits.append((0...9).first { Patterns.luhn(cardDigits + [$0]) }!)
        let cardString = cardDigits.map(String.init).joined()
        let card = gen.int(0...1) == 0 ? cardString : stride(from: 0, to: 16, by: 4).map { i in String(cardString.dropFirst(i).prefix(4)) }.joined(separator: " ")
        let account = (0..<gen.int(10...12)).map { _ in String(gen.int(0...9)) }.joined()
        let license = gen.choose(["D", "S", "W", "K"]) + (0..<7).map { _ in String(gen.int(0...9)) }.joined()
        let passport = String(gen.int(500_000_000...599_999_999))
        return Person(id: nextPerson, gender: gender, first: first, middle: middle, last: last, email: email, phone: phone, phoneDigits: phoneDigits, ssn: ssn, dob: dob,
                      street: street, streetName: streetName, city: city.name, state: city.region, stateName: city.regionName, country: city.country,
                      latitude: city.latitude, longitude: city.longitude, zip: city.postal, ip: ip, username: username,
                      card: card, account: account, license: license, passport: passport)
    }

    // MARK: Keys

    func key(_ words: [String]) -> String {
        switch style {
        case .snake: return words.joined(separator: "_")
        case .kebab: return words.joined(separator: "-")
        case .upper: return words.joined(separator: "_").uppercased()
        case .camel: return words.enumerated().map { $0.offset == 0 ? $0.element : $0.element.capitalized }.joined()
        case .pascal: return words.map(\.capitalized).joined()
        }
    }

    func plural(_ word: String) -> String { word.hasSuffix("s") ? word + "es" : word.hasSuffix("y") ? String(word.dropLast()) + "ies" : word + "s" }

    // MARK: Values

    func leaf(_ text: String, _ truth: Truth, number: Bool = false, dateFormat: String? = nil) -> PNode {
        .leaf(PLeaf(text: text, number: number, truth: truth, dateFormat: dateFormat))
    }
    func keep(_ text: String, number: Bool = false) -> PNode { leaf(text, .keep, number: number) }
    /// The same node, its leaves joined to the given relations.
    func linked(_ node: PNode, _ links: String...) -> PNode {
        switch node {
        case .leaf(var leaf): leaf.links += links; return .leaf(leaf)
        case .object(let pairs): return .object(pairs.map { ($0.0, linked($0.1, links)) })
        case .array(let members, let item): return .array(members.map { linked($0, links) }, item: item)
        default: return node
        }
    }
    func linked(_ node: PNode, _ links: [String]) -> PNode {
        switch node {
        case .leaf(var leaf): leaf.links += links; return .leaf(leaf)
        case .object(let pairs): return .object(pairs.map { ($0.0, linked($0.1, links)) })
        case .array(let members, let item): return .array(members.map { linked($0, links) }, item: item)
        default: return node
        }
    }

    mutating func dob(_ person: Person) -> PNode {
        let format = gen.choose(["yyyy-MM-dd", "yyyy-MM-dd", "MM/dd/yyyy", "dd/MM/yyyy", "MMMM d, yyyy", "yyyyMMdd", "d MMM yyyy"])
        return linked(leaf(Self.formatDate(person.dob, format), .pii(.dob), dateFormat: format), person.link("dob"))
    }
    /// An age as of today, from the birth date.
    static func age(_ person: Person) -> Int {
        let now = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date())
        let before = (now.month!, now.day!) < (person.dob.month!, person.dob.day!)
        return now.year! - person.dob.year! - (before ? 1 : 0)
    }
    static func formatDate(_ components: DateComponents, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return formatter.string(from: calendar.date(from: components)!)
    }
    mutating func ssn(_ person: Person) -> PNode {
        switch gen.int(0...5) {
        case 0: return linked(leaf(person.ssn.filter(\.isNumber), .pii(.ssn), number: true), person.link("ssn"))
        case 1, 2: return linked(leaf(person.ssn.filter(\.isNumber), .pii(.ssn)), person.link("ssn"))
        default: return linked(leaf(person.ssn, .pii(.ssn)), person.link("ssn"))
        }
    }
    mutating func phone(_ person: Person) -> PNode {
        linked(gen.int(0...7) == 0 ? leaf(person.phoneDigits, .pii(.phone), number: gen.int(0...1) == 0) : leaf(person.phone, .pii(.phone)), person.link("phone"))
    }
    mutating func zip(_ person: Person) -> PNode {
        switch gen.int(0...5) {
        case 0 where person.country != "US": return leaf(person.zip, .pii(.zip))
        case 0: return leaf(person.zip + "-" + String(gen.int(1000...9899)), .pii(.zip))
        case 1 where !person.zip.hasPrefix("0") && person.country != "CA" && person.country != "GB": return leaf(person.zip, .pii(.zip), number: true)
        default: return leaf(person.zip, .pii(.zip))
        }
    }
    mutating func id(_ prefix: String) -> String {
        let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
        return gen.int(0...3) == 0 ? UUID(uuid: (0..<16).reduce(into: [UInt8]()) { a, _ in a.append(UInt8(gen.int(0...255))) }.withUnsafeBytes { $0.load(as: uuid_t.self) }).uuidString.lowercased()
            : prefix + "_" + gen.string(alphabet, count: gen.int(12...20))
    }
    mutating func timestamp() -> PNode {
        let date = String(format: "%04d-%02d-%02d", gen.int(2022...2026), gen.int(1...12), gen.int(1...28))
        let time = String(format: "%02d:%02d:%02d", gen.int(0...23), gen.int(0...59), gen.int(0...59))
        switch gen.int(0...3) {
        case 0: return keep("\(date)T\(time)Z")
        case 1: return keep("\(date)T\(time).\(gen.int(100...999))\(gen.choose(["-05:00", "+00:00", "+02:00"]))")
        case 2: return keep(String(gen.int(1_650_000_000...1_790_000_000)), number: true)
        default: return keep("\(date) \(time)")
        }
    }
    mutating func status() -> String {
        let values = ["approved", "declined", "pending_review", "succeeded", "requires_action", "verified", "in_progress", "completed", "accept", "refer"]
        let value = gen.choose(values)
        return gen.int(0...2) == 0 ? value.uppercased() : value
    }
    mutating func matchStatus() -> String {
        let value = gen.choose(["match", "no_match", "partial_match", "not_found", "mismatch", "verified", "unverified", "unavailable", "fuzzy_match", "exact"])
        return gen.int(0...1) == 0 ? value.uppercased() : value
    }
    static let userAgents = ["Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
                             "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
                             "okhttp/4.12.0", "python-requests/2.32.3", "PostmanRuntime/7.39.0"]
    static let companies = ["Northwind Traders LLC", "Harborview Logistics Inc.", "Bluebird Dental Group", "Cascade Mountain Outfitters", "Riverside Community Credit Union"]
    static let titles = ["Senior Accountant", "Staff Engineer", "Registered Nurse", "Operations Manager", "Customer Success Lead"]
    static let departments = ["Finance", "Engineering", "Operations", "Human Resources", "Sales"]
}
