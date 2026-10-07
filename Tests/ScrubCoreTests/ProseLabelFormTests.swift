import Foundation
@testable import ScrubCore
import Testing

// Values a form, a markdown list or table, or a sentence gives after their label,
// in English and in the other languages forms are filled in. Each case goes in as a
// text file and as a JSON note's string. Every value below is invented.

private struct FormCase: Sendable, CustomTestStringConvertible {
    let name: String
    let text: String
    /// Values that must be gone from every rendering's output.
    let gone: [String]
    /// Text that must come out as written.
    var kept: [String] = []
    var testDescription: String { name }
}

private func renderings(_ text: String) throws -> [(String, String, Data)] {
    let note = try JSONSerialization.data(withJSONObject: ["note": text], options: [.withoutEscapingSlashes])
    return [("text", "doc.txt", Data(text.utf8)), ("json", "doc.json", note)]
}

/// The text a rendering's output holds: the note's string decoded, or the text itself.
private func written(_ output: Data, _ rendering: String) throws -> String {
    guard rendering == "json" else { return String(decoding: output, as: UTF8.self) }
    let object = try #require(try JSONSerialization.jsonObject(with: output) as? [String: String], "no longer parses")
    return try #require(object["note"])
}

private let cases: [FormCase] = [
    FormCase(name: "a bold label with its colon inside the marks",
             text: "**Payment**\n- **CVV:** 418\n- **Postcode:** 60614\n- **User Name**: quillmere88\n- **License Plate**: KD 514 RX 30\n- **City:** Port Elwyn",
             gone: ["418", "60614", "quillmere88", "KD 514 RX 30", "514 RX"], kept: ["- **CVV:** ", "- **Postcode:** ", "- **User Name**: ", "- **License Plate**: "]),
    FormCase(name: "a table's row naming its field",
             text: "| Field | Value |\n|---|---|\n| **Postcode** | 482913 |\n| PIN | 5531 |\n| Status | Active |",
             gone: ["482913", "5531"], kept: ["| **Postcode** | ", "| PIN | ", "| Status | Active |"]),
    FormCase(name: "a table whose header names its columns",
             text: "| Name | Device | Plate | Amount |\n|------|--------|-------|--------|\n| Odalys Fernhart | 9c2e41d7-5b3a-4f08-a6e1-3d7c9b2f8a14 | KX 482 TB | $1,250.00 |",
             gone: ["Fernhart", "9c2e41d7-5b3a-4f08-a6e1-3d7c9b2f8a14", "KX 482 TB"], kept: ["| Name | Device | Plate | Amount |", "| $1,250.00 |"]),
    FormCase(name: "labels in other languages",
             text: "Geboortedatum: 14-02-1979\nCreditcard veiligheidscode: 381\nPasswort: Tr4m!betrieb9\nKundennummer: K-58213\nCódigo postal: 28014\nGebruikersnaam: velden_k77\nDate de naissance : 03/09/1984",
             gone: ["14-02-1979", "381", "Tr4m!betrieb9", "58213", "28014", "velden_k77", "03/09/1984"],
             kept: ["Geboortedatum: ", "Creditcard veiligheidscode: ", "Passwort: ", "Kundennummer: ", "Código postal: ", "Gebruikersnaam: "]),
    FormCase(name: "a point after its labels, with its hemispheres, or after a word for one",
             text: "Latitude: 41.3874, Longitude: 2.1686\nDeparting from 57.7692525 S, 48.945249 W at noon.\nThe incident was at the coordinates 40.7128, -74.0060 last week.",
             gone: ["41.3874", "2.1686", "57.7692525", "48.945249", "40.7128", "74.0060"], kept: ["Latitude: ", ", Longitude: ", "Departing from ", "The incident was at the coordinates "]),
    FormCase(name: "a device's identifier after its label",
             text: "Device ID: 3f8a2c1e-7b4d-4e9a-b2c6-1d5e8f7a9b03\nDevice Identifier (358240051111110)\nThe device identifier for this request is 6d1f0a9e8c7b5a43.",
             gone: ["3f8a2c1e-7b4d-4e9a-b2c6-1d5e8f7a9b03", "358240051111110", "6d1f0a9e8c7b5a43"], kept: ["Device ID: ", "Device Identifier ("]),
    FormCase(name: "a short first name after its label", text: "- First Name: Ava\n- Last Name: Brennick\n- Recipient Name: Taylor",
             gone: ["Ava", "Brennick", "Taylor"], kept: ["- First Name: ", "- Last Name: "]),
    FormCase(name: "a handle after the word for a user", text: "The sign-in code for user corvane_77 was sent. The user name lzimmerfeld was entered.",
             gone: ["corvane_77", "lzimmerfeld"], kept: ["The sign-in code for user ", " was sent."]),
    FormCase(name: "an identifier in pieces after its label is replaced whole",
             text: "License plate: Q41-7720-385-19\nVehicle: 2019 hatchback, Policy Holder ID: E-48213",
             gone: ["Q41", "7720", "385-19"], kept: ["License plate: ", "Vehicle: 2019 hatchback"]),
    FormCase(name: "a card's code, a PIN, a password and a one-time code in sentences",
             text: "The CVV for this card is 364. Keep your PIN, which is 820461, secret. Use the password Lanter9!kite to sign in. Your two-factor authentication code is 507193.",
             gone: ["364", "820461", "Lanter9!kite", "507193"], kept: ["The CVV for this card is ", "Keep your PIN, which is ", "Use the password ", " to sign in."]),
]

@Test(arguments: cases)
private func proseLabelFormValuesAreReplaced(_ formCase: FormCase) throws {
    for (rendering, file, data) in try renderings(formCase.text) {
        let output = try written(Scrubber.scrub(data, name: file, forceFullDetection: false, seed: 7).output, rendering)
        for value in formCase.gone { #expect(!output.contains(value), "[\(rendering)] \(value) left in \(output)") }
        for value in formCase.kept { #expect(output.contains(value), "[\(rendering)] \(value) changed in \(output)") }
    }
}

/// What a form writes that is no one's: versions, dates of a release, amounts, headings, a
/// field's name in a sentence, a year after a PIN, a hyphenated word, a UUID no label names, a
/// code's field, and a sentence in another language opening with a word that is no name.
@Test func proseLabelFormLeavesOrdinaryTextAsWritten() throws {
    let text = """
    Version: 2.4.1, Release Date: 2024-03-01, Total: 1,250.00
    ## Summary: the release went fine
    Note: the password field is required and the PIN must be 4 digits. The PIN expires in 2026.
    Passwords must meet the following criteria: Minimum length of twelve.
    Use strong passwords, two-factor sign-in and short sessions.
    const q = { password: sql`SELECT 1` };
    - Added `ipv4_address` to user profile.
    Login with IPv4 or IPv6 from the office.
    Request 7d2e4c1a-9b3f-4a6e-8c5d-1f0e2b3a4c5d completed in 120 ms.
    Uw nieuwe wachtwoord is verstuurd. Zorg ervoor dat u het goed bewaart.
    """
    for (rendering, file, data) in try renderings(text) {
        let output = try written(Scrubber.scrub(data, name: file, forceFullDetection: false, seed: 7).output, rendering)
        #expect(output == text, "[\(rendering)] \(output)")
    }
}

@Test func proseLabelFormMasksOnlyEmphasis() {
    // Offsets stay; marks inside a value or a mask of digits stay too.
    let text = "- **CVV:** 771 and ab**cd, **** **** 1234, CVV:** 772"
    let masked = FormFields.masked(text)
    #expect(masked.utf16.count == text.utf16.count)
    #expect(masked == "-   CVV:   771 and ab**cd, **** **** 1234, CVV:   772")
}
