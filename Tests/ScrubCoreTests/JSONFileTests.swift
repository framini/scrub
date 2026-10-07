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

/// Half a surrogate pair is allowed by JSON's grammar, and a string cut inside an emoji
/// is written with one: the document is read, its people replaced, the half kept where it stood.
@Test func aHalfSurrogatePairIsRead() throws {
    let document = #"{"email":"\ud800robert.mitchell@acme.com","n\udc00ame":"Robert Mitchell","note":"\ud83d\ude00"}"#
    let output = String(decoding: try Scrubber.scrub(Data(document.utf8), name: "a.json").output, as: UTF8.self)
    #expect(!output.contains("robert.mitchell") && !output.contains("Robert Mitchell"))
    #expect(output.contains(#""n\udc00ame":"#) && output.contains(#""note":"\ud83d\ude00""#))
    #expect(OrderedJSON.render(try OrderedJSON.parse(#"["\ud800","\u00e9\t"]"#)).0 == "[\n  \"\u{FFFD}\",\n  \"é\\t\"\n]\n")
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
    // Each of two keys written alike keeps its own value, as written.
    #expect(output.contains(#""plain":2"#) && output.contains(#""plain":1"#))
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
    for kept in [#""name":"Everyday Checking""#, #""subtype":"checking""#, #""type":"home""#, #""A1""#] { #expect(output.contains(kept)) }
    // The region moves with the address, still a state code.
    #expect(!output.contains(#""region":"NY""#) && output.range(of: #""region":"[A-Z]{2}""#, options: .regularExpression) != nil)
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
                 #""dob":0.99"#, #""america/new_york""#, #""America/Los_Angeles""#, "Chrome/131.0.0.0"] { #expect(output.contains(kept)) }
    for replaced in ["92301962141", "122199983", "912355201", "111223333", "Jane Doe", "Mertz", "San Francisco", "94105"] { #expect(!output.contains(replaced)) }
    for key in ["accountNumber", "routingNumber", "ein", "entity"] {
        #expect(output.range(of: #""\#(key)":"\d{9,11}""#, options: .regularExpression) != nil)
    }
    #expect(output.range(of: #""locality":"[^"]+""#, options: .regularExpression).map { !output[$0].contains("San Francisco") && !output[$0].contains(" Hill") } == true)
}

@Test func jsonIsWrittenInTimeLinearInItsLengthWhateverItHolds() throws {
    // A character outside ASCII early on ("Café Lumen"), then many numbers, each set where it is written.
    func time(_ count: Int) throws -> Duration {
        let text = #"{"venue":"Café Lumen","readings":["# + (0..<count).map { (index: Int) -> String in String(1000 + index) }.joined(separator: ",") + "]}"
        let value = try OrderedJSON.parse(text)
        let clock = ContinuousClock()
        let started = clock.now
        let (output, _) = OrderedJSON.render(value)
        #expect(output.contains("Café Lumen"))
        return clock.now - started
    }
    let short = try time(4_000), long = try time(32_000)
    // Eight times the numbers take about eight times as long; measured afresh each time, sixty-four.
    #expect(long < short * 16 + .milliseconds(500), "\(short) then \(long)")
}

// A number written again under a key that names nothing is the same value, and takes the same stand-in.
@Test func jsonNumberWrittenAgainTakesTheSameStandIn() throws {
    let input = #"{"phone":2128675309,"copy":2128675309,"items":[2128675309],"count":2128675309,"order":5550001234,"seats":12}"#
    let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: "a.json").output, as: UTF8.self)
    let out = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    let phone = try #require(out["phone"] as? Int)
    #expect(phone != 2128675309)
    #expect(out["copy"] as? Int == phone)
    #expect((out["items"] as? [Int])?.first == phone)
    #expect(out["count"] as? Int == 2128675309)
    #expect(out["order"] as? Int == 5550001234)
    #expect(out["seats"] as? Int == 12)
    #expect(output.contains(#""copy":\#(phone)"#))
}

// A secret written into a key is replaced there too; a name matched inside a key's word is not.
@Test func jsonSecretInsideAKeyIsReplaced() throws {
    let input = #"{"password":"quillharbor","quillharborMetric":1,"middle":"The","lengthOfTheCurrentLease":"24 months"}"#
    let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: "a.json").output, as: UTF8.self)
    #expect(!output.contains("quillharbor"))
    let out = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    #expect(out.count == 4)
    #expect(out.contains { $0.key.hasSuffix("Metric") && $0.value as? Int == 1 })
    #expect(out["lengthOfTheCurrentLease"] as? String == "24 months")
}

// A secret written as a decimal is personal in every digit: its fraction is drawn too.
@Test func jsonDecimalSecretsDrawTheirFraction() throws {
    let input = #"{"password":0.123456789,"pin":0.98765,"phone":2128675309.0}"#
    let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: "a.json").output, as: UTF8.self)
    #expect(!output.contains("123456789") && !output.contains("98765") && !output.contains("2128675309"))
    let out = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: NSNumber])
    #expect(output.range(of: #""password":0\.\d{9},"pin":0\.\d{5},"phone":\d{10}\.0"#, options: .regularExpression) != nil, "\(output)")
    #expect(out.count == 3)
}

// A key written twice in one object is one key: both are written as the same stand-in.
@Test func jsonDuplicatePersonalKeysStayOneKey() throws {
    let input = #"{"rosalind@example.org":1,"rosalind@example.org":2,"plain":3}"#
    let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: "a.json").output, as: UTF8.self)
    #expect(!output.contains("rosalind"))
    let source = try JSONSource.read(output)
    guard case .object(let pairs) = source.root else { Issue.record("Expected an object"); return }
    #expect(pairs.count == 3)
    #expect(pairs[0].0 == pairs[1].0 && pairs[0].0 != pairs[2].0)
    #expect(pairs[0].0.contains("@") && !pairs[0].0.hasSuffix("_"))
}

// A string changed in part keeps every escape outside what changed as written, half a surrogate pair among them.
@Test func jsonPartialEditKeepsEscapesAsWritten() throws {
    let slash = String(UnicodeScalar(92))
    let note = "ok " + slash + "/ " + slash + "ud800 rosalind@example.org " + slash + "t " + slash + "u00e9 rosalind@example.org end"
    let input = "{\"note\":\"" + note + "\",\"k" + slash + "/ rosalind@example.org\":1}"
    let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: "a.json").output, as: UTF8.self)
    #expect(!output.contains("rosalind"), "\(output)")
    #expect(output.hasPrefix("{\"note\":\"ok " + slash + "/ " + slash + "ud800 "), "\(output)")
    #expect(output.contains(" " + slash + "t " + slash + "u00e9 ") && output.contains(" end\""), "\(output)")
    #expect(output.contains("\"k" + slash + "/ "), "\(output)")
    let source = try JSONSource.read(output)
    guard case .object(let pairs) = source.root, case .string(let value) = pairs[0].1 else { Issue.record("Expected an object"); return }
    let emails = value.split(separator: " ").filter { $0.contains("@") }
    #expect(emails.count == 2 && emails[0] == emails[1])
}

// A document opening with a byte order mark keeps it when anything in it is replaced.
@Test func jsonByteOrderMarkStaysWhenReplaced() throws {
    let data = Data([0xEF, 0xBB, 0xBF]) + Data(#"{"email":"rosalind@example.org"}"#.utf8)
    let output = try Scrubber.scrub(data, name: "a.json").output
    #expect(output.starts(with: [0xEF, 0xBB, 0xBF]))
    #expect(!String(decoding: output, as: UTF8.self).contains("rosalind"))
}

/// A script's file name is no one's handle; a handle beside it still is.
@Test func jsonFileNameIsNoHandle() throws {
    let source = #"{"name":"tool","bin":"./bin/maria-cli.js","main":"./lib/tool.js","author":"ask jdoe42 or maria.gonzalez"}"#
    let output = String(decoding: try Scrubber.scrub(Data(source.utf8), name: "a.json").output, as: UTF8.self)
    #expect(output.contains(#""bin":"./bin/maria-cli.js""#))
    #expect(output.contains(#""main":"./lib/tool.js""#))
    #expect(!output.contains("jdoe42") && !output.contains("gonzalez"))
}

// Two keys spelled apart in their scalars (a precomposed letter, a letter and its accent) stay two keys, each as spelled.
@Test func jsonKeysSpelledApartStayApart() throws {
    let input = "{\"password\":\"quillharbor\",\"\u{E9} quillharbor\":1,\"e\u{301} quillharbor\":2}"
    let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: "a.json").output, as: UTF8.self)
    #expect(!output.contains("quillharbor"), "\(output)")
    let source = try JSONSource.read(output)
    guard case .object(let pairs) = source.root else { Issue.record("Expected an object"); return }
    #expect(pairs.count == 3)
    #expect(pairs[1].0.unicodeScalars.first == "\u{E9}" && pairs[2].0.unicodeScalars.prefix(2).elementsEqual(["e", "\u{301}"]), "\(output)")
    #expect(!pairs[1].0.unicodeScalars.elementsEqual(pairs[2].0.unicodeScalars))
}

// A number written again in another spelling of the same value (a point, an exponent) takes the stand-in too, in its own shape.
@Test func jsonNumberSpelledAgainTakesTheSameStandIn() throws {
    let input = #"{"phone":2128675309,"copy":2128675309.0,"copy2":2.128675309e9,"copy3":21286753090E-1,"items":[2128675309.00],"body":"{\"again\":2.128675309E+9}","ratio":2128675309.0}"#
    let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: "a.json", forceFullDetection: false, seed: 7).output, as: UTF8.self)
    let out = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    #expect((out["ratio"] as? NSNumber)?.doubleValue == 2128675309.0)
    #expect(!output.replacingOccurrences(of: #""ratio":2128675309.0"#, with: "").contains("128675309"), "\(output)")
    let phone = try #require(out["phone"] as? NSNumber).doubleValue
    for key in ["copy", "copy2", "copy3"] { #expect((out[key] as? NSNumber)?.doubleValue == phone, "\(key): \(output)") }
    #expect(((out["items"] as? [NSNumber])?.first)?.doubleValue == phone)
    #expect(output.range(of: #""copy":\d{10}\.0,"#, options: .regularExpression) != nil, "\(output)")
    #expect(output.range(of: #""items":\[\d{10}\.00\]"#, options: .regularExpression) != nil, "\(output)")
    let body = try #require(out["body"] as? String)
    let inner = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: NSNumber])
    #expect(inner["again"]?.doubleValue == phone, "\(output)")
}

// A body written inside a string, changed in part, keeps the string's other escapes as written, half a surrogate pair among them.
@Test func jsonNestedEditKeepsOuterEscapesAsWritten() throws {
    let slash = String(UnicodeScalar(92)), quote = slash + "\""
    let body = "{" + quote + "password" + quote + ":" + quote + slash + slash + "u0071uillharbor" + quote + "," + quote + "note" + quote + ":" + quote + slash + "ud800" + slash + slash + "/ok" + quote + "}"
    let input = "{\"body\":\"" + body + "\"}"
    let output = String(decoding: try Scrubber.scrub(Data(input.utf8), name: "a.json").output, as: UTF8.self)
    #expect(!output.contains("quillharbor") && !output.contains("u0071uillharbor"), "\(output)")
    #expect(output.hasPrefix("{\"body\":\"{" + quote + "password" + quote + ":" + quote), "\(output)")
    #expect(output.hasSuffix("," + quote + "note" + quote + ":" + quote + slash + "ud800" + slash + slash + "/ok" + quote + "}\"}"), "\(output)")
    #expect((try? JSONSource.read(output)) != nil)
}

/// Under a role's key, a version, a standard's name, a configuration's file name or a release's
/// tag is no one's handle; a handle is, and a client's handle written as a file's name is too.
@Test func jsonRoleKeysKeepTechnicalValues() throws {
    let source = #"{"agent":"curl8.0","author":"RFC4716","reviewer":"config.ini","owner":"release_2026","approver":"name1.2","#
        + #""assignee":"jdoe42","requester":"maria.lopez","sender":"j_smith","recipient":"m-garcia7","patient":"jdoe.js","customer":"pwhitlock.py"}"#
    let output = String(decoding: try Scrubber.scrub(Data(source.utf8), name: "a.json", forceFullDetection: false, seed: 7).output, as: UTF8.self)
    let out = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
    for (key, value) in [("agent", "curl8.0"), ("author", "RFC4716"), ("reviewer", "config.ini"), ("owner", "release_2026"), ("approver", "name1.2")] {
        #expect(out[key] == value, "\(key): \(output)")
    }
    for (key, value) in [("assignee", "jdoe42"), ("requester", "maria.lopez"), ("sender", "j_smith"), ("recipient", "m-garcia7"), ("patient", "jdoe.js"), ("customer", "pwhitlock.py")] {
        #expect(out[key] != nil && out[key] != value, "\(key): \(output)")
    }
}

// A number whose exponent is the most negative a whole number holds is read and kept, not a stop.
@Test func jsonFarExponentIsKept() throws {
    let source = #"{"x":1e-9223372036854775808,"y":2e9223372036854775807}"#
    let output = String(decoding: try Scrubber.scrub(Data(source.utf8), name: "a.json").output, as: UTF8.self)
    #expect(output == source)
}

// A number written again in a shape too long to hold its stand-in takes the stand-in as written, never the original.
@Test func jsonNumberTooLongToReshapeIsStillReplaced() throws {
    let copy = "2128675309" + String(repeating: "0", count: 401) + "e-401"
    let source = #"{"phone":2128675309,"copy":"# + copy + "}"
    let output = String(decoding: try Scrubber.scrub(Data(source.utf8), name: "a.json", forceFullDetection: false, seed: 7).output, as: UTF8.self)
    let out = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: NSNumber])
    #expect(!output.contains("2128675309"), "\(output)")
    #expect(out["copy"]?.doubleValue == out["phone"]?.doubleValue, "\(output)")
}

// A client's handle written as a file's name is theirs under "user" too.
@Test func jsonUserHandleWrittenAsAFileIsReplaced() throws {
    let output = String(decoding: try Scrubber.scrub(Data(#"{"user":"jdoe42.js","main":"lib/tool.js"}"#.utf8), name: "a.json").output, as: UTF8.self)
    #expect(!output.contains("jdoe42"), "\(output)")
    #expect(output.contains(#""main":"lib/tool.js""#))
}

// Under a client's key a handle with no digit, written as a file's name, is theirs too.
@Test func jsonClientHandleWithoutDigitsIsReplaced() throws {
    let output = String(decoding: try Scrubber.scrub(Data(#"{"user":"jdoe.js","reviewer":"config.ini"}"#.utf8), name: "a.json").output, as: UTF8.self)
    #expect(!output.contains("jdoe"), "\(output)")
    #expect(output.contains(#""reviewer":"config.ini""#))
}

// A number written again with an exponent past any reshaping, its value the same, takes the stand-in.
@Test func jsonNumberWithAFarExponentStillMatches() throws {
    let copy = "2128675309" + String(repeating: "0", count: 1 << 20) + "e-" + String(1 << 20)
    let source = #"{"phone":2128675309,"copy":"# + copy + "}"
    let output = String(decoding: try Scrubber.scrub(Data(source.utf8), name: "a.json", forceFullDetection: false, seed: 7).output, as: UTF8.self)
    #expect(!output.contains("2128675309"), "\(output.prefix(200))")
    #expect((try? JSONSource.read(output)) != nil)
}

// A client's handle with spaces around it is replaced, the spaces kept.
@Test func jsonPaddedClientHandleIsReplaced() throws {
    let output = String(decoding: try Scrubber.scrub(Data(#"{"user":" jdoe.js ","assignee":"  maria.lopez"}"#.utf8), name: "a.json").output, as: UTF8.self)
    #expect(!output.contains("jdoe") && !output.contains("maria.lopez"), "\(output)")
    #expect(output.range(of: #""user":" [^ "]+ ","assignee":"  [^ "]+""#, options: .regularExpression) != nil, "\(output)")
}

// A number at the far end of the exponent's range, written again with a place after the point, matches its value.
@Test func jsonNumberAtTheExponentsEndMatchesAnotherSpelling() throws {
    let source = #"{"password":1e-9223372036854775808,"copy":1.0e-9223372036854775808}"#
    let output = String(decoding: try Scrubber.scrub(Data(source.utf8), name: "a.json", forceFullDetection: false, seed: 7).output, as: UTF8.self)
    #expect(!output.contains("1.0e-"), "\(output)")
}
