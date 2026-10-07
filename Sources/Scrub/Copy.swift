import Foundation
import ScrubCore

enum Copy {
    static let howItWorksSteps = [
        "Finds personal details three ways: field names such as “password”, “email” or “assigned_to”; patterns for emails, card numbers, IBANs, IDs, IP addresses and secrets; and Apple’s on-device recognition of names, places, phone numbers and addresses.",
        "Replaces each one with a realistic stand-in. The same person or value gets the same stand-in everywhere in the file.",
        "Checks the result against what it replaced: a name, number or email written another way is replaced too, and anything it only suspects is left for you to decide.",
        "Asks you about the replacements it’s least sure of before you copy or save, so you can leave any that aren’t personal.",
        "Lets you select anything it missed in the result and replace it too, everywhere it’s written, keep the original of anything it shouldn’t have replaced, or change a value’s kind and type its replacement.",
        "Keeps the file’s structure, so JSON, CSV and XML stay valid.",
    ]
    static let howItWorksFooter = "macOS sandboxes the app with no network access, so nothing can be sent anywhere."

    static let formats = "JSON · JSONL · XML · CSV · TXT · MD · LOG"

    static func label(_ entity: String) -> String {
        switch entity {
        case "PERSON", "FIRST_NAME", "LAST_NAME", "INITIALS": "Names"
        case "EMAIL_ADDRESS": "Emails"
        case "PHONE_NUMBER": "Phones"
        case "ADDRESS", "POSTAL_CODE": "Addresses"
        case "LOCATION", "REGION", "LATITUDE", "LONGITUDE", "COORDINATES", "TIME_ZONE": "Places"
        case "DATE_OF_BIRTH", "AGE": "Birth dates"
        case "US_SSN": "SSNs"
        case "CREDIT_CARD", "EXPIRY_DATE": "Cards"
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
        case "ADDRESS", "POSTAL_CODE": "Street or address"
        case "LOCATION", "REGION", "LATITUDE", "LONGITUDE", "COORDINATES", "TIME_ZONE": "Place"
        case "DATE_OF_BIRTH", "AGE": "Birth date"
        case "SECRET": "Secret"
        case "EXPIRY_DATE": "Expiry date"
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
    static func changes(marked: Int, kept: Int, edited: Int = 0) -> String {
        [marked > 0 ? "\(marked) marked" : nil, kept > 0 ? "\(kept) kept" : nil, edited > 0 ? "\(edited) edited" : nil].compactMap { $0 }.joined(separator: " · ") + " by you"
    }
    static let changesHelp = "See the values you marked, kept or edited in the Values panel"
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
    static func inPlaces(_ count: Int) -> String { count == 1 ? "in 1 place" : "in \(count) places" }
    /// What a mark, a kept original, an undo or a redo just did, said under the preview.
    static func replaced(_ values: [String], places count: Int, as entity: String) -> String {
        let kind = kind(entity), lowered = kind == kind.uppercased() ? kind : kind.lowercased()
        let article = "AEIOU".contains(kind.prefix(1)) ? "an" : "a"
        // Every place it is written was replaced already, by Scrub or an earlier mark.
        guard count > 0 else { return "\(quoted(values)) was already replaced everywhere" }
        return "Replaced \(quoted(values)) as \(article) \(lowered) \(inPlaces(count))"
    }
    static func kept(_ originals: [String], places count: Int, unmarking: Bool) -> String {
        unmarking ? "Took the mark off \(quoted(originals)) \(inPlaces(count))" : "Put back \(quoted(originals)) \(inPlaces(count))"
    }
    static func undid(_ change: String) -> String { "Undone: \(change)" }
    static func redid(_ change: String) -> String { "Redone: \(change)" }
    static let removeMark = "Remove mark"
    static let removeMarkHelp = "Take this mark off, and put back what it replaced everywhere"

    // Editing a value: its kind, and what replaces it.
    static let editorFor = "For"
    static let replaceWith = "Replace with"
    static let apply = "Apply"
    static let cancel = "Cancel"
    static let kindHelp = "What to read it as; a new kind draws a new stand-in"
    static let replaceWithHelp = "Type what to write in its place, everywhere it’s written"
    /// A kind in a sentence: "a place", "an email", "an ID".
    static func article(_ entity: String) -> String {
        let kind = kind(entity), lowered = kind == kind.uppercased() ? kind : kind.lowercased()
        return ("AEIOU".contains(kind.prefix(1)) ? "an " : "a ") + lowered
    }
    /// The Edit menu's name for a change of kind, a typed replacement, or both.
    static func editStep(_ original: String, kind entity: String?, replacement: String?) -> String {
        switch (entity, replacement) {
        case (let entity?, let typed?): "Replace \(quoted([original])) with \(quoted([typed])) as \(kind(entity))"
        case (nil, let typed?): "Replace \(quoted([original])) with \(quoted([typed]))"
        case (let entity?, nil): "Change \(quoted([original])) to \(kind(entity))"
        case (nil, nil): "Edit \(quoted([original]))"
        }
    }
    static func editStep(_ originals: [String], kind entity: String) -> String { "Change \(quoted(originals)) to \(kind(entity))" }
    /// What an edit just did, said under the preview.
    static func edited(_ original: String, kind entity: String?, replacement: String?, places count: Int) -> String {
        switch (entity, replacement) {
        case (let entity?, let typed?): "Replaced \(quoted([original])) with \(quoted([typed])), as \(article(entity)), \(inPlaces(count))"
        case (nil, let typed?): "Replaced \(quoted([original])) with \(quoted([typed])) \(inPlaces(count))"
        case (let entity?, nil): changed([original], to: entity, places: count)
        case (nil, nil): "Nothing changed"
        }
    }
    static func changed(_ originals: [String], to entity: String, places count: Int) -> String {
        "Changed \(quoted(originals)) to \(article(entity)) \(inPlaces(count))"
    }
    static func replaceAgainStep(_ originals: [String]) -> String { "Replace \(quoted(originals)) Again" }
    static func replacedAgain(_ originals: [String], places count: Int) -> String { "Replaced \(quoted(originals)) again \(inPlaces(count))" }
    static func placesStep(_ original: String) -> String { "Choose Places for \(quoted([original]))" }
    static func chosePlaces(_ original: String) -> String { "Chose where \(quoted([original])) is replaced" }
    /// Why a typed replacement, or a kind, can't be used, beside the field.
    static func refusal(_ refusal: Refusal, original: String) -> String {
        switch refusal {
        case .empty: "Type something to replace it with"
        case .original: "That still holds \(quoted([original]))"
        case .other(let value): "That holds \(quoted([value])), another value in this file"
        case .part(let word): "That still holds \(quoted([word]))"
        case .number: "It’s a bare number in the file, so only a number can replace it"
        case .uncovered(let form): "That would leave \(quoted([form])) as written"
        }
    }
    /// Why a change of kind changed none of the values chosen, under the
    /// preview: how many of them can't take it, which, and why.
    static func unchanged(_ refused: [String], of total: Int, because refusal: Refusal) -> String {
        let one = refused.count == 1
        let which = total == 1 ? quoted(refused) : "\(refused.count) of \(total) values (\(quoted(refused)))"
        switch refusal {
        case .number: return "Nothing changed: \(which) \(one ? "is a bare number" : "are bare numbers") in the file, and only a number can replace \(one ? "it" : "them")"
        default: return "Nothing changed: \(which) can’t take that kind"
        }
    }

    // The Values panel.
    static let values = "Values"
    static let showValues = "Show Values"
    static let hideValues = "Hide Values"
    static let valuesHelp = "Every value Scrub found or you marked, to find, filter and change (⇧⌘L)"
    static let searchValues = "Search originals and stand-ins"
    static let allKinds = "All kinds"
    static let original = "Original"
    static let kindColumn = "Kind"
    static let standIn = "Stand-in"
    static let placesColumn = "Places"
    static let statusColumn = "Status"
    static func valueCount(shown: Int, of total: Int) -> String {
        shown == total ? (total == 1 ? "1 value" : "\(total) values") : "\(shown) of \(total)"
    }
    static func selected(_ count: Int) -> String { "\(count) selected" }
    static let changeKind = "Change kind"
    static let keepOriginalAction = "Keep original"
    static let replaceAgain = "Replace again"
    static let placeByPlace = "Place by place…"
    static let placeByPlaceHelp = "Choose where this value is replaced and where it’s left, place by place"
    static func placesTitle(_ original: String) -> String { "Places of \(quoted([original]))" }
    static let placesBody = "Leave a place to keep the original there. Every other place keeps its stand-in."
    static let replaceAgainHelp = "Write the stand-in again wherever the original was left"
    static func placesCount(_ count: Int) -> String { count == 1 ? "1 place" : "\(count) places" }
    static func status(_ status: ValueStatus) -> String {
        switch status {
        case .replaced: "Replaced"
        case .left: "Left as written"
        case .toCheck: "To check"
        case .marked: "Marked by you"
        }
    }
    static func filter(_ filter: ValueFilter) -> String {
        switch filter {
        case .all: "All statuses"
        case .status(let status): Self.status(status)
        case .yours: yourChanges
        }
    }
    static let noValues = "Scrub found nothing to replace here"
    static let noMatches = "No values match"
    static func reviewBanner(_ count: Int) -> String {
        count == 1 ? "1 replacement to check before sharing" : "\(count) replacements to check before sharing"
    }
    static let reviewBannerBody = "Scrub isn’t sure about these. Copy and Save ask you first."
    static func moreCounts(_ count: Int) -> String { "+\(count) more" }
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
