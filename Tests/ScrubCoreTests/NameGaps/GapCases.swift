import Foundation
@testable import ScrubCore

/// One labelled sample: the prose a name sits in, the names a reader would
/// take as people, and the words that look like names but name no one.
struct GapCase {
    let category: GapCategory
    let prose: String
    let names: [String]
    let keep: [String]
    let filename: String
    let data: Data
}

enum GapCategory: String, CaseIterable, Codable {
    case plain, lowercase, signOff, greeting, surnameOnly, diverse, wordNames, fragments, handles, jsonNote, csvRemark
    case wordsNotNames, toolsAndOrgs

    var isKeep: Bool { self == .wordsNotNames || self == .toolsAndOrgs }
    var summary: String {
        switch self {
        case .plain: "Full capitalised names in whole sentences"
        case .lowercase: "Names typed in lowercase, chat style"
        case .signOff: "A first name alone after a sign-off"
        case .greeting: "A name in the opening line of a message"
        case .surnameOnly: "A surname on its own, with or without a title"
        case .diverse: "Names beyond English: diacritics, particles, family-name-first"
        case .wordNames: "Names that are also words or places (Will, April, Austin)"
        case .fragments: "Names in log lines, chat transcripts and cc lists"
        case .handles: "Usernames and handles built from a name"
        case .jsonNote: "Names in free text inside a JSON field"
        case .csvRemark: "Names in free text inside a CSV column"
        case .wordsNotNames: "Name-like words used as plain words (keep)"
        case .toolsAndOrgs: "Tools, languages and companies named like people (keep)"
        }
    }
}

/// Builds cases from its own name lists and sentences. Nothing here is drawn
/// from Scrub's name tables or key hints, so the score measures what the app
/// does with names it was never tuned on as well as ones it was.
struct GapCaseGen {
    var gen: Gen
    init(seed: UInt64) { gen = Gen(seed: seed) }

    static let firsts = ["Maria", "Priya", "Sven", "Ngozi", "Tomasz", "Aisha", "Kenji", "Lucia", "Rafael", "Ingrid", "Oluwaseun", "Mei", "Dmitri", "Fatima", "Hamid", "Elena", "Thabo", "Siobhan", "Mateus", "Yuki", "Anders", "Leilani", "Bogdan", "Camille", "Tariq", "Nadia", "Joaquín", "Saoirse", "Arjun", "Hye-jin", "Kofi", "Zofia", "Emeka", "Beatriz", "Rhys", "Aigerim", "Pedro", "Linnea", "Omar", "Keanu"]
    static let lasts = ["Gonzalez", "Okafor", "Lindqvist", "Nair", "Wójcik", "Tanaka", "Haddad", "Moreau", "Adeyemi", "Kowalczyk", "Rahman", "Fitzgerald", "Petrov", "Hakimi", "Mbeki", "Sørensen", "Castellanos", "Iyer", "Brennan", "Nakamura", "Achterberg", "Kahananui", "Popescu", "Ferreira", "Nurlanovna", "Delacroix", "Osei", "Varga", "Esposito", "Ramaswamy", "Whitfield", "Kuznetsova", "Abubakar", "Lindgren", "Ortega"]
    static let diverseFull = ["Nguyen Thi Lan", "Zhou Xiaoming", "Siddharth Venkataraman", "Oluwaseun Adeyemi", "Bjørn Søreide", "Łukasz Wójcik", "Ana María de la Cruz", "Pieter van der Berg", "Mohammed bin Rashid Al-Amin", "Aigerim Nurlanovna", "Kalani Kahananui", "Mateus Araújo", "Ngozi Okonkwo", "Eszter Szabó", "Tanvir Rahman", "Søren Kierulf", "Thandiwe Dlamini", "Juan Pablo Ibáñez", "Park Ji-woo", "Ahmet Yılmaz", "Ólafur Sigurðsson", "Chiamaka Eze", "Dương Văn Minh", "Rania El-Sayed"]
    /// Words that are also names, each with a sentence using it as a name and one using it as a word.
    static let wordNames: [(name: String, asName: String, asWord: String)] = [
        ("Will", "Will approved the refund this morning", "we will approve the refund this morning"),
        ("April", "ask April whether the invoice went out", "the invoice went out in April"),
        ("Grace", "Grace said the account is locked", "the grace period ends Friday"),
        ("Mark", "Mark is handling the escalation", "mark the escalation as handled"),
        ("Hope", "Hope called back about the charge", "hope the charge clears soon"),
        ("Bill", "Bill disputed the late fee", "the bill includes a late fee"),
        ("Rose", "Rose updated her shipping address", "the price rose after the update"),
        ("June", "June wants a copy of the contract", "the contract renews in June"),
        ("Austin", "Austin reset his password twice", "the Austin office reset the router"),
        ("Jordan", "Jordan is waiting on the replacement card", "shipping to Jordan takes a week"),
        ("Sunny", "Sunny opened a ticket about the outage", "it was sunny during the outage"),
        ("Chase", "Chase signed the renewal form", "please chase the renewal form"),
        ("Hunter", "Hunter asked for an itemised receipt", "the bounty hunter asked for a receipt"),
        ("Faith", "Faith confirmed her date of birth", "we have faith the fix holds"),
        ("Dawn", "Dawn left a voicemail for billing", "the job runs at dawn every day"),
        ("Victoria", "Victoria needs the refund before Friday", "the Victoria warehouse ships Friday"),
        ("Florence", "Florence never received the parcel", "the parcel went through Florence"),
        ("Summer", "Summer wants to cancel the plan", "the plan is cheaper in summer"),
    ]
    static let toolsAndOrgs: [(word: String, sentence: String)] = [
        ("Jenkins", "The Jenkins build failed on the release branch"),
        ("Julia", "We rewrote the solver in Julia last year"),
        ("Ada", "The flight software is written in Ada"),
        ("Ruby", "Upgrade Ruby before the next deploy"),
        ("Alexa", "Ask Alexa to turn off the office lights"),
        ("Siri", "Siri misheard the street name again"),
        ("Hartigan Vosk Securities", "The wire came from Hartigan Vosk Securities"),
        ("Merriwether Bank", "Merriwether Bank flagged the transfer"),
        ("Abernett & Abernett", "The order ships to Abernett & Abernett"),
        ("Pellworth Foundation", "The grant was funded by the Pellworth Foundation"),
        ("Dependabot", "Dependabot opened twelve pull requests overnight"),
        ("Corliss", "Corliss Bay Logistics delivers on Tuesdays"),
        ("Grafana", "The Grafana panel shows the latency spike"),
        ("Cassandra", "The Cassandra cluster lost a node"),
        ("Maven", "Maven could not resolve the dependency"),
        ("Darwin", "The kernel reports Darwin 25.6.0"),
    ]

    mutating func first() -> String { gen.choose(Self.firsts) }
    mutating func last() -> String { gen.choose(Self.lasts) }

    mutating func make(_ category: GapCategory) -> GapCase {
        let (prose, names, keep) = text(category)
        switch category {
        case .jsonNote:
            let key = gen.choose(["message", "body", "text", "comment", "content", "summary"])
            let object: [String: Any] = ["id": gen.int(1000...99999), "status": gen.choose(["open", "pending", "closed"]), key: prose]
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return GapCase(category: category, prose: prose, names: names, keep: keep, filename: "ticket.json", data: data)
        case .csvRemark:
            let quoted = "\"" + prose.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let csv = "id,created,status,remarks\n\(gen.int(1000...99999)),2026-0\(gen.int(1...9))-1\(gen.int(0...9)),open,\(quoted)\n"
            return GapCase(category: category, prose: prose, names: names, keep: keep, filename: "tickets.csv", data: Data(csv.utf8))
        default:
            return GapCase(category: category, prose: prose, names: names, keep: keep, filename: "note.txt", data: Data(prose.utf8))
        }
    }

    private mutating func text(_ category: GapCategory) -> (String, [String], [String]) {
        let f = first(), l = last()
        let other = gen.choose(Self.firsts.filter { $0 != f })
        switch category {
        case .plain:
            let full = "\(f) \(l)"
            return (gen.choose([
                "\(full) called about a duplicate charge on her account.",
                "Per the attached notes, \(full) requested a refund on March 3.",
                "The courier left the parcel with \(full) at the front desk.",
                "Escalated by \(full) after the second failed delivery.",
            ]), [f, l], [])
        case .lowercase:
            let lf = f.lowercased(), ll = l.lowercased()
            return gen.choose([
                ("spoke w \(lf) earlier, she says the card was charged twice", [lf], []),
                ("can you ask \(lf) \(ll) to resend the form", [lf, ll], []),
                ("\(lf) said the replacement never arrived", [lf], []),
                ("fyi \(lf) \(ll) is out until monday so loop in finance", [lf, ll], []),
                ("just got off the phone with \(lf), all sorted", [lf], []),
            ])
        case .signOff:
            return (gen.choose([
                "Let me know if you need anything else.\n\nThanks,\n\(f)",
                "I've attached the receipt.\n\nBest,\n\(f)\n",
                "See you Thursday.\n\nCheers,\n— \(f)",
                "That should cover it.\n\nKind regards,\n\(f) \(l)\nAccounts Payable",
            ]), [f], [])
        case .greeting:
            return gen.choose([
                ("Hi \(f),\n\nYour replacement card has shipped.", [f], []),
                ("Hey \(f.lowercased()), quick one: did the refund land?", [f.lowercased()], []),
                ("Dear \(f) \(l),\n\nWe received your request.", [f, l], []),
                ("Morning \(f) - the invoice is attached.", [f], []),
            ])
        case .surnameOnly:
            return gen.choose([
                ("\(l) confirmed the shipping address by phone.", [l], []),
                ("Dr. \(l) signed off on the discharge summary.", [l], []),
                ("Forwarding to Ms. \(l) for approval.", [l], []),
                ("As \(l) pointed out, the totals don't match.", [l], []),
            ])
        case .diverse:
            let full = gen.choose(Self.diverseFull)
            let words = full.split(separator: " ").map(String.init).filter { $0.first?.isUppercase == true }
            return (gen.choose([
                "\(full) asked us to update the billing address.",
                "Refund approved for \(full) after review.",
                "Spoke with \(full) about the missing parcel.",
            ]), words, [])
        case .wordNames:
            let pick = gen.choose(Self.wordNames)
            return (pick.asName.prefix(1).uppercased() + pick.asName.dropFirst() + ".", [pick.name], [])
        case .wordsNotNames:
            let pick = gen.choose(Self.wordNames)
            let sentence = pick.asWord.prefix(1).uppercased() + pick.asWord.dropFirst() + "."
            let word = sentence.range(of: pick.name) != nil ? pick.name : pick.name.lowercased()
            return (sentence, [], [word])
        case .toolsAndOrgs:
            let pick = gen.choose(Self.toolsAndOrgs)
            return (pick.sentence + ".", [], [pick.word])
        case .fragments:
            let lf = f.lowercased()
            return gen.choose([
                ("[09:14] \(lf): can someone check the refund queue\n[09:15] ops-bot: queue is empty", [lf], []),
                ("2026-09-30T10:42:07Z INFO assigned ticket 4821 to \(f) \(l)", [f, l], []),
                ("cc: \(f), \(other)", [f, other], []),
                ("TODO(\(lf)): drop the retry once the vendor fixes timeouts", [lf], []),
                ("\(f) \(l) <> support | re: order 77120", [f, l], []),
            ])
        case .handles:
            let lf = f.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            let ll = l.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            let handle = gen.choose(["\(lf).\(ll)", "\(lf)_\(ll)", "\(lf.prefix(1))\(ll)", "\(lf)\(ll.prefix(1))"])
            return gen.choose([
                ("ping @\(handle) in the billing channel", [handle], []),
                ("git blame says \(handle) changed the rate limit", [handle], []),
                ("Reassigned from \(handle) to the on-call queue.", [handle], []),
            ])
        case .jsonNote, .csvRemark:
            return gen.choose([
                ("Customer \(f) \(l) says the parcel never arrived.", [f, l], []),
                ("Called \(f) back, refund approved.", [f], []),
                ("\(f) wants the invoice resent to her work address.", [f], []),
                ("per \(l), waive the late fee", [l], []),
            ])
        }
    }
}
