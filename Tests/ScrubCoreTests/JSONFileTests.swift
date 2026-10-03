import Foundation
@testable import ScrubCore
import Testing

@Test(arguments: [
    (#"{"a":1,"b":[true,null,"é"]}"#, "{\n  \"a\": 1,\n  \"b\": [\n    true,\n    null,\n    \"é\"\n  ]\n}\n"),
    (#"{"a":1,"a":2,"n":1.0}"#, "{\n  \"a\": 2,\n  \"n\": 1.0\n}\n"),
    (#"{"large":123456789012345678901234567890,"escaped":"\u00e9"}"#, "{\n  \"large\": 123456789012345678901234567890,\n  \"escaped\": \"é\"\n}\n")
])
func orderedJSONRoundTrip(_ input: String, _ expected: String) throws {
    let parsed = try OrderedJSON.parse(input)
    #expect(OrderedJSON.render(parsed).0 == expected)
}

@Test(arguments: ["francisco", "customers"])
func orderedJSONFixtureOutput(_ name: String) throws {
    let source = try String(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "json")), encoding: .utf8)
    let expected = try String(contentsOf: #require(Bundle.module.url(forResource: name + ".expected", withExtension: "json")), encoding: .utf8)
    #expect(OrderedJSON.render(try OrderedJSON.parse(source)).0 == expected)
}

@Test func jsonScrubsValuesAndKeepsNumberTypes() throws {
    let result = try Scrubber.scrub(Data(#"{"phone":2128675309,"count":42,"name":"Robert Mitchell","email":"robert.mitchell@acme.com"}"#.utf8), name: "a.json")
    let out = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
    #expect(out["count"] as? Int == 42)
    #expect(out["phone"] as? Int != 2128675309)
    #expect(out["name"] as? String != "Robert Mitchell")
    #expect(out["email"] as? String != "robert.mitchell@acme.com")
    if case .text(let preview, let marks, _) = result.preview {
        #expect(!marks.isEmpty)
        #expect(marks.allSatisfy { !$0.range.isEmpty && $0.range.upperBound <= (preview as NSString).length })
    } else { Issue.record("Expected text preview") }
}

@Test func malformedJSONIsRejected() {
    #expect(throws: ScrubError.unsupported("invalid_json")) {
        try Scrubber.scrub(Data(#"{"name":"Robert Mitchell", "#.utf8), name: "a.json")
    }
}

@Test func jsonFixtureKeepsRecordsAndAssociatesPersona() throws {
    let data = try Data(contentsOf: #require(Bundle.module.url(forResource: "francisco", withExtension: "json")))
    let result = try Scrubber.scrub(data, name: "francisco.json")
    let out = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
    let customer = try #require(out["customer"] as? [String: Any])
    let first = try #require(customer["firstName"] as? String)
    let last = try #require(customer["lastName"] as? String)
    let email = try #require(customer["email"] as? String)
    #expect(email.hasPrefix("\(first.lowercased()).\(last.lowercased())@"))
    #expect(out["plan"] as? String == "enterprise")
    #expect(out["seats"] as? Int == 12)
    #expect(!(out["support_notes"] as? String ?? "").contains("Francisco Ramini"))
}

@Test func jsonNumericIdentityFieldsAndCardValidation() throws {
    let input = #"{"phone":2128675309,"dob":19900101,"ssn":123456789.0,"value":4111111111111111,"total":4111111111111112,"count":19900101}"#
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.json")
    let out = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
    #expect(out["phone"] as? Int != 2128675309)
    #expect(out["dob"] as? Int != 19900101)
    #expect(out["ssn"] as? Double != 123456789)
    #expect(out["value"] as? Int != 4111111111111111)
    #expect(out["total"] as? Int == 4111111111111112)
    #expect(out["count"] as? Int == 19900101)
}

@Test func jsonSensitiveKeysAndDuplicateKeys() throws {
    let input = #"{"password":"hunter2","api_key":"sk_live_51Hx9aQ2eZvKYlo2C","alice@example.com":{"plan":"pro"},"customer_2128675309":1,"plain":1,"plain":2}"#
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.json")
    let output = String(decoding: result.output, as: UTF8.self)
    #expect(!output.contains("hunter2"))
    #expect(!output.contains("alice@example.com"))
    #expect(!output.contains("2128675309"))
    #expect(output.contains(#""plain": 2"#))
    #expect(!output.contains(#""plain": 1"#))
}

@Test func jsonRepeatedValuesGetStableStandIns() throws {
    let input = #"[{"email":"a.b@corp.com"},{"email":"a.b@corp.com"},{"email":"c.d@corp.com"}]"#
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.json")
    let out = try #require(JSONSerialization.jsonObject(with: result.output) as? [[String: String]])
    #expect(out[0]["email"] == out[1]["email"])
    #expect(out[0]["email"] != out[2]["email"])
}

@Test func jsonNestedEmailUsesEnclosingPersona() throws {
    let input = #"{"firstName":"Ana","lastName":"Pereira","contact":{"email":"work@pereira.pt"}}"#
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.json")
    let out = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
    let first = try #require(out["firstName"] as? String)
    let last = try #require(out["lastName"] as? String)
    let contact = try #require(out["contact"] as? [String: String])
    #expect(contact["email"]?.hasPrefix("\(first.lowercased()).\(last.lowercased())@") == true)
}

@Test func jsonSensitiveDecimalsKeepFloatShape() throws {
    let input = #"{"phone":2128675309.0,"dob":19900101.0,"ssn":123456789.0,"tel":2.128675309e9,"ratio":2128675309.0}"#
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.json")
    let out = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: NSNumber])
    for key in ["phone", "dob", "ssn", "tel"] { #expect(out[key]?.doubleValue != (["dob": 19900101.0, "ssn": 123456789.0][key] ?? 2128675309.0)) }
    #expect(out["ratio"]?.doubleValue == 2128675309.0)
    #expect(result.counts.values.reduce(0, +) == 4)
}

@Test func jsonIdentityAndSecretFieldsKeepRequiredShapes() throws {
    let input = #"{"national_id":"SE-TEST-827364","passportNumber":"X1234567","tax_id":123456789,"password":"Tr0ub4dor&3","api_key":"sk_live_51Hx9aQ2eZvKYlo2C","token":"sk_live_","plan":"pro"}"#
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.json")
    let out = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
    let id = try #require(out["national_id"] as? String)
    #expect(id.range(of: #"^[A-Z]{2}-[A-Z]{4}-\d{6}$"#, options: .regularExpression) != nil)
    #expect(id != "SE-TEST-827364")
    #expect(out["passportNumber"] as? String != "X1234567")
    #expect(out["tax_id"] as? Int != 123456789)
    #expect((out["password"] as? String)?.count == 24)
    #expect((out["api_key"] as? String)?.hasPrefix("sk_live_") == true)
    #expect(out["token"] as? String != "sk_live_")
    #expect(out["plan"] as? String == "pro")
}

@Test func jsonRecordsKeepPeopleDistinct() throws {
    let input = #"[{"name":"Robert Mitchell","email":"robert.mitchell@acme.com"},{"name":"Ana Pereira","email":"ana.pereira@acme.com"},{"name":"Robert Mitchell","email":"robert.mitchell@acme.com"}]"#
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.json")
    let rows = try #require(JSONSerialization.jsonObject(with: result.output) as? [[String: String]])
    #expect(rows[0] != rows[1])
    #expect(rows[0] == rows[2])
    for row in rows {
        let names = try #require(row["name"]?.lowercased().split(separator: " "))
        #expect(row["email"]?.hasPrefix("\(names[0]).\(names[names.count - 1])@") == true)
    }
}

@Test func jsonCurrencyCodeStaysWhileCityChanges() throws {
    let result = try Scrubber.scrub(Data(#"{"currency":"USD","city":"Lisbon"}"#.utf8), name: "a.json")
    let out = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: String])
    #expect(out["currency"] == "USD")
    #expect(out["city"] != "Lisbon")
}

@Test func jsonFixtureNotesSharePersonaAndOtherPeopleStayDistinct() throws {
    let data = try Data(contentsOf: #require(Bundle.module.url(forResource: "francisco", withExtension: "json")))
    let result = try Scrubber.scrub(data, name: "francisco.json")
    let out = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
    let customer = try #require(out["customer"] as? [String: String])
    let first = try #require(customer["firstName"])
    let last = try #require(customer["lastName"])
    let notes = try #require(out["support_notes"] as? String)
    #expect(notes.hasPrefix("\(first) \(last) called"))
    #expect(notes.contains("\(first.prefix(1).lowercased())\(last.lowercased())@"))
    let other = try #require(notes.components(separatedBy: "He mentioned ").last?.components(separatedBy: " from finance").first)
    #expect(other != "\(first) \(last)")
    #expect(other.split(separator: " ").count == 2)
}

@Test func jsonKeyPathAddsDetectionContext() throws {
    let input = #"{"birth":{"reference":"1990-01-01"}}"#
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.json")
    let out = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: [String: String]])
    #expect(out["birth"]?["reference"] != "1990-01-01")
}

@Test func jsonCustomerFixtureKeepsNonPersonalFields() throws {
    let data = try Data(contentsOf: #require(Bundle.module.url(forResource: "customers", withExtension: "json")))
    let result = try Scrubber.scrub(data, name: "customers.json")
    let rows = try #require(JSONSerialization.jsonObject(with: result.output) as? [[String: Any]])
    // A customer's ID names them: a stand-in of its shape ("cus_" and one digit).
    #expect((rows[0]["id"] as? String).map { $0 != "cus_1" && $0.range(of: #"^cus_\d$"#, options: .regularExpression) != nil } == true, "\(rows[0])")
    #expect(rows[0]["plan"] as? String == "enterprise")
    #expect(!String(decoding: result.output, as: UTF8.self).contains("robert.mitchell@acme-corp.com"))
    #expect(result.counts.values.reduce(0, +) > 0)
}

@Test func jsonKeyMarksPointAtReplacedKey() throws {
    let input = #"{"owners":{"alice@example.com":{"role":"admin"}},"plain":1}"#
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.json")
    let out = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
    let owners = try #require(out["owners"] as? [String: Any])
    let key = try #require(owners.keys.first)
    #expect(key.contains("@example."))
    if case .text(let text, let marks, _) = result.preview {
        #expect(marks.contains { (text as NSString).substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) == key })
    } else { Issue.record("Expected text preview") }
}

@Test func jsonCardShapedNumberUnderCardKeyIsReplaced() throws {
    let input = #"{"card_number":4111111111111112,"total":4111111111111112}"#
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.json")
    let out = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: Int])
    #expect(out["card_number"] != 4111111111111112)
    #expect(out["total"] == 4111111111111112)
}

// An identity request where the ID sits under a plain "value" key.
@Test func jsonIDNumberUnderValueKeyStaysAnIDNumber() throws {
    let input = #"{"user":{"id_number":{"value":"123456789","type":"us_ssn"},"secret":{"type":"api"}}}"#
    let result = try Scrubber.scrub(Data(input.utf8), name: "a.json")
    let out = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
    let id = try #require((out["user"] as? [String: Any])?["id_number"] as? [String: Any])
    let value = try #require(id["value"] as? String)
    #expect(value != "123456789")
    #expect(value.range(of: #"^\d{9}$"#, options: .regularExpression) != nil)
    #expect(id["type"] as? String == "us_ssn")
}

// Owners hold lists of one field each, and the account itself has a "name".
@Test func jsonFieldListsAreHintedAndAccountNamesStay() throws {
    let input = #"""
    {"accounts":[{"name":"Everyday Checking","subtype":"checking","owners":[{
      "names":["Alberta Bobbeth Charleson"],
      "emails":[{"data":"accountholder0@example.com","type":"primary"}],
      "phone_numbers":[{"data":"2025550123","type":"home"}],
      "addresses":[{"data":{"street":"2992 Cameron Road","region":"NY"}}]
    }]}],"user":{"legal_name":"Jane Smith"},"cells":["A1"]}
    """#
    let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: "a.json").output, as: UTF8.self)
    for original in ["Alberta", "Charleson", "accountholder0", "2025550123", "Cameron", "Jane Smith"] { #expect(!output.contains(original)) }
    for kept in [#""name": "Everyday Checking""#, #""subtype": "checking""#, #""type": "home""#, #""A1""#] { #expect(output.contains(kept)) }
    // The region moves with the address, still a state code.
    #expect(!output.contains(#""region": "NY""#) && output.range(of: #""region": "[A-Z]{2}""#, options: .regularExpression) != nil)
}

@Test(arguments: [
    (#"{"id":7,"name":"Robert Mitchell"}"#, true),
    (#"{"name":"Priya Raghunathan","email":"p@example.org"}"#, true),
    (#"{"customers":[{"name":"Priya Raghunathan"}]}"#, true),
    (#"{"manager":{"name":"Priya Raghunathan"}}"#, true),
    (#"{"plan":{"name":"Premium Checking","seats":12}}"#, false)
])
func bareNameKeyNeedsAPersonRecord(_ input: String, _ replaced: Bool) throws {
    let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: "a.json").output, as: UTF8.self)
    let original = input.contains("Robert") ? "Robert Mitchell" : input.contains("Priya") ? "Priya Raghunathan" : "Premium Checking"
    #expect(output.contains(original) != replaced)
}

// Verification results reuse personal keys for statuses.
@Test func statusValuesUnderPersonalKeysStay() throws {
    let input = #"""
    {"user":{"name":{"given_name":"Leslie","family_name":"Knope"},"date_of_birth":"1990-05-29"},
     "analysis":{"name":"match","first_name":"match","last_name":"no_match","date_of_birth":"match","postal_code":"no_data","street":"partial_match","city":"match","id_number":"match"},
     "authenticity":"match","gender":"match"}
    """#
    let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: "a.json").output, as: UTF8.self)
    #expect(!output.contains("Leslie") && !output.contains("Knope") && !output.contains("1990-05-29"))
    #expect(output.components(separatedBy: "\"match\"").count - 1 == 7)
    for kept in ["no_match", "no_data", "partial_match"] { #expect(output.contains("\"\(kept)\"")) }
}

// Response shapes that used to be replaced, or replaced with the wrong kind of value.
@Test func verificationResponseKeepsDataAndReplacesPeople() throws {
    let input = #"""
    {"eval_id":"11111111-2222-3333-4444-555555555555","id":"Case_FPF-1761754896062",
     "account":{"accountNumber":"92301962141","routingNumber":"122199983"},"request":{"ein":"912355201","entity":"111223333"},
     "business":{"name":"NORTHWIND","website":"https://northwind.io/","phone":"+12125554540"},
     "response":{"callerName":"Jane Doe","phoneNumber":"+14155551212"},
     "address":{"line_1":"463 Mertz Motorway","locality":"San Francisco","postal_code":"94105"},
     "sourceAttribution":{"firstName":["Government"],"address":["USPS","Utility Records"]},
     "fieldValidations":{"dob":0.99,"firstName":0.99},
     "timezones":["america/new_york"],"attributes":{"timeZone":"America/Los_Angeles"},
     "userAgent":"Mozilla/5.0 (Macintosh) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36"}
    """#
    let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: "a.json").output, as: UTF8.self)
    for kept in ["11111111-2222-3333-4444-555555555555", "Case_FPF-1761754896062", #""NORTHWIND""#, "https://northwind.io/", #""Government""#, #""USPS""#, #""Utility Records""#,
                 #""dob": 0.99"#, #""america/new_york""#, #""America/Los_Angeles""#, "Chrome/131.0.0.0"] { #expect(output.contains(kept)) }
    for replaced in ["92301962141", "122199983", "912355201", "111223333", "Jane Doe", "Mertz", "San Francisco", "94105"] { #expect(!output.contains(replaced)) }
    for key in ["accountNumber", "routingNumber", "ein", "entity"] {
        #expect(output.range(of: #""\#(key)": "\d{9,11}""#, options: .regularExpression) != nil)
    }
    #expect(output.range(of: #""locality": "[^"]+""#, options: .regularExpression).map { !output[$0].contains("San Francisco") && !output[$0].contains(" Hill") } == true)
}
