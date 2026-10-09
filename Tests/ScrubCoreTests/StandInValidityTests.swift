import Foundation
@testable import ScrubCore
import Testing

/// Stand-ins that must still be valid values of their kind: a card's expiry
/// month is a month, written as wide as the original was.
struct StandInValidityTests {
    static func json(_ text: String, seed: UInt64) throws -> [String: Any] {
        let result = try Scrubber.scrub(Data(text.utf8), name: "charge.json", forceFullDetection: false, seed: seed)
        return try #require(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
    }

    @Test func aCardsExpiryMonthIsAMonthAsWideAsWritten() throws {
        // A one-digit month was drawn as a day of the month past twelve ("exp_month": 8 became 24).
        let charge = #"""
        {
          "id": "ch_3PqR8sT2uV",
          "object": "charge",
          "amount": 4999,
          "currency": "usd",
          "billing_details": {"name": "Odalys Fenwright", "email": "o.fenwright@example.com"},
          "payment_method_details": {
            "type": "card",
            "card": {"brand": "visa", "last4": "4242", "exp_month": 8, "exp_year": 2028, "funding": "credit"}
          },
          "source": {"object": "card", "exp_month": "08", "exp_year": "2028", "cvc_check": "pass"}
        }
        """#
        for seed in UInt64(0)..<12 {
            let out = try Self.json(charge, seed: seed)
            let card = try #require((out["payment_method_details"] as? [String: Any])?["card"] as? [String: Any])
            let month = try #require(card["exp_month"] as? Int, "seed \(seed): \(card)")
            #expect((1...12).contains(month) && month != 8, "seed \(seed): month \(month)")
            let year = try #require(card["exp_year"] as? Int)
            #expect((2027...2040).contains(year) && year != 2028, "seed \(seed): year \(year)")
            let source = try #require(out["source"] as? [String: Any])
            let padded = try #require(source["exp_month"] as? String)
            #expect(padded.count == 2 && (1...12).contains(Int(padded) ?? 0) && padded != "08", "seed \(seed): month \(padded)")
            #expect(card["funding"] as? String == "credit" && source["cvc_check"] as? String == "pass")
        }
    }

    @Test func aCardsExpiryMonthInACSVColumnIsAMonth() throws {
        let csv = "cardholder,last4,exp_month,exp_year,amount\nOdalys Fenwright,4242,8,2028,49.99\nTobiah Quennell,1881,3,2027,12.00\n"
        for seed in UInt64(0)..<12 {
            let result = try Scrubber.scrub(Data(csv.utf8), name: "payments.csv", forceFullDetection: false, seed: seed)
            let rows = String(decoding: result.output, as: UTF8.self).split(separator: "\n").dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false) }
            for row in rows {
                let month = String(row[2])
                #expect(month.count == 1 && (1...9).contains(Int(month) ?? 0), "seed \(seed): \(row)")
            }
            #expect(rows.map { String($0[4]) } == ["49.99", "12.00"])
        }
    }

    @Test func aFictionalLocalNumberStaysOnTheFictionalLines() throws {
        // "555-0181" became "712-3082": a fictional number made real.
        let text = "Call the front desk on 555-0181 or Ottoline Wexcombe directly on 555-0147.\n"
        for seed in UInt64(0)..<6 {
            let output = String(decoding: try Scrubber.scrub(Data(text.utf8), name: "note.txt", forceFullDetection: false, seed: seed).output, as: UTF8.self)
            let numbers = output.matches(of: /\b\d{3}-\d{4}\b/).map { String(output[$0.range]) }
            #expect(numbers.count == 2 && numbers.allSatisfy { $0.hasPrefix("555-01") }, "seed \(seed): \(output)")
        }
    }

    @Test func aCityWithNoCapitalsToKeepIsNotShouted() throws {
        // "上海" was replaced by "NASHVILLE": a script with no case read as written in capitals.
        let json = "{\"customers\": [{\"name\": \"Ottoline Wexcombe\", \"email\": \"o.wexcombe@example.com\", \"city\": \"\\u4e0a\\u6d77\"}, {\"name\": \"Tobiah Quennell\", \"city\": \"BOSTON\"}]}"
        for seed in UInt64(0)..<3 {
            let out = try Self.json(json, seed: seed)
            let customers = try #require(out["customers"] as? [[String: Any]])
            let first = try #require(customers[0]["city"] as? String), second = try #require(customers[1]["city"] as? String)
            #expect(first != "上海" && first != first.uppercased(), "seed \(seed): \(first)")
            #expect(second != "BOSTON" && second == second.uppercased(), "seed \(seed): \(second)")
        }
    }

    @Test func aBirthDateWrittenWithItsTimeKeepsTheTime() throws {
        // "1975-11-22T00:00:00Z" became "1994-12-03": a timestamp field given a bare date.
        let check = #"{"subject": {"name": "Ottoline Wexcombe", "dob": "1975-11-22T00:00:00Z"}, "sources": [{"name": "credit header", "dob": "1975-11-22T00:00:00Z", "match": "EXACT"}], "created_at": "2026-10-02T09:14:00Z"}"#
        for seed in UInt64(0)..<3 {
            let out = try Self.json(check, seed: seed)
            let dob = try #require((out["subject"] as? [String: Any])?["dob"] as? String)
            #expect(dob.range(of: #"^\d{4}-\d{2}-\d{2}T00:00:00Z$"#, options: .regularExpression) != nil && dob != "1975-11-22T00:00:00Z", "seed \(seed): \(dob)")
            let again = try #require((out["sources"] as? [[String: Any]])?.first?["dob"] as? String)
            #expect(again == dob, "seed \(seed): \(again) vs \(dob)")
            #expect(out["created_at"] as? String == "2026-10-02T09:14:00Z")
        }
    }

    /// An identifier read under its own key, or named before it in its own script, takes a stand-in of its
    /// kind that passes its check: an Emirates ID (784, a year, a Luhn digit), a Swedish personnummer
    /// in a vendor's nested response, an IBAN under an account number's key, and an Aadhaar named in Hindi.
    @Test func anIdentifierTakesAStandInOfItsOwnKind() throws {
        let aadhaar = try #require(Recognizers.all.first { $0.name == "AADHAAR" })
        let personnummer = try #require(Recognizers.all.first { $0.name == "PERSONNUMMER" })
        func digits(_ value: String) -> [Int] { value.compactMap(\.wholeNumberValue) }
        for seed in UInt64(0)..<8 {
            let onboarding = try Self.json(#"{"applicant": {"fullName": "Rashid Al Noori", "emiratesId": "784-1985-3021746-6", "nationality": "AE"}}"#, seed: seed)
            let emirates = try #require((onboarding["applicant"] as? [String: Any])?["emiratesId"] as? String)
            #expect(emirates != "784-1985-3021746-6" && emirates.range(of: #"^784-(19|20)\d{2}-\d{7}-\d$"#, options: .regularExpression) != nil && Patterns.luhn(digits(emirates)), "seed \(seed): \(emirates)")

            let response = try Self.json(#"{"Response": {"Person": {"GivenName": "ASTRID", "Surname": "LINDQVIST", "Pnr": "790314-6020"}, "Status": "MATCH"}}"#, seed: seed)
            let pnr = try #require(((response["Response"] as? [String: Any])?["Person"] as? [String: Any])?["Pnr"] as? String)
            #expect(pnr != "790314-6020" && personnummer.passes(pnr) && pnr.range(of: #"^\d{6}-\d{4}$"#, options: .regularExpression) != nil, "seed \(seed): \(pnr)")

            let report = "<AccountReport><AccountNumber>LU430010283746501920</AccountNumber><Name>Odalys Fenwright</Name></AccountReport>"
            let xml = String(decoding: try Scrubber.scrub(Data(report.utf8), name: "report.xml", forceFullDetection: false, seed: seed).output, as: UTF8.self)
            let iban = try #require(xml.range(of: #"(?<=<AccountNumber>)[^<]+"#, options: .regularExpression).map { String(xml[$0]) })
            #expect(iban != "LU430010283746501920" && iban.hasPrefix("LU") && iban.count == 20 && Patterns.iban(iban), "seed \(seed): \(iban)")

            let message = "नमस्ते, मेरा आधार नंबर 6830 1925 7407 है।\n"
            let text = String(decoding: try Scrubber.scrub(Data(message.utf8), name: "Pasted text", forceFullDetection: false, seed: seed).output, as: UTF8.self)
            let number = try #require(text.range(of: #"\d{4} \d{4} \d{4}"#, options: .regularExpression).map { String(text[$0]) }, "seed \(seed): \(text)")
            #expect(number != "6830 1925 7407" && aadhaar.passes(number), "seed \(seed): \(number)")
        }
    }

    /// A cédula and a birth number, wherever they are read from, take stand-ins passing their checks
    /// over many seeds: a cédula's digit read as a phone's ("1234567-2") too, and a woman's birth number stays one.
    @Test func checkedIdentifiersDrawnOverManySeedsPassTheirChecks() throws {
        let cedula = try #require(Recognizers.all.first { $0.name == "UY_CI" })
        let birth = try #require(Recognizers.all.first { $0.name == "RODNE_CISLO" })
        let inputs: [(text: String, name: String, original: String, kind: Recognizer)] = [
            (#"{"giro": {"monto": "1250.00", "moneda": "UYU"}, "beneficiario": {"nombre_completo": "Odalys Fenwright", "doc_benef": "1.234.567-2"}}"#, "giro.json", "1.234.567-2", cedula),
            (#"{"giro": {"monto": "1250.00", "moneda": "UYU"}, "beneficiario": {"nombre_completo": "Odalys Fenwright", "doc_benef": "1234567-2"}}"#, "giro.json", "1234567-2", cedula),
            ("Beneficiaria Odalys Fenwright, cédula 1.234.567-2, Montevideo.\n", "Pasted text", "1.234.567-2", cedula),
            (#"gw DEBUG req=7f1c body={"customer": {"name": "Ivana Kollárová", "ids": [{"type": "RC", "value": "905714/3183"}]}}"# + "\n", "gateway.log", "905714/3183", birth),
            (#"{"customer": {"name": "Ivana Kollárová", "rodne_cislo": "905714/3183", "status": "ACTIVE"}}"#, "customer.json", "905714/3183", birth),
        ]
        for input in inputs {
            for seed in UInt64(0)..<40 {
                let result = try Scrubber.scrub(Data(input.text.utf8), name: input.name, forceFullDetection: false, seed: seed)
                let made = try #require(result.findings.first { $0.original == input.original }?.standIn, "\(input.name) seed \(seed): \(input.original) not found")
                #expect(made != input.original && input.kind.passes(made) && input.kind.writes(made), "\(input.name) seed \(seed): \(input.original) → \(made)")
                #expect(made.count == input.original.count && zip(made, input.original).allSatisfy { $0.isNumber == $1.isNumber }, "\(input.original) → \(made)")
                if input.kind.name == "RODNE_CISLO" {
                    let digits = made.compactMap(\.wholeNumberValue)
                    #expect(digits.count == 10 && (digits.reduce(0) { $0 * 10 + $1 }) % 11 == 0 && digits[2] >= 5, "\(input.name) seed \(seed): a woman's birth number: \(made)")
                }
            }
        }
    }
}
