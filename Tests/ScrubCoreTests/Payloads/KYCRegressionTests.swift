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
