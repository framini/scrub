import Foundation
@testable import ScrubCore
import Testing

// Values that belong together must still agree after scrubbing: one test per
// fault the payload relations found, on fixed inputs.

private func scrub(_ text: String, as name: String) throws -> String {
    String(decoding: try Scrubber.scrub(Data(text.utf8), name: name, forceFullDetection: false, seed: 11).output, as: UTF8.self)
}
private func object(_ output: String, _ path: String...) throws -> [String: String] {
    var node = try OrderedJSON.parse(output)
    for key in path {
        guard case .object(let pairs) = node, let next = pairs.first(where: { $0.0 == key })?.1 else { Issue.record("no \(key)"); return [:] }
        node = next
    }
    guard case .object(let pairs) = node else { return [:] }
    var fields: [String: String] = [:]
    for (key, value) in pairs {
        switch value {
        case .string(let s): fields[key] = s
        case .number(let n): fields[key] = n
        default: break
        }
    }
    return fields
}
private func place(_ city: String?, _ region: String?, _ postal: String?) -> Place? {
    Places.all.first { place in
        city.map { $0 == place.city } ?? true
            && (region.map { Places.region($0, in: place.country).map { [$0.code, $0.name].contains(place.region) } ?? false } ?? true)
            && (postal.map { place.postal.contains(StandIns.district($0)) } ?? true)
    }
}

/// The table stand-ins come from, checked against facts it wasn't written
/// from: USPS ZIP prefixes by state, the first letter of a Canadian postcode
/// by province, Australian postcode ranges, and each country's bounds.
@Test func placesAreReal() {
    let zipPrefixes: [String: [ClosedRange<Int>]] = [
        "MA": [10...27], "RI": [28...29], "NH": [30...38], "ME": [39...49], "VT": [50...59], "CT": [60...69], "NJ": [70...89], "NY": [100...149],
        "PA": [150...196], "DE": [197...199], "DC": [200...205], "MD": [206...219], "VA": [220...246], "WV": [247...268], "NC": [270...289],
        "SC": [290...299], "GA": [300...319], "FL": [320...349], "AL": [350...369], "TN": [370...385], "MS": [386...397], "KY": [400...427],
        "OH": [430...459], "IN": [460...479], "MI": [480...499], "IA": [500...528], "WI": [530...549], "MN": [550...567], "SD": [570...577],
        "ND": [580...588], "MT": [590...599], "IL": [600...629], "MO": [630...658], "KS": [660...679], "NE": [680...693], "LA": [700...714],
        "AR": [716...729], "OK": [730...749], "TX": [750...799], "CO": [800...816], "WY": [820...831], "ID": [832...838], "UT": [840...847],
        "AZ": [850...865], "NM": [870...884], "NV": [889...898], "CA": [900...961], "HI": [967...968], "OR": [970...979], "WA": [980...994], "AK": [995...999]]
    let provinceLetters: [String: Set<Character>] = ["ON": ["K", "L", "M", "N", "P"], "QC": ["G", "H", "J"], "BC": ["V"], "AB": ["T"], "MB": ["R"], "SK": ["S"], "NS": ["B"]]
    let australian: [String: [ClosedRange<Int>]] = ["NSW": [2000...2599], "ACT": [2600...2618], "VIC": [3000...3999], "QLD": [4000...4999], "SA": [5000...5999], "WA": [6000...6999], "TAS": [7000...7999], "NT": [800...999]]
    let bounds: [String: (ClosedRange<Double>, ClosedRange<Double>)] = ["US": (18...72, -170 ... -66), "CA": (42...70, -141 ... -52), "GB": (49...61, -9...2), "AU": (-44 ... -10, 112...154)]
    for place in Places.all {
        switch place.country {
        case "US":
            for zip in place.postal { #expect(zipPrefixes[place.region]?.contains { $0.contains(Int(zip.prefix(3))!) } == true, "\(zip) is not in \(place.region)") }
        case "CA":
            for district in place.postal { #expect(provinceLetters[place.region]?.contains(district.first!) == true, "\(district) is not in \(place.region)") }
        case "AU":
            for code in place.postal { #expect(australian[place.region]?.contains { $0.contains(Int(code)!) } == true, "\(code) is not in \(place.region)") }
        default:
            #expect(place.postal.allSatisfy { $0.range(of: #"^[A-Z]{1,2}\d[A-Z\d]?$"#, options: .regularExpression) != nil })
        }
        #expect(TimeZone(identifier: place.timeZone) != nil, "\(place.timeZone)")
        #expect(bounds[place.country]!.0.contains(place.latitude) && bounds[place.country]!.1.contains(place.longitude), "\(place.city) lies outside \(place.country)")
        if ["US", "CA"].contains(place.country) { #expect(place.areaCode.count == 3 && !"01".contains(place.areaCode.first!), "\(place.areaCode)") }
        #expect(Places.region(place.region, in: place.country) != nil, "\(place.region)")
    }
}

@Test(arguments: ["address.json", "address.xml", "address.csv", "address.txt"])
func addressPartsComeFromOnePlace(_ name: String) throws {
    let input: String
    switch name {
    case "address.xml": input = "<address><line1>4821 Juniper Hollow Rd</line1><line2>Apt 2B</line2><city>Tacoma</city><state>WA</state><zip>98402-1234</zip><country>US</country></address>"
    case "address.csv": input = "line1,line2,city,state,zip,country\n4821 Juniper Hollow Rd,Apt 2B,Tacoma,WA,98402-1234,US\n"
    default: input = #"{"address": {"line1": "4821 Juniper Hollow Rd", "line2": "Apt 2B", "city": "Tacoma", "state": "WA", "zip": "98402-1234", "country": "US"}}"#
    }
    let output = try scrub(input, as: name)
    for original in ["Juniper", "Apt 2B", "Tacoma", "WA", "98402"] { #expect(!output.contains(original), "\(original) in \(output)") }
    #expect(output.contains("US"))
    let city = Places.all.first { output.contains($0.city) && $0.country == "US" }
    let found = try #require(city, "no real city in \(output)")
    #expect(output.contains(">\(found.region)<") || output.contains(",\(found.region),") || output.contains("\"\(found.region)\""), "\(output)")
    #expect(found.postal.contains { output.contains($0 + "-") }, "\(output)")
    #expect(output.range(of: #"Apt \d[A-Z]"#, options: .regularExpression) != nil, "\(output)")
}

@Test func oneLineAddressesAgreeWithTheirParts() throws {
    let json = #"{"address": {"line1": "4821 Juniper Hollow Rd", "city": "Tacoma", "state": "Washington", "zip": 98402, "formatted": "4821 Juniper Hollow Rd, Tacoma, WA 98402"}}"#
    let fields = try object(try scrub(json, as: "a.json"), "address")
    let line = try #require(AddressParts.line(fields["formatted"] ?? ""), "\(fields)")
    #expect(line.parts.city == fields["city"] && line.pieces[0] == fields["line1"], "\(fields)")
    #expect(place(fields["city"], fields["state"], fields["zip"]) != nil && place(line.parts.city, line.parts.region, line.parts.postal) != nil, "\(fields)")
    #expect(fields["state"]?.count ?? 0 > 3 && line.parts.region?.count == 2, "a state written out stays written out: \(fields)")
}

@Test func otherCountriesKeepTheirShape() throws {
    let json = #"""
    {"ca": {"city": "Mississauga", "province": "ON", "postal_code": "L5B 3C2", "country": "CA"},
     "gb": {"city": "Sheffield", "region": "England", "postcode": "S1 2HE", "country": "GB"},
     "au": {"city": "Geelong", "state": "VIC", "postcode": "3220", "country": "AU"}}
    """#
    let output = try scrub(json, as: "a.json")
    let ca = try object(output, "ca"), gb = try object(output, "gb"), au = try object(output, "au")
    #expect(place(ca["city"], ca["province"], ca["postal_code"])?.country == "CA" && ca["postal_code"]?.range(of: #"^[A-Z]\d[A-Z] \d[A-Z]\d$"#, options: .regularExpression) != nil, "\(ca)")
    #expect(place(gb["city"], gb["region"], gb["postcode"])?.country == "GB" && gb["postcode"]?.range(of: #"^[A-Z]\d \d[A-Z]{2}$"#, options: .regularExpression) != nil, "\(gb)")
    #expect(place(au["city"], au["state"], au["postcode"])?.country == "AU" && au["postcode"]?.count == 4 && au["state"] != "VIC", "\(au)")
    for original in ["Mississauga", "L5B", "Sheffield", "S1 2HE", "Geelong", "3220"] { #expect(!output.contains(original)) }
}

@Test func pointsTimeZonesAndPhonesFollowTheAddress() throws {
    let json = #"""
    {"customer": {"phone": "(253) 734-9021", "timezone": "America/Los_Angeles",
      "address": {"city": "Tacoma", "state": "WA", "zip": "98402", "latitude": 47.2529, "longitude": -122.4443},
      "geo": {"type": "Point", "coordinates": [-122.4443, 47.2529]}}}
    """#
    let output = try scrub(json, as: "a.json")
    let customer = try object(output, "customer"), address = try object(output, "customer", "address")
    let found = try #require(place(address["city"], address["state"], address["zip"]), "\(address)")
    #expect(customer["phone"]?.hasPrefix("(\(found.areaCode)) 555-01") == true, "\(customer)")
    #expect(customer["timezone"] == found.timeZone || found.timeZone == "America/Los_Angeles", "\(customer)")
    #expect(abs((Double(address["latitude"] ?? "") ?? 0) - found.latitude) < 0.1 && abs((Double(address["longitude"] ?? "") ?? 0) - found.longitude) < 0.1, "\(address)")
    #expect(address["latitude"]?.split(separator: ".").last?.count == 4)
    #expect(!output.contains("47.2529") && !output.contains("-122.4443"))
}

@Test func valuesReadOffOthersAgreeWithThem() throws {
    let json = #"""
    {"first_name": "Oluwaseun", "last_name": "O'Sullivan", "initials": "O.O.", "email": "oluwaseun.osullivan@gmail.com", "username": "oosullivan74",
     "dob": "1974-04-12", "birth_year": 1974, "age": 52, "ssn": "536-21-7784", "ssn_last4": 7784, "masked_ssn": "***-**-7784",
     "card": {"number": "4111 1111 1111 1111", "last4": "1111"}, "phone": "2537349021", "phone_last4": "9021"}
    """#
    let fields = try object(try scrub(json, as: "a.json"))
    let first = try #require(fields["first_name"]), last = try #require(fields["last_name"])
    #expect(fields["initials"] == "\(first.prefix(1)).\(last.prefix(1)).", "\(fields)")
    #expect(fields["email"]?.hasPrefix(first.lowercased() + "." + last.lowercased().filter(\.isLetter) + "@") == true, "\(fields)")
    #expect(fields["username"]?.range(of: "^" + first.prefix(1).lowercased() + last.lowercased().filter(\.isLetter) + #"\d\d$"#, options: .regularExpression) != nil, "\(fields)")
    let year = try #require(Int(fields["dob"]?.prefix(4) ?? ""))
    #expect(fields["birth_year"] == String(year) && year != 1974)
    let now = Calendar(identifier: .gregorian).component(.year, from: Date())
    #expect([now - year - 1, now - year].contains(Int(fields["age"] ?? "") ?? -1), "\(fields)")
    let ssn = try #require(fields["ssn"])
    #expect(fields["ssn_last4"] == String(ssn.suffix(4)) && fields["masked_ssn"] == "***-**-" + ssn.suffix(4) && fields["ssn_last4"]?.first != "0", "\(fields)")
    #expect(fields["phone_last4"] == fields["phone"].map { String($0.suffix(4)) })
    let card = try object(try scrub(json, as: "a.json"), "card")
    #expect(card["last4"] == card["number"].map { String($0.filter(\.isNumber).suffix(4)) }, "\(card)")
}

@Test func namesFitAGenderOrTitle() throws {
    for (gender, key) in [("female", "gender"), ("F", "sex"), ("Ms.", "title"), ("male", "gender"), ("Mr.", "title")] {
        let json = #"{"name": {"first": "Jiwon", "last": "Brightwater"}, "\#(key)": "\#(gender)", "email": "jiwon.brightwater@proton.me"}"#
        let output = try scrub(json, as: "a.json")
        let first = try #require(try object(output, "name")["first"])
        let female = ["female", "F", "Ms."].contains(gender)
        #expect(female ? Names.female.contains(first.lowercased()) : Names.male.contains(first.lowercased()), "\(gender): \(first)")
        #expect(try object(output)["email"]?.hasPrefix(first.lowercased() + ".") == true, "the email follows the name inside \"name\": \(output)")
    }
    let text = try scrub("Ms. Siobhan Okafor called about her order.", as: "note.txt")
    #expect(text.hasPrefix("Ms. ") && !text.contains("Siobhan") && Names.female.contains(String(text.dropFirst(4).prefix { $0 != " " }).lowercased()), "\(text)")
}

@Test func pastedRecordsAreReadAsRecords() throws {
    let text = #"""
    {"customer": {"first_name": "Oluwaseun", "last_name": "Brightwater", "gender": "female", "email": "oluwaseun.brightwater@gmail.com",
      "username": "obrightwater74", "initials": "OB", "phones": [2537349021], "timezone": "America/Los_Angeles",
      "address": {"street": "4821 Juniper Hollow Rd", "city": "Tacoma", "state": "WA", "zip": 98402},
      "geo": {"coordinates": [-122.4443, 47.2529]}}}
    """#
    let output = try scrub(text, as: "pasted.txt")
    let customer = try object(output, "customer"), address = try object(output, "customer", "address")
    let first = try #require(customer["first_name"]), last = try #require(customer["last_name"])
    #expect(Names.female.contains(first.lowercased()), "\(first)")
    #expect(customer["email"]?.hasPrefix(first.lowercased() + "." + last.lowercased()) == true && customer["username"]?.hasPrefix(first.prefix(1).lowercased() + last.lowercased()) == true, "\(customer)")
    #expect(customer["initials"] == String(first.prefix(1) + last.prefix(1)))
    let found = try #require(place(address["city"], address["state"], address["zip"]), "\(address)")
    #expect(output.contains("[" + found.areaCode + "5550"), "\(output)")
    #expect(found.timeZone == "America/Los_Angeles" || customer["timezone"] == found.timeZone, "\(customer)")
    #expect(!output.contains("47.2529") && !output.contains("-122.4443"))
}

@Test func writtenAddressesTakeTheirWholeLine() throws {
    let text = try scrub("Ship to Oluwaseun Brightwater, 4821 Juniper Hollow Rd, Tacoma, WA 98402.\nThe return goes to Boise, ID 83702 this week.", as: "note.txt")
    for original in ["Oluwaseun", "Brightwater", "Juniper", "Tacoma", "98402", "Boise", "ID 83702"] { #expect(!text.contains(original), "\(original) in \(text)") }
    let lines = text.split(separator: "\n").map(String.init)
    let label = try #require(TextRanges.matches(TextPattern(#"(\p{Lu}[\p{L}. ]+), (\p{Lu}{2}) (\d{5})"#), in: lines[0]).last)
    let ns = lines[0] as NSString
    #expect(place(ns.substring(with: label.range(at: 1)).components(separatedBy: ", ").last, ns.substring(with: label.range(at: 2)), ns.substring(with: label.range(at: 3))) != nil, "\(lines[0])")
    let second = try #require(TextRanges.matches(TextPattern(#"to (\p{Lu}[\p{L} ]+), (\p{Lu}{2}) (\d{5})"#), in: lines[1]).first)
    let ns2 = lines[1] as NSString
    #expect(place(ns2.substring(with: second.range(at: 1)), ns2.substring(with: second.range(at: 2)), ns2.substring(with: second.range(at: 3))) != nil, "\(lines[1])")
}

@Test func bareLastDigitsStayNumbers() throws {
    for name in ["a.json", "a.txt"] {
        for last4 in ["1024", "7084", "9001"] {
            let json = #"{"ssn": "536-21-\#(last4)", "ssn_last4": \#(last4), "SSN_LAST_FOUR": \#(last4)}"#
            let output = try scrub(json, as: name)
            let fields = try object(output)
            #expect(fields["ssn_last4"]?.first != "0" && fields["ssn_last4"] == fields["ssn"].map { String($0.suffix(4)) }, "\(name): \(output)")
        }
    }
    #expect(try object(try scrub(#"{"SSN_LAST_FOUR": 1024}"#, as: "a.txt"))["SSN_LAST_FOUR"]?.first != "0")
}

@Test func oneNumberInTwoLayoutsKeepsOneStandIn() throws {
    let fields = try object(try scrub(#"{"ssn": "536-21-7784", "tax_id": "536217784", "national_id": 536217784, "phone": "+1 (253) 734-9021", "mobile": 2537349021}"#, as: "a.json"))
    let digits = try #require(fields["ssn"]?.filter(\.isNumber))
    #expect(fields["tax_id"] == digits && fields["national_id"] == digits, "\(fields)")
    #expect(fields["phone"]?.filter(\.isNumber).dropFirst() == Substring(fields["mobile"] ?? ""), "\(fields)")
}

@Test func settingsNamedLikePlacesStay() throws {
    let json = #"""
    {"order": {"state": "open", "region": "us-east-1", "age": 3, "timezone": "America/Chicago"},
     "cache": {"max_age": 3600}, "country": "Canada", "id": "4ae18f24-cabe-d57c-0b51-a0c9e2272a48",
     "form": {"unit": "kg", "suite": "regression", "state": "OK", "title": "Mr."}}
    """#
    for name in ["a.json", "a.txt"] {
        let output = try scrub(json, as: name)
        for kept in [#""state": "open""#, #""region": "us-east-1""#, #""age": 3"#, #""timezone": "America/Chicago""#, #""max_age": 3600"#, #""country": "Canada""#, "4ae18f24-cabe-d57c-0b51-a0c9e2272a48", #""unit": "kg""#, #""title": "Mr.""#] {
            #expect(output.contains(kept), "\(name): \(kept) in \(output)")
        }
        #expect(!output.contains("[") || output == json, "no placeholder in \(output)")
    }
}

@Test func phoneNumbersKeepTheirLayout() throws {
    let fields = try object(try scrub(#"{"home_phone": "(253) 734-9021", "primary_mobile": "+1 253.734.9022", "office": {"phone": "+44 20 7946 0123"}, "customer_cell": 2537349023}"#, as: "a.json"))
    #expect(fields["home_phone"]?.range(of: #"^\(\d{3}\) 555-01\d\d$"#, options: .regularExpression) != nil, "\(fields)")
    #expect(fields["primary_mobile"]?.range(of: #"^\+1 \d{3}\.555\.01\d\d$"#, options: .regularExpression) != nil, "\(fields)")
    #expect(fields["customer_cell"]?.range(of: #"^\d{3}55501\d\d$"#, options: .regularExpression) != nil, "\(fields)")
    let office = try object(try scrub(#"{"office": {"phone": "+44 20 7946 0123"}}"#, as: "a.json"), "office")
    #expect(office["phone"]?.range(of: #"^\+44 \d{2} \d{4} \d{4}$"#, options: .regularExpression) != nil && office["phone"] != "+44 20 7946 0123", "\(office)")
}

@Test func stringPrefixesAreNoValues() throws {
    let code = "headers = {\n    \"Authorization\": f\"Bearer {os.getenv('API_KEY')}\",\n    \"X-Token\": r'raw'\n}\nconst q = { password: sql`SELECT 1` };\n"
    #expect(try scrub(code, as: "client.py.txt") == code)
}

@Test func anAddressWrittenTwiceIsOnePlace() throws {
    let json = #"{"documentType": {"country": "USA", "state": "NY"}, "documentData": {"address": "32194 N College Ave, Apt 4B, New York City, NY 10001", "parsedAddress": {"physicalAddress": "32194 N College Ave", "physicalAddress2": "Apt 4B", "city": "New York City", "state": "NY", "country": "US", "zip": "10001"}}}"#
    let output = try scrub(json, as: "a.json")
    let parsed = try object(output, "documentData", "parsedAddress"), document = try object(output, "documentType")
    let line = try #require(try object(output, "documentData")["address"])
    #expect(line == "\(parsed["physicalAddress"]!), \(parsed["physicalAddress2"]!), \(parsed["city"]!), \(parsed["state"]!) \(parsed["zip"]!)", "\(output)")
    #expect(document["state"] == parsed["state"] && document["state"] != "NY", "\(output)")
}

@Test func aLonePostcodeFollowsItsPlace() throws {
    for json in [#"{"location": {"city": "boulder", "postalCode": "80302"}, "profiles": [{"postalCodes": ["80302"]}, {"postalCodes": ["80302"]}]}"#,
                 #"{"profiles": [{"postalCodes": ["80302"]}], "location": {"city": "boulder", "postalCode": "80302"}}"#] {
        let output = try scrub(json, as: "a.json")
        let data = try #require(output.data(using: .utf8))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let location = try #require(root["location"] as? [String: String])
        let codes = try #require(root["profiles"] as? [[String: [String]]]).compactMap { $0["postalCodes"]?.first }
        #expect(location["postalCode"] != "80302" && codes.allSatisfy { $0 == location["postalCode"] }, "\(output)")
    }
}

@Test func placeholdersAndIdentifiersStay() throws {
    let json = #"{"physicalAddress2": "Address Line 2", "line_2": "Address Line 2", "zip": "12345", "id": "client-transaction-12345", "order": "order_12345"}"#
    let output = try scrub(json, as: "a.json")
    for kept in [#""physicalAddress2": "Address Line 2""#, #""line_2": "Address Line 2""#, "client-transaction-12345", "order_12345"] { #expect(output.contains(kept), "\(kept) in \(output)") }
    #expect(!output.contains(#""zip": "12345""#))
}
