import Foundation
@testable import ScrubCore
import Testing

// Health records in the standard interchange shape: an identifier is named by its
// record's coded type and system rather than its key, a reference names whom it
// points to in a "display", and a bundle writes one patient across several
// resources. Each is sent as a file, as pasted text, in a curl command and in a
// log line. Every name, number and place below is invented.

private let renderings: [(String, String, @Sendable (String) -> String)] = [
    ("file", "record.json", { $0 }),
    ("pasted", "record.txt", { $0 }),
    ("curl", "record.txt", { "curl -X POST https://records.example.org/api/Bundle -H 'Content-Type: application/json' -d '\($0.replacingOccurrences(of: "'", with: "'\\''"))'\n" }),
    ("log", "record.txt", { "2026-03-11T09:15:02Z INFO ingest - bundle=\($0)\n" }),
]

private func body(_ output: String, _ rendering: String) -> String {
    guard rendering == "curl" || rendering == "log", let open = output.firstIndex(where: { $0 == "{" || $0 == "[" }),
          let close = output.lastIndex(where: { $0 == "}" || $0 == "]" }) else { return output }
    let text = String(output[open...close])
    return rendering == "curl" ? text.replacingOccurrences(of: "'\\''", with: "'") : text
}

private func scrubbed(_ json: String, _ rendering: (String, String, @Sendable (String) -> String)) throws -> String {
    let output = String(decoding: try Scrubber.scrub(Data(rendering.2(json).utf8), name: rendering.1, forceFullDetection: false, seed: 7).output, as: UTF8.self)
    return body(output, rendering.0)
}

/// Every leaf of a document with its path, in order.
private func leaves(_ value: JSONValue, _ path: String = "") -> [(String, String)] {
    switch value {
    case .object(let pairs): return pairs.flatMap { leaves($0.1, path + "/" + $0.0) }
    case .array(let members): return members.enumerated().flatMap { leaves($0.1, path + "/" + String($0.0)) }
    case .string(let text): return [(path, text)]
    case .number(let text): return [(path, text)]
    case .bool(let flag): return [(path, flag ? "true" : "false")]
    case .null: return [(path, "null")]
    }
}

private func value(_ json: String, at path: String) -> String? {
    guard let root = try? OrderedJSON.parse(json) else { return nil }
    return leaves(root).first { $0.0 == path }?.1
}

private let licenceType = #"{"coding":[{"code":"DL","display":"Driver's license number","system":"http://terminology.hl7.org/CodeSystem/v2-0203"}],"text":"Driver's license number"}"#
private let passportType = #"{"coding":[{"code":"PPN","display":"Passport Number","system":"http://terminology.hl7.org/CodeSystem/v2-0203"}],"text":"Passport Number"}"#

@Test(arguments: renderings.map(\.0))
private func anIdentifierIsNamedByItsTypeAndSystem(_ name: String) throws {
    let rendering = try #require(renderings.first { $0.0 == name })
    let json = #"{"identifier":["#
        + #"{"system":"urn:oid:2.16.840.1.113883.4.3.25","type":"# + licenceType + #","value":"K40817263"},"#
        + #"{"system":"http://hl7.org/fhir/sid/passport-USA","type":"# + passportType + #","value":"X52906148Q"},"#
        + #"{"system":"http://hl7.org/fhir/sid/passport-USA","value":"X71203348K"},"#
        + #"{"type":{"coding":[{"code":"MR","system":"http://terminology.hl7.org/CodeSystem/v2-0203"}]},"system":"https://hospital.example.org/mrn","value":"MRN-0047731"},"#
        + #"{"type":{"text":"Medical Record Number"},"system":"https://hospital.example.org","value":"6d1f0c3e-2a4b-4c8d-9e7f-1a2b3c4d5e6f"}]}"#
    let output = try scrubbed(json, rendering)
    #expect((try? OrderedJSON.parse(output)) != nil, "[\(name)] no longer parses: \(output)")
    for original in ["K40817263", "X52906148Q", "X71203348K", "0047731"] { #expect(!output.contains(original), "[\(name)] \(original) left in \(output)") }
    // A licence stays a licence's shape and a passport a passport's.
    let licence = try #require(value(output, at: "/identifier/0/value"))
    #expect(licence.wholeMatch(of: /[A-Z][0-9]{8}/) != nil, "[\(name)] licence stand-in \(licence)")
    for index in [1, 2] {
        let passport = try #require(value(output, at: "/identifier/\(index)/value"))
        #expect(passport.wholeMatch(of: /[A-Z][0-9]{8}[A-Z]/) != nil, "[\(name)] passport stand-in \(passport)")
    }
    #expect(value(output, at: "/identifier/3/value")?.hasPrefix("MRN-") == true, "[\(name)] \(output)")
    // A UUID is the system's own key, kept as every UUID is; the types, codes and systems name values and hold none.
    let kept = ["6d1f0c3e-2a4b-4c8d-9e7f-1a2b3c4d5e6f", licenceType, passportType, "urn:oid:2.16.840.1.113883.4.3.25", "http://hl7.org/fhir/sid/passport-USA", "https://hospital.example.org/mrn", #"{"text":"Medical Record Number"}"#]
    for text in kept { #expect(output.contains(text), "[\(name)] \(text) changed in \(output)") }
}

@Test(arguments: renderings.map(\.0))
private func aReferencesDisplayNamesWhomItPointsTo(_ name: String) throws {
    let rendering = try #require(renderings.first { $0.0 == name })
    let json = #"{"resourceType":"Claim","patient":{"display":"Ilse Marrow","reference":"urn:uuid:3c9d2e71-5f0a-4b6c-8d13-7e2a9f4b0c58"},"#
        + #""beneficiary":{"display":"Marrow, Ilse","reference":"Patient/3c9d2e71"},"#
        + #""requester":{"display":"Dr. Oswin Teague","reference":"Practitioner/pr-2207"},"#
        + #""careTeam":[{"sequence":1,"provider":{"display":"Oswin Teague","reference":"Practitioner/pr-2207"}}],"#
        + #""provider":{"display":"Harrowgate Family Practice","reference":"Organization/4471"},"#
        + #""insurer":{"display":"Lakeshore Mutual"},"facility":{"display":"Harrowgate Clinic West","reference":"Location/88"},"#
        + #""subject":{"display":"Spring Screening Cohort","reference":"Group/12"}}"#
    let output = try scrubbed(json, rendering)
    #expect((try? OrderedJSON.parse(output)) != nil, "[\(name)] no longer parses: \(output)")
    for original in ["Ilse", "Marrow", "Oswin", "Teague"] { #expect(!output.contains(original), "[\(name)] \(original) left in \(output)") }
    // One person, one stand-in: the patient's in either order, the practitioner's with or without a title.
    let patient = try #require(value(output, at: "/patient/display")).split(separator: " ")
    #expect(patient.count == 2 && value(output, at: "/beneficiary/display") == "\(patient[1]), \(patient[0])", "[\(name)] \(output)")
    let practitioner = try #require(value(output, at: "/careTeam/0/provider/display"))
    #expect(value(output, at: "/requester/display") == "Dr. " + practitioner, "[\(name)] \(output)")
    // An organisation, a place and a group name no one, and a reference's ID is no one's handle.
    for text in ["Harrowgate Family Practice", "Lakeshore Mutual", "Harrowgate Clinic West", "Spring Screening Cohort", "Patient/3c9d2e71", "Practitioner/pr-2207",
                 "urn:uuid:3c9d2e71-5f0a-4b6c-8d13-7e2a9f4b0c58"] {
        #expect(output.contains(text), "[\(name)] \(text) changed in \(output)")
    }
}

/// A reference whose address names no type (a contained "#p1", a "urn:uuid:…", an identifier alone)
/// says whom it points to in its own "type", by name or by the type's full address.
@Test(arguments: renderings.map(\.0))
private func aReferencesTypeNamesWhomItPointsTo(_ name: String) throws {
    let rendering = try #require(renderings.first { $0.0 == name })
    let json = ##"{"resourceType":"Claim","provider":{"display":"Ilse Marrow","type":"Practitioner","reference":"#p1"},"##
        + #""referral":{"display":"Oswin Teague","type":"http://hl7.org/fhir/StructureDefinition/Practitioner","reference":"urn:uuid:3c9d2e71-5f0a-4b6c-8d13-7e2a9f4b0c58"},"#
        + #""related":{"display":"Wren Halloway","type":"RelatedPerson","identifier":{"system":"https://records.example.org/staff","value":"st-5512"}},"#
        + ##""payee":{"party":{"display":"Harrowgate Family Practice","type":"Organization","reference":"#o1"}},"##
        + #""facility":{"display":"Harrowgate Clinic West","type":"Location","reference":"urn:uuid:7a1c4e90-2b3d-4f5a-8c6e-9d0f1a2b3c4d"}}"#
    let output = try scrubbed(json, rendering)
    #expect((try? OrderedJSON.parse(output)) != nil, "[\(name)] no longer parses: \(output)")
    for original in ["Ilse", "Marrow", "Oswin", "Teague", "Wren", "Halloway"] { #expect(!output.contains(original), "[\(name)] \(original) left in \(output)") }
    for text in ["Harrowgate Family Practice", "Harrowgate Clinic West", #""type":"Practitioner""#, #""type":"RelatedPerson""#, ##""reference":"#p1""##] {
        #expect(output.contains(text), "[\(name)] \(text) changed in \(output)")
    }
}

/// A patient, a visit and its claim, as one bundle.
private let bundle = #"""
{"resourceType":"Bundle","type":"collection","entry":[
{"fullUrl":"urn:uuid:5b0e7c2a-91d4-4f3e-a8b6-2c7d1e9f0a43","resource":{"resourceType":"Patient","id":"5b0e7c2a-91d4-4f3e-a8b6-2c7d1e9f0a43",
"extension":[{"url":"http://hl7.org/fhir/us/core/StructureDefinition/us-core-birthsex","valueCode":"F"},
{"url":"http://hl7.org/fhir/StructureDefinition/patient-mothersMaidenName","valueString":"Varnholm"},
{"url":"http://hl7.org/fhir/StructureDefinition/patient-birthPlace","valueAddress":{"city":"Marbleton","state":"Vermont","country":"US"}}],
"identifier":[{"system":"https://records.example.org/patients","value":"5b0e7c2a-91d4-4f3e-a8b6-2c7d1e9f0a43"},
{"type":{"coding":[{"system":"http://terminology.hl7.org/CodeSystem/v2-0203","code":"MR","display":"Medical Record Number"}],"text":"Medical Record Number"},"system":"https://hospital.example.org","value":"5b0e7c2a-91d4-4f3e-a8b6-2c7d1e9f0a43"},
{"type":{"coding":[{"system":"http://terminology.hl7.org/CodeSystem/v2-0203","code":"SS","display":"Social Security Number"}],"text":"Social Security Number"},"system":"http://hl7.org/fhir/sid/us-ssn","value":"999-41-7203"},
{"type":{"coding":[{"system":"http://terminology.hl7.org/CodeSystem/v2-0203","code":"DL","display":"Driver's license number"}],"text":"Driver's license number"},"system":"urn:oid:2.16.840.1.113883.4.3.25","value":"K73150926"},
{"type":{"coding":[{"system":"http://terminology.hl7.org/CodeSystem/v2-0203","code":"PPN","display":"Passport Number"}],"text":"Passport Number"},"system":"http://hl7.org/fhir/sid/passport-USA","value":"X61842075R"}],
"name":[{"use":"official","family":"Brennholt","given":["Marisol","Jette"],"prefix":["Mrs."]}],
"telecom":[{"system":"phone","value":"555-301-4478","use":"home"},{"system":"email","value":"m.brennholt@example.org","use":"home"}],
"gender":"female","birthDate":"1981-06-17",
"address":[{"line":["4417 Larchmere Hollow Rd"],"city":"Easthampton","state":"Massachusetts","postalCode":"01027","country":"US"}],
"maritalStatus":{"coding":[{"system":"http://terminology.hl7.org/CodeSystem/v3-MaritalStatus","code":"M","display":"Married"}],"text":"Married"},
"contact":[{"relationship":[{"text":"Spouse"}],"name":{"family":"Brennholt","given":["Dorian"]},"telecom":[{"system":"phone","value":"555-301-9921"}]}],
"communication":[{"language":{"coding":[{"system":"urn:ietf:bcp:47","code":"en-US","display":"English"}],"text":"English"}}]}},
{"fullUrl":"urn:uuid:c3a19e70-2b5d-4c8f-9e61-7d04f2a8b915","resource":{"resourceType":"Encounter","id":"c3a19e70-2b5d-4c8f-9e61-7d04f2a8b915","status":"finished",
"class":{"system":"http://terminology.hl7.org/CodeSystem/v3-ActCode","code":"AMB"},
"type":[{"coding":[{"system":"https://terminology.example.org/visit-types","code":"185345009","display":"Office visit"}],"text":"Office visit"}],
"subject":{"reference":"urn:uuid:5b0e7c2a-91d4-4f3e-a8b6-2c7d1e9f0a43","display":"Mrs. Marisol Brennholt"},
"participant":[{"individual":{"reference":"Practitioner/ab12c3","display":"Dr. Anselm Rookwood"}}],
"period":{"start":"2024-03-11T09:15:00-05:00","end":"2024-03-11T09:45:00-05:00"},
"serviceProvider":{"reference":"Organization/4471","display":"Quarry Valley Medical Group"},
"location":[{"location":{"reference":"Location/88","display":"Quarry Valley Clinic East Wing"}}]}},
{"fullUrl":"urn:uuid:e81f4b06-7c3a-4d92-b5e0-19a6c2f7d384","resource":{"resourceType":"Claim","id":"e81f4b06-7c3a-4d92-b5e0-19a6c2f7d384","status":"active",
"patient":{"reference":"Patient/5b0e7c2a-91d4-4f3e-a8b6-2c7d1e9f0a43","display":"Marisol Brennholt"},
"billablePeriod":{"start":"2024-03-11T09:15:00-05:00","end":"2024-03-11T09:45:00-05:00"},"created":"2024-03-12T08:00:00-05:00",
"provider":{"reference":"Organization/4471","display":"Quarry Valley Medical Group"},
"careTeam":[{"sequence":1,"provider":{"reference":"Practitioner/ab12c3","display":"Dr. Anselm Rookwood"}}],
"insurer":{"display":"Cardinal Mutual"},"insurance":[{"sequence":1,"focal":true,"coverage":{"display":"Cardinal Mutual Health Plan"}}],
"item":[{"sequence":1,"productOrService":{"coding":[{"system":"https://terminology.example.org/procedures","code":"99213","display":"Office visit, established patient"}]},
"encounter":[{"reference":"urn:uuid:c3a19e70-2b5d-4c8f-9e61-7d04f2a8b915"}],"net":{"value":142.37,"currency":"USD"}}],
"total":{"value":142.37,"currency":"USD"}}}]}
"""#

/// The bundle's personal values, each of which must be gone; every other leaf must come out as written.
private let personal: Set<String> = ["Varnholm", "Marbleton", "Vermont", "999-41-7203", "K73150926", "X61842075R", "Brennholt", "Marisol", "Jette", "555-301-4478",
                                     "m.brennholt@example.org", "1981-06-17", "4417 Larchmere Hollow Rd", "Easthampton", "Massachusetts", "01027", "Dorian", "555-301-9921",
                                     "Mrs. Marisol Brennholt", "Dr. Anselm Rookwood", "Marisol Brennholt"]

@Test(arguments: renderings.map(\.0))
private func aHealthRecordBundleKeepsOnePatientAndEveryCode(_ name: String) throws {
    let rendering = try #require(renderings.first { $0.0 == name })
    let output = try scrubbed(bundle, rendering)
    let root = try #require(try? OrderedJSON.parse(output), "[\(name)] no longer parses: \(output)")
    let before = leaves(try OrderedJSON.parse(bundle)), after = leaves(root)
    // The same paths in the same order: no key, member or type changed.
    #expect(before.map(\.0) == after.map(\.0), "[\(name)] structure changed: \(output)")
    for ((path, original), (_, written)) in zip(before, after) {
        if personal.contains(original) {
            #expect(written != original, "[\(name)] \(path) left as \(original)")
        } else {
            #expect(written == original, "[\(name)] \(path) changed from \(original) to \(written)")
        }
    }
    for word in ["Brennholt", "Marisol", "Jette", "Dorian", "Varnholm", "Anselm", "Rookwood", "Larchmere", "Easthampton", "Marbleton", "301-4478", "301-9921", "41-7203"] {
        #expect(!output.contains(word), "[\(name)] \(word) left in \(output)")
    }
    // One patient across the resources: the name the Patient is given is the one each reference writes.
    let family = try #require(value(output, at: "/entry/0/resource/name/0/family"))
    let given = try #require(value(output, at: "/entry/0/resource/name/0/given/0"))
    #expect(value(output, at: "/entry/1/resource/subject/display") == "Mrs. \(given) \(family)", "[\(name)] \(output)")
    #expect(value(output, at: "/entry/2/resource/patient/display") == "\(given) \(family)", "[\(name)] \(output)")
    #expect(value(output, at: "/entry/1/resource/participant/0/individual/display") == value(output, at: "/entry/2/resource/careTeam/0/provider/display"), "[\(name)] \(output)")
    // The stand-ins keep their kinds' shapes.
    let shapes: [(String, Regex<Substring>)] = [("/entry/0/resource/identifier/2/value", /[0-9]{3}-[0-9]{2}-[0-9]{4}/), ("/entry/0/resource/identifier/3/value", /[A-Z][0-9]{8}/),
                                                ("/entry/0/resource/identifier/4/value", /[A-Z][0-9]{8}[A-Z]/), ("/entry/0/resource/birthDate", /[0-9]{4}-[0-9]{2}-[0-9]{2}/)]
    for (path, shape) in shapes {
        let written = try #require(value(output, at: path))
        #expect(written.wholeMatch(of: shape) != nil, "[\(name)] \(path) is \(written)")
    }
}

/// A type no record standard lists says nothing of whom a display names: the key it is under still does.
@Test func anUnlistedTypeLeavesTheKeyToNameThePerson() throws {
    let source = #"{"subject":{"type":"Human","display":"Ilse Marrow"},"location":{"type":"Location","display":"Clinic East Wing"}}"#
    let output = String(decoding: try Scrubber.scrub(Data(source.utf8), name: "a.json").output, as: UTF8.self)
    #expect(!output.contains("Marrow"), "\(output)")
    #expect(output.contains("Clinic East Wing"), "\(output)")
}

/// A reference to a product the standard lists keeps its display, under a person's key too.
@Test func aProductsDisplayStaysUnderASubject() throws {
    let source = #"{"subject":{"reference":"NutritionProduct/42","display":"Infant Formula"},"focus":{"type":"BiologicallyDerivedProduct","display":"Packed Red Cells"}}"#
    let output = String(decoding: try Scrubber.scrub(Data(source.utf8), name: "a.json").output, as: UTF8.self)
    #expect(output == source, "\(output)")
}
