import Foundation
@testable import ScrubCore
import Testing

/// Values that name no one, written where personal data is replaced around
/// them, stay exactly as written: a time zone's identifier, a sales file's
/// quantities, an organisation's name, a plan's description, a greeting.
struct NonPersonalKeptTests {
    static func scrub(_ text: String, name: String, seed: UInt64) throws -> String {
        String(decoding: try Scrubber.scrub(Data(text.utf8), name: name, forceFullDetection: false, seed: seed).output, as: UTF8.self)
    }
    static func count(_ part: String, in text: String) -> Int { text.components(separatedBy: part).count - 1 }

    @Test func aTimeZonesIdentifierIsNeverEdited() throws {
        // "London" was replaced inside "Europe/London" as the city it is in the address, leaving "Europe/Birmingham".
        let profile = #"""
        {
          "sub": "248289761001",
          "name": "Ottoline Wexcombe",
          "given_name": "Ottoline",
          "family_name": "Wexcombe",
          "email": "o.wexcombe@example.co.uk",
          "zoneinfo": "Europe/London",
          "locale": "en-GB",
          "address": {
            "street_address": "14 Tavistock Mews",
            "locality": "London",
            "postal_code": "W11 1QX",
            "country": "GB"
          },
          "updated_at": 1790000000
        }
        """#
        let ticket = """
        Subject: Locked out after travelling
        From: Ottoline Wexcombe <o.wexcombe@example.co.uk>
        X-Timezone: Europe/London

        Hi, I moved from Berlin to 14 Tavistock Mews, London W11 1QX last month. My account still shows Europe/Berlin
        and the reminders arrive at 03:00 Europe/London time.
        """
        for seed in UInt64(0)..<3 {
            let json = try Self.scrub(profile, name: "userinfo.json", seed: seed)
            #expect(json.contains(#""zoneinfo": "Europe/London""#), "\(json)")
            #expect(!json.contains("Wexcombe") && !json.contains("Tavistock"), "\(json)")
            let text = try Self.scrub(ticket, name: "ticket.txt", seed: seed)
            #expect(text.contains("X-Timezone: Europe/London\n"), "\(text)")
            #expect(text.contains("still shows Europe/Berlin\n") && text.contains("03:00 Europe/London time"), "\(text)")
            #expect(!text.contains("Wexcombe") && !text.contains("Tavistock"), "\(text)")
        }
    }
}
