import Foundation

enum Copy {
    static let howItWorksSteps = [
        "Finds personal details three ways: field names such as “password”, “email” or “assigned_to”; patterns for emails, card numbers, IBANs, IDs, IP addresses and secrets; and Apple’s on-device recognition of names, places, phone numbers and addresses.",
        "Replaces each one with a realistic stand-in. The same person or value gets the same stand-in everywhere in the file.",
        "Checks the result again, replaces what slipped through, and shows anything it couldn’t resolve as left to review.",
        "Keeps the file’s structure, so JSON, CSV and XML stay valid.",
    ]
    static let howItWorksFooter = "macOS sandboxes the app with no network access, so nothing can be sent anywhere."

    static let formats = "JSON · XML · CSV · TXT · MD · LOG"

    static func label(_ entity: String) -> String {
        switch entity {
        case "PERSON", "FIRST_NAME", "LAST_NAME", "INITIALS": "Names"
        case "EMAIL_ADDRESS": "Emails"
        case "PHONE_NUMBER": "Phones"
        case "ADDRESS", "POSTAL_CODE": "Addresses"
        case "LOCATION", "REGION", "LATITUDE", "LONGITUDE", "COORDINATES", "TIME_ZONE": "Places"
        case "DATE_OF_BIRTH", "AGE": "Birth dates"
        case "US_SSN": "SSNs"
        case "CREDIT_CARD": "Cards"
        case "IBAN_CODE", "US_BANK_NUMBER": "Bank accounts"
        case "IP_ADDRESS": "IP addresses"
        case "SECRET": "Secrets"
        case "USERNAME": "Usernames"
        default: "IDs"
        }
    }

    static func grouped(_ counts: [String: Int]) -> [(label: String, count: Int)] {
        var totals: [String: Int] = [:]
        for (entity, n) in counts where n > 0 { totals[label(entity), default: 0] += n }
        return totals.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
    }

    struct Failure {
        let title: String
        let body: String
    }

    static func failure(_ code: String) -> Failure {
        switch code {
        case "invalid_json": Failure(title: "This file isn't valid JSON", body: "Check that it opens in a text editor and ends where it should, then try again.")
        case "invalid_xml": Failure(title: "This file isn't valid XML", body: "Check that every tag is closed and the file isn't cut off, then try again.")
        case "xml_doctype": Failure(title: "This XML defines its own entities", body: "Scrub can't safely check values hidden in a DOCTYPE. Remove the <!DOCTYPE …> section and try again.")
        case "invalid_csv": Failure(title: "This CSV couldn't be read", body: "Check that every row has matching quotes, then try again.")
        case "empty_file": Failure(title: "This file is empty", body: "There's nothing in it to clean.")
        case "too_deep": Failure(title: "This file is nested too deeply", body: "Reduce the nesting to 64 levels or fewer, then try again.")
        case "too_large": Failure(title: "This file is too large", body: "Scrub handles files up to 50 MB. Split it into smaller files and clean each one.")
        case "not_utf8": Failure(title: "This file isn't UTF-8 text", body: "Open it in a text editor, save it with UTF-8 encoding, then try again.")
        case "binary_file": Failure(title: "This isn't a text file", body: "Scrub can clean \(formats) files.")
        case "images_not_supported_yet": Failure(title: "Scrub can't clean images yet", body: "Choose a JSON, XML, CSV, or text file instead.")
        case "internal": Failure(title: "Scrub couldn't finish checking this file", body: "Nothing was saved. Try again, and if it keeps happening, let us know which kind of file it was.")
        case "unsupported_type": Failure(title: "Scrub can't clean this type of file yet", body: "Supported files: \(formats).")
        case "empty_clipboard": Failure(title: "The clipboard is empty", body: "Copy some text, like a JSON response, then paste it here.")
        case "clipboard_not_text": Failure(title: "The clipboard doesn't hold text", body: "Copy the text itself rather than a file or image, then paste it here.")
        case "unreadable": Failure(title: "This file couldn't be opened", body: "Check that you have permission to read it, then try again.")
        case "not_saved": Failure(title: "The file couldn't be saved", body: "Nothing was written. Check there is space and that you can write there, then save again.")
        default: Failure(title: "Something went wrong while cleaning", body: "Nothing was saved. Try again, and if it keeps happening, let us know which kind of file it was.")
        }
    }
}
