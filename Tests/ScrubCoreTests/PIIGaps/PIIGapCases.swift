import Foundation
@testable import ScrubCore

/// One sentence with a personal value written in prose, or (for keep
/// categories) ordinary text that only looks like one.
struct PIIGapCase {
    let category: PIIGapCategory
    let prose: String
    /// What must be gone from the output; empty for keep cases.
    let targets: [String]
    /// The words that name the value ("born", "passport number"): still there after scrubbing.
    var cues: [String] = []
}

enum PIIGapCategory: String, CaseIterable, Codable {
    case birthDates, labelledIDs, secretsInProse, poBoxes, birthYears, phoneExtensions, stackedAddresses, mailHeaders, titledNames
    case placesInProse, employersOfPeople, nonLatinNames, handlesInProse
    case datesNotBirths, labelsWithoutValues, secretWordsNotSecrets, yearsNotBirths, extensionLookAlikes, headersWithoutPeople, titlesWithoutPeople
    case companiesWithoutPeople, nonLatinNotNames

    var isKeep: Bool {
        [.datesNotBirths, .labelsWithoutValues, .secretWordsNotSecrets, .yearsNotBirths, .extensionLookAlikes, .headersWithoutPeople, .titlesWithoutPeople,
         .companiesWithoutPeople, .nonLatinNotNames].contains(self)
    }

    /// The type a found value must be replaced as.
    var entity: String? {
        switch self {
        case .birthDates: "DATE_OF_BIRTH"
        case .labelledIDs: "ID_NUMBER"
        case .secretsInProse: "SECRET"
        case .poBoxes, .stackedAddresses: "ADDRESS"
        case .birthYears: "DATE_OF_BIRTH"
        case .phoneExtensions: "PHONE_NUMBER"
        case .mailHeaders, .titledNames, .nonLatinNames: "PERSON"
        case .placesInProse: "LOCATION"
        case .employersOfPeople: "EMPLOYER"
        case .handlesInProse: "USERNAME"
        default: nil
        }
    }

    var summary: String {
        switch self {
        case .birthDates: "A date of birth after a cue: born, DOB, d.o.b., birthday"
        case .labelledIDs: "An ID after its label: passport, NI number, MRN, employee ID"
        case .secretsInProse: "A password, PIN, key or token written in a sentence or URL"
        case .poBoxes: "The number of a post office box"
        case .datesNotBirths: "Due dates, release dates, ranges (keep)"
        case .labelsWithoutValues: "ID labels with no value beside them (keep)"
        case .secretWordsNotSecrets: "Password and key talk with no secret in it (keep)"
        case .birthYears: "A birth year alone: \"born in 1948\", \"(b. 1962)\""
        case .phoneExtensions: "An extension: x41872, ext. 5-3310"
        case .stackedAddresses: "A signature's street over its city line"
        case .mailHeaders: "People in mail headers: office paths, Last, First lists, the sender"
        case .titledNames: "A title before initials or a surname: Ms E. Lind, Dr Osei"
        case .yearsNotBirths: "Companies, ideas and releases born or founded in a year (keep)"
        case .extensionLookAlikes: "Sizes, hex and counts with an x (keep)"
        case .headersWithoutPeople: "Header lines that list no person (keep)"
        case .titlesWithoutPeople: "Titles before a role, a street or a business (keep)"
        case .placesInProse: "A town someone lives in, moved to or comes from"
        case .employersOfPeople: "The company someone works for"
        case .nonLatinNames: "A name in another script inside English text"
        case .handlesInProse: "A handle given in a sentence: discord, insta, slack"
        case .companiesWithoutPeople: "Companies named with no one working there (keep)"
        case .nonLatinNotNames: "Words in another script that name no one (keep)"
        }
    }
}

struct PIIGapCaseGen {
    var gen: Gen
    init(seed: UInt64) { gen = Gen(seed: seed) }

    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    static let words = ["tangerine", "falcon", "harbor", "velvet", "cobalt", "meadow", "quartz", "ember", "willow", "saffron"]
    static let people = ["Kofi Mensah", "Linnea Achterberg", "Priya Ramaswamy", "Tomasz Wójcik", "Aisha Haddad", "Rhys Brennan"]
    static let hosts = ["db.corvane.test", "git.tallowmere.test", "files.brightwater.test"]
    static let firsts = ["Kofi", "Linnea", "Priya", "Tomasz", "Aisha", "Rhys", "Ingrid", "Mehmet", "Zofia", "Oren", "Marisol", "Teodor"]
    static let lasts = ["Mensah", "Achterberg", "Ramaswamy", "Wójcik", "Haddad", "Brennan", "Gravenor", "Çelikkaya", "Wąsowska", "Halloway", "Quintero", "Okonkwo-Lind"]
    static let towns = ["Košice", "Debrecen", "Tromsø", "Haarlem", "Bunbury", "Kitwe", "Chiclayo", "Ballarat", "Szeged", "Aalborg", "Trieste"]
    static let companies = ["Brackenfold Dental", "Orrinvale Freight", "Ellensby Motors", "Tamberlyn Care Home", "Hesketh Lane Bakery", "Quorrow Pharmacy"]
    static let jobs = ["nurse", "driver", "receptionist", "bookkeeper", "night porter", "pharmacist"]
    static let nonLatin = ["陈雨桐", "Дмитрий Орлов", "박서연", "Νίκος Λαμπράκης", "أحمد منصور", "רונית כהן", "สมชาย ใจดี", "प्रिया शर्मा"]
    static let offices = ["/HOU/CVN@CVN", "/NA/Corvane@Corvane", "/Corp/Tallowmere@TALLOWMERE", "/LON/BW@BW"]
    static let streets = ["Kessler Avenue", "Marlowe Street", "Juniper Hollow Rd", "Wexcombe Drive", "Tamsin Court"]
    static let cityLines: [(city: String, line: String)] = [("Austin", "Austin, TX  78701"), ("Denver", "Denver, Colorado 80205"), ("Boise", "Boise, ID 83702"), ("Halifax", "Halifax, NS B3J 2K9"), ("Raleigh", "Raleigh, NC 27601")]

    private mutating func pick<T>(_ values: [T]) -> T { gen.choose(values) }
    private mutating func n(_ range: ClosedRange<Int>) -> Int { gen.int(range) }
    private mutating func digits(_ count: Int) -> String { gen.string("0123456789", count: count) }
    private mutating func upper(_ count: Int) -> String { gen.string("ABCDEFGHJKLMNPRSTUVWXYZ", count: count) }
    private mutating func alnum(_ count: Int) -> String { gen.string("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789", count: count) }
    private mutating func hex(_ count: Int) -> String { gen.string("0123456789abcdef", count: count) }
    private func two(_ value: Int) -> String { String(format: "%02d", value) }

    mutating func make(_ category: PIIGapCategory) -> PIIGapCase {
        switch category {
        case .birthDates:
            let day = n(1...28), month = n(1...12), year = n(1940...2006)
            let name = Self.months[month - 1]
            let (cue, date): (String, String) = pick([
                ("born on", "\(name) \(day), \(year)"),
                ("born", "\(day) \(name.prefix(3)) \(year)"),
                ("DOB", "\(month)/\(day)/\(String(year).suffix(2))"),
                ("DOB:", "\(two(month))/\(two(day))/\(year)"),
                ("d.o.b.", "\(year)-\(two(month))-\(two(day))"),
                ("date of birth", "\(two(day)).\(two(month)).\(year)"),
                ("born in", "\(name) \(year)"),
                ("birthday is", "\(name) \(day)"),
            ])
            let value = "\(cue) \(date)"
            let prose = pick([
                "The patient was \(value), per the intake form.",
                "Verified caller, \(value).",
                "fyi he was \(value) so the senior discount applies",
                "\(pick(Self.people)) (\(value)) called about the claim.",
                "Applicant \(value), lives alone.",
            ]).replacingOccurrences(of: "was birthday is", with: "said her birthday is")
            return PIIGapCase(category: category, prose: prose, targets: [date], cues: [cue])
        case .labelledIDs:
            let (label, value): (String, String) = pick([
                ("passport number", "\(upper(1))\(digits(7))"),
                ("NI number", "\(upper(2)) \(digits(2)) \(digits(2)) \(digits(2)) \(pick(["A", "B", "C", "D"]))"),
                ("DNI", "\(digits(8))\(upper(1))"),
                ("CPF", "\(digits(3)).\(digits(3)).\(digits(3))-\(digits(2))"),
                ("SIN", "\(digits(3)) \(digits(3)) \(digits(3))"),
                ("employee ID", "EMP-\(digits(6))"),
                ("MRN", digits(8)),
                ("member number", "\(upper(1))\(digits(8))"),
                ("tax ID", "\(digits(2))-\(digits(7))"),
                ("student number", "S\(digits(7))"),
                ("policy number", "POL-\(digits(3))-\(digits(5))"),
                ("driver's license", "\(upper(1))\(digits(3))-\(digits(4))-\(digits(4))"),
            ])
            let prose = pick([
                "My \(label) is \(value).",
                "the customer's \(label): \(value)",
                "Can you check \(label) \(value) for me?",
                "\(label.prefix(1).uppercased() + label.dropFirst()) \(value) was rejected at the desk.",
                "\(pick(Self.people)) gave \(label) \(value) over the phone.",
            ])
            return PIIGapCase(category: category, prose: prose, targets: [value], cues: [String(label.split(separator: " ")[0])])
        case .secretsInProse:
            let password = "\(pick(Self.words))-\(pick(Self.words).capitalized)-\(n(10...99))"
            let pin = digits(6), key = hex(32), token = alnum(40), bearer = alnum(36)
            let license = "\(upper(5))-\(upper(5))-\(upper(5))-\(upper(5))"
            let (prose, secret): (String, String) = pick([
                ("the wifi password is \(password)", password),
                ("my password's \(password) btw", password),
                ("Password: \(password) (change it after first login)", password),
                ("temporary pin is \(pin)", pin),
                ("here's the key \(key)", key),
                ("token \(token) expires Friday", token),
                ("Authorization: Bearer \(bearer)", bearer),
                ("postgres://admin:\(password)@\(pick(Self.hosts)):5432/app", password),
                ("clone from https://deploy:\(password)@\(pick(Self.hosts))/app.git", password),
                ("the license key is \(license)", license),
                ("set CORVANE_API_KEY to qv_\(token.prefix(32)) in prod", "qv_\(token.prefix(32))"),
            ])
            return PIIGapCase(category: category, prose: prose, targets: [secret], cues: [["password", "Password", "pin", "key", "token", "Bearer", "postgres://admin:", "https://deploy:", "CORVANE_API_KEY"].first { prose.contains($0) }!])
        case .poBoxes:
            let box = String(n(10...9999))
            let address = pick([
                "PO Box \(box), Tucson AZ 85701",
                "P.O. Box \(box), Halifax NS B3J 2K9",
                "Post Office Box \(box), Boise, ID 83701",
                "Postfach \(box), 10115 Berlin",
                "PO Box \(box), Dunedin 9054",
            ])
            let prose = pick([
                "Please send the forms to \(address) instead.",
                "Mailing address: \(address)",
                "\(pick(Self.people)) gets post at \(address) now.",
            ])
            return PIIGapCase(category: category, prose: prose, targets: [box], cues: [String(address.prefix { !$0.isNumber })])
        case .birthYears:
            let year = String(n(1930...2004)), other = String(n(1930...2004))
            let (prose, targets): (String, [String]) = pick([
                ("The applicant was born in \(year) and lives in Lyon.", [year]),
                ("The applicants were born in \(year) and \(other) respectively.", [year, other]),
                ("\(pick(Self.people)) (b. \(year)) joined the board last spring.", [year]),
                ("Born in \(year), she moved to Leeds as a child.", [year]),
                ("Her son was born \(year), per the intake notes.", [year]),
            ])
            return PIIGapCase(category: category, prose: prose, targets: targets, cues: [prose.contains("(b.") ? "b." : "born"])
        case .phoneExtensions:
            let digits4 = digits(4), digits5 = digits(5), split = "\(n(2...7))-\(digits(4))"
            let (prose, value, cue): (String, String, String) = pick([
                ("Please call \(pick(Self.people)) at x\(digits5) with any questions.", digits5, "x"),
                ("Regards,\n\(pick(Self.firsts))\next. \(split)", split, "ext."),
                ("Dial (512) 555-0143 extension \(digits4) for the front desk.", digits4, "extension"),
                ("Thanks,\n\(pick(Self.firsts))\nX\(split)", split, "X"),
            ])
            return PIIGapCase(category: category, prose: prose, targets: [value], cues: [cue])
        case .stackedAddresses:
            let number = String(n(10...9999)), street = pick(Self.streets), place = pick(Self.cityLines)
            let unit = pick(["", ", Suite \(n(100...900))", "\nSuite \(n(100...900))", ", EB\(n(1000...4000))"])
            let block = "\(number) \(street)\(unit)\n\(place.line)"
            let prose = pick([
                "Regards,\n\(pick(Self.people))\nTallowmere Holdings\n\(block)\nPhone: (512) 555-0143",
                "Send the signed copy to:\n\(block)\n\nThanks!",
                "\(pick(Self.people))\n\(block)\n\(pick(Self.firsts).lowercased())@corvane.test",
            ])
            let zip = String(place.line.split(separator: " ").suffix(place.line.hasSuffix("2K9") ? 2 : 1).joined(separator: " "))
            return PIIGapCase(category: category, prose: prose, targets: [number, String(street.split(separator: " ")[0]), place.city, zip])
        case .mailHeaders:
            let f1 = pick(Self.firsts), l1 = pick(Self.lasts), f2 = pick(Self.firsts.filter { $0 != f1 }), l2 = pick(Self.lasts.filter { $0 != l1 })
            let office = pick(Self.offices)
            let (prose, cues): (String, [String]) = pick([
                ("To: \(f1) \(l1)\(office), \(f2) \(l2)\(office)\ncc: \nSubject: Storage contracts", ["To:", office, "Subject: Storage contracts"]),
                ("To: \(f1) \(l1)\(office), \(f2) \n\(l2)\(office)\nSubject: Q3 numbers", ["To:", office, "Subject: Q3 numbers"]),
                ("-----Original Message-----\nFrom: \t\(l1), \(f1)\nSent:\tFriday, May 3, 2002 9:12 AM\nTo:\t\(l2), \(f2); Brennan, Rhys\nSubject:\tTiming", ["From:", "Sent:", "Friday, May 3, 2002 9:12 AM", "Subject:\tTiming"]),
                ("From: \t\(l1), \(f1)   On Behalf Of \(l2), \(f2)\nSubject:\tRenewal", ["From:", "On Behalf Of", "Renewal"]),
                ("\(f1) \(l1)\n09/14/2001 08:31 AM\nTo: \(f2) \(l2)\(office)\nSubject: Re: pipeline", ["09/14/2001 08:31 AM", office, "Subject: Re: pipeline"]),
                ("Subject: Inventory Storage\n\(f1) \(l1)\(office), \(f2) \(l2)\(office)", ["Subject: Inventory Storage", office]),
            ])
            let names = [f1, l1, f2, l2] + (prose.contains("Rhys") ? ["Rhys"] : [])
            return PIIGapCase(category: category, prose: prose, targets: names.flatMap { $0.split(separator: "-").map(String.init) }, cues: cues)
        case .titledNames:
            let f = pick(Self.firsts), l = pick(Self.lasts), initials = pick(["E.", "H.S.", "J.", "Z.M."])
            let (prose, title, targets): (String, String, [String]) = pick([
                ("The applicant was represented by Ms \(initials) \(l), a lawyer practising in Leeds.", "Ms", [l]),
                ("Mrs \(l) attended the hearing on 4 May.", "Mrs", [l]),
                ("The court heard Dr \(l)’s evidence on the second day.", "Dr", [l]),
                ("Mr. \(f) \(l) did not attend.", "Mr.", [f, l]),
                ("Counsel: Mr \(initials) \(l.uppercased()) Solicitor, for the applicant.", "Mr", [l.uppercased()]),
            ])
            return PIIGapCase(category: category, prose: prose, targets: targets.flatMap { $0.split(separator: "-").map(String.init) }, cues: [title])
        case .placesInProse:
            let town = pick(Self.towns)
            let (prose, cue): (String, String) = pick([
                ("\(pick(Self.people)) moved to \(town) last spring.", "moved to"),
                ("my sister still lives in \(town), so I visit at Easter", "lives in"),
                ("Her parents run a small shop in \(town).", "run a small shop in"),
                ("He's flying into \(town) on Thursday for the funeral.", "flying into"),
                ("We grew up in \(town) but left after school.", "grew up in"),
            ])
            return PIIGapCase(category: category, prose: prose, targets: [town], cues: [cue])
        case .employersOfPeople:
            let company = pick(Self.companies), first = pick(Self.firsts)
            let (prose, cue): (String, String) = pick([
                ("\(first) works at \(company) as a \(pick(Self.jobs)).", "works at"),
                ("My manager at \(company) signed the reference letter.", "manager at"),
                ("She has been with \(company) for six years now.", "has been with"),
                ("Employer: \(company)", "Employer:"),
                ("He quit \(company) in March and is looking for work.", "quit"),
            ])
            return PIIGapCase(category: category, prose: prose, targets: [String(company.split(separator: " ")[0])], cues: [cue])
        case .nonLatinNames:
            let name = pick(Self.nonLatin)
            let (prose, cue): (String, String) = pick([
                ("\(name) called about the refund on Tuesday.", "called about the refund"),
                ("Spoke with \(name) this morning, she will resend the form.", "Spoke with"),
                ("Ticket opened by \(name), waiting on a reply.", "Ticket opened by"),
                ("Please forward this to \(name) before Friday.", "Please forward this to"),
            ])
            return PIIGapCase(category: category, prose: prose, targets: name.split(separator: " ").map(String.init), cues: [cue])
        case .handlesInProse:
            let handle = pick(Self.firsts).lowercased().folding(options: .diacriticInsensitive, locale: nil) + pick(["_", ".", ""]) + pick(Self.lasts).lowercased().folding(options: .diacriticInsensitive, locale: nil).replacingOccurrences(of: "-", with: "") + String(n(7...99))
            let (prose, cue): (String, String) = pick([
                ("my discord is \(handle) if you want to talk", "my discord is"),
                ("ping \(handle) on slack about the deploy", "on slack"),
                ("dm me on insta: \(handle)", "dm me on insta"),
                ("The review was left by \(handle) last night.", "The review was left by"),
            ])
            return PIIGapCase(category: category, prose: prose, targets: [handle], cues: [cue])
        case .companiesWithoutPeople:
            let company = pick(Self.companies)
            let prose = pick([
                "\(company) delivered the pallets this morning.",
                "Invoice from \(company) attached.",
                "\(company) is closed on bank holidays.",
                "Paid \(company) by bank transfer.",
            ])
            return PIIGapCase(category: category, prose: prose, targets: [])
        case .nonLatinNotNames:
            let prose = pick([
                "The menu lists 天丼 as sold out.",
                "The box is marked Осторожно on two sides.",
                "Subtitle language: 한국어 only.",
                "The shop sign reads 営業中 all night.",
                "The caption said Καλημέρα with a sunrise.",
            ])
            return PIIGapCase(category: category, prose: prose, targets: [])
        case .yearsNotBirths:
            let year = String(n(1900...2024))
            let prose = pick([
                "Corvane was founded in \(year) in a rented garage.",
                "The idea was born in \(year) at a hackathon.",
                "Tallowmere Holdings was born in \(year) out of a merger.",
                "The project was born in \(year), then rewritten twice.",
                "Version 2 shipped in \(year).",
            ])
            return PIIGapCase(category: category, prose: prose, targets: [])
        case .extensionLookAlikes:
            let prose = pick([
                "Set the display to 1920x1080 and restart.",
                "Write 0x4f2a to the control register.",
                "Load the next 2000 rows before sorting.",
                "Order 3 x 4000 pallets for the warehouse.",
                "The box1234 volume is full.",
            ])
            return PIIGapCase(category: category, prose: prose, targets: [])
        case .headersWithoutPeople:
            let prose = pick([
                "To: All Staff\nSubject: Holiday hours",
                "From: Corvane Billing\nSubject: Your invoice",
                "Sent: Monday, March 3, 2025 9:12 AM\nSubject: Weekly report",
                "To: Engineering Team; Support Desk\nSubject: Outage review",
                "To: Undisclosed Recipients\nSubject: Notice",
            ])
            return PIIGapCase(category: category, prose: prose, targets: [])
        case .titlesWithoutPeople:
            let prose = pick([
                "The Elm Dr Apartments open next week.",
                "Mr President, the floor is yours.",
                "Dear Sir or Madam, please find the form attached.",
                "Madam Chair, the motion carries.",
                "Mr Justice presided over the opening session.",
            ])
            return PIIGapCase(category: category, prose: prose, targets: [])
        case .datesNotBirths:
            let day = n(1...28), month = n(1...12), year = n(2015...2027)
            let name = Self.months[month - 1]
            let prose = pick([
                "The invoice is due on \(name) \(day), \(year).",
                "Our office closes on \(name) \(day) for the holiday.",
                "Version 3 shipped in \(name) \(year).",
                "The contract runs from \(month)/\(day)/\(year) to \(month)/\(day)/\(year + 1).",
                "The idea was born in a hackathon in \(name) \(year).",
                "Last backup: \(year)-\(two(month))-\(two(day)).",
            ])
            return PIIGapCase(category: category, prose: prose, targets: [])
        case .labelsWithoutValues:
            let prose = pick([
                "Ask the caller for their passport number before you continue.",
                "The member number is printed on the back of the card.",
                "Enter your employee ID on the first screen.",
                "We never store the full tax ID, only the last four digits.",
                "The MRN field is required for every admission.",
                "Policy numbers start with three letters.",
            ])
            return PIIGapCase(category: category, prose: prose, targets: [])
        case .secretWordsNotSecrets:
            let prose = pick([
                "Reset your password from the settings page.",
                "The password must be at least 12 characters long.",
                "The password is incorrect, please try again.",
                "Key takeaways from the meeting are below.",
                "Press any key to continue.",
                "Your PIN is never stored on our servers.",
                "Bearer tokens expire after an hour.",
                "The key is to keep the steps small.",
                "Pass -P password or --password password to encrypt the entries.",
                "Preferences key: auto-open-ro-root",
                "Keyboard-interactive authentication prompts for a one-time code.",
                "Usage: passwd user_path [new_password | old_password new_password]",
            ])
            return PIIGapCase(category: category, prose: prose, targets: [])
        }
    }
}
