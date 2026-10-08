import Foundation
@testable import ScrubCore
import Testing

// Identity check requests: one test per fault the identity shape found, on
// fixed, invented inputs.

private func scrub(_ text: String, as name: String, seed: UInt64 = 5) throws -> String {
    String(decoding: try Scrubber.scrub(Data(text.utf8), name: name, forceFullDetection: false, seed: seed).output, as: UTF8.self)
}
private func value(_ output: String, _ path: String...) throws -> String {
    var node = try OrderedJSON.parse(output.firstIndex(of: "{").map { String(output[$0...output.lastIndex(of: "}")!]) } ?? output)
    for key in path {
        switch node {
        case .object(let pairs): node = try #require(pairs.first { $0.0 == key }?.1, "no \(key)")
        case .array(let members): node = members[Int(key)!]
        default: Issue.record("no \(key)")
        }
    }
    switch node {
    case .string(let s): return s
    case .number(let n): return n
    default: return ""
    }
}

private let birth = DateComponents(year: 1981, month: 9, day: 23)
private let expiry = DateComponents(year: 2031, month: 4, day: 17)
private let zone = MRZ.passport(issuer: "ITA", last: "Brightwater", first: "Rosalind", number: "YB4417203", nationality: "ITA", birth: birth, sex: "F", expiry: expiry)
private let request = """
{
  "CountryCode": "IT",
  "DataFields": {
    "PersonInfo": {"FirstGivenName": "Rosalind", "FirstSurName": "Brightwater", "DayOfBirth": 23, "MonthOfBirth": 9, "YearOfBirth": 1981},
    "Location": {
      "BuildingNumber": "37",
      "UnitNumber": "4",
      "StreetName": "VIA SAN BIAGIO",
      "City": "BOLOGNA",
      "StateProvinceCode": "BO",
      "PostalCode": "40126",
      "AdditionalFields": {"Address1": "VIA SAN BIAGIO 37/4"}
    },
    "DriverLicence": {"Number": "BO4471230K", "State": "BO"},
    "NationalIds": [{"Number": "BRGRSL81P63A944T", "Type": "NationalID"}],
    "Passport": {"Mrz1": "\(zone.0)", "Mrz2": "\(zone.1)", "Number": "YB4417203"}
  }
}
"""

@Test(arguments: ["request.json", "request.txt"])
func splitAddressAgreesWithItsLine(_ name: String) throws {
    let output = try scrub(name.hasSuffix(".txt") ? "curl -X POST https://api.example.com/v3/verify -d '\(request)'" : request, as: name)
    let street = try value(output, "DataFields", "Location", "StreetName"), number = try value(output, "DataFields", "Location", "BuildingNumber")
    let unit = try value(output, "DataFields", "Location", "UnitNumber"), line = try value(output, "DataFields", "Location", "AdditionalFields", "Address1")
    #expect(street != "VIA SAN BIAGIO" && !output.contains("BIAGIO"))
    #expect(number != "37" && unit != "4")
    #expect(line == "\(street) \(number)/\(unit)", "line \(line) is not \(street) \(number)/\(unit)")
}

/// "country_code": "IT" at the top places the address two objects down: an
/// Italian city with its own province and a postcode written the same way.
@Test(arguments: ["request.json", "request.txt"])
func addressAbroadStaysInItsCountry(_ name: String) throws {
    let output = try scrub(name.hasSuffix(".txt") ? "curl -X POST https://api.example.com/v3/verify -d '\(request)'" : request, as: name)
    let city = try value(output, "DataFields", "Location", "City"), province = try value(output, "DataFields", "Location", "StateProvinceCode")
    let postal = try value(output, "DataFields", "Location", "PostalCode")
    let place = try #require(Places.abroad.first { $0.city.uppercased() == city }, "\(city) is no city abroad")
    #expect(place.country == "IT" && city != "BOLOGNA")
    #expect(province == place.region)
    #expect(postal.count == 5 && postal.allSatisfy(\.isNumber) && postal != "40126")
}

/// A document's number under a bare "number" key is replaced as its document is.
@Test(arguments: ["request.json", "request.txt"])
func documentNumbersUnderBareKeysAreReplaced(_ name: String) throws {
    let output = try scrub(name.hasSuffix(".txt") ? "curl -X POST https://api.example.com/v3/verify -d '\(request)'" : request, as: name)
    for original in ["BO4471230K", "BRGRSL81P63A944T", "YB4417203"] { #expect(!output.contains(original), "\(original) left") }
    #expect(try value(output, "DataFields", "NationalIds", "0", "Number").count == 16)
}

/// A passport's zone names the stand-in person, writes the stand-in passport
/// number and birth date, and its check digits still add up.
@Test(arguments: ["request.json", "request.txt"])
func passportZoneFollowsItsHolder(_ name: String) throws {
    let output = try scrub(name.hasSuffix(".txt") ? "curl -X POST https://api.example.com/v3/verify -d '\(request)'" : request, as: name)
    let line1 = try value(output, "DataFields", "Passport", "Mrz1"), line2 = try value(output, "DataFields", "Passport", "Mrz2")
    let first = try value(output, "DataFields", "PersonInfo", "FirstGivenName"), last = try value(output, "DataFields", "PersonInfo", "FirstSurName")
    #expect(line1 != zone.0 && line2 != zone.1 && !output.contains("BRIGHTWATER"))
    #expect(MRZ.misfit(zone.0 + "\n" + zone.1, line1 + "\n" + line2) == nil, "\(line1) \(line2)")
    let written = try #require(MRZ.writtenName(line1))
    #expect(written.last == MRZ.fold(last).filter(\.isLetter) && written.first == MRZ.fold(first))
    #expect(MRZ.data(line2).number == (try value(output, "DataFields", "Passport", "Number")))
    let day = try value(output, "DataFields", "PersonInfo", "DayOfBirth"), month = try value(output, "DataFields", "PersonInfo", "MonthOfBirth"), year = try value(output, "DataFields", "PersonInfo", "YearOfBirth")
    #expect(MRZ.data(line2).birth == String(format: "%02d%02d%02d", Int(year)! % 100, Int(month)!, Int(day)!))
}

/// A zone pasted into a note, with no key to say what it is, is still found and rewritten whole.
@Test func zoneInTextIsFound() throws {
    let card = MRZ.card(issuer: "D<<", last: "Achterberg", first: "Linnea", number: "LK7731905", nationality: "D<<", birth: birth, sex: "F", expiry: expiry)
    let note = "Scanned at the counter:\n\(card.joined(separator: "\n"))\nPlease attach to the file.\n"
    let output = try scrub(note, as: "note.txt")
    #expect(!output.contains("ACHTERBERG") && !output.contains("LK7731905"))
    let lines = output.split(separator: "\n").map(String.init).filter { $0.count == 30 }
    #expect(lines.count == 3 && MRZ.misfit(card.joined(separator: "\n"), lines.joined(separator: "\n")) == nil, "\(lines)")
}

/// A house number written as a JSON number stays a number, and the line beside it agrees.
@Test func numericHouseNumberStaysANumber() throws {
    let output = try scrub(#"{"address": {"house_number": 4821, "street_name": "Juniper Hollow Rd", "city": "Tacoma", "state": "WA", "line1": "4821 Juniper Hollow Rd"}}"#, as: "a.json")
    let parsed = try OrderedJSON.parse(output)
    guard case .object(let root) = parsed, case .object(let address)? = root.first?.1, case .number(let number)? = address.first(where: { $0.0 == "house_number" })?.1 else {
        Issue.record("house_number is no number: \(output)"); return
    }
    #expect(number != "4821")
    let street = try value(output, "address", "street_name"), line = try value(output, "address", "line1")
    #expect(line == "\(number) \(street)", "\(line) is not \(number) \(street)")
}

/// A state written alone first ("VIC" on a licence) shares its place with the
/// address in that state only where the address's postcode can be written there.
@Test func lonePlaceNeverForcesAPostcodeItCannotWrite() throws {
    for seed in UInt64(1)...12 {
        let output = try scrub(#"{"licence": {"state": "VIC"}, "address": {"city": "Geelong", "state": "Victoria", "postcode": "3220", "country": "AU"}}"#, as: "a.json", seed: seed)
        let city = try value(output, "address", "city"), postcode = try value(output, "address", "postcode")
        let place = try #require(Places.all.first { $0.city == city && $0.country == "AU" })
        #expect(place.postal.contains(postcode), "seed \(seed): \(postcode) is not in \(city)")
    }
}

/// An inline document image and a long hyphenated slug, as identity checks and
/// watchlist hits send them, are scrubbed in seconds: a name-and-number ID
/// pattern whose repeated pieces could each start without a separator split a
/// run of letters exponentially many ways before failing, and never returned.
@Test func longLetterRunsScrubPromptly() throws {
    var gen = Gen(seed: 41)
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+/"
    let image = "data:image/png;base64," + gen.string(alphabet, count: 600) + "=="
    // At 64 letters the old pattern took 0.7 s, at 73 over 4 s, doubling about every four letters.
    let slug = "northern-registry-of-persons-and-entities-subject-to-restrictive-measures-under-council-decisions"
    let body = #"{"document": {"front_image": "\#(image)", "type": "id_card"}, "hit": {"source": "\#(slug)", "name": "Oluwaseun Abernathy"}}"#
    for name in ["request.json", "request.txt"] {
        let started = Date()
        _ = try scrub(name.hasSuffix(".txt") ? "curl -d '\(body)'" : body, as: name)
        #expect(Date().timeIntervalSince(started) < 20, "\(name) took \(Int(Date().timeIntervalSince(started)))s")
    }
}

/// A secret's key with nothing in its place, at the end of an object in a
/// minified body logged on one line ("evaluation_token":null}]), leaves the
/// brackets after it alone: the pattern for secrets once took `null}]` as the token.
@Test func nullUnderASecretKeyKeepsTheBodyWhole() throws {
    let line = #"2026-01-12T10:04:11Z INFO http - response body={"entity":{"name_first":"Oluwaseun","addresses":[{"city":"Tacoma","evaluation_token":null}],"type":"person","session_token":null}}"#
    let output = try scrub(line + "\n", as: "log.txt")
    let body = String(output[output.firstIndex(of: "{")!...output.lastIndex(of: "}")!])
    #expect((try? OrderedJSON.parse(body)) != nil, "\(body)")
    #expect(body.contains(#""evaluation_token":null}]"#) && body.contains(#""session_token":null}}"#))
}

/// A password that is the word "password" is still a password: replaced, and its key stays.
@Test(arguments: ["a.json", "a.txt"])
func passwordSpellingItsKeyIsReplaced(_ name: String) throws {
    let output = try scrub(#"{"user": {"email": "rosalind.b@example.org", "password": "password", "secret": "secret"}}"#, as: name)
    #expect(try value(output, "user", "password") != "password" && (try value(output, "user", "secret")) != "secret", "\(output)")
}

/// An ID card's zone stored a line per field: the check over the first two
/// lines adds up whichever order the fields come in.
@Test(arguments: [[0, 1, 2], [1, 0, 2], [2, 1, 0]])
func cardZoneSplitAcrossFieldsKeepsItsChecks(_ order: [Int]) throws {
    let card = MRZ.card(issuer: "D<<", last: "Achterberg", first: "Linnea", number: "LK7731905", nationality: "D<<", birth: birth, sex: "F", expiry: expiry)
    let fields = order.map { #""mrz\#($0 + 1)": "\#(card[$0])""# }.joined(separator: ", ")
    for name in ["a.json", "a.txt"] {
        for seed in UInt64(1)...6 {
            let output = try scrub(#"{"first_name": "Linnea", "last_name": "Achterberg", "id_card": {\#(fields)}}"#, as: name, seed: seed)
            let lines = try (1...3).map { try value(output, "id_card", "mrz\($0)") }
            #expect(!output.contains("LK7731905") && !output.contains("ACHTERBERG"))
            #expect(MRZ.misfit(card.joined(separator: "\n"), lines.joined(separator: "\n")) == nil, "\(name) seed \(seed): \(lines)")
        }
    }
}

/// Two people's cards, each split across fields: every card's check over both
/// lines holds, and each zone's birth date is its own holder's stand-in date.
@Test(arguments: ["a.json", "a.txt"])
func twoSplitCardsKeepTheirOwnChecksAndDates(_ name: String) throws {
    let second = DateComponents(year: 1985, month: 9, day: 23)
    let cards = [MRZ.card(issuer: "D<<", last: "Achterberg", first: "Linnea", number: "LK7731905", nationality: "D<<", birth: birth, sex: "F", expiry: expiry),
                 MRZ.card(issuer: "D<<", last: "Vandermeer", first: "Odile", number: "TR5520874", nationality: "D<<", birth: second, sex: "F", expiry: expiry)]
    let people = zip(cards, [birth, second]).map { card, day in
        #"{"birth_year": \#(day.year!), "birth_month": \#(day.month!), "birth_day": \#(day.day!), "id_card": {"mrz2": "\#(card[1])", "mrz1": "\#(card[0])", "mrz3": "\#(card[2])"}}"#
    }
    for seed in UInt64(1)...6 {
        let output = try scrub(#"{"people": [\#(people.joined(separator: ", "))]}"#, as: name, seed: seed)
        for (index, card) in cards.enumerated() {
            let lines = try (1...3).map { try value(output, "people", String(index), "id_card", "mrz\($0)") }
            #expect(MRZ.misfit(card.joined(separator: "\n"), lines.joined(separator: "\n")) == nil, "seed \(seed) card \(index): \(lines)")
            let (year, month, day) = try (value(output, "people", String(index), "birth_year"), value(output, "people", String(index), "birth_month"), value(output, "people", String(index), "birth_day"))
            let written = String(format: "%02d%02d%02d", (Int(year) ?? 0) % 100, Int(month) ?? 0, Int(day) ?? 0)
            #expect(String(lines[1].prefix(6)) == written, "seed \(seed) card \(index): \(lines[1]) beside \(year)-\(month)-\(day)")
        }
    }
}

/// A credential's value can be any word, a status's or a type's too: each is replaced.
@Test(arguments: ["a.json", "a.txt"])
func credentialsThatReadAsWordsAreReplaced(_ name: String) throws {
    let output = try scrub(#"{"password": "pass", "client_secret": "string", "pin": "4417", "recovery_token": "R-wq7Hk2Lm9Pz4Xc"}"#, as: name)
    for (key, original) in [("password", "pass"), ("client_secret", "string"), ("pin", "4417"), ("recovery_token", "R-wq7Hk2Lm9Pz4Xc")] {
        #expect(try value(output, key) != original, "\(key) left: \(output)")
    }
}

/// A sample's template slot under a secret's key, and a check's result under a card code,
/// are kept, and so is the same word elsewhere in the response.
@Test(arguments: ["a.json", "a.txt", "a.log"])
func secretSlotsAndCheckResultsAreKept(_ name: String) throws {
    let input = #"{"case_token": ":case_token", "api_key": "{api_key}", "client_secret": "<client_secret>", "href": "/v1/cases/:case_token", "check": {"cvv": "match", "postal_code": "match", "first_name": "match"}}"#
    let output = try scrub(input, as: name)
    #expect(try value(output, "case_token") == ":case_token" && value(output, "api_key") == "{api_key}" && value(output, "client_secret") == "<client_secret>", "\(output)")
    #expect(try value(output, "href") == "/v1/cases/:case_token", "\(output)")
    for key in ["cvv", "postal_code", "first_name"] { #expect(try value(output, "check", key) == "match", "\(key): \(output)") }
}

/// A passport's data line with every field filled has no "<"; its checks still say it is one.
@Test(arguments: ["a.json", "a.txt"])
func filledZoneLineIsReplaced(_ name: String) throws {
    let full = MRZ.passport(issuer: "ITA", last: "Brightwater", first: "Rosalind", number: "YB4417203", nationality: "ITA", birth: birth, sex: "F", expiry: expiry)
    var data = Array(full.1)
    data.replaceSubrange(28..<42, with: Array("12345678901234"))
    let line = String(MachineZone.rechecked(data, kind: .data))
    #expect(!line.contains("<") && MachineZone.isZone(line))
    let output = try scrub(#"{"passport": {"mrz1": "\#(full.0)", "mrz2": "\#(line)"}}"#, as: name)
    #expect(!output.contains("YB4417203") && !output.contains(line), "\(output)")
}

/// A postcode abroad written as a number stays a number with no leading zero,
/// and is its stand-in city's, in a file and pasted alike.
@Test(arguments: ["a.json", "a.txt"])
func numericPostcodeAbroadStaysANumberOfItsCity(_ name: String) throws {
    for seed in UInt64(1)...12 {
        let output = try scrub(#"{"country": "IT", "address": {"city": "Bologna", "state": "BO", "postcode": 40126}}"#, as: name, seed: seed)
        let parsed = try #require(try? OrderedJSON.parse(output), "seed \(seed): \(output)")
        guard case .object(let root) = parsed, case .object(let address)? = root.last?.1, case .number(let postcode)? = address.last?.1 else {
            Issue.record("seed \(seed): postcode is no number: \(output)"); continue
        }
        let city = try value(output, "address", "city")
        let place = try #require(Places.abroad.first { $0.city == city && $0.country == "IT" })
        #expect(postcode.first != "0" && postcode.prefix(2) == place.postal.prefix(2), "seed \(seed): \(postcode) in \(city)")
    }
}

/// A secret's common word is replaced where it was found, and nowhere else;
/// a secret written "false" is one too, and every literal keeps its type.
@Test(arguments: ["a.json", "a.txt", "a.log"])
func secretWordsStayWhereTheyAre(_ name: String) throws {
    let output = try scrub(#"{"password": "pass", "status": "pass", "secret": "false", "verified": false, "review_token": null}"#, as: name)
    let body = String(output[output.firstIndex(of: "{")!...output.lastIndex(of: "}")!])
    #expect(try OrderedJSON.parse(body) != nil, "\(output)")
    #expect(try value(output, "password") != "pass" && value(output, "status") == "pass" && value(output, "secret") != "false", "\(output)")
    #expect(body.contains(#""verified": false"#) || body.contains(#""verified":false"#), "\(output)")
}

/// A map of credentials under any names holds secrets, and so does a hash beside them;
/// what describes an authorization does not.
@Test(arguments: ["a.json", "a.txt"])
func credentialMapsAreSecretWhateverTheirNames(_ name: String) throws {
    let output = try scrub(#"{"credentials": {"primary": "t7Pq9mN2sV4bX6kL", "webhook": "wk_9fK2mPq7Lx4Rt", "hash": "a8f3c9e1b2d47f60"}, "authorizations": [{"amount": "12.50", "category": "fuel"}]}"#, as: name)
    for key in ["primary", "webhook", "hash"] { #expect(!output.contains(try #require([("primary", "t7Pq9mN2sV4bX6kL"), ("webhook", "wk_9fK2mPq7Lx4Rt"), ("hash", "a8f3c9e1b2d47f60")].first { $0.0 == key }).1), "\(key): \(output)") }
    #expect(try value(output, "authorizations", "0", "amount") == "12.50" && value(output, "authorizations", "0", "category") == "fuel", "\(output)")
}

/// A key written with someone's data in it is scrubbed as the value is; a field's plain name is kept.
@Test(arguments: ["a.json", "a.txt"])
func keysHoldingDataAreReplaced(_ name: String) throws {
    let output = try scrub(#"{"email": "rosalind@example.org", "password": "hunter42x", "keys": {"rosalind@example.org_token": "active", "hunter42x_token": "on"}}"#, as: name)
    #expect(!output.contains("rosalind@example.org") && !output.contains("hunter42x"), "\(output)")
    #expect(output.contains(#""email""#) && output.contains(#""password""#), "\(output)")
}

/// An address number written with an exponent stays a JSON number in pasted text.
@Test(arguments: ["a.txt", "a.log"])
func exponentNumbersKeepTheirGrammar(_ name: String) throws {
    let output = try scrub(#"{"unit_number": 1e1, "building_number": 1.2e2, "street_name": "Via Garibaldi", "country": "IT"}"#, as: name)
    let body = String(output[output.firstIndex(of: "{")!...output.lastIndex(of: "}")!])
    #expect((try? OrderedJSON.parse(body)) != nil, "\(output)")
}

/// Names written with JSON escapes, and a body sent as an escaped string, are read as any other value.
@Test(arguments: ["a.txt", "a.log"])
func escapedValuesAndStringBodiesAreScrubbed(_ name: String) throws {
    let output = try scrub(#"{"givenName": "Ren\u00e9", "familyName": "Br\u00fcl\u00e9", "body": "{\"password\": \"mYsEcReT\", \"last_name\": \"Brightwater\"}"}"#, as: name)
    let body = String(output[output.firstIndex(of: "{")!...output.lastIndex(of: "}")!])
    #expect(!output.contains("Ren\\u00e9") && !output.contains("Br\\u00fc") && !output.contains("mYsEcReT") && !output.contains("Brightwater"), "\(output)")
    guard case .object(let root)? = try? OrderedJSON.parse(body), case .string(let inner)? = root.last?.1 else { Issue.record("\(output)"); return }
    #expect((try? OrderedJSON.parse(inner)) != nil, "\(inner)")
}

/// A birth country is no address's: the city keeps to the address's own country.
@Test(arguments: ["a.json", "a.txt"])
func birthCountryLeavesTheAddressCountry(_ name: String) throws {
    for seed in UInt64(1)...6 {
        let output = try scrub(#"{"city": "Bologna", "country_of_birth": "FR", "country": "IT"}"#, as: name, seed: seed)
        let city = try value(output, "city")
        #expect(Places.abroad.contains { $0.city == city && $0.country == "IT" }, "seed \(seed): \(output)")
    }
}

/// A card with only its first line, beside a whole one: the whole card's check over both lines holds.
@Test(arguments: ["a.json", "a.txt"])
func anIncompleteCardLeavesTheNextWhole(_ name: String) throws {
    let lone = MRZ.card(issuer: "D<<", last: "Achterberg", first: "Linnea", number: "LK7731905", nationality: "D<<", birth: birth, sex: "F", expiry: expiry)
    let card = MRZ.card(issuer: "D<<", last: "Vandermeer", first: "Odile", number: "TR5520874", nationality: "D<<", birth: DateComponents(year: 1985, month: 9, day: 23), sex: "F", expiry: expiry)
    for seed in UInt64(1)...6 {
        let output = try scrub(#"{"people": [{"id_card": {"mrz1": "\#(lone[0])"}}, {"id_card": {"mrz1": "\#(card[0])", "mrz2": "\#(card[1])", "mrz3": "\#(card[2])"}}]}"#, as: name, seed: seed)
        let lines = try (1...3).map { try value(output, "people", "1", "id_card", "mrz\($0)") }
        #expect(MRZ.misfit(card.joined(separator: "\n"), lines.joined(separator: "\n")) == nil, "seed \(seed): \(lines)")
    }
}

/// Two people whose zone lines read alike: each zone is its own holder's, its date and its checks.
@Test(arguments: ["a.json", "a.txt"])
func alikeZoneLinesAreEachTheirHolders(_ name: String) throws {
    let cards = [MRZ.card(issuer: "D<<", last: "Achterberg", first: "Linnea", number: "LK7731905", nationality: "D<<", birth: birth, sex: "F", expiry: expiry),
                 MRZ.card(issuer: "D<<", last: "Vandermeer", first: "Odile", number: "TR5520874", nationality: "D<<", birth: birth, sex: "F", expiry: expiry)]
    #expect(cards[0][1] == cards[1][1])
    let people = cards.map { card in
        #"{"birth_year": 1981, "birth_month": 9, "birth_day": 23, "id_card": {"mrz1": "\#(card[0])", "mrz2": "\#(card[1])", "mrz3": "\#(card[2])"}}"#
    }
    for seed in UInt64(1)...6 {
        let output = try scrub(#"{"people": [\#(people.joined(separator: ", "))]}"#, as: name, seed: seed)
        for (index, card) in cards.enumerated() {
            let lines = try (1...3).map { try value(output, "people", String(index), "id_card", "mrz\($0)") }
            #expect(MRZ.misfit(card.joined(separator: "\n"), lines.joined(separator: "\n")) == nil, "seed \(seed) card \(index): \(lines)")
            let (year, month, day) = try (value(output, "people", String(index), "birth_year"), value(output, "people", String(index), "birth_month"), value(output, "people", String(index), "birth_day"))
            let written = String(format: "%02d%02d%02d", (Int(year) ?? 0) % 100, Int(month) ?? 0, Int(day) ?? 0)
            #expect(String(lines[1].prefix(6)) == written, "seed \(seed) card \(index): \(lines[1]) beside \(year)-\(month)-\(day)")
        }
    }
}

/// A document check's zone stored as "line1" and "line2" under "mrz": the
/// data line is the zone's, never an address's second line, so it takes the
/// stand-in passport number and birth date with its check digits right.
@Test(arguments: ["docv.json", "Pasted text"])
func zoneLinesUnderLineKeysStayAZone(_ name: String) throws {
    let full = MRZ.passport(issuer: "NZL", last: "Ferncastle", first: "Imogen", number: "LH5520917", nationality: "NZL", birth: birth, sex: "F", expiry: expiry)
    let response = """
    {
      "verification_id": "docv_51c0e2",
      "status": "approved",
      "document": {
        "type": "passport",
        "issuing_country": "NZL",
        "number": "LH5520917",
        "mrz": {"line1": "\(full.0)", "line2": "\(full.1)", "checksums_valid": true}
      },
      "extracted": {"surname": "FERNCASTLE", "given_names": "IMOGEN", "date_of_birth": "1981-09-23", "nationality": "NZL"}
    }
    """
    let output = try scrub(response, as: name)
    let line1 = try value(output, "document", "mrz", "line1"), line2 = try value(output, "document", "mrz", "line2")
    #expect(!output.contains("LH5520917") && !output.contains("FERNCASTLE"), "\(output)")
    #expect(line2.count == 44 && MachineZone.isZone(line2), "\(line2)")
    #expect(MRZ.misfit(full.0 + "\n" + full.1, line1 + "\n" + line2) == nil, "\(line1) \(line2)")
    let number = try value(output, "document", "number")
    #expect(MRZ.data(line2).number == number, "\(output)")
    let born = try value(output, "extracted", "date_of_birth").split(separator: "-").compactMap { Int($0) }
    #expect(MRZ.data(line2).birth == String(format: "%02d%02d%02d", born[0] % 100, born[1], born[2]), "\(output)")
    let written = try #require(MRZ.writtenName(line1))
    let surname = try value(output, "extracted", "surname"), given = try value(output, "extracted", "given_names")
    #expect(written.last == surname.filter(\.isLetter) && written.first == given, "\(output)")
}
