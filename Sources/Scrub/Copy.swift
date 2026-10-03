import Foundation
import ScrubCore

enum Copy {
    static let howItWorksSteps = [
        "Finds personal details three ways: field names such as “password”, “email” or “assigned_to”; patterns for emails, card numbers, IBANs, IDs, IP addresses and secrets; and Apple’s on-device recognition of names, places, phone numbers and addresses.",
        "Replaces each one with a realistic stand-in. The same person or value gets the same stand-in everywhere in the file.",
        "Checks the result against what it replaced: a name, number or email written another way is replaced too, and anything it only suspects is left for you to decide.",
        "Asks you about the replacements it’s least sure of before you copy or save, so you can leave any that aren’t personal.",
        "Lets you select anything it missed in the result and replace it too, everywhere it’s written, or keep the original of anything it shouldn’t have replaced.",
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
        case "EMPLOYER": "Employers"
        case "RECORD_ID": "Record IDs"
        default: "IDs"
        }
    }

    /// One finding's kind, for the review list.
    static func kind(_ entity: String) -> String {
        switch entity {
        case "PERSON", "FIRST_NAME", "LAST_NAME", "INITIALS": "Name"
        case "EMAIL_ADDRESS": "Email"
        case "PHONE_NUMBER": "Phone"
        case "ADDRESS", "POSTAL_CODE": "Address"
        case "LOCATION", "REGION", "LATITUDE", "LONGITUDE", "COORDINATES", "TIME_ZONE": "Place"
        case "DATE_OF_BIRTH", "AGE": "Birth date"
        case "SECRET": "Secret"
        case "USERNAME": "Username"
        case "EMPLOYER": "Employer"
        case "RECORD_ID": "Record ID"
        default: "ID"
        }
    }

    static func reviewTitle(_ count: Int) -> String {
        count == 1 ? "Check 1 replacement before sharing" : "Check \(count) replacements before sharing"
    }
    static let reviewBody = "Scrub isn’t sure about these. Leave any that aren’t personal, and replace any it left as written but you want gone. A choice covers every place the value appears unless you choose place by place, and every other stand-in stays as it is."
    static let replaceHelp = "Replace it everywhere it appears"
    static func leaveHelp(_ original: String) -> String { "Leave “\(original)” as written everywhere it appears" }
    static func reviewTally(leaving: Int, of total: Int) -> String {
        leaving == 0 ? "Replacing all \(total)" : "Leaving \(leaving) of \(total)"
    }
    /// Why Scrub asks about a finding, in a few words; nil when its kind and confidence say enough.
    static func reason(_ finding: Finding) -> String? {
        switch finding.doubt {
        case .unconfirmed: finding.entity == "ADDRESS" ? "Looks like a street or a house, but nothing beside it says it is an address"
            : "Looks like a name, but nothing else in the text agrees"
        case .unclearOwner: "More than one person nearby could own this; it follows the first"
        case nil: finding.suspected ? "Written like a value Scrub replaced, but not surely it" : nil
        }
    }
    static func places(_ count: Int) -> String { "Choose for each of \(count) places" }
    static let leaveHere = "Leave here"
    static func toCheck(_ count: Int) -> String { count == 1 ? "1 to check" : "\(count) to check" }

    // Marking values by hand.
    static let yourChanges = "Your changes"
    static let yourChangesBody = "Values you marked are replaced everywhere they’re written, and values you kept stay as written. Leave a place to undo it there, or everywhere to undo it all."
    static let markedSection = "Marked by you"
    static let keptSection = "Kept as written by you"
    static func changes(marked: Int, kept: Int) -> String {
        [marked > 0 ? "\(marked) marked" : nil, kept > 0 ? "\(kept) kept" : nil].compactMap { $0 }.joined(separator: " · ") + " by you"
    }
    /// A selected value, quoted, short enough for the bar under the preview.
    static func quoted(_ values: [String]) -> String {
        let first = values.first ?? ""
        let line = first.split(whereSeparator: \.isNewline).first.map(String.init) ?? first
        let shown = line.count > 40 ? String(line.prefix(39)) + "…" : line
        return "“\(shown)”" + (values.count > 1 ? " and \(values.count - 1) more" : "")
    }
    static let replaceSelectionHelp = "Replace it with a stand-in everywhere it’s written, with its variants"
    static let keepOriginalHelp = "Put back what this stand-in replaced, everywhere"
    static func keepOriginal(_ originals: [String]) -> String { originals.count == 1 ? "Keep “\(originals[0])”" : "Keep \(originals.count) originals" }
    static func checked(leaving: Int) -> String { leaving == 0 ? "Checked" : "Checked · \(leaving) left as written" }

    static let reducedCoverageTitle = "Reduced coverage"
    /// Which of Scrub's own detectors didn't load, and what that costs.
    static func reducedCoverage(_ missing: [Coverage.Part]) -> String {
        let names = missing.map { part -> String in
            switch part {
            case .nameModel: "the name model"
            case .addressModel: "an address model"
            case .contextModel: "the context model"
            case .nameLists: "the name lists"
            }
        }
        let list = names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        let plural = names.count > 1 || missing == [.nameLists]
        let (verb, them) = plural ? ("are", "them") : ("is", "it")
        return "\(list.prefix(1).uppercased() + list.dropFirst()) \(verb) missing or damaged, so this scrub ran without \(them) and may have missed names, places or IDs. Reinstall Scrub to restore \(them)."
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
