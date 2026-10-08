import Foundation
@testable import ScrubCore
import Testing

// Identity-check responses: one test per fault the identity-check shapes
// (see `kycSSN`) found, on fixed, invented inputs, each opened as a file and
// pasted in a curl command.

private func scrub(_ text: String, as name: String, seed: UInt64 = 5) throws -> String {
    let input = name.hasSuffix(".txt") ? "curl -X POST https://api.example.com/v2/checks -H 'Content-Type: application/json' -d '\(text)'\n" : text
    return String(decoding: try Scrubber.scrub(Data(input.utf8), name: name, forceFullDetection: false, seed: seed).output, as: UTF8.self)
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
private let renderings = ["check.json", "check.txt"]

/// A birth date's parts in an object named for them ("dateOfBirthParts")
/// are the stand-in date's parts, never the real ones.
@Test(arguments: renderings)
func birthDatePartsObjectFollowsTheDate(_ name: String) throws {
    let response = #"{"transactionId":"txn_7Qm2LrX9","subject":{"fullName":"Thandiwe Adeyemi","birthDate":"1955/10/11","dateOfBirthParts":{"day":11,"month":10,"year":1955},"age":70},"dobVerification":{"dobMatch":"MATCH","score":360}}"#
    let output = try scrub(response, as: name)
    let date = try value(output, "subject", "birthDate").split(separator: "/").compactMap { Int($0) }
    let parts = try ["year", "month", "day"].map { try Int(value(output, "subject", "dateOfBirthParts", $0)) }
    #expect(date.count == 3 && date[0] != 1955)
    #expect(parts == date.map(Optional.some), "parts \(parts), date \(date)")
}

/// A month written alone beside a date whose day and month read either way
/// round in their stand-in ("16.09.1976" → "05.06.1968") is the stand-in's
/// month, in the place the original wrote its month.
@Test(arguments: renderings)
func birthMonthFollowsADayFirstDate(_ name: String) throws {
    for (date, month, day) in [("16.09.1976", 9, 16), ("04.06.1981", 6, 4)] {
        let response = #"{"subject":{"full_name":"Ingrid Oyelaran","dob":"\#(date)","birth_month":\#(month),"birth_day":\#(day)},"dob_verification":{"dob_match":"N","min_age":18}}"#
        for seed in UInt64(1)...6 {
            let output = try scrub(response, as: name, seed: seed)
            let written = try value(output, "subject", "dob").split(separator: ".").compactMap { Int($0) }
            let standInMonth = try Int(value(output, "subject", "birth_month")), standInDay = try Int(value(output, "subject", "birth_day"))
            #expect(written.count == 3 && standInMonth == written[1] && standInDay == written[0], "\(date) → \(written), month \(standInMonth ?? 0), day \(standInDay ?? 0)")
        }
    }
}

/// A device's bare "fingerprint" is the device's, as its "device_id" is;
/// a certificate's beside it is no one's.
@Test(arguments: renderings)
func deviceFingerprintIsReplaced(_ name: String) throws {
    let response = #"{"request_id":"req_Lk2m9QxT","device":{"device_id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","fingerprint":"342759fea86a7b9c5c2705a642b29887","ip_address":"198.51.100.24"},"tls":{"fingerprint":"e3b0c44298fc1c149afbf4c8996fb924"},"decision":{"outcome":"ACCEPT","score":712}}"#
    let output = try scrub(response, as: name)
    let fingerprint = try value(output, "device", "fingerprint")
    #expect(fingerprint != "342759fea86a7b9c5c2705a642b29887" && fingerprint.count == 32 && fingerprint.allSatisfy(\.isHexDigit) && fingerprint == fingerprint.lowercased(), "\(fingerprint)")
    #expect(try value(output, "tls", "fingerprint") == "e3b0c44298fc1c149afbf4c8996fb924")
}

/// An address abroad written in parts and again on one line is one address:
/// the line's postcode is the one its postcode field took.
@Test(arguments: renderings)
func postcodeAbroadAgreesWithItsLine(_ name: String) throws {
    for seed in UInt64(1)...4 {
        let response = #"{"applicant":{"given_name":"Friederike","family_name":"Hollenbach","address":{"street":"Am Gries","houseNumber":"3a","postalCode":"80538","city":"München","country":"DE","formatted":"Am Gries 3a, 80538 München, Germany"},"previous_addresses":[{"line1":"22 rue des Acacias","postal_code":"69003","city":"Lyon","country":"FR","single_line":"22 rue des Acacias, 69003 Lyon"}]}}"#
        let output = try scrub(response, as: name, seed: seed)
        let postal = try value(output, "applicant", "address", "postalCode"), city = try value(output, "applicant", "address", "city")
        let line = try value(output, "applicant", "address", "formatted")
        #expect(postal != "80538" && line.contains(", \(postal) \(city), Germany"), "\(postal) \(city) vs \(line)")
        let before = try value(output, "applicant", "previous_addresses", "0", "postal_code"), beforeCity = try value(output, "applicant", "previous_addresses", "0", "city")
        #expect(try value(output, "applicant", "previous_addresses", "0", "single_line").hasSuffix(", \(before) \(beforeCity)"))
    }
}

/// A second address line as other countries write a unit stays a unit of its
/// kind: "App. 3" never becomes a street.
@Test(arguments: renderings)
func unitsAbroadStayUnits(_ name: String) throws {
    let response = #"{"addresses":[{"address1":"4520 rue Saint-Denis","address2":"App. 3","city":"Montréal","province":"QC","postal_code":"H2J 2L3","country":"CA"},{"line1":"22 rue des Acacias","line2":"Bât. A","city":"Lyon","postal_code":"69003","country":"FR"},{"line1":"Calle Mayor 14","line2":"3º B","city":"Sevilla","postal_code":"41004","country":"ES"},{"line1":"Lindenallee 12","line2":"2. OG","city":"Hamburg","postal_code":"20095","country":"DE"}]}"#
    let output = try scrub(response, as: name)
    let units = try (0..<4).map { try value(output, "addresses", String($0), $0 == 0 ? "address2" : "line2") }
    for (unit, pattern) in zip(units, [#"^App\. \d$"#, #"^Bât\. [A-Z]$"#, #"^\dº B$"#, #"^\d\. OG$"#]) {
        #expect(unit.range(of: pattern, options: .regularExpression) != nil, "\(unit)")
    }
    #expect(units != ["App. 3", "Bât. A", "3º B", "2. OG"])
}

/// An ITIN typed as one, a ZIP code's last four in a field of their own and
/// an SSN written as bare digits each take a stand-in of their kind: an ITIN
/// the IRS could issue, four other digits, an SSN the SSA could issue.
@Test(arguments: renderings)
func taxNumbersAndZipExtensionsKeepTheirKind(_ name: String) throws {
    for seed in UInt64(1)...12 {
        let response = #"{"subject":{"identifiers":[{"type":"ITIN","value":"923655914"}],"tin":"512487731","address":{"line1":"4821 Juniper Hollow Rd","city":"Tacoma","state":"WA","zip":"98402","zip4":"1648"}},"results":{"ssn_match":"Y","score":0.87}}"#
        let output = try scrub(response, as: name, seed: seed)
        let itin = try value(output, "subject", "identifiers", "0", "value"), tin = try value(output, "subject", "tin"), zip4 = try value(output, "subject", "address", "zip4")
        let group = Int(itin.dropFirst(3).prefix(2)) ?? 0
        #expect(itin != "923655914" && itin.count == 9 && itin.first == "9" && [50...65, 70...88, 90...92, 94...99].contains { $0.contains(group) }, "ITIN \(itin)")
        let area = Int(tin.prefix(3)) ?? 0
        #expect(tin != "512487731" && tin.count == 9 && area != 0 && area != 666 && area < 900 && !tin.dropFirst(3).hasPrefix("00") && !tin.hasSuffix("0000"), "SSN \(tin)")
        #expect(zip4 != "1648" && zip4.count == 4 && zip4.allSatisfy(\.isNumber), "ZIP+4 \(zip4)")
    }
}

/// An SSN a health record types by its system, written as bare digits, takes
/// an SSN the SSA could issue, never nine digits drawn at random.
@Test func typedSSNTakesAnIssuableOne() throws {
    var made: [String] = []
    for seed in UInt64(1)...40 {
        let record = #"{"resourceType":"Patient","identifier":[{"system":"http://hl7.org/fhir/sid/us-ssn","value":"352318010"}],"name":[{"family":"Kowalczyk","given":["Thandiwe"]}],"birthDate":"1962-08-17"}"#
        let ssn = try value(scrub(record, as: "patient.json", seed: seed), "identifier", "0", "value")
        let area = Int(ssn.prefix(3)) ?? 0
        if ssn == "352318010" || ssn.count != 9 || area == 0 || area == 666 || area >= 900 || ssn.dropFirst(3).hasPrefix("00") || ssn.hasSuffix("0000") { made.append(ssn) }
    }
    #expect(made.isEmpty, "not SSNs the SSA issues: \(made)")
}

/// A state of a country Scrub has no full places for ("Jalisco") is the
/// stand-in city's state, and a city that begins another's name ("Porto",
/// "Porto Alegre") stays in its own country.
@Test(arguments: renderings)
func regionsAndCitiesAbroadStayInTheirCountry(_ name: String) throws {
    let response = #"{"customer":{"full_name":"Lúcia Ferreira","bio":"Backend dev in Porto. Previously at Vellum Systems.","location":"Porto, Portugal","address":{"line1":"Calle Morelos 88","city":"Guadalajara","state":"Jalisco","postal_code":"44160","country":"MX"}}}"#
    let output = try scrub(response, as: name)
    let city = try value(output, "customer", "address", "city"), state = try value(output, "customer", "address", "state")
    let mexico = ["Ciudad de México": "CDMX", "Monterrey": "Nuevo León", "Puebla": "Puebla"]
    #expect(mexico[city] == state, "\(city), \(state)")
    let location = try value(output, "customer", "location")
    #expect(location.hasSuffix(", Portugal") && ["Lisboa", "Braga", "Coimbra", "Faro"].contains(String(location.dropLast(", Portugal".count))), "\(location)")
}

/// A Quebec address with no country beside it stays in Canada, out of
/// Montréal however it is spelled, and its street is the same street in its
/// own field and on the line that joins it.
@Test(arguments: renderings)
func quebecAddressStaysCanadianAndOneStreet(_ name: String) throws {
    let canadian = ["Toronto", "Ottawa", "Vancouver", "Calgary", "Edmonton", "Winnipeg", "Halifax", "Regina"]
    for seed in UInt64(1)...6 {
        let lone = #"{"name":"Anaïs Beaulieu","address1":"4520 rue Saint-Denis","address2":"App. 3","city":"Montréal"}"#
        let city = try value(scrub(lone, as: name, seed: seed), "city")
        #expect(canadian.contains(city), "Montréal → \(city)")
        let split = #"{"previousAddresses":[{"streetName":"rue Saint-Denis","streetNumber":"384","locality":"Montréal","state":"QC","postalCode":"H2J 2L3","countryCode":"CA","singleLine":"384 rue Saint-Denis, Montréal, QC H2J 2L3, Canada"}]}"#
        let output = try scrub(split, as: name, seed: seed)
        let street = try value(output, "previousAddresses", "0", "streetName"), number = try value(output, "previousAddresses", "0", "streetNumber")
        let line = try value(output, "previousAddresses", "0", "singleLine")
        #expect(street.hasPrefix("rue ") && line.hasPrefix("\(number) \(street), "), "\(number) \(street) vs \(line)")
    }
}

/// A time zone beside an IP address's place is one name: it stays a zone
/// the system knows, never "Europe/Frankfurt am Main" or a person's name.
@Test(arguments: renderings)
func timeZonesBesideAnIPsPlaceStayZones(_ name: String) throws {
    let event = #"{"visitor_id":"Xk2PqR8sLm4TzW9v","ip_info":{"v4":{"address":"198.51.100.24","geolocation":{"accuracy_radius":5,"latitude":50.0755,"longitude":14.4378,"postal_code":"110 00","timezone":"Europe/Prague","city_name":"Prague","country_code":"CZ"}},"v6":{"address":"2001:db8:3333:4444::8888","geolocation":{"postal_code":"10112","timezone":"Europe/Berlin","city_name":"Berlin","country_code":"DE","subdivisions":[{"iso_code":"BE","name":"Land Berlin"}]}}},"vpn_origin_timezone":"Europe/Berlin","ip_address":{"location":{"accuracy_radius":96,"latitude":51.5142,"longitude":-0.0931,"time_zone":"Europe/London"},"city":{"names":{"en":"London"}}}}"#
    let output = try scrub(event, as: name)
    for path in [["ip_info", "v4", "geolocation", "timezone"], ["ip_info", "v6", "geolocation", "timezone"], ["vpn_origin_timezone"], ["ip_address", "location", "time_zone"]] {
        let zone = try path.count == 1 ? value(output, path[0]) : path.count == 3 ? value(output, path[0], path[1], path[2]) : value(output, path[0], path[1], path[2], path[3])
        #expect(TimeZone(identifier: zone) != nil, "\(path.joined(separator: ".")) = \(zone)")
    }
}

/// A check's result written as one digit under a personal field's key
/// ("dob": 1, "document_number": 0) is no birth date and no number: it stays.
@Test(arguments: renderings)
func oneDigitResultsUnderPersonalKeysStay(_ name: String) throws {
    let callback = #"{"reference":"ref_7Hq2Lm","event":"verification.accepted","verification_result":{"face":{"face":1},"document":{"name":1,"dob":1,"age":1,"expiry_date":1,"document_number":0,"gender":""},"address":{"name":1,"full_address":1}},"verification_data":{"document":{"name":{"first_name":"Rosalind","last_name":"Achterberg"},"dob":"1984-03-17","document_number":"C03005988"}}}"#
    let output = try scrub(callback, as: name)
    #expect(try value(output, "verification_result", "document", "dob") == "1")
    #expect(try value(output, "verification_result", "document", "document_number") == "0")
    #expect(try value(output, "verification_data", "document", "dob") != "1984-03-17")
}

/// A house number with its letter ("32b") opens the line that joins a split
/// address as it stands in its own field, on the same street.
@Test(arguments: renderings)
func lettedHouseNumberAgreesWithItsLine(_ name: String) throws {
    for seed in UInt64(1)...4 {
        let response = #"{"previous_addresses":[{"street_name":"Whiteladies Road","house_number":"32b","apt":"Flat 9","city":"Bristol","zip":"BS8 1TH","country":"GB","formatted":"32b Whiteladies Road, Bristol BS8 1TH, United Kingdom"}]}"#
        let output = try scrub(response, as: name, seed: seed)
        let street = try value(output, "previous_addresses", "0", "street_name"), number = try value(output, "previous_addresses", "0", "house_number")
        let line = try value(output, "previous_addresses", "0", "formatted")
        #expect(number != "32b" && line.hasPrefix("\(number) \(street), "), "\(number) \(street) vs \(line)")
    }
}

/// A dotted birth date whose day and month are the same number is read day
/// first, so parts beside it take the stand-in's day and month in their places;
/// a floor written the German way under "unit" is a unit.
@Test(arguments: renderings)
func sameDayAndMonthAndGermanFloors(_ name: String) throws {
    for seed in UInt64(1)...6 {
        let response = #"{"subject":{"fullName":"Jennifer Okafor","dob":"10.10.1956","dobParts":{"day":10,"month":10,"year":1956}},"address":{"address1":"Am Mühlbach 13a","unit":"2. OG","town":"Hamburg","zip":"20095","country":"DE"}}"#
        let output = try scrub(response, as: name, seed: seed)
        let date = try value(output, "subject", "dob").split(separator: ".").compactMap { Int($0) }
        let parts = try ["day", "month", "year"].map { try Int(value(output, "subject", "dobParts", $0)) }
        #expect(parts == date.map(Optional.some), "parts \(parts), date \(date)")
        let unit = try value(output, "address", "unit")
        #expect(unit != "2. OG" && unit.range(of: #"^\d\. OG$"#, options: .regularExpression) != nil, "\(unit)")
    }
}

/// Nine digits written as an SSN under a national ID's key, which no other
/// kind's check passes, take an SSN the SSA could issue.
@Test func ssnShapedNationalIDTakesAnIssuableOne() throws {
    var made: [String] = []
    for seed in UInt64(1)...30 {
        let ssn = try value(scrub(#"{"first_name":"Rosalind","national_id":{"data":"458-96-1485"}}"#, as: "signup.json", seed: seed), "national_id", "data")
        let area = Int(ssn.prefix(3)) ?? 0
        if ssn == "458-96-1485" || ssn.range(of: #"^\d{3}-\d{2}-\d{4}$"#, options: .regularExpression) == nil || area == 0 || area == 666 || area >= 900 || ssn.dropFirst(4).hasPrefix("00") || ssn.hasSuffix("0000") { made.append(ssn) }
    }
    #expect(made.isEmpty, "not SSNs the SSA issues: \(made)")
}

private func scrubText(_ text: String, seed: UInt64 = 5) throws -> String {
    String(decoding: try Scrubber.scrub(Data(text.utf8), name: "Pasted text", forceFullDetection: false, seed: seed).output, as: UTF8.self)
}

/// A phone number named as one in a sentence is replaced in any country's
/// grouping, after an IBAN or not.
@Test func phonesNamedInProseAreReplaced() throws {
    for (note, phone) in [("Mail sent to Via delle Rose 12, 40121 Bologna (BO) was returned. Her IBAN is GB82WEST12345698765432 and phone 323 1798382. Escalated to tier 2.", "1798382"),
                          ("The address on the application was Viale Mazzini 7, 10121 Torino (TO). Her IBAN is GB82WEST12345698765432 and phone +39 347 112 0583. Escalated to tier 2.", "112 0583")] {
        let output = try scrubText(note)
        #expect(!output.contains(phone) && output.contains("tier 2"), "\(output)")
    }
}

/// A birth date written with a time ("1975-11-22T00:00:00Z") keeps its time
/// and zone; only the date changes.
@Test(arguments: renderings)
func birthDateWithTimeKeepsItsTime(_ name: String) throws {
    let output = try scrub(#"{"rows":[{"input":{"nm":"Odalys Ferriter","dob":"1975-11-22T00:00:00Z"}}]}"#, as: name)
    let dob = try value(output, "rows", "0", "input", "dob")
    #expect(dob != "1975-11-22T00:00:00Z" && dob.range(of: #"^\d{4}-\d{2}-\d{2}T00:00:00Z$"#, options: .regularExpression) != nil, "\(dob)")
}

/// An address validator's split house number ("primary_number") is replaced.
@Test(arguments: renderings)
func primaryNumberIsAHouseNumber(_ name: String) throws {
    let output = try scrub(#"{"subject":{"firstName":"Ottilie","address":{"primaryNumber":"4387","streetName":"Kingsbridge Ct","cityName":"Cedar Rapids"}},"components":{"primary_number":"3961","street_name":"Larchmont","street_suffix":"Ln"}}"#, as: name)
    #expect(try value(output, "subject", "address", "primaryNumber") != "4387")
    #expect(try value(output, "components", "primary_number") != "3961")
    #expect(try value(output, "components", "street_suffix") == "Ln")
}

/// A street's whole name goes in a log line: an Australian one the model reads
/// from its kind on ("Tce, …"), a Spanish one whose name is a kind of street too.
@Test func streetNamesInLogLinesAreReplaced() throws {
    let log = """
    {"ts":"2026-04-08T02:11:09.402Z","level":"info","msg":"address normalized","input":"317 Coolabah Tce, Fremantle WA 2601"}
    {"ts":"2026-04-08T02:11:10.118Z","level":"info","msg":"address normalized","input":"Paseo de la Alameda, 128, 52198 Bilbao"}
    """
    let output = try scrubText(log)
    for part in ["317", "Coolabah", "Alameda", "128,", "Bilbao"] { #expect(!output.contains(part), "\(part): \(output)") }
}

/// An Italian address written in a letter's block and again in its body is
/// one address: the same stand-in, in Italy, though its province ("BA") is
/// also a Brazilian state's code.
@Test func italianAddressInALetterIsOneAddress() throws {
    let letter = """
    Ottilie Brannagh
    Viale Bracciano 188
    41500 Padova (BA)
    Italy

    Dear Ms Brannagh,

    Please send a recent utility bill showing Viale Bracciano 188, 41500 Padova (BA).
    """
    for seed in UInt64(1)...4 {
        let output = try scrubText(letter, seed: seed)
        let lines = output.components(separatedBy: "\n")
        let block = lines[1] + ", " + lines[2]
        #expect(output.contains("showing \(block)."), "\(output)")
        #expect(lines[2].range(of: #"^\d{5} [\p{L} ]+ \([A-Z]{2}\)$"#, options: .regularExpression) != nil && !output.contains("Padova"), "\(output)")
    }
}

/// A letter's address abroad, in its block and again in its body, is one
/// address: one flat ("8º C") and one city, though only the block names the country.
@Test func addressAbroadInALetterKeepsOneFlatAndOneCity() throws {
    let spanish = "Ottilie Brannagh\nAvenida de los Almendros, 16, 8º C\n43269 Murcia\nSpain\n\nPlease send a bill showing Avenida de los Almendros, 16, 8º C, 43269 Murcia.\n"
    let german = "Ottilie Brannagh\nMühlbachgasse 8a\n12825 Rostock\nGermany\n\nPlease send a bill showing Mühlbachgasse 8a, 12825 Rostock.\n"
    for seed in UInt64(1)...4 {
        let es = try scrubText(spanish, seed: seed).components(separatedBy: "\n")
        #expect(es[5].contains(es[1] + ", " + es[2]), "\(es)")
        let de = try scrubText(german, seed: seed).components(separatedBy: "\n")
        #expect(de[5].contains(de[1] + ", " + de[2]), "\(de)")
    }
}

/// Last four digits named by their kind in a sentence are replaced, with no
/// whole number anywhere to read them off; a year after "ends in" is no one's.
@Test func lastFourInProseAreReplaced() throws {
    let ticket = """
    Hi team, the applicant's date of birth on file is 11/18/1951 and the SSN we submitted ends in 6413.
    Customer Ottilie Brannagh called in, says her card ending 8806 was declined twice.
    Spoke to Ottilie again, verified the last four of SSN (3159).
    The promotion ends in 2027, and the invoice total was 1250.
    """
    for (name, text) in [("ticket", ticket), ("json", #"{"comments":[{"body":"Customer Ottilie Brannagh called in, says her card ending 8806 was declined twice."},{"body":"Spoke to Ottilie again, verified the last four of SSN (3159)."}]}"#)] {
        let output = try name == "json" ? scrub(text, as: "ticket.json") : scrubText(text)
        for digits in ["6413", "8806", "3159"] where text.contains(digits) { #expect(!output.contains(digits), "\(name): \(output)") }
        if name == "ticket" { #expect(output.contains("ends in 2027") && output.contains("1250"), "\(output)") }
    }
}


/// A screening hit that lists two birth dates in one field replaces both, each in its own format,
/// and a time after a single date still stays as written.
@Test func aListOfBirthDatesTakesAStandInForEach() throws {
    let output = try scrub(#"{"hits":[{"name":"Imre Halvorsen-Bakó","birth_date":"1958-08-17, 1957-08-17","dob":"03/14/1987 08:30","dates_of_birth":"12 Mar 1961; 14 Apr 1962"}]}"#, as: "screening.json")
    for original in ["1958-08-17", "1957-08-17", "03/14/1987", "12 Mar 1961", "14 Apr 1962"] { #expect(!output.contains(original), "\(output)") }
    #expect(output.range(of: #""birth_date":"\d{4}-\d{2}-\d{2}, \d{4}-\d{2}-\d{2}""#, options: .regularExpression) != nil, "\(output)")
    #expect(output.range(of: #""dob":"\d{2}/\d{2}/\d{4} 08:30""#, options: .regularExpression) != nil, "\(output)")
}

/// A customer's ID whose value opens like a reference ("ref_9876") is still theirs; a request's reference stays.
@Test func aCustomersIDThatLooksLikeAReferenceIsTheirs() throws {
    let output = try scrub(#"{"referrer_customer_id":"ref_9876","request_ref":"ref-55af36d14d","status":"approved"}"#, as: "decision.json")
    #expect(!output.contains("ref_9876") && output.contains(#""request_ref":"ref-55af36d14d""#), "\(output)")
}

/// An address split into fields and written again on one line, in capitals
/// or not, in a country that writes the street first or the number first:
/// the line is the split parts' stand-ins joined as the original joined them,
/// and no word of the real street is left in it.
@Test(arguments: renderings)
func aSplitAddressAndItsOneLineFormAgree(_ name: String) throws {
    let addresses: [[(String, String)]] = [
        [("address1", "AM GRIES 57a"), ("city", "MÜNCHEN"), ("postalCode", "80538"), ("countryCode", "DE"), ("singleLine", "AM GRIES 57a, 80538 MÜNCHEN")],
        [("address1", "Am Gries 57a"), ("city", "München"), ("postalCode", "80538"), ("countryCode", "DE"), ("singleLine", "Am Gries 57a, 80538 München")],
        [("addressLine1", "GOETHESTRASSE 640"), ("town", "MÜNCHEN"), ("zipCode", "80538"), ("countryCode", "DE"), ("singleLine", "GOETHESTRASSE 640, 80538 MÜNCHEN, Germany")],
        [("line1", "CORSO CAVOUR 83"), ("city", "TORINO"), ("region", "TO"), ("zipCode", "10128"), ("countryCode", "IT"), ("fullAddress", "CORSO CAVOUR 83, 10128 TORINO TO")],
        [("streetName", "RUA XV DE NOVEMBRO"), ("buildingNumber", "29a"), ("town", "CURITIBA"), ("region", "PR"), ("zip", "80010-010"), ("countryCode", "BRA"), ("singleLine", "RUA XV DE NOVEMBRO 29a, 80010-010 CURITIBA, PR")],
        [("street", "OUDEGRACHT 112"), ("city", "UTRECHT"), ("postcode", "3511 LX"), ("country", "NL"), ("singleLine", "OUDEGRACHT 112, 3511 LX UTRECHT")],
        [("street", "CALLE MAYOR 14"), ("city", "SEVILLA"), ("postcode", "41004"), ("country", "ES"), ("singleLine", "CALLE MAYOR 14, 41004 SEVILLA, Spain")],
        [("address1", "12 RUE DES ACACIAS"), ("city", "LYON"), ("postalCode", "69003"), ("country", "FR"), ("singleLine", "12 RUE DES ACACIAS, 69003 LYON")],
        [("address1", "6a KINGSLEY ROAD"), ("city", "LEEDS"), ("postalCode", "LS6 3HN"), ("countryCode", "GB"), ("singleLine", "6a KINGSLEY ROAD, LEEDS LS6 3HN")],
    ]
    for seed in UInt64(1)...4 {
        for fields in addresses {
            let json = "{\"subject\":{\"fullName\":\"Odalys Ferriter\"},\"address\":{" + fields.map { "\"\($0.0)\":\"\($0.1)\"" }.joined(separator: ",") + "}}"
            let output = try scrub(json, as: name, seed: seed)
            let (lineKey, line) = fields.last!
            var expected = line
            // Longest first, each where it is a word of its own: "TORINO" before the "TO" after it.
            for (key, original) in fields.dropLast().sorted(by: { $0.1.count > $1.1.count }) {
                let pattern = #"(?<![\p{L}\d])"# + NSRegularExpression.escapedPattern(for: original) + #"(?![\p{L}\d])"#
                expected = expected.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: try value(output, "address", key)), options: .regularExpression)
            }
            let written = try value(output, "address", lineKey)
            #expect(written == expected, "seed \(seed): \(line) → \(written), parts give \(expected)")
            for word in fields[0].1.split(separator: " ") where word.count >= 4 && word.allSatisfy(\.isLetter) && !["CALLE", "CORSO", "ROAD", "RUE"].contains(word.uppercased()) {
                #expect(!output.uppercased().contains(word.uppercased()), "seed \(seed): \(word) left in \(output)")
            }
        }
    }
}

/// A German street opening with "Am" or "An der" keeps those words, in the
/// original's case, and takes another name after them.
@Test func aGermanStreetKeepsItsOpeningWords() throws {
    for (street, lead) in [("Am Gries 57a", "Am "), ("AM GRIES 57a", "AM "), ("An der Alster 4", "An der ")] {
        let output = try scrub(#"{"address":{"street":"\#(street)","city":"Hamburg","zip":"20095","country":"DE"}}"#, as: "check.json")
        let written = try value(output, "address", "street")
        #expect(written.hasPrefix(lead) && !written.lowercased().contains("gries") && !written.lowercased().contains("alster"), "\(street) → \(written)")
    }
}

/// One flat written in capitals in one address and as a word in another
/// takes one stand-in, each in its own case; and a floor's one-digit number
/// ("3. OG") always takes another digit, never a placeholder.
@Test func aUnitKeepsItsCaseAndAlwaysTakesANumber() throws {
    let output = try scrub(#"{"address":{"streetAddress":"108 WHITELADIES ROAD","line2":"FLAT 5B","town":"BRISTOL","postcode":"BS8 1TH"},"previousAddresses":[{"thoroughfare":"Kingsley Road","houseNumber":"814","apt":"Flat 5B","town":"Leeds","postcode":"LS6 3HN"}]}"#, as: "check.json")
    let caps = try value(output, "address", "line2"), word = try value(output, "previousAddresses", "0", "apt")
    #expect(caps.hasPrefix("FLAT ") && word.hasPrefix("Flat ") && caps == word.uppercased() && caps != "FLAT 5B", "\(caps) / \(word)")
    for seed in UInt64(1)...40 {
        let floor = try value(scrub(#"{"address":{"street":"Lindenallee 12","address2":"3. OG","city":"München","postcode":"80538","country":"DE"}}"#, as: "check.json", seed: seed), "address", "address2")
        #expect(floor.range(of: #"^\d\. OG$"#, options: .regularExpression) != nil && floor != "3. OG", "seed \(seed): \(floor)")
    }
}

/// A name under "Name:" beside a street address is the person living there, as it is beside
/// an email: replaced, not left for review; a business's name beside one stays as written.
@Test func aLabelledNameBesideAnAddressIsReplaced() throws {
    func scrubbed(_ text: String, _ name: String) throws -> String {
        String(decoding: try Scrubber.scrub(Data(text.utf8), name: name, forceFullDetection: false, seed: 5).output, as: UTF8.self)
    }
    let record = "Name:    Anđa Tomić\nAddress:     594 Hegedûs Gyula utca 76. Apt. 289 Mogyorósbánya Hungary\n"
    #expect(!(try scrubbed(record, "Pasted text")).contains("Tomić"))
    #expect(try scrubbed(#"{"name":"Riverside Clinic","address":"Hegedűs Gyula utca 76, 1136 Budapest"}"#, "record.json").contains("Riverside Clinic"))
    #expect(try scrubbed("Name: Northwind Traders\nAddress: 12 Harbor Road, Leeds LS6 3HN\n", "Pasted text").contains("Northwind Traders"))
}

/// An SSN's stand-in is one the SSA could issue whole: no area of 000, 666
/// or 9xx, no group of 00 and no serial of 0000, in each way it is written.
@Test(arguments: renderings)
func ssnStandInIsIssuableWhole(_ name: String) throws {
    let response = #"{"request_id":"req_FYJSHYZqytMESg5K","subject":{"first_name":"Leilani","last_name":"Kowalczyk","tax_id":114232855,"ssn_last4":2855,"ssn_display":"***-**-2855","identifiers":[{"type":"US_SSN","value":"114 23 2855"},{"type":"ITIN","value":"996-92-9800"}]},"results":{"ssn_match":"MATCH","name_match":"PARTIAL","dob_match":"MATCH","reason_codes":["R137"],"score":685,"confidence":0.07,"ssn_issued_start_year":1982,"deceased":"false"},"notes":["SSN on file ends in 2855; customer read back 114-23-2855."],"created_at":"2023-02-22 03:19:33"}"#
    for seed in [4514971557829735021] + Array(UInt64(1)...60) {
        // A stand-in name with an apostrophe ("O'Brien") is escaped for the shell in a curl command.
        let output = try scrub(response, as: name, seed: seed).replacingOccurrences(of: #"'\''"#, with: "'")
        for written in [try value(output, "subject", "tax_id"), try value(output, "subject", "identifiers", "0", "value")] {
            let d = written.filter(\.isNumber)
            let area = Int(d.prefix(3)) ?? 0
            #expect(d.count == 9 && area != 0 && area != 666 && area < 900 && d.dropFirst(3).prefix(2) != "00" && d.suffix(4) != "0000", "seed \(seed): \(written)")
        }
    }
}

/// One SSN written spaced, dashed in a note and ended by "ssn_last4" takes
/// one stand-in in every spelling, its note's included.
@Test(arguments: renderings)
func ssnSpellingsShareOneStandIn(_ name: String) throws {
    let response = #"{"RequestId":"0e7eb179-f0b1-4546-9239-7b7693e9bc34","Subject":{"FirstName":"Jiwon","LastName":"Hallorann","Tin":"329 69 1435","SsnLast4":"1435","MaskedSsn":"XXX-XX-1435","Identifiers":[{"Type":"SSN","Value":"329 69 1435"}]},"Results":{"SsnMatch":"PARTIAL","Score":981},"Notes":["SSN on file ends in 1435; customer read back 329-69-1435."]}"#
    for seed in UInt64(1)...60 {
        let output = try scrub(response, as: name, seed: seed).replacingOccurrences(of: #"'\''"#, with: "'")
        let tin = try value(output, "Subject", "Tin").filter(\.isNumber)
        let note = try value(output, "Notes", "0")
        let dashed = note.split(separator: " ").last.map { $0.filter(\.isNumber) } ?? ""
        #expect(tin.count == 9 && tin != "329691435" && dashed == tin, "seed \(seed): \(tin) vs \(note)")
        #expect(try value(output, "Subject", "SsnLast4") == String(tin.suffix(4)))
    }
}

/// A German ID card's number with X's among its letters ("X6HXVN7MN1") is
/// the card's, not a mask: its stand-in passes the card's check digit.
@Test(arguments: renderings)
func germanCardNumberWithXsKeepsItsCheck(_ name: String) throws {
    func icao(_ s: Substring) -> Int {
        s.enumerated().reduce(0) { sum, item in
            let c = item.element
            let v = c.isNumber ? c.wholeNumberValue! : Int(c.asciiValue!) - 55
            return sum + v * [7, 3, 1][item.offset % 3]
        } % 10
    }
    let response = #"{"verification_id":"dv_8KfP2mQx","documents":{"national_ids":[{"country":"DE","type":"ID_CARD","value":"X6HXVN7MN1"},{"country":"DE","type":"ID_CARD","number":"FXTH5X8JY7"},{"country":"DE","type":"ID_CARD","number":"PVX218X8F6"}]},"checks":{"mrz_checksum_valid":true}}"#
    for seed in UInt64(1)...6 {
        let output = try scrub(response, as: name, seed: seed).replacingOccurrences(of: #"'\''"#, with: "'")
        for (index, (key, original)) in [("value", "X6HXVN7MN1"), ("number", "FXTH5X8JY7"), ("number", "PVX218X8F6")].enumerated() {
            let made = try value(output, "documents", "national_ids", String(index), key)
            #expect(made != original && made.count == 10 && made.allSatisfy({ "CFGHJKLMNPRTVWXYZ0123456789".contains($0) }) && icao(made.prefix(9)) == made.last?.wholeNumberValue, "seed \(seed): \(original) → \(made)")
        }
    }
}

/// A bare "name" beside a street address is the person living there even when
/// one of its words is a rare dictionary entry the name lists don't hold ("Ilka
/// Sztojka"), in JSON as in plain text, the street first or the number first;
/// a business's name beside one stays as written.
@Test(arguments: renderings)
func aRareWordNameBesideAnAddressIsReplaced(_ name: String) throws {
    for address in ["Hegedűs Gyula utca 76, 1136 Budapest", "76 Hegedűs Gyula utca, 1136 Budapest"] {
        let response = #"{"ref":"rec_5Rk2Wq","name":"Ilka Sztojka","address":"\#(address)","status":"REVIEW"}"#
        let output = try scrub(response, as: name)
        #expect(!output.contains("Sztojka") && !output.contains("Ilka"), "\(output)")
        #expect(try scrub(#"{"name":"Halcyon Bakery","address":"\#(address)"}"#, as: name).contains("Halcyon Bakery"))
    }
    let pasted = String(decoding: try Scrubber.scrub(Data("Name: Ilka Sztojka\nAddress: Hegedűs Gyula utca 76, 1136 Budapest\n".utf8), name: "Pasted text", forceFullDetection: false, seed: 5).output, as: UTF8.self)
    #expect(!pasted.contains("Sztojka"), "\(pasted)")
}

/// A floor or flat in one address never draws another the document writes
/// ("1. OG" beside a current "2. OG"), so it always takes a stand-in of its
/// own shape rather than a placeholder.
@Test(arguments: renderings)
func aUnitNeverDrawsAnotherAddresssUnit(_ name: String) throws {
    let response = #"{"fullName":"Wendelin Achterberg","address":{"streetAddress":"Am Gries 654","address2":"2. OG","city":"München","postalCode":"80538","countryCode":"DE"},"previousAddresses":[{"street":"AM MÜHLBACH","buildingNumber":613,"apt":"1. OG","town":"HAMBURG","postcode":"20095","country":"DE"},{"street":"CALLE MAYOR","buildingNumber":914,"apt":"8º B","town":"SEVILLA","postcode":"41004","country":"ES"},{"street":"CALLE OLIVOS","buildingNumber":12,"apt":"3º B","town":"BILBAO","postcode":"48001","country":"ES"}]}"#
    for seed in UInt64(1)...40 {
        let output = try scrub(response, as: name, seed: seed).replacingOccurrences(of: #"'\''"#, with: "'")
        #expect(!output.contains("[ADDRESS]"), "seed \(seed): \(output)")
        let units = [try value(output, "address", "address2")] + (try (0..<3).map { try value(output, "previousAddresses", String($0), "apt") })
        for (unit, pattern) in zip(units, [#"^\d\. OG$"#, #"^\d\. OG$"#, #"^\dº B$"#, #"^\dº B$"#]) {
            #expect(unit.range(of: pattern, options: .regularExpression) != nil && !["2. OG", "1. OG", "8º B", "3º B"].contains(unit), "seed \(seed): \(units)")
        }
    }
}

/// A birth date a check echoes back in other spellings ("dob_variants") is the
/// same day in each: every spelling takes the one stand-in day, written as the
/// original was, its month's name and its year of two digits among them.
@Test(arguments: renderings)
func birthDateSpellingsFollowTheDate(_ name: String) throws {
    let response = #"{"check_id":"chk_4Rz8Lm2Q","subject":{"given_name":"Ottoline","family_name":"Wexcombe","date_of_birth":"1984-03-07","dob_variants":["03/07/1984","March 7, 1984","7 March 1984","07-Mar-1984","07MAR1984","7/3/84"]},"result":{"dob_match":"PARTIAL","note":"bureau holds 07/03/1984"}}"#
    for seed in UInt64(1)...4 {
        let output = try scrub(response, as: name, seed: seed)
        for original in ["1984", "March 7", "7 March", "07-Mar", "07MAR", "7/3/84"] { #expect(!output.contains(original), "\(original) left: \(output)") }
        let iso = try value(output, "subject", "date_of_birth").split(separator: "-").compactMap { Int($0) }
        try #require(iso.count == 3)
        let (year, month, day) = (iso[0], iso[1], iso[2])
        let names = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        let full = names[month - 1], short = String(full.prefix(3))
        let expected = [String(format: "%02d/%02d/%d", month, day, year), "\(full) \(day), \(year)", "\(day) \(full) \(year)", String(format: "%02d-%@-%d", day, short, year),
                        String(format: "%02d%@%d", day, short.uppercased(), year), "\(day)/\(month)/\(String(format: "%02d", year % 100))"]
        let variants = try (0..<6).map { try value(output, "subject", "dob_variants", String($0)) }
        #expect(variants == expected, "seed \(seed): \(variants) for \(iso)")
        #expect(try value(output, "result", "note") == String(format: "bureau holds %02d/%02d/%d", day, month, year))
    }
}

/// A driver's licence under its initials ("dl": {"number": …}), inside a
/// payload a check stores as escaped JSON, is replaced, and so is the same
/// number where a note names it by "DL" alone.
@Test(arguments: renderings)
func driversLicenceByItsInitialsIsReplaced(_ name: String) throws {
    let payload = #"{\"applicant\":{\"name\":\"Ottoline Wexcombe\"},\"dl\":{\"number\":\"N4829175\",\"state\":\"CA\",\"expires\":\"2025-11-30\"}}"#
    let response = #"{"check_id":"chk_9Tq3Vx7B","payload":"\#(payload)","note":"prior DL N4829175 expired","status":"review"}"#
    let output = try scrub(response, as: name)
    #expect(!output.contains("N4829175"), "\(output)")
    let note = try value(output, "note")
    #expect(note.hasPrefix("prior DL ") && note.hasSuffix(" expired"), "\(note)")
    let standIn = String(note.dropFirst("prior DL ".count).dropLast(" expired".count))
    #expect(standIn.count == 8 && standIn.first!.isLetter && standIn.dropFirst().allSatisfy(\.isNumber), "\(standIn)")
    #expect(try value(output, "payload").contains(#""number":"\#(standIn)""#), "\(output)")
    #expect(try value(output, "status") == "review" && value(output, "check_id") == "chk_9Tq3Vx7B")
}
