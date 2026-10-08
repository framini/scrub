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

    /// A document check's code for the kind of document it read, dotted and naming a driver's licence by its
    /// initials ("DOC.2.1.USA.TX.DL.041503"), is the document type's, not the licence's number.
    @Test func aDocumentTypesDottedCodeStays() throws {
        let response = #"{"images": [{"classification": {"docsid": "DOC.2.1.USA.TX.DL.041503", "imageType": "DriversLicenseFront"}}], "extracted": {"fullName": "Rosalind Okonkwo-Barre", "documentNumber": "47120936", "dateOfBirth": "1984-11-02"}}"#
        for seed: UInt64 in 1...3 {
            for name in ["check.json", "Pasted text"] {
                let output = try Self.scrub(response, name: name, seed: seed)
                #expect(output.contains(#""docsid": "DOC.2.1.USA.TX.DL.041503""#), "[\(name) seed \(seed)] \(output)")
                #expect(!output.contains("47120936") && !output.contains("Okonkwo"), "[\(name) seed \(seed)] \(output)")
            }
        }
    }

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
            // A first name opening a line is still the person's, wherever the tagger places it.
            let signed = try Self.scrub("James B\n", name: "note.txt", seed: seed)
            #expect(!signed.contains("James"), "\(signed)")
            // A unit after a number is still the address's, never a sentence after it.
            let unit = try Self.scrub("Please deliver to 1407 Linden Park Road 4410. Apt. 12 is on the left.\n", name: "note.txt", seed: seed)
            #expect(!unit.contains("Linden Park") && !unit.contains("Apt. 12 "), "\(unit)")
            let street = try Self.scrub("The bus drops you off at 731 Rákóczi Ferenc útja 48. St.\n", name: "note.txt", seed: seed)
            #expect(!street.contains("Rákóczi") && street.components(separatedBy: "St").count == 2, "\(street)")
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

    @Test func aClinicalNotesReadingsAndCodesStay() throws {
        // "BP 156/62" became "WO 836/76" and "R07.89" became "K19.98": readings and a diagnosis code read as IDs.
        let note = """
        PROGRESS NOTE
        Patient: Wexcombe, Ottoline    MRN#: 48213907
        DOB: 03/21/1953    Sex: F
        Address: 4821 Juniper Hollow Rd, # 22, Tacoma, WA 98402
        Phone: (253) 555-0144
        Date of service: 04/27/2026
        Attending: Dr. Tobiah Quennell

        S: Ottoline is a 73-year-old who presents with a three-day history of productive cough. Lives with her daughter, Marisol Quent, who also attended.
        O: BP 156/62, HR 82, RR 18/min, T 37.4 C. SpO2 90% on room air.
        A: Mechanical low back pain (M54.50), cough (R05.9).
        P: Started amoxicillin 500 mg TID x 7 days. Follow up with Ama Okafor, RN in 10 days.
        Ins: Northgale Mutual member ID W053165199.

        Electronically signed by Tobiah Quennell, DO on 2026-05-28T10:57:38Z

        """
        for seed in UInt64(0)..<3 {
            let output = try Self.scrub(note, name: "note.txt", seed: seed)
            for kept in ["O: BP 156/62, HR 82, RR 18/min, T 37.4 C. SpO2 90% on room air.", "(M54.50), cough (R05.9)."] { #expect(output.contains(kept), "\(kept): \(output)") }
            #expect(!output.contains("Wexcombe") && !output.contains("48213907"), "\(output)")
        }
    }

    @Test func referencesAndReasonCodesInProseStay() throws {
        // An application's reference, a tracker's key and a check's reason code after an address were replaced;
        // a firm named for its trade was read as a person. An account's number is still replaced.
        let notes = """
        Case note: spoke to Ottoline Wexcombe regarding account ACC-0610949. Her application reference APP-95146469 is on hold.
        Action: Tobiah to follow up with Brackwater Telecom about reason code ID-SYN-3, tracked on the onboarding board (ONB-1693).
        [12:22] tobiah: ok. looks like ottoline's address 9769 Larchmont Ave, Apt 4D, Albany, NY 12203 failed ID-SYN-3
        [12:24] tobiah: and the old one Lindenauerring 33b, 72194 Regensburg failed WL_FUZZY_HIT

        """
        for seed in UInt64(0)..<3 {
            let output = try Self.scrub(notes, name: "notes.txt", seed: seed)
            for kept in ["APP-95146469", "Brackwater Telecom", "(ONB-1693)", "failed ID-SYN-3\n", "failed WL_FUZZY_HIT\n"] { #expect(output.contains(kept), "\(kept): \(output)") }
            for gone in ["Wexcombe", "0610949", "Larchmont", "Lindenauerring"] { #expect(!output.contains(gone), "\(gone): \(output)") }
            // A house number is no postcode: the unit written in small letters after the street is still the address's.
            let lives = try Self.scrub("She lives at 4821 Juniper Hollow Dr. suite 210, Tacoma, WA 98402 since May.\n", name: "note.txt", seed: seed)
            #expect(!lives.contains("Juniper") && !lives.contains("suite 210"), "\(lives)")
        }
    }

    @Test func aRequestsOwnReferenceStaysAndASessionKeepsItsShape() throws {
        // A client's reference to its request ("ref-55af36d14d") was replaced as a person's ID, and a session's UUID became 24 random letters.
        let request = #"{"client_reference": "ref-55af36d14d", "workflow": "kyc_standard", "consumer": {"name": {"first": "Ottoline", "last": "Wexcombe"}, "customer_id": "cus_Q8vZr2LmT0aBcD"}, "device": {"session_id": "54a2c09b-a704-46f4-89a6-2f3d5dde9c1b", "ip": "203.0.113.24"}}"#
        for seed in UInt64(0)..<3 {
            let output = try Self.scrub(request, name: "request.json", seed: seed)
            #expect(output.contains(#""client_reference": "ref-55af36d14d""#) && !output.contains("Wexcombe") && !output.contains("cus_Q8vZr2LmT0aBcD"), "\(output)")
            let session = try #require(output.firstMatch(of: /"session_id": "([^"]*)"/)?.1)
            #expect(session != "54a2c09b-a704-46f4-89a6-2f3d5dde9c1b" && session.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) != nil, "\(output)")
        }
    }

    @Test func aDateInALogsKeyAndValueIsNoPhoneNumber() throws {
        // A matcher's log wrote the birth dates it compared as "input=1984-03-07", and both became phone-shaped digits ("6245-56-21").
        let log = """
        2026-09-14T10:22:31.519Z WARN [matcher] dob mismatch input=1984-03-07 bureau=1984-07-03 email=t.okonkwo@example.com
        2026-09-14T10:22:31.611Z INFO [matcher] retry=2 source=credit_header matched_on=name,address
        2026-09-14T10:22:32.004Z WARN [matcher] dob mismatch input=1990/11/23 bureau=1990/11/28 email=r.lindqvist@example.org

        """
        let day = /(?:19|20)\d\d([-\/])(?:0[1-9]|1[0-2])\1(?:0[1-9]|[12]\d|3[01])/
        for seed in UInt64(0)..<3 {
            for name in ["matcher.log", "Pasted text"] {
                let output = try Self.scrub(log, name: name, seed: seed)
                for gone in ["1984-03-07", "1984-07-03", "1990/11/23", "1990/11/28", "okonkwo", "lindqvist"] { #expect(!output.contains(gone), "\(gone): \(output)") }
                for kept in ["2026-09-14T10:22:31.519Z WARN [matcher] dob mismatch input=", "retry=2 source=credit_header matched_on=name,address\n"] { #expect(output.contains(kept), "\(kept): \(output)") }
                let values = output.matches(of: /(?:input|bureau)=(\S+)/).map { String($0.1) }
                #expect(values.count == 4 && values.allSatisfy { $0.wholeMatch(of: day) != nil }, "\(values): \(output)")
            }
        }
    }

    @Test func aNetworksMachinesAddressesStay() throws {
        // A cluster's status named no one, yet its node's host name became a person and every address a stand-in.
        let cluster = """
        {
          "cluster": "prod-eu-1",
          "nodes": [
            {"name": "ip-10-0-3-17.eu-west-1.compute.internal", "ip": "10.0.3.17", "status": "Ready"},
            {"name": "worker-b", "ip": "192.168.1.20", "status": "NotReady"}
          ],
          "dns": ["8.8.8.8", "1.1.1.1"],
          "subnet": {"cidr": "10.42.0.0/16", "gateway": "10.42.0.1"},
          "listen": "0.0.0.0:8443",
          "loopback": "127.0.0.1",
          "ipv6_loopback": "::1",
          "maintainers": ["team-payments", "team-sre"]
        }
        """
        // A person's session keeps none of its addresses but the resolver it asked.
        let session = #"{"session": {"user": "Tobiah Quarrington", "email": "t.quarrington@example.net", "ip": "98.204.17.66", "lan_ip": "192.168.1.20", "dns": "8.8.8.8"}}"#
        let log = """
        2026-09-14T10:22:31Z INFO [edge] listening on 127.0.0.1:8080, routing 10.42.0.0/16 via 10.42.0.1
        2026-09-14T10:22:33Z INFO [edge] login user=t.quarrington@example.net client=98.204.17.66 iface=98.204.17.66/24

        """
        for seed in UInt64(0)..<3 {
            for name in ["cluster.json", "Pasted text"] {
                let output = try Self.scrub(cluster, name: name, seed: seed)
                #expect(output == cluster, "\(output)")
            }
            let person = try Self.scrub(session, name: "session.json", seed: seed)
            for gone in ["Quarrington", "98.204.17.66", "192.168.1.20"] { #expect(!person.contains(gone), "\(gone): \(person)") }
            #expect(person.contains(#""dns": "8.8.8.8""#), "\(person)")
            let text = try Self.scrub(log, name: "edge.log", seed: seed)
            #expect(text.contains("listening on 127.0.0.1:8080, routing 10.42.0.0/16 via"), "\(text)")
            for gone in ["quarrington", "98.204.17.66"] { #expect(!text.contains(gone), "\(gone): \(text)") }
        }
    }

    @Test func aChatsLineTimesStayWhenItAsksForABirthDate() throws {
        // Asking for a "dob" made every line's time "[2026-09-14 14:02:40]" a birth date, rewritten everywhere.
        let chat = """
        [2026-09-14 14:02:11] agent_mara: hi! how can i help today?
        [2026-09-14 14:02:40] customer: hey its tobiah quarrington, my id check keeps failing
        [2026-09-14 14:03:05] agent_mara: sorry about that tobiah. can you confirm your email and dob?
        [2026-09-14 14:03:31] customer: t.quarrington@example.net and my dob is 1991-04-12
        [2026-09-14 14:04:30] agent_mara: thanks, passing this to the risk team.

        """
        for seed in UInt64(0)..<3 {
            let output = try Self.scrub(chat, name: "Pasted text", seed: seed)
            #expect(Self.count("[2026-09-14 14:0", in: output) == 5, "\(output)")
            for gone in ["quarrington", "1991-04-12"] { #expect(!output.contains(gone), "\(gone): \(output)") }
        }
    }

    @Test func aCountryAWeekdayAndAYearAloneKeepTheirShape() throws {
        // "Ukraine" was read as a person, so a sanctions program "UKRAINE-EO13660" and "Dnipro, Ukraine" took a woman's name;
        // a birth year "circa 1970" became a whole date; "On Fri, 11 Sep 2026" became "On Carolyn, 11 Sep 2026".
        let screening = """
        {"name": "Bohdan Kovalchyk", "places_of_birth": ["Dnipro, Ukraine"], "programs": ["UKRAINE-EO13660"], "dates_of_birth": ["1971-11-02", "circa 1970"], "nationalities": ["Ukraine"]}
        """
        let email = """
        From: Bohdan Kovalchyk <b.kovalchyk@example.org>
        To: verification@example.com

        Hello, my check was rejected again.

        > On Fri, 11 Sep 2026, Verification Team wrote:
        > Dear Mr Kovalchyk, we could not confirm your address.

        """
        for seed in UInt64(0)..<3 {
            for name in ["screening.json", "Pasted text"] {
                let output = try Self.scrub(screening, name: name, seed: seed)
                #expect(output.contains(#""programs": ["UKRAINE-EO13660"]"#) && output.contains(#", Ukraine"]"#) && output.contains(#""nationalities": ["Ukraine"]"#), "\(output)")
                for gone in ["Kovalchyk", "1971-11-02", "circa 1970"] { #expect(!output.contains(gone), "\(gone): \(output)") }
                #expect(output.contains(/"(?:1[89]|20)\d\d-\d\d-\d\d", "circa (?:19|20)\d\d"\]/), "\(output)")
            }
            let text = try Self.scrub(email, name: "Pasted text", seed: seed)
            #expect(text.contains("> On Fri, 11 Sep 2026, Verification Team wrote:\n"), "\(text)")
            #expect(!text.contains("Kovalchyk") && !text.contains("kovalchyk"), "\(text)")
        }
    }

    @Test func aRequestsHeaderNamesStay() throws {
        // In a pasted request "-H 'Idempotency-Key: …'" lost its header's name to a city ("Burlington-Key").
        let request = """
        curl -X POST https://api.example.com/v2/identity/verify \\
          -H 'Content-Type: application/json' \\
          -H 'Idempotency-Key: 6c3f8e2a-91b4-4d7e-b5a0-2f1c9d8e7b6a' \\
          --header "Correlation-Id: req-77120" \\
          -d '{"first_name": "Bohdan", "last_name": "Kovalchyk", "date_of_birth": "1971-11-02", "address": {"line1": "Villa 17, Street 23b", "city": "Kharkiv", "country": "UA"}}'

        """
        for seed in UInt64(0)..<3 {
            let output = try Self.scrub(request, name: "Pasted text", seed: seed)
            for kept in ["  -H 'Content-Type: application/json' \\\n", "  -H 'Idempotency-Key: ", "  --header \"Correlation-Id: "] { #expect(output.contains(kept), "\(kept): \(output)") }
            for gone in ["Bohdan", "Kovalchyk", "1971-11-02"] { #expect(!output.contains(gone), "\(gone): \(output)") }
        }
    }

    @Test func aCSVsQuotedCellsKeepTheirQuotes() throws {
        // A note written in quotes it didn't need lost them, though only its name changed; cells naming no one lost theirs too.
        let cases = """
        case_id,customer,notes,status,amount
        C-1002,Bohdan Kovalchyk,"Bohdan's brother called",open,75.00
        C-1003,"Ilse Marrow","Awaiting documents","pending review",120.50
        "C-1004",Ilse Marrow,"Called back, no answer",closed,0.00

        """
        for seed in UInt64(0)..<3 {
            let output = try Self.scrub(cases, name: "cases.csv", seed: seed)
            let lines = output.components(separatedBy: "\n")
            #expect(lines.count == 5 && lines[0] == "case_id,customer,notes,status,amount", "\(output)")
            #expect(lines[1].hasPrefix("C-1002,") && lines[1].hasSuffix("'s brother called\",open,75.00") && lines[1].contains(",\""), "\(output)")
            #expect(lines[2].hasPrefix("C-1003,\"") && lines[2].hasSuffix("\",\"Awaiting documents\",\"pending review\",120.50"), "\(output)")
            #expect(lines[3].hasPrefix("\"C-1004\",") && lines[3].hasSuffix(",\"Called back, no answer\",closed,0.00"), "\(output)")
            for gone in ["Bohdan", "Kovalchyk", "Marrow"] { #expect(!output.contains(gone), "\(gone): \(output)") }
        }
    }

    @Test func anIDItsOwnWordsCallAPersonsIsReplacedThoughShapedLikeAReference() throws {
        // A record number, a plate, a member's or an employee's ID of capitals and a short number was let go
        // as a tracker's key ("ONB-1693"), and a licence number opening "TX-" as a transaction's reference.
        let notes = """
        Service note 2026-09-14: oil change for the vehicle with the license plate KWD-4417, owner Ottoline Wexcombe.
        Intake: patient seen in triage, MRN-58213, referred to Dr. Tobiah Quennell. MRN-58213 to be flagged for follow-up.
        The customer id for reference is QV-30418 and the member's card number is HLM-7720.
        The certificate license number for this audit is TX-6604183.
        | Employee ID: | PLN-2291 |
        | Name: | Ottoline Wexcombe |
        Action: Tobiah to follow up on the onboarding board (ONB-1693) and request REQ-20417.
        """
        let body = #"{"case": {"note": "\#(notes.replacingOccurrences(of: "\n", with: "\\n"))", "status": "open"}}"#
        for seed in UInt64(0)..<3 {
            for (document, name) in [(notes, "notes.txt"), (body, "case.json")] {
                let output = try Self.scrub(document, name: name, seed: seed)
                for gone in ["KWD-4417", "58213", "QV-30418", "HLM-7720", "TX-6604183", "PLN-2291", "Wexcombe"] { #expect(!output.contains(gone), "\(gone) in \(name): \(output)") }
                for kept in ["(ONB-1693)", "REQ-20417"] { #expect(output.contains(kept), "\(kept) in \(name): \(output)") }
            }
        }
    }
}
