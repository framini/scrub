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

    @Test func aGreetingAndASentenceAfterAnAddressStayWords() throws {
        // "Hi" was read as Hawaii, "Done" as the end of the address before it, and "I'm" as part of the name after "Hi,".
        let ticket = #"""
        {
          "ticket": {
            "id": 48213,
            "subject": "Can't sign in",
            "status": "solved",
            "requester": {"id": 90021, "name": "Bartholomew Ng", "email": "b.ng@example.org"},
            "comments": [
              {"author_id": 90021, "public": true, "body": "Hi, I'm Bartholomew Ng and I've been locked out since Friday."},
              {"author_id": 1203, "public": false, "body": "Changed the shipping address to 77 Halloway Street, Brooklyn, NY 11215. Done in admin. Error code E_AUTH_LOCKED cleared."}
            ]
          }
        }
        """#
        let note = "Hi, I'm Bartholomew Ng.\n\nI can't reach the portal since the password reset.\n\nThanks,\nBart\n"
        for seed in UInt64(0)..<3 {
            let json = try Self.scrub(ticket, name: "ticket.json", seed: seed)
            #expect(json.contains(#""body": "Hi, I'm "#) && !json.contains("Bartholomew") && !json.contains("Halloway"), "\(json)")
            #expect(json.contains(". Done in admin. Error code E_AUTH_LOCKED cleared."), "\(json)")
            #expect(json.range(of: #", [A-Z]{2} \d{5}\. Done"#, options: .regularExpression) != nil, "\(json)")
            let text = try Self.scrub(note, name: "note.txt", seed: seed)
            #expect(text.hasPrefix("Hi, I'm ") && !text.contains("Bartholomew"), "\(text)")
        }
    }

    @Test func anOrganisationNamedForItsTradeIsKept() throws {
        // A firm's name before what it does was replaced as a person's ("Carolyn Coleman") or its first word as a city ("Chicago Analytics").
        let letter = """
        October 2, 2026

        Hiring Committee
        Fernhill Robotics
        400 Innovation Way
        Pittsburgh, PA 15213

        Dear Ms. Harrowgate,

        I am writing to apply for the controls engineer role. Last spring Marcus raised the churn issue with Halberd Capital on a call; Ingeborg followed up with their CTO.

        Kind regards,
        Wilhelmina Castellanos
        Senior Accounts Manager
        Brightwater Logistics

        """
        let crm = #"{"contacts": [{"name": "Priya Venkataraman", "email": "priya.v@example.com", "company": "Northfield Analytics", "jobtitle": "Head of Data"}, {"name": "Gideon Farraday", "company": "Granite Peak Supply"}]}"#
        let xml = "<contact><name>Ysolde Brackenridge</name><phone>+1 312 555 0117</phone><company>Granite Peak Supply</company></contact>\n"
        for seed in UInt64(0)..<3 {
            let text = try Self.scrub(letter, name: "cover_letter.txt", seed: seed)
            for kept in ["\nFernhill Robotics\n", "with Halberd Capital on", "\nBrightwater Logistics\n"] { #expect(text.contains(kept), "\(kept): \(text)") }
            for gone in ["Harrowgate", "Wilhelmina", "Castellanos", "Ingeborg"] { #expect(!text.contains(gone), "\(gone): \(text)") }
            let json = try Self.scrub(crm, name: "contacts.json", seed: seed)
            #expect(json.contains(#""company": "Northfield Analytics""#) && json.contains(#""company": "Granite Peak Supply""#), "\(json)")
            #expect(!json.contains("Venkataraman") && !json.contains("Farraday"), "\(json)")
            let record = try Self.scrub(xml, name: "contact.xml", seed: seed)
            #expect(record.contains("<company>Granite Peak Supply</company>") && !record.contains("Brackenridge"), "\(record)")
        }
    }

    @Test func aPlansDescriptionIsNoOnesHandle() throws {
        // A price's "nickname" was read as a person's handle and became "carolyn377".
        let event = #"""
        {
          "id": "evt_1PxYzAbCdEf",
          "type": "customer.subscription.created",
          "data": {
            "object": {
              "id": "sub_1PxYzAbCdEf",
              "customer": {"name": "Ottoline Wexcombe", "email": "o.wexcombe@example.com"},
              "items": {"data": [{"price": {"id": "price_1Mx", "unit_amount": 1500, "currency": "eur", "nickname": "Team plan (monthly)", "recurring": {"interval": "month"}}},
                                 {"price": {"id": "price_1My", "unit_amount": 15000, "currency": "eur", "nickname": "Team annual"}}]}
            }
          }
        }
        """#
        for seed in UInt64(0)..<3 {
            let json = try Self.scrub(event, name: "webhook.json", seed: seed)
            #expect(json.contains(#""nickname": "Team plan (monthly)""#) && json.contains(#""nickname": "Team annual""#), "\(json)")
            #expect(!json.contains("Wexcombe"), "\(json)")
        }
        // A person's nickname is still replaced.
        let profile = #"{"user": {"name": "Bartholomew Ng", "nickname": "Bart", "username": "bng_77"}}"#
        let output = try Self.scrub(profile, name: "profile.json", seed: 1)
        #expect(!output.contains(#""Bart""#) && !output.contains("bng_77"), "\(output)")
    }

    @Test func aReplysTimeStaysOutOfTheNameAfterIt() throws {
        // "07:34 AM, Kwabena Boateng <…>" was read as "Boateng"'s surname "AM" written first, and became "07:34 JENKINS, Lawrence";
        // "4:12 PM Jasper Thornquist" lost its "PM" to the name.
        let thread = """
        Thanks Kwabena, I've reset the device binding. Try again and let me know.

        Jasper Thornquist
        Support, Tier 2

        On Tue, Oct 6, 2026 at 07:34 AM, Kwabena Boateng <k.boateng@example.com> wrote:
        > Still locked out after the update. Can you check?
        >
        > On Mon, Oct 5, 2026 at 4:12 PM Jasper Thornquist <jasper.thornquist@example.org> wrote:
        >> Hi Kwabena, could you send the error code you see?

        """
        let ticket = #"{"ticket": {"id": 7731, "comments": [{"author": "Jasper Thornquist", "body": "On Tue, Oct 6, 2026 at 07:34 AM, Kwabena Boateng <k.boateng@example.com> wrote:\n> Still locked out."}]}}"#
        for seed in UInt64(0)..<3 {
            for (input, name) in [(thread, "reply.txt"), (ticket, "ticket.json")] {
                let output = try Self.scrub(input, name: name, seed: seed)
                #expect(output.contains("at 07:34 AM, ") && !output.contains("Boateng") && !output.contains("Thornquist"), "\(output)")
                // The name after the time is a first name and a surname, written as before, in the same case.
                #expect(output.range(of: #"07:34 AM, \p{Lu}\p{Ll}+ \p{Lu}\p{Ll}+ <"#, options: .regularExpression) != nil, "\(output)")
                if name == "reply.txt" {
                    #expect(output.range(of: #"at 4:12 PM \p{Lu}\p{Ll}+ \p{Lu}\p{Ll}+ <"#, options: .regularExpression) != nil, "\(output)")
                }
            }
        }
    }
}
