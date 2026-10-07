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
}
