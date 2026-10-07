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

    @Test func aSalesFilesUnitsAreQuantities() throws {
        // "units" was read as an apartment's unit and every quantity rewritten, in a file naming no one.
        let sales = """
        date,sku,units,unit_price,revenue,currency,country
        2026-10-01,WIDGET-RED-001,120,19.99,2398.80,EUR,DE
        2026-10-01,GADGET-XL-9,7,249.00,1743.00,USD,US
        2026-10-02,WIDGET-RED-001,98,19.99,1959.02,EUR,FR

        """
        let inventory = #"{"warehouse": "north", "items": [{"sku": "WIDGET-RED-001", "units": "120", "unit": "pcs"}, {"sku": "GADGET-XL-9", "units": "7", "unit": "kg"}]}"#
        for seed in UInt64(0)..<3 {
            #expect(try Self.scrub(sales, name: "sales.csv", seed: seed) == sales)
            #expect(try Self.scrub(inventory, name: "inventory.json", seed: seed) == inventory)
        }
        // Beside an address, a unit is still the address's.
        let customers = """
        name,street,unit,city,state,zip,units_ordered
        Ottoline Wexcombe,19 Bellweather Ave,4B,Albany,NY,12203,3
        Tobiah Quennell,7740 Canyon Ridge Dr,12,Los Angeles,CA,90068,1

        """
        for seed in UInt64(0)..<3 {
            let output = try Self.scrub(customers, name: "customers.csv", seed: seed)
            let rows = output.split(separator: "\n").dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
            #expect(rows.map { $0[2] } != ["4B", "12"], "\(output)")
            #expect(rows.map { $0[6] } == ["3", "1"], "\(output)")
            #expect(!output.contains("Bellweather") && !output.contains("Canyon Ridge"), "\(output)")
        }
    }
}
