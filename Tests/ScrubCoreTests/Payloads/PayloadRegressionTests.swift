import Foundation
@testable import ScrubCore
import Testing

// One test per fault the payload properties found, on fixed inputs, so none
// comes back on a seed the random runs don't reach.

private func scrub(_ text: String, as name: String) throws -> String {
    String(decoding: try Scrubber.scrub(Data(text.utf8), name: name, forceFullDetection: false, seed: 11).output, as: UTF8.self)
}

@Test func pastedJSONKeepsBareNumbersBare() throws {
    let text = #"{"ssn": 486133926, "dob": {"day": 16, "month": 7, "year": 1974}, "phone": 2067349021, "created_at": 1713428568}"#
    let output = try scrub(text, as: "pasted.txt")
    guard case .object(let pairs) = try OrderedJSON.parse(output) else { Issue.record("not an object"); return }
    let fields = Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, $0.1) })
    guard case .number(let ssn) = fields["ssn"], case .number(let phone) = fields["phone"], case .number(let created) = fields["created_at"] else { Issue.record("types changed: \(output)"); return }
    #expect(ssn.count == 9 && ssn != "486133926")
    #expect(phone.count == 10 && phone != "2067349021")
    #expect(created == "1713428568")
    #expect(!output.contains("1974"))
}

@Test(arguments: [("times.csv", "id,created,amount\nA1,1713428568,12.50\n"),
                  ("times.xml", "<r><id>A1</id><created>1713428568</created></r>"),
                  ("times.txt", "created=1713428568 status=200 took 1713428568 ms")])
func unixTimesAreNoPhoneNumbers(_ name: String, _ text: String) throws {
    #expect(try scrub(text, as: name) == text)
}

@Test func statusesAndScoresUnderPersonalKeysStay() throws {
    let json = #"{"checks": {"first_name": "MATCH", "last_name": "NO_MATCH", "address": "not_found", "dob": "UNAVAILABLE", "phone": 0.74, "ssn": 1.00, "surname": "0.86"}}"#
    #expect(try scrub(json, as: "checks.json") == json)
    let xml = "<checks><surname>0.86</surname><cell_phone>0.74</cell_phone><first_name>PARTIAL_MATCH</first_name></checks>"
    #expect(try scrub(xml, as: "checks.xml") == xml)
}

@Test func nestedPartsOfPersonalFieldsAreRead() throws {
    let json = #"""
    {"applicant": {"name": {"first": "Oluwaseun", "middle": "Adaeze", "last": "Brightwater"}, "dob": {"year": 1974},
     "phones": [{"type": "mobile", "number": "2067349021"}], "emails": [{"type": "work", "address": "o.brightwater@proton.me"}],
     "national_id": {"type": "SSN", "value": "536217784"}}}
    """#
    let output = try scrub(json, as: "applicant.json")
    for value in ["Oluwaseun", "Adaeze", "Brightwater", "1974", "2067349021", "536217784"] { #expect(!output.contains(value), "\(value) in \(output)") }
    #expect(output.contains(#""type": "mobile""#) && output.contains(#""type": "SSN""#))
}

@Test func fhirPatientIsRead() throws {
    let json = #"""
    {"resourceType": "Patient", "name": [{"use": "official", "family": "Brightwater", "given": ["Oluwaseun", "Adaeze"]}],
     "telecom": [{"system": "phone", "value": "(206) 734-9021"}, {"system": "email", "value": "o.b@proton.me"}],
     "identifier": [{"system": "http://hl7.org/fhir/sid/us-ssn", "value": "536217784"}], "gender": "female", "birthDate": "1974-04-12",
     "address": [{"line": ["4821 Juniper Hollow Rd"], "city": "Tacoma", "postalCode": "98402"}]}
    """#
    for name in ["patient.json", "patient.txt"] {
        let output = try scrub(json, as: name)
        for value in ["Brightwater", "Oluwaseun", "Adaeze", "734-9021", "o.b@proton.me", "536217784", "1974-04-12", "Juniper Hollow", "98402"] { #expect(!output.contains(value), "\(name): \(value)") }
        for kept in ["official", "http://hl7.org/fhir/sid/us-ssn", "female", "Patient"] { #expect(output.contains(kept), "\(name): \(kept)") }
    }
}

@Test func formFieldsAreNamedBySiblings() throws {
    let json = #"{"fields": [{"name": "first_name", "value": "Oluwaseun"}, {"key": "zip", "value": "98402"}, {"label": "Date of birth", "value": "04/12/1974"}, {"name": "plan", "value": "starter"}]}"#
    for name in ["form.json", "form.txt"] {
        let output = try scrub(json, as: name)
        for value in ["Oluwaseun", "98402", "04/12/1974"] { #expect(!output.contains(value), "\(name): \(value)") }
        for kept in ["first_name", "\"zip\"", "Date of birth", "starter"] { #expect(output.contains(kept), "\(name): \(kept)") }
    }
    let xml = "<form><field><name>first_name</name><value>Oluwaseun</value></field><field name=\"email\">o.b@proton.me</field></form>"
    let output = try scrub(xml, as: "form.xml")
    #expect(!output.contains("Oluwaseun") && !output.contains("o.b@proton.me"))
}

@Test func flattenedCSVHeadersAreRead() throws {
    let csv = "applicant.name.first,Applicant Dob Day,applicant.dob,billing_details.address.city,Plan Name,Company Name\nOluwaseun,12,1974-04-12,Tacoma,Business Pro,Northwind Traders LLC\n"
    let output = try scrub(csv, as: "export.csv")
    let rows = try CSVFile.parse(output, delimiter: ",")
    #expect(rows[0] == ["applicant.name.first", "Applicant Dob Day", "applicant.dob", "billing_details.address.city", "Plan Name", "Company Name"])
    #expect(rows[1][0] != "Oluwaseun" && rows[1][2] != "1974-04-12" && rows[1][3] != "Tacoma")
    #expect(rows[1][4] == "Business Pro" && rows[1][5] == "Northwind Traders LLC")
}

@Test func keyValueCSVExportIsRead() throws {
    let csv = "Field,Value\nfirst_name,Oluwaseun\nzip,98402\nplan,starter\n"
    let output = try scrub(csv, as: "export.csv")
    #expect(!output.contains("Oluwaseun") && !output.contains("98402"))
    for kept in ["Field,Value", "first_name,", "zip,", "plan,starter"] { #expect(output.contains(kept), "\(kept) in \(output)") }
}

@Test func yamlKeysAndNestingAreRead() throws {
    let yaml = """
    applicant:
      name:
        first: Oluwaseun
        last: Montgomery-Reyes
      emails:
        - o.reyes@proton.me
      city: Tacoma
      timezone: America/Chicago
    customers:
      - id: cus_8f3k2
        given_name: Siobhan
        status: ACTIVE
    """
    let output = try scrub(yaml, as: "config.txt")
    for value in ["Oluwaseun", "Montgomery", "o.reyes@proton.me", "Tacoma", "Siobhan"] { #expect(!output.contains(value), "\(value) in \(output)") }
    for kept in ["status: ACTIVE"] { #expect(output.contains(kept), "\(kept) in \(output)") }
    // A customer's ID names them: a stand-in of its shape.
    #expect(!output.contains("cus_8f3k2") && output.range(of: #"id: cus_[a-z0-9]{5}\n"#, options: .regularExpression) != nil, "\(output)")
    // The time zone moves with the city beside it.
    let zone = output.components(separatedBy: "timezone: ").last?.split(separator: "\n").first.map(String.init) ?? ""
    #expect(TimeZone(identifier: zone) != nil, "\(output)")
}

@Test func quotedShellBodyIsRead() throws {
    let text = #"curl -X POST https://api.example.com/v1/users -H 'Content-Type: application/json' -d '{"first_name":"Oluwaseun","postal_code":"98402","timezone":"America/Chicago"}'"#
    let output = try scrub(text, as: "request.txt")
    #expect(!output.contains("Oluwaseun") && !output.contains("98402"))
    #expect(output.contains("Content-Type: application/json"), "\(output)")
    let zone = output.components(separatedBy: #""timezone":""#).last?.split(separator: "\"").first.map(String.init) ?? ""
    #expect(TimeZone(identifier: zone) != nil, "\(output)")
}

@Test func codeTypesAndExpressionsAreNoValues() throws {
    let code = "interface User {\n  firstName: string;\n  email: string;\n}\nconst user = { firstName: form.firstName, email: user.email, lastName: 'Brightwater' };\n"
    let output = try scrub(code, as: "user.ts.txt")
    #expect(output.contains("firstName: string;") && output.contains("email: string;") && output.contains("firstName: form.firstName") && output.contains("email: user.email"))
    #expect(!output.contains("Brightwater"))
}

@Test func standInsKeepTheirType() throws {
    let json = #"{"dob": "April 21, 2003", "birthdate": "16 JUL 1982", "birthday": "11/07/1984", "ssn": "194685291", "ip": "2600:1700:5a3c:8e10::1b", "account_number": "0012345678"}"#
    let output = try scrub(json, as: "types.json")
    guard case .object(let pairs) = try OrderedJSON.parse(output) else { Issue.record("not an object"); return }
    var fields: [String: String] = [:]
    for (key, value) in pairs { if case .string(let s) = value { fields[key] = s } }
    #expect(fields["dob"]?.range(of: #"^[A-Z][a-z]+ \d{1,2}, \d{4}$"#, options: .regularExpression) != nil, "\(fields)")
    #expect(fields["birthdate"]?.range(of: #"^\d{2} [A-Z]{3} \d{4}$"#, options: .regularExpression) != nil, "\(fields)")
    // Both parts of "11/07/1984" are at most 12, so the stand-in must read either way.
    let parts = (fields["birthday"] ?? "").split(separator: "/").compactMap { Int($0) }
    #expect(parts.count == 3 && parts[0] <= 12 && parts[1] <= 12)
    #expect(fields["ssn"]?.range(of: #"^\d{9}$"#, options: .regularExpression) != nil && fields["ssn"] != "194685291")
    #expect(fields["ip"]?.contains(":") == true)
    #expect(fields["account_number"]?.count == 10)
}

@Test func organisationRunIsNoPlace() throws {
    let json = #"{"employer": "Northwind Traders LLC", "vendor": "Cascade Mountain Outfitters Inc."}"#
    #expect(try scrub(json, as: "employer.json") == json)
}

@Test func countsAndFlagsNamedAfterFieldsStay() throws {
    let json = #"{"id": "vrf_8Hk2mQ9xLp1Ra", "num_family_names": 1, "email_count": 2, "total_phone_numbers": 0, "has_ssn": true, "first_name_match_score": 97, "dob_source": "credit_header", "url": "https://api.example.com/verifications/vrf_8Hk2mQ9xLp1Ra/documents/1/face.jpeg"}"#
    #expect(try scrub(json, as: "counts.json") == json)
    #expect(KeyHints.hint("customer_phone_number") == "PHONE_NUMBER" && KeyHints.hint("billing_email") == "EMAIL_ADDRESS")
    #expect(KeyHints.hint("num_family_names") == nil && KeyHints.header("num_family_names") == nil && KeyHints.hint("company_name") == nil && KeyHints.hint("mac_address") == nil)
}

@Test func keysInPastedTextAreNoNames() throws {
    let text = #"{"contact_phone":"+1 206 734 9021","dob":"1963-09-14","family_name":"Brightwater"}"#
    let output = try scrub(text, as: "pasted.txt")
    #expect(output.contains(#""dob":"#) && output.contains(#""contact_phone":"#) && !output.contains("Brightwater"))
    #expect(KeyHints.header("customer-email-addrs") == "email_addrs" || KeyHints.hint(KeyHints.header("customer-email-addrs")) == "EMAIL_ADDRESS")
}

@Test func shortNumbersStayWhereTheyWereFound() throws {
    let json = #"{"dob": {"day": 18, "month": 7, "year": 1974}, "created_at": "2025-05-07T18:38:49Z", "items": 7}"#
    let output = try scrub(json, as: "short.json")
    #expect(output.contains(#""created_at": "2025-05-07T18:38:49Z""#) && output.contains(#""items": 7"#))
    #expect(!output.contains("1974"))
}
