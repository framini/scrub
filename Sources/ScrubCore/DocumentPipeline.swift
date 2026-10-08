import Foundation
import Synchronization

struct DocumentLeaf: Sendable {
    let text: String
    let key: String?
    private let records: RecordPath
    var lastRecord: Int? { records.last }
    /// The records this value sits in, innermost first.
    var enclosing: [Int] { records.all.reversed() }
    let contextWords: Set<String>
    /// The words that may name an identifier it holds: its own key's, and where that key is
    /// only a slot ("number", "value") those of the keys around it and of its record's kind
    /// field ("type": "CPR"). Nil where every context word may. They say nothing about whose record it is.
    var namingWords: Set<String>?
    /// The words naming it: those above where a reader gave them, else its key's.
    var naming: Set<String> { namingWords ?? Set(KeyHints.words(rawKey ?? key)) }
    /// The identifier its field holds, decided across every value the field writes (see
    /// `JSONDocument.Collector`): empty when decided none, nil where no reader decided.
    var column: String?
    /// The identifier its field holds, where one was decided.
    var decided: String? { column.flatMap { $0.isEmpty ? nil : $0 } }
    let numericEntity: String?
    /// A column header or similar label: read for patterns only, since the name
    /// model takes words like "Dob" for places.
    let fieldName: Bool
    /// The key of a value no hint covers ("country", "gender", "timezone"),
    /// kept because it tells what the personal values beside it should fit.
    let rawKey: String?
    /// The text as a reader sees it, when hidden characters or in-word markup
    /// make it differ from the text as written (see `Visible`). Detection reads this.
    let view: Visible?
    var seen: String { view?.clean ?? text }
    /// The object a flattened header names within its record ("applicant" of
    /// "applicant.first_name"), or a flat key's person ("applicant" of
    /// "applicant_email" beside "spouse_name", see `DocumentPipeline.byPerson`).
    var objectPath: String
    /// The key of an address field whose value has no number ("line1": "the
    /// old rectory, church lane"), which `key` leaves out (see `KeyHints.numberlessLine`).
    let addressKey: String?
    /// The part of a birth date the value is, when its key names one ("birth_month", "dob": {"day": …}).
    let datePart: KeyHints.DatePart?
    /// Whether the value's key says it holds no one's data: a status, an amount, a time, a code,
    /// or a secret's key over a value that is none (an object's reference, a placeholder).
    /// A secret's bytes found in one are the field's own, never the secret written again.
    let nonPersonal: Bool
    /// The field the value is one of across its document: its keys from the root, a list's
    /// items one field ("people.aka"). Nil outside a document's structure.
    var field: String?
    /// A bare "name" written as a person's though nothing says it is one (see
    /// `KeyHints.writtenAsName`): unless detection finds the person, it is doubted.
    var unsureName = false
    /// One written only of names under a business's or an account's key ("account": {"name": …}):
    /// never replaced on the name model's word, but never kept unseen either.
    var doubtedName = false
    /// A key, an element's or attribute's name or a column's header, not a value: renamed only for a name
    /// read in it, or for being whole a person a field's key named (see `DocumentPipeline.keyIsName`), never
    /// because a name only guessed elsewhere is spelled the same ("garante" beside "Garante Verdi").
    var isKey = false
    /// A value written as a code in capitals joined by underscores ("NO_MATCH", "KEIN_TREFFER") under a key that
    /// names no one: a status or an enum, which no name, read in it or elsewhere, rewrites (see `DocumentPipeline.namesCode`).
    var isCode: Bool {
        !["PERSON", "FIRST_NAME", "LAST_NAME"].contains(KeyHints.hint(key) ?? "") && text.contains("_") && text.utf16.count <= 64
            && !TextRanges.matches(Self.code, in: text).isEmpty
    }
    private static let code = TextPattern(#"^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+$"#)
    /// How the span tagger reads the value once the rules are done; nil where it never does (keys, headers).
    var reading: TaggerReading?
    private static let nonPersonalWords: Set<String> = ["status", "state", "type", "kind", "result", "outcome", "decision", "amount", "currency", "total", "balance", "fee",
                                                        "price", "count", "quantity", "at", "time", "timestamp", "date", "created", "updated", "version", "method", "code", "level", "score", "reason", "category", "channel", "mode"]

    init(_ text: String, key: String? = nil, records: [Int] = [], contextWords: Set<String> = [], numericEntity: String? = nil, fieldName: Bool = false, objectPath: String = "") {
        self.objectPath = objectPath
        self.text = text
        // A note written after the value ("128 -- gate code on file") says nothing of what the value is.
        let judged = numericEntity == nil ? KeyHints.judged(key, text) : text
        self.key = numericEntity != nil || KeyHints.fits(key, judged) ? key : nil
        addressKey = self.key == nil && numericEntity == nil && (KeyHints.numberlessLine(key, judged) || KeyHints.regionCode(key, judged)) ? key : nil
        self.rawKey = KeyHints.hint(key) == nil ? key : nil
        datePart = rawKey == nil ? KeyHints.datePart(self.key) : nil
        self.records = RecordPath(records)
        self.contextWords = contextWords
        self.numericEntity = numericEntity
        self.fieldName = fieldName
        view = numericEntity == nil ? Visible(text) : nil
        nonPersonal = Self.holdsNoOnesData(key)
            || KeyHints.hint(key) == "SECRET" && numericEntity == nil && !KeyHints.fits(key, text)
    }
    /// Whether the value is a private network's address under a network's machines
    /// ("nodes": [{"ip": "10.0.3.17"}], "subnet", "gateway"): a machine's, no one's.
    var machineAddress: Bool {
        !contextWords.isDisjoint(with: Patterns.infrastructureWords) && Patterns.privateAddress(text.trimmingCharacters(in: .whitespaces))
    }
    /// Whether `key` says its value is a status, an amount, a time, a code or the like.
    static func holdsNoOnesData(_ key: String?) -> Bool {
        KeyHints.hint(key) == nil && KeyHints.words(key).last.map(nonPersonalWords.contains) == true
    }
}

private enum RecordPath: Sendable {
    case none
    case one(Int)
    case many([Int])

    init(_ records: [Int]) {
        switch records.count {
        case 0: self = .none
        case 1: self = .one(records[0])
        default: self = .many(records)
        }
    }
    var all: [Int] {
        switch self {
        case .none: []
        case .one(let record): [record]
        case .many(let records): records
        }
    }
    var last: Int? {
        switch self {
        case .none: nil
        case .one(let record): record
        case .many(let records): records.last
        }
    }
}

struct DocumentValue {
    let text: String
    private let storedMarks: [Mark]
    private let full: Mark?
    /// What the final check left as written and asks about: the original's
    /// range in `text`, and with `proposals`, the stand-in each would take.
    let unresolved: [Mark]
    let proposals: [String]
    /// People only a model read and doubted, left as written (`Doubt.unconfirmed`):
    /// carried through every round, and joined to `unresolved` at the end.
    let held: [Mark]

    init(text: String, marks: [Mark], unresolved: [Mark], proposals: [String] = [], held: [Mark] = []) {
        self.text = text
        self.unresolved = unresolved
        self.proposals = proposals
        self.held = held
        if marks.count == 1, marks[0].range == 0..<(text as NSString).length {
            storedMarks = []
            full = marks[0]
        } else {
            storedMarks = marks
            full = nil
        }
    }
    var marks: [Mark] {
        if let full { return [full] }
        return storedMarks
    }
    var fullyMarked: Bool { full != nil }
}

enum DocumentPipeline {
    private struct IdentityFields {
        var first: String?
        var last: String?
        var full: String?
        var email: String?
        var gender: String?
        /// Two full names with no word in common: a row's "applicant_name" and
        /// "guarantor_name" are two people, so the record is no one person's.
        /// A middle name, a display name or a nickname beside a name is still one.
        var several = false
        /// The script a name's first letter is written in: Latin 0, or the start of another's block.
        static func script(_ name: String) -> UInt32 {
            guard let letter = name.unicodeScalars.first(where: \.properties.isAlphabetic) else { return 0 }
            switch letter.value {
            case ..<0x0250: return 0
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return 0x3040
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return 0x4E00
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return 0xAC00
            default: return letter.value & ~0x7F
            }
        }
        mutating func set(_ value: String, for hint: String) {
            switch hint {
            case "FIRST_NAME": first = value
            case "LAST_NAME": last = value
            case "PERSON":
                func words(_ name: String) -> Set<String> { Set(name.lowercased().split { !$0.isLetter }.map(String.init)) }
                // One name written in two scripts ("佐藤 美咲" and "SATO MISAKI") is one person, known by the Latin one.
                if let full, Self.script(full) != Self.script(value) {
                    if Self.script(full) != 0 && Self.script(value) == 0 { self.full = value }
                    return
                }
                if let full, words(full).count >= 2, words(value).count >= 2, words(full).isDisjoint(with: words(value)) { several = true }
                full = value
            case "EMAIL_ADDRESS": email = value
            default: break
            }
        }
    }
    // The name model tags some first names as places ("Best, Kevin").
    private static let nameEntities: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME", "LOCATION"]
    private static let identityHints: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME", "EMAIL_ADDRESS", "USERNAME", "INITIALS"]
    private static let genderWords: Set<String> = ["gender", "sex", "title", "honorific", "salutation", "prefix", "pronouns", "pronoun"]
    static func isTimeZone(_ leaf: DocumentLeaf) -> Bool {
        let words = KeyHints.words(leaf.rawKey)
        guard words.last == "timezone" || words.last == "tz" || words.suffix(2) == ["time", "zone"] else { return false }
        return leaf.text.contains("/") && TimeZone(identifier: leaf.text) != nil
    }

    static func run(_ given: [DocumentLeaf], job: Job, forceFullDetection: Bool = false, progress: (Stage, Int, Int) -> Void = { _, _, _ in }) throws -> [DocumentValue] {
        let leaves = byPerson(given)
        let merchants = merchantLeaves(leaves)
        var (gazetteer, values, emptyBases) = try detectAndPrepare(leaves, job: job, progress: progress)
        try Scrubber.checkCancellation()
        var active = Array(repeating: true, count: values.count)
        var originals = OriginalMatcher(job)
        // What every value's stand-ins replaced, for the leak gate to find written another way.
        var gate = LeakGate(values)
        try Scrubber.checkCancellation()
        for _ in 0..<3 {
            let beforeReplacements = job.replacements.count
            var changedIndices: [Int] = []
            var changed = false
            for index in values.indices where active[index] {
                try Scrubber.checkCancellation()
                let previous = values[index]
                // A zone was decided whole: a city found elsewhere is no city inside "Europe/Prague".
                if previous.fullyMarked || isTimeZone(leaves[index]) { continue }
                let reusable = !forceFullDetection && emptyBases[index] && previous.text == leaves[index].text
                job.enter(value: index, records: leaves[index].enclosing, part: leaves[index].datePart, object: leaves[index].objectPath, naming: leaves[index].naming, kind: leaves[index].decided)
                var held = previous.held
                let (text, marks, unresolved) = try Correction.run(previous.text, marks: previous.marks, job: job, matcher: originals, gazetteer: gazetteer, gate: gate, passes: 1, base: reusable ? [] : nil, held: &held,
                                                                   sparing: Set(leaves[index].nonPersonal ? ["SECRET"] : []).union(leaves[index].machineAddress ? ["IP_ADDRESS"] : [])
                                                                    .union(merchants.contains(index) ? merchantKinds : []).union(leaves[index].isKey && !keyIsName(leaves[index], job: job) || leaves[index].isCode && !namesCode(leaves[index], job: job) ? nameEntities : []))
                if text != previous.text { changed = true; changedIndices.append(index) }
                values[index] = DocumentValue(text: text, marks: marks, unresolved: unresolved, held: held)
            }
            if !changed { break }
            let newReplacements = job.replacements[beforeReplacements...]
            originals.add(newReplacements)
            gate.add(newReplacements)
            if forceFullDetection { continue }
            active = Array(repeating: false, count: values.count)
            for index in changedIndices { active[index] = true }
            let newOriginals = newReplacements.map(\.original).filter { !$0.isEmpty }
            if !newOriginals.isEmpty {
                let newMatcher = Matcher(newOriginals, isCancelled: { Task.isCancelled })
                // A value read before these were found may hold them written another way.
                var newGate = LeakGate()
                newGate.add(newReplacements)
                for index in values.indices where !active[index] {
                    if index.isMultiple(of: 1024) { try Scrubber.checkCancellation() }
                    let value = values[index]
                    guard !value.marks.contains(where: { $0.range == 0..<(value.text as NSString).length }) else { continue }
                    if !newMatcher.matches(in: value.text).isEmpty || !newGate.isEmpty && newGate.hits(value.text) { active[index] = true }
                }
            }
        }
        // The span tagger's suspects join what review asks about; nothing it reads is replaced.
        if let tagger = Escalation.tagger {
            for (index, suspects) in try Escalation.suspects(leaves, values, tagger: tagger) {
                let value = values[index]
                values[index] = DocumentValue(text: value.text, marks: value.marks, unresolved: value.unresolved + suspects, proposals: value.proposals, held: value.held)
            }
        }
        // What is left as written gets the stand-in it would take, drawn in
        // document order once the rounds are done, so review can offer it.
        for index in values.indices where !values[index].unresolved.isEmpty || !values[index].held.isEmpty {
            try Scrubber.checkCancellation()
            let value = values[index]
            job.enter(value: index, records: leaves[index].enclosing, part: leaves[index].datePart, object: leaves[index].objectPath, naming: leaves[index].naming, kind: leaves[index].decided)
            var kept: [Mark] = [], proposals: [String] = []
            // A doubted person the final check also suspects is its suspect.
            var suspected = IndexSet()
            for mark in value.unresolved where !mark.range.isEmpty { suspected.insert(integersIn: mark.range) }
            let doubted = value.held.filter { !$0.range.isEmpty && !suspected.intersects(integersIn: $0.range) }
            for mark in (value.unresolved + doubted).sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                guard let original = mark.original, let fake = job.proposal(for: mark.entity, original: original) else { continue }
                kept.append(mark)
                proposals.append(fake)
            }
            values[index] = DocumentValue(text: value.text, marks: value.marks, unresolved: kept, proposals: proposals)
        }
        // Detectors and matchers stop early once cancelled and hand back what
        // they found so far; a scrub cut short that way throws, never returns.
        try Scrubber.checkCancellation()
        return values
    }
    private static func detectAndPrepare(_ leaves: [DocumentLeaf], job: Job, progress: (Stage, Int, Int) -> Void) throws -> (GazetteerMatcher, [DocumentValue], [Bool]) {
        let (bases, keyed, doubts) = try detectBases(leaves, progress: progress)
        let prepared = try prepare(leaves, bases: keyed, doubts: doubts, job: job)
        return (prepared.0, prepared.1, bases.map { $0?.isEmpty == true })
    }

    /// `bases`: each value's spans in the text as seen (`DocumentLeaf.seen`), its key's where detection left it to the key.
    private static func prepare(_ leaves: [DocumentLeaf], bases: [[Span]], doubts: [[Span]], job: Job) throws -> (GazetteerMatcher, [DocumentValue]) {
        var addresses = associateAddresses(leaves)
        try Scrubber.checkCancellation()
        // A value that writes its record's address out on one line is that address whole, read before anything is learned from it.
        var bases = bases
        for (index, parts) in writtenOut(leaves, addresses) {
            bases[index] = [Span(range: 0..<(leaves[index].seen as NSString).length, entity: "ADDRESS", score: 1)]
            addresses[index] = parts
        }
        job.reserveNames(zip(leaves, bases).flatMap { leaf, base in
            base.compactMap { span -> String? in
                if nameEntities.contains(span.entity) { return TextRanges.substring(leaf.seen, span.range) }
                // A name in an email's local part ("mateo.nguyen@") is someone's: no stand-in reuses it.
                // Ordinary words ("info", "the", "sales") name no one, and would block half the names to draw from.
                guard span.entity == "EMAIL_ADDRESS" else { return nil }
                let words = TextRanges.substring(leaf.seen, span.range).prefix { $0 != "@" }.split(whereSeparator: { !$0.isLetter }).map(String.init)
                let names = words.filter { $0.count >= 3 && !NameLists.isOrdinary($0.lowercased()) }
                return names.isEmpty ? nil : names.joined(separator: " ")
            }
        })
        for leaf in leaves {
            if let entity = leaf.numericEntity { job.reserveNumeric(leaf.text, entity: entity) }
        }
        try Scrubber.checkCancellation()
        // These steps stop early when cancelled; the check after each one throws
        // before anything partial is used.
        let owners = associateOwners(leaves, job: job)
        try Scrubber.checkCancellation()
        observeInitial(leaves, bases: bases, job: job)
        try Scrubber.checkCancellation()
        let gazetteer = GazetteerMatcher(job.gazetteer, nameParts: job.nameParts, cuedParts: job.cuedParts, isCancelled: { Task.isCancelled })
        try Scrubber.checkCancellation()
        job.setReplacementRecording(false)
        defer { job.setReplacementRecording(true) }
        var values = [DocumentValue?](repeating: nil, count: leaves.count)
        // What a record's identifier may spell out: the names, email local parts and phone numbers found.
        let spelled = RecordIDs.Known(job.gazetteer)
        // Objects that hold a person's name or email themselves, or say they are a
        // person ("resourceType": "Patient"), whose "id" is that person's. A flattened
        // header's path counts as its object: "applicant.name" is not "id"'s.
        func object(_ leaf: DocumentLeaf) -> String? {
            guard let record = leaf.lastRecord else { return nil }
            return "\(record)\u{0}" + leaf.objectPath
        }
        let people: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME", "EMAIL_ADDRESS"]
        // Keys repeat in every record: what each says is read once.
        var hints: [String: String] = [:], typeKeys: [String: Bool] = [:], naming: [String: Bool] = [:]
        func hint(_ key: String?) -> String? {
            guard let key else { return nil }
            if let known = hints[key] { return known.isEmpty ? nil : known }
            let found = KeyHints.hint(key)
            hints[key] = found ?? ""
            return found
        }
        func typeKey(_ key: String?) -> Bool {
            guard let key else { return false }
            if let known = typeKeys[key] { return known }
            let found = RecordIDs.typeKeys.contains(KeyHints.words(key).joined())
            typeKeys[key] = found
            return found
        }
        func mayName(_ key: String?) -> Bool {
            guard let key else { return false }
            if let known = naming[key] { return known }
            let found = RecordIDs.keyMayName(key)
            naming[key] = found
            return found
        }
        var personal: Set<String> = []
        for (index, leaf) in leaves.enumerated() {
            if index.isMultiple(of: 1024) { try Scrubber.checkCancellation() }
            // A record's own person, not one it names in a role ("receiver_name", "emboss_name", "aka"): a transfer is no one's record.
            if people.contains(hint(leaf.key) ?? "") && !KeyHints.namesARole(leaf.key) || typeKey(leaf.rawKey) && RecordIDs.namesPersonType(key: leaf.rawKey, value: leaf.text), let object = object(leaf) { personal.insert(object) }
        }
        // An age, last four digits or a birth date's month or day is read off the stand-ins it belongs with, so those come first.
        let later = { (index: Int) in StandIns.derived.contains(leaves[index].numericEntity ?? KeyHints.hint(leaves[index].key) ?? "") || KeyHints.hint(leaves[index].key) != nil && StandIns.isMasked(leaves[index].text)
            || leaves[index].datePart.map { $0 != .year } == true }
        // A machine-readable zone writes a name, a number and a birth date drawn elsewhere: it comes last.
        var order: [Int] = [], derived: [Int] = [], zones: [Int] = []
        for index in leaves.indices {
            if index.isMultiple(of: 1024) { try Scrubber.checkCancellation() }
            if hint(leaves[index].key) == "MRZ" { zones.append(index) } else if later(index) { derived.append(index) } else { order.append(index) }
        }
        order += derived + zones.filter { MachineZone.opensCard(leaves[$0].text) } + zones.filter { !MachineZone.opensCard(leaves[$0].text) }
        // What each value holds, read first for all of them: a field then decides
        // across its values (see `Fields`) before any is replaced.
        var founds = [[Span]](repeating: [], count: leaves.count)
        // A unit's key alone says no address: its record, or one inside it, must hold one, or the value is a quantity ("units": "120").
        var addressed: Set<Int> = []
        for leaf in leaves where !KeyHints.bareUnitKey(leaf.key) {
            let part = ["ADDRESS", "LOCATION", "POSTAL_CODE"].contains(hint(leaf.key ?? leaf.addressKey) ?? "")
            if part || KeyHints.words(leaf.objectPath).contains(where: { $0 == "address" || $0 == "addr" }) { addressed.formUnion(leaf.enclosing) }
        }
        for index in order {
            try Scrubber.checkCancellation()
            let leaf = leaves[index]
            var found = detected(leaf, base: bases[index], gazetteer: gazetteer, detector: job.detector, job: job)
            if found.isEmpty, leaf.numericEntity == nil, hint(leaf.key) == nil, mayName(leaf.rawKey ?? leaf.key), RecordIDs.isPersonal(leaf, spelled: spelled, ownRecord: object(leaf).map(personal.contains) ?? false) {
                found = [Span(range: 0..<(leaf.seen as NSString).length, entity: "RECORD_ID", score: 1)]
            } else if leaf.numericEntity == nil, !leaf.fieldName, hint(leaf.key) == nil, case let ids = RecordIDs.spelled(in: leaf.seen, known: spelled), !ids.isEmpty {
                // An ID in running text that spells someone out ("cus_odalys_ferriter") is theirs too.
                found = Detector.resolve(found + ids)
            }
            // An address field with no number, beside address parts that are replaced, is
            // the rest of that address: it never stays as written while they change.
            if leaf.addressKey != nil, let address = addresses[index], address.city != nil || address.postal != nil || address.region != nil,
               !found.contains(where: { $0.entity == "ADDRESS" && $0.range.count * 2 >= (leaf.seen as NSString).length }) {
                found = [Span(range: 0..<(leaf.seen as NSString).length, entity: KeyHints.hint(leaf.addressKey) == "REGION" ? "REGION" : "ADDRESS", score: 1)]
            }
            if KeyHints.bareUnitKey(leaf.key), !(leaf.lastRecord.map(addressed.contains) ?? false) { found.removeAll { $0.entity == "ADDRESS" } }
            founds[index] = found
        }
        Fields.decide(leaves, &founds)
        for index in merchantLeaves(leaves) { founds[index].removeAll { merchantKinds.contains($0.entity) } }
        if placesStandAlone(leaves, founds, doubts) {
            for index in founds.indices {
                guard standsAsPlace(leaves[index]) else { continue }
                let whole = leaves[index].seen.trimmingCharacters(in: .whitespaces)
                founds[index].removeAll { placeKinds.contains($0.entity) && TextRanges.substring(leaves[index].seen, $0.range) == whole && namesAPlace(whole) }
            }
        }
        for index in order {
            try Scrubber.checkCancellation()
            let leaf = leaves[index]
            job.enter(value: index, records: leaf.enclosing, part: leaf.datePart, object: leaf.objectPath, naming: leaf.naming, kind: leaf.decided)
            var found = founds[index]
            if leaf.machineAddress { found.removeAll { $0.entity == "IP_ADDRESS" } }
            // So is one after a machine's key in a log's pairs ("node=10.0.4.17", "gateway: 192.168.1.1").
            else if leaf.key == nil { found.removeAll { $0.entity == "IP_ADDRESS" && Self.machineAddress($0.range, in: leaf.seen) } }
            job.recordOriginals([(leaf.seen, found)])
            // Read in the text as seen, replaced in the text as written.
            if let view = leaf.view { found = found.map(view.raw) }
            let owner = identityHints.contains(KeyHints.hint(leaf.key) ?? "") || KeyHints.hint(leaf.key) == "MRZ" ? owners.of(leaf) : nil
            var (text, marks): (String, [Mark])
            var held: [Mark] = []
            if let entity = leaf.numericEntity {
                text = job.numericLexeme(leaf.text, entity: entity, address: addresses[index])
                marks = [job.lastUnclear ? Mark(range: 0..<(text as NSString).length, entity: entity, original: leaf.text, confidence: Doubt.unclearOwner.confidence, doubt: .unclearOwner)
                         : Mark(range: 0..<(text as NSString).length, entity: entity, original: leaf.text, confidence: 1)]
            } else if isTimeZone(leaf) {
                // A zone is one name, "Europe/Berlin": never a city or a person read inside it. It follows
                // the stand-in place of an address beside it, and stays as written beside none.
                if let address = addresses[index] {
                    text = job.replacement(for: "TIME_ZONE", original: leaf.text, persona: nil, address: address)
                    marks = [Mark(range: 0..<(text as NSString).length, entity: "TIME_ZONE", original: leaf.text, confidence: 1)]
                } else { (text, marks) = (leaf.text, []) }
            } else {
                held = doubts.indices.contains(index) ? doubts[index].map { doubt in
                    Mark(range: leaf.view?.raw(doubt.range) ?? doubt.range, entity: doubt.entity, original: TextRanges.substring(leaf.seen, doubt.range), confidence: min(doubt.score, Doubt.unconfirmed.confidence), doubt: .unconfirmed)
                } : []
                (text, marks) = try job.apply(leaf.text, spans: found, owner: owner, address: addresses[index], held: &held)
            }
            // An age with no birth date to follow stays as it was.
            if text == leaf.text, marks.count == 1, StandIns.derived.contains(marks[0].entity) || marks[0].entity == "TIME_ZONE" { marks = [] }
            values[index] = DocumentValue(text: text, marks: marks, unresolved: [], held: held)
        }
        return (gazetteer, values.map { $0! })
    }

    /// Whether the address at `range` is a private network's after a machine's key ("node=", "edge_ip=").
    static func machineAddress(_ range: Range<Int>, in text: String) -> Bool {
        let ns = text as NSString
        guard Patterns.privateAddress(TextRanges.substring(text, range)), let key = Patterns.keyBefore(ns, range.lowerBound) else { return false }
        return !Set(KeyHints.words(key)).isDisjoint(with: Patterns.infrastructureWords)
    }
    private static let merchantKinds: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME", "ADDRESS", "LOCATION"]
    /// A card payment's description as a bank writes it: the shop's name, its store's number and its town ("FENWICK GROCERS 1043 AMSTERDAM").
    private static let storeLine = TextPattern(#"^([A-Za-z][A-Za-z'&.\- ]*?[A-Za-z.]) +#?\d{2,6} +([A-Za-z][A-Za-z'\- ]*[A-Za-z])$"#)
    private static let transactionWords: Set<String> = ["transaction", "transactions", "txn", "txns", "payment", "payments", "purchase", "purchases", "merchant", "card", "statement", "entries", "entry"]
    /// The values of a transaction that name its merchant: a description written as a shop's name, its store's number and a town
    /// Scrub knows, and a value of the same transaction that writes that name alone ("counterparty": "Fenwick Grocers").
    /// A transfer to a person names them with no store's number, so it is read as any value is.
    static func merchantLeaves(_ leaves: [DocumentLeaf]) -> Set<Int> {
        var found: Set<Int> = [], names: [Int: Set<String>] = [:]
        for (index, leaf) in leaves.enumerated() {
            guard let record = leaf.lastRecord, let field = leaf.field, leaf.key == nil || KeyHints.hint(leaf.key) == nil,
                  !Set(field.split(separator: ".").flatMap { KeyHints.words(String($0)) }).isDisjoint(with: transactionWords),
                  let match = TextRanges.matches(storeLine, in: leaf.text.trimmingCharacters(in: .whitespaces)).first else { continue }
            let text = leaf.text.trimmingCharacters(in: .whitespaces) as NSString
            let town = text.substring(with: match.range(at: 2))
            func same(_ city: String) -> Bool { city.caseInsensitiveCompare(town) == .orderedSame }
            guard Places.all.contains(where: { same($0.city) }) || Places.abroad.contains(where: { same($0.city) }) else { continue }
            found.insert(index)
            names[record, default: []].insert(text.substring(with: match.range(at: 1)).lowercased())
        }
        guard !names.isEmpty else { return found }
        for (index, leaf) in leaves.enumerated() {
            if let record = leaf.lastRecord, names[record]?.contains(leaf.text.trimmingCharacters(in: .whitespaces).lowercased()) == true { found.insert(index) }
        }
        return found
    }
    private static let placeKinds: Set<String> = ["LOCATION", "REGION"]
    /// Whether the document's places are all it holds of anyone's: no person, street, postcode
    /// or other personal value found or named by a key, nor a place of birth. A cloud's regions
    /// and a configuration's data centres keyed by their cities name a place and no one in it
    /// (see `standsAsPlace` for the ones kept).
    private static func placesStandAlone(_ leaves: [DocumentLeaf], _ founds: [[Span]], _ doubts: [[Span]]) -> Bool {
        // A paste's text has no fields to read around its places by.
        guard leaves.contains(where: { $0.lastRecord != nil }), founds.contains(where: { $0.contains { placeKinds.contains($0.entity) } }),
              founds.allSatisfy({ $0.allSatisfy { placeKinds.contains($0.entity) } }), doubts.allSatisfy(\.isEmpty) else { return false }
        return !leaves.contains { leaf in
            guard !leaf.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            if leaf.numericEntity != nil || leaf.unsureName || leaf.doubtedName { return true }
            guard let hint = KeyHints.hint(leaf.key ?? leaf.addressKey) else { return false }
            let key = KeyHints.words(leaf.key ?? leaf.addressKey).joined()
            return !placeKinds.contains(hint) || key.contains("birth") || key == "pob"
        }
    }

    /// Whether a value names a place for what it is rather than where someone is: an object's key
    /// ("dataCenters": {"Austin": …}) or a region's ("region": "Virginia", "regions": [...]),
    /// a cloud's or a service's as often as a state. A city's or a state's key is an address's part.
    private static func standsAsPlace(_ leaf: DocumentLeaf) -> Bool {
        if leaf.lastRecord == nil { return leaf.key == nil && leaf.field == nil }
        guard let last = leaf.field?.split(separator: ".").last else { return false }
        return ["region", "regions"].contains(KeyHints.words(String(last)).last ?? "")
    }
    /// Whether a place read alone is one: a state or a city Scrub knows, or words no one is named
    /// ("Frankfurt"), never a first name or a surname read as a place ("James").
    private static func namesAPlace(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        func same(_ city: String) -> Bool { city.caseInsensitiveCompare(trimmed) == .orderedSame }
        if Places.region(trimmed) != nil || Places.all.contains(where: { same($0.city) }) || Places.abroad.contains(where: { same($0.city) }) { return true }
        return trimmed.split(separator: " ").allSatisfy { !NameLists.isFirst(String($0)) && !NameLists.isSurname(String($0)) }
    }

    /// The person each record is, read off the names in it (see `associateOwners`).
    struct Owners {
        fileprivate var people: [Persona?] = []
        /// The record of its own each object a flattened header names takes
        /// inside its row ("applicant" of "applicant.email"), by row and path.
        fileprivate var objects: [String: Int] = [:]
        /// Each object's record's parent: the object around it in the same
        /// row ("data.object" around "data.object.name"), or else its row.
        fileprivate var parents: [Int: Int] = [:]
        fileprivate static func object(_ record: Int, _ path: String) -> String { "\(record)\u{0}" + path }
        /// The records around a leaf, innermost first: its object's and the
        /// objects around that, then its own and those around it.
        fileprivate func chain(_ leaf: DocumentLeaf) -> [Int] {
            var objectRecords: [Int] = []
            var next = leaf.objectPath.isEmpty ? nil : leaf.lastRecord.flatMap { objects[Self.object($0, leaf.objectPath)] }
            while let record = next, record != leaf.lastRecord {
                objectRecords.append(record)
                next = parents[record]
            }
            return objectRecords + leaf.enclosing
        }
        /// Whose a leaf's name, email or username is: its innermost record's that has a person.
        func of(_ leaf: DocumentLeaf) -> Persona? {
            // Another name a record gives ("aka": ["SANTANGELO, TOSHIM"]) is no name of its own person's.
            if KeyHints.namesARole(leaf.key) { return nil }
            for record in chain(leaf) where people.indices.contains(record) {
                if let person = people[record] { return person }
            }
            return nil
        }
    }

    /// A record that names several people in flat keys ("applicant_name" and
    /// "spouse_name", "applicantEmail" and "cosignerEmail", "applicant_dob")
    /// holds an object for each, as "applicant.name" or a nested object would,
    /// so each one's fields are read as theirs. Only a qualifier that holds a
    /// name of its own counts, and only beside another name: one person's
    /// record ("name" beside "home_phone" and "work_phone", or "billing_email")
    /// stays whole, and "first_name" and "last_name" qualify nothing.
    static func byPerson(_ leaves: [DocumentLeaf]) -> [DocumentLeaf] {
        var prefixes = [String?](repeating: nil, count: leaves.count)
        var holders: [Int: Set<String>] = [:]
        // Keys repeat in every row and record: each is read once.
        var known: [String: String?] = [:]
        for (index, leaf) in leaves.enumerated() where leaf.objectPath.isEmpty && !leaf.text.isEmpty {
            guard let record = leaf.lastRecord, let key = leaf.key ?? leaf.rawKey else { continue }
            let prefix: String?
            if let cached = known[key] { prefix = cached } else {
                prefix = KeyHints.personPrefix(key)
                known[key] = .some(prefix)
            }
            prefixes[index] = prefix
            if ["PERSON", "FIRST_NAME", "LAST_NAME"].contains(KeyHints.hint(leaf.key) ?? "") { holders[record, default: []].insert(prefix ?? "") }
        }
        guard holders.values.contains(where: { $0.count > 1 }) else { return leaves }
        var result = leaves
        for index in leaves.indices {
            guard let prefix = prefixes[index], let record = leaves[index].lastRecord, let names = holders[record], names.count > 1, names.contains(prefix) else { continue }
            result[index].objectPath = prefix
        }
        return result
    }

    /// Who each record is: the name, email and gender read under their keys
    /// in it. A CSV row of flattened objects ("applicant.name", "spouse.name")
    /// holds a record for each object, as a JSON record holds one for each of
    /// its objects, so two people in one row are two people.
    static func associateOwners(_ leaves: [DocumentLeaf], job: Job) -> Owners {
        let maxRecord = leaves.compactMap(\.lastRecord).max() ?? -1
        guard maxRecord >= 0 else { return Owners() }
        var result = Owners()
        var count = maxRecord + 1
        // Each row's objects, the shallower first, so an object's record is numbered after the one around it.
        var paths: [(record: Int, path: String)] = []
        var seen: Set<String> = []
        for (index, leaf) in leaves.enumerated() where !leaf.objectPath.isEmpty {
            if index.isMultiple(of: 1024) && Task.isCancelled { return Owners() }
            guard let record = leaf.lastRecord, seen.insert(Owners.object(record, leaf.objectPath)).inserted else { continue }
            paths.append((record, leaf.objectPath))
        }
        func depth(_ path: String) -> Int { path.reduce(0) { $1 == "." ? $0 + 1 : $0 } }
        for (record, path) in paths.enumerated().sorted(by: { (depth($0.element.path), $0.offset) < (depth($1.element.path), $1.offset) }).map(\.element) {
            result.objects[Owners.object(record, path)] = count
            var parent = record, around = path
            while let dot = around.lastIndex(of: ".") {
                around = String(around[..<dot])
                if let enclosing = result.objects[Owners.object(record, around)] { parent = enclosing; break }
            }
            result.parents[count] = parent
            count += 1
        }
        var recordFields = Array<IdentityFields?>(repeating: nil, count: count)
        var genders = Array<String?>(repeating: nil, count: count)
        func innermost(_ leaf: DocumentLeaf) -> Int? {
            leaf.objectPath.isEmpty ? leaf.lastRecord : leaf.lastRecord.flatMap { result.objects[Owners.object($0, leaf.objectPath)] }
        }
        func owner<Value>(_ leaf: DocumentLeaf, in values: [Value?]) -> Value? {
            for record in result.chain(leaf) where values.indices.contains(record) {
                if let value = values[record] { return value }
            }
            return nil
        }
        for (index, leaf) in leaves.enumerated() {
            if index.isMultiple(of: 1024) && Task.isCancelled { return Owners() }
            if let record = innermost(leaf), let last = KeyHints.words(leaf.rawKey).last, genderWords.contains(last), let gender = People.gender(leaf.text) {
                genders[record] = gender
                continue
            }
            guard let record = innermost(leaf), let hint = KeyHints.hint(leaf.key), identityHints.contains(hint), !leaf.text.isEmpty, !KeyHints.namesARole(leaf.key) else { continue }
            // "middle": "R" beside "first": "JAMES" is not who the record names first.
            if hint == "FIRST_NAME", KeyHints.words(leaf.key).contains("middle") { continue }
            if recordFields[record] == nil { recordFields[record] = IdentityFields() }
            recordFields[record]?.set(leaf.seen, for: hint)
        }
        // A gender beside a name object ("gender" next to "name": {"first": …}) is that person's.
        for (index, leaf) in leaves.enumerated() {
            if index.isMultiple(of: 1024) && Task.isCancelled { return Owners() }
            guard let record = innermost(leaf), recordFields[record] != nil, recordFields[record]?.gender == nil, let gender = owner(leaf, in: genders) else { continue }
            recordFields[record]?.gender = gender
        }
        // An object holding only part of a name ("Fname.value" beside "Lastname.value")
        // gives it to the object around it, where the rest of the name is.
        for record in stride(from: count - 1, through: maxRecord + 1, by: -1) {
            guard let fields = recordFields[record], fields.full == nil, fields.email == nil, (fields.first == nil) != (fields.last == nil),
                  let parent = result.parents[record] else { continue }
            var around = recordFields[parent] ?? IdentityFields()
            if let first = fields.first {
                guard around.first == nil else { continue }
                around.first = first
            }
            if let last = fields.last {
                guard around.last == nil else { continue }
                around.last = last
            }
            if around.gender == nil { around.gender = fields.gender }
            recordFields[parent] = around
            recordFields[record] = nil
        }
        var identities: [Int?] = recordFields.enumerated().map { index, fields in
            guard let fields, !fields.several, fields.first != nil || fields.last != nil || fields.full != nil else { return nil }
            return index
        }
        // A record whose name sits in one child object ("applicant": {"name": {"first": …},
        // "contact": {"emails": […]}}) is that person's; a list of several people is no one's.
        var parents = [Int?](repeating: nil, count: count)
        for (child, parent) in result.parents { parents[child] = parent }
        for (index, leaf) in leaves.enumerated() {
            if index.isMultiple(of: 1024) && Task.isCancelled { return Owners() }
            for (child, parent) in zip(leaf.enclosing, leaf.enclosing.dropFirst()) where parents[child] == nil { parents[child] = parent }
        }
        // Children before parents: an object's record is numbered after every row's.
        var named = [Set<Int>](repeating: [], count: count)
        for record in Array(stride(from: count - 1, through: maxRecord + 1, by: -1)) + Array(stride(from: maxRecord, through: 0, by: -1)) {
            if let identity = identities[record] { named[record].insert(identity) }
            if identities[record] == nil, named[record].count == 1 { identities[record] = named[record].first }
            if let parent = parents[record], !named[record].isEmpty { named[parent].formUnion(named[record].count == 1 ? named[record] : [-1, -2]) }
        }
        if Task.isCancelled { return Owners() }
        for leaf in leaves where KeyHints.hint(leaf.key) == "EMAIL_ADDRESS" && !leaf.text.isEmpty {
            if let record = owner(leaf, in: identities), recordFields[record]?.email == nil {
                recordFields[record]?.email = leaf.seen
            }
        }
        var owners = Array<Persona?>(repeating: nil, count: count)
        for record in recordFields.indices {
            if record.isMultiple(of: 1024) && Task.isCancelled { return Owners() }
            guard let fields = recordFields[record], !fields.several else { continue }
            owners[record] = job.associateRecord(first: fields.first, last: fields.last, full: fields.full, email: fields.email, gender: fields.gender)
        }
        result.people = identities.map { $0.flatMap { owners[$0] } }
        return result
    }

    /// A country key that says where a record's places are; never a birth's, a
    /// document's issuer's or a citizenship ("country_of_birth", "issuing_country").
    static func placesCountry(_ words: [String]) -> Bool {
        words.contains("country") && !words.contains { ["birth", "born", "issuing", "issuer", "issue", "issued", "citizenship", "nationality", "origin", "tax", "passport", "document"].contains($0) }
    }
    /// The address each leaf belongs to: the city, region, postcode and country
    /// read under their keys in one record ("billing_city" and "billing_zip"
    /// apart from "shipping_city"), so their stand-ins come from one place.
    private static let addressKinds: Set<String> = ["billing", "shipping", "mailing", "home", "work", "delivery", "residential", "physical", "previous", "current", "permanent", "legal", "registered", "business", "office", "pickup", "dropoff", "origin", "destination"]
    /// Values no key names that write out, on one line, an address their record
    /// holds in parts ("singleLine": "AM GRIES 57a, 80538 MÜNCHEN" beside "city"
    /// and "postalCode"): each with those parts, so its pieces take the stand-ins
    /// the parts take, however the detectors read it.
    static func writtenOut(_ leaves: [DocumentLeaf], _ addresses: [AddressParts?]) -> [(Int, AddressParts)] {
        var held: [Int: [AddressParts]] = [:]
        for (index, leaf) in leaves.enumerated() where ["LOCATION", "POSTAL_CODE"].contains(KeyHints.hint(leaf.key) ?? "") {
            guard let record = leaf.lastRecord, let parts = addresses[index], !(held[record]?.contains(parts) ?? false) else { continue }
            held[record, default: []].append(parts)
        }
        guard !held.isEmpty else { return [] }
        func same(_ a: String?, _ b: String?) -> Bool {
            guard let a, let b else { return false }
            return a.trimmingCharacters(in: .whitespaces).compare(b.trimmingCharacters(in: .whitespaces), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        var result: [(Int, AddressParts)] = []
        for (index, leaf) in leaves.enumerated() {
            if index.isMultiple(of: 1024) && Task.isCancelled { return [] }
            guard KeyHints.hint(leaf.key ?? leaf.addressKey) == nil, leaf.numericEntity == nil, !leaf.fieldName, !leaf.nonPersonal, leaf.seen.contains(","),
                  let candidates = leaf.enclosing.lazy.compactMap({ held[$0] }).first,
                  let block = AddressBlock.read(leaf.seen), block.roles.contains(.street), block.roles.contains(.locality) else { continue }
            // Every piece is part of an address: a district or a region's code may be, a name never.
            let pieces = zip(block.pieces, block.roles).allSatisfy { piece, role in
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                return role != .place || Places.region(trimmed) != nil || Places.regionAbroad(trimmed) != nil || AddressBlock.isKnownPlace(trimmed)
            }
            guard pieces, let parts = candidates.first(where: { parts in
                block.localities.contains { same($0.locality.postal, parts.postal) || same($0.locality.city, parts.city) }
            }) else { continue }
            result.append((index, parts))
        }
        return result
    }

    static func associateAddresses(_ leaves: [DocumentLeaf]) -> [AddressParts?] {
        var groups: [String: AddressParts] = [:]
        var member = [String?](repeating: nil, count: leaves.count)
        // "billing_city" apart from "shipping_city"; "postal_code" and "street_address"
        // name no qualifier, and one qualifier alone ("applicantCity") splits nothing.
        func qualifier(_ key: String) -> String {
            let words = KeyHints.words(key)
            return words.count >= 2 && addressKinds.contains(words[0]) && KeyHints.hint(words.dropFirst().joined(separator: "_")) != nil ? words[0] : ""
        }
        // Only a part that repeats ("billing_city" and "shipping_city") splits a record's addresses.
        var slots: [Int: [String: Set<String>]] = [:]
        for (index, leaf) in leaves.enumerated() {
            if index.isMultiple(of: 1024) && Task.isCancelled { return [] }
            guard let record = leaf.lastRecord, let key = leaf.key, let hint = KeyHints.hint(key), ["LOCATION", "REGION", "POSTAL_CODE"].contains(hint) else { continue }
            slots[record, default: [:]][hint, default: []].insert(qualifier(key))
        }
        let split = Set(slots.compactMap { record, byHint in byHint.values.contains { $0.count > 1 } ? record : nil })
        for (index, leaf) in leaves.enumerated() {
            if index.isMultiple(of: 1024) && Task.isCancelled { return [] }
            guard let record = leaf.lastRecord, let key = leaf.key ?? leaf.rawKey ?? leaf.addressKey, !leaf.text.isEmpty else { continue }
            let words = KeyHints.words(key)
            let hint = KeyHints.hint(leaf.key ?? leaf.addressKey) ?? leaf.numericEntity
            // "country", "country_code", "address_country": what country the record's places are in.
            let country = KeyHints.hint(leaf.key) == nil && Self.placesCountry(words) && Places.code(leaf.text) != nil
            guard StandIns.placed.contains(hint ?? "") || StandIns.local.contains(hint ?? "") || country || isTimeZone(leaf) else { continue }
            let group = "\(record)\u{0}\(split.contains(record) ? qualifier(key) : "")"
            member[index] = group
            var parts = groups[group] ?? AddressParts()
            switch hint {
            case "LOCATION": if parts.city == nil { parts.city = leaf.seen }
            case "REGION": if parts.region == nil { parts.region = leaf.seen }
            case "POSTAL_CODE": if parts.postal == nil { parts.postal = leaf.seen }
            case "LATITUDE", "COORDINATES": if parts.coordinates == nil || hint == "LATITUDE" { parts.coordinates = leaf.seen }
            case "LONGITUDE": if parts.coordinates == nil { parts.coordinates = leaf.seen }
            case _ where country: if parts.country == nil { parts.country = leaf.seen }
            default: break
            }
            groups[group] = parts
        }
        // A phone or time zone joins its record's address whatever qualifies it
        // ("home_phone" beside "city"). A wrapped part ("zip": {"value": …}) is
        // already in the record around it.
        for (index, leaf) in leaves.enumerated() {
            if index.isMultiple(of: 1024) && Task.isCancelled { return [] }
            guard let group = member[index], let record = leaf.lastRecord else { continue }
            let hint = KeyHints.hint(leaf.key) ?? leaf.numericEntity ?? ""
            let qualifier = String(group.drop { $0 != "\u{0}" }.dropFirst())
            var target: String?
            if StandIns.local.contains(hint) || isTimeZone(leaf) {
                target = [qualifier, ""].map { "\(record)\u{0}\($0)" }.first { groups[$0].map { $0.city != nil || $0.region != nil || $0.postal != nil } == true }
            }
            guard let target, target != group else { continue }
            var merged = groups[target] ?? AddressParts()
            let own = groups[group] ?? AddressParts()
            merged.city = merged.city ?? own.city
            merged.region = merged.region ?? own.region
            merged.postal = merged.postal ?? own.postal
            merged.country = merged.country ?? own.country
            merged.coordinates = merged.coordinates ?? own.coordinates
            groups[target] = merged
            member[index] = target
        }
        // A record's places with no country of their own are in the country a
        // record around them names: "country_code": "IT" at a request's top
        // and "city" two objects down.
        var countries: [Int: String] = [:]
        for leaf in leaves {
            guard let record = leaf.lastRecord, countries[record] == nil, KeyHints.hint(leaf.key) == nil, Self.placesCountry(KeyHints.words(leaf.rawKey)),
                  Places.code(leaf.text) != nil else { continue }
            countries[record] = leaf.seen
        }
        if !countries.isEmpty {
            for (index, leaf) in leaves.enumerated() {
                guard let group = member[index], groups[group]?.country == nil else { continue }
                if let country = leaf.enclosing.lazy.compactMap({ countries[$0] }).first { groups[group]?.country = country }
            }
        }
        // Members moved after a group was merged read the merged parts.
        // A record's address also covers what sits beside it: "timezone" and
        // "phone" next to "address": {…}, or "geo": {"coordinates": …} as its sibling.
        var inherited: [Int: AddressParts] = [:], own: [Int: AddressParts] = [:]
        for (index, leaf) in leaves.enumerated() {
            if index.isMultiple(of: 1024) && Task.isCancelled { return [] }
            guard let group = member[index], let parts = groups[group], parts.city != nil || parts.region != nil || parts.postal != nil else { continue }
            if let record = leaf.lastRecord, own[record] == nil { own[record] = parts }
            for record in leaf.enclosing.dropFirst() where inherited[record] == nil { inherited[record] = parts }
        }
        return leaves.indices.map { index in
            let ownParts = member[index].flatMap { groups[$0] }
            if let ownParts, ownParts.city != nil || ownParts.region != nil || ownParts.postal != nil { return ownParts }
            // A street line in an object of its own ("additional_fields": {"address1": …})
            // is the address around it, and at least in its country.
            if KeyHints.hint(leaves[index].key ?? leaves[index].addressKey) == "ADDRESS" {
                if let around = leaves[index].enclosing.dropFirst().lazy.compactMap({ own[$0] }).first { return around }
                if let ownParts, ownParts.country != nil { return ownParts }
            }
            // A point or a phone may sit one level down: in a list ("phones": […], <telephones>)
            // or, in XML, as an element inside the address's.
            let point = ["LATITUDE", "LONGITUDE", "COORDINATES", "PHONE_NUMBER"].contains(KeyHints.hint(leaves[index].key) ?? leaves[index].numericEntity ?? "")
            guard point || isTimeZone(leaves[index]) || KeyHints.hint(leaves[index].key) == "PHONE_NUMBER" else { return ownParts.flatMap { $0.isEmpty ? nil : $0 } }
            // A time zone or phone number beside the address object, or a point
            // one level further out ("geo": {"coordinates": …} next to "address").
            // In XML a point's numbers are elements of their own, inside the address's.
            let enclosing = leaves[index].enclosing
            let outer = point ? enclosing.dropFirst().prefix(2).lazy.compactMap({ own[$0] }).first : nil
            guard var near = outer ?? enclosing.prefix(point ? 2 : 1).lazy.compactMap({ inherited[$0] }).first else { return ownParts.flatMap { $0.isEmpty ? nil : $0 } }
            near.coordinates = ownParts?.coordinates ?? near.coordinates
            return near
        }
    }

    private static func observeInitial(_ leaves: [DocumentLeaf], bases: [[Span]], job: Job) {
        for (index, (leaf, base)) in zip(leaves, bases).enumerated() {
            if index.isMultiple(of: 1024) && Task.isCancelled { return }
            let found = leaf.numericEntity.map { [Span(range: 0..<(leaf.text as NSString).length, entity: $0, score: 1)] }
                ?? Detector.resolve(base)
            job.observeSpans([(leaf.seen, found)])
        }
    }

    /// Whether names may rewrite a code (see `DocumentLeaf.isCode`): only one spelling out, word for word, a person
    /// a field's key or a rule named ("ODALYS_QUILLMERE" beside "last_name": "Quillmere"), never one a model guessed.
    static func namesCode(_ leaf: DocumentLeaf, job: Job) -> Bool {
        let words = leaf.text.split(separator: "_").map { $0.lowercased() }
        func sure(_ original: String) -> Bool { (job.confidence(of: original) ?? 0) >= 0.95 }
        return sure(words.joined(separator: " ")) || words.allSatisfy(sure)
    }
    /// Whether a key is, written as a name, the whole of a person a field's key or a rule named
    /// ({"by_person": {"Nas": true}} beside "full_name": "Nas Garcia"): their data itself, renamed as they are.
    static func keyIsName(_ leaf: DocumentLeaf, job: Job) -> Bool {
        leaf.text.first?.isUppercase == true && (job.confidence(of: leaf.text) ?? 0) >= 0.95
    }
    private static func detected(_ leaf: DocumentLeaf, base: [Span], gazetteer: GazetteerMatcher, detector: Detector, job: Job) -> [Span] {
        if let entity = leaf.numericEntity { return [Span(range: 0..<(leaf.text as NSString).length, entity: entity, score: 1)] }
        let found = detector.combined(base, text: leaf.seen, matcher: gazetteer)
        if leaf.isCode, !namesCode(leaf, job: job) { return found.filter { !nameEntities.contains($0.entity) } }
        guard leaf.isKey, !keyIsName(leaf, job: job) else { return found }
        return found.filter { span in
            !nameEntities.contains(span.entity) || base.contains { nameEntities.contains($0.entity) && $0.range.overlaps(span.range) }
        }
    }


    /// A bare "name" written as a person's that nothing found or doubted: the whole name,
    /// found where it holds only names the name model reads as a person's, else doubted.
    private static func unsureName(_ text: String, besides found: [Span], model: NameModel?, isCancelled: () -> Bool) -> (span: Span, sure: Bool)? {
        guard !found.contains(where: { nameEntities.contains($0.entity) }) else { return nil }
        let ns = text as NSString
        let trimmed = ns.range(of: #"\S(?:.*\S)?"#, options: .regularExpression)
        guard trimmed.location != NSNotFound else { return nil }
        let range = trimmed.location..<NSMaxRange(trimmed), name = ns.substring(with: trimmed)
        if EastAsianNames.surnamed(name) == nil, KeyHints.onlyNames(name), model?.readsAsName(name, isCancelled: isCancelled) == true {
            return (Span(range: range, entity: "PERSON", score: NameModel.score), true)
        }
        return (Span(range: range, entity: "PERSON", score: Doubt.unconfirmed.confidence), false)
    }

    /// What detection found in each value, nil where it left the value to its key; the
    /// same with the key's spans in those; and the people each value's detectors doubt.
    private static func detectBases(_ leaves: [DocumentLeaf], progress: (Stage, Int, Int) -> Void) throws -> ([[Span]?], [[Span]], [[Span]]) {
        let count = leaves.count
        guard count > 0 else { return ([], [], []) }
        // The context model first: its findings fill only what every other detector leaves.
        let context = try ContextStage.find(leaves.map { leaf in
            leaf.numericEntity != nil || leaf.fieldName || KeyHints.hint(leaf.key) != nil || KeyHints.isStructural(leaf.key) ? nil : leaf.seen
        }, progress: progress, cancelled: CancellationFlag())
        let chunkSize = max(128, (count + max(1, ProcessInfo.processInfo.activeProcessorCount) * 4 - 1) / (max(1, ProcessInfo.processInfo.activeProcessorCount) * 4))
        let chunkCount = (count + chunkSize - 1) / chunkSize
        let results = Mutex(Array<[Span]?>(repeating: nil, count: count))
        let keyed = Mutex(Array<[Span]>(repeating: [], count: count))
        let doubted = Mutex(Array<[Span]>(repeating: [], count: count))
        // Worker threads are outside the task, so Task.isCancelled is always false
        // there; the calling thread watches it and raises a flag they can see.
        let cancelled = CancellationFlag()
        // Read here, in the scrub's task: the worker threads below see no task-local values.
        let addresses = AddressModel.active && !Coverage.withheld.contains(.addressModel), learned = PersonScorer.learned
        let names = !Coverage.withheld.contains(.nameModel)
        let done = DispatchGroup()
        done.enter()
        Work.queue.async {
            DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                let detector = Detector(isCancelled: { cancelled.isSet }, addresses: addresses, learned: learned, names: names)
                let start = chunk * chunkSize
                let end = min(count, start + chunkSize)
                var local: [[Span]?] = [], doubts: [(Int, [Span])] = []
                local.reserveCapacity(end - start)
                // Records repeat their values ("level": "info"): one read the model had no part in
                // is the same wherever its text, key and words are.
                var reads: [ReadKey: (spans: [Span], doubts: [Span])] = [:]
                var notes: [Int: [Span]] = [:]
                for index in start..<end {
                    if cancelled.isSet { return }
                    let leaf = leaves[index]
                    if leaf.numericEntity != nil || KeyHints.hint(leaf.key) != nil && !leaf.text.isEmpty {
                        local.append(nil)
                        // A note written after the field's value ("128 -- call Odalys first") is read as any text is.
                        if leaf.numericEntity == nil, case let head = KeyHints.judged(leaf.key, leaf.seen), case let cut = (head as NSString).length, cut < (leaf.seen as NSString).length {
                            let note = TextRanges.substring(leaf.seen, cut..<(leaf.seen as NSString).length)
                            notes[index] = detector.read(note).spans.map { Span(range: ($0.range.lowerBound + cut)..<($0.range.upperBound + cut), entity: $0.entity, score: $0.score) }
                        }
                    }
                    else if leaf.fieldName { local.append(Patterns.find(leaf.seen, isCancelled: { cancelled.isSet })) }
                    else {
                        let key = context[index] == nil ? ReadKey(text: leaf.seen, key: leaf.key, contextWords: leaf.contextWords, naming: leaf.namingWords) : nil
                        let read = key.flatMap { reads[$0] } ?? detector.read(leaf.seen, key: leaf.key, contextWords: leaf.contextWords, naming: leaf.namingWords, context: context[index])
                        if let key, reads[key] == nil { reads[key] = read }
                        var doubted = read.doubts
                        if leaf.unsureName || leaf.doubtedName, let name = unsureName(leaf.seen, besides: read.spans + doubted, model: names && !leaf.doubtedName ? NameModel.shared : nil, isCancelled: { cancelled.isSet }) {
                            if name.sure { local.append(read.spans + [name.span]) } else { local.append(read.spans); doubted.append(name.span) }
                        } else {
                            local.append(read.spans)
                        }
                        if !doubted.isEmpty { doubts.append((index, doubted)) }
                    }
                }
                // Where detection leaves a value to its key, the key's spans.
                let keys = zip(local, start..<end).map { found, index in
                    let leaf = leaves[index]
                    return found ?? ((leaf.text.isEmpty ? [] : Detector.keyed(leaf.seen, key: leaf.key) ?? []) + (notes[index] ?? []))
                }
                results.withLock { $0.replaceSubrange(start..<end, with: local) }
                keyed.withLock { $0.replaceSubrange(start..<end, with: keys) }
                if !doubts.isEmpty { doubted.withLock { all in for (index, found) in doubts { all[index] = found } } }
            }
            done.leave()
        }
        while done.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if Task.isCancelled { cancelled.set() }
        }
        try Scrubber.checkCancellation()
        return (results.withLock { $0 }, keyed.withLock { $0 }, doubted.withLock { $0 })
    }
    /// A text and key as written, code unit for code unit: two spellings Swift calls equal
    /// ("é" composed or not) differ in length, so in where their spans fall.
    private struct ReadKey: Hashable {
        let text: [UInt8]
        let key: [UInt8]?
        let contextWords: Set<String>
        let naming: Set<String>?
        init(text: String, key: String?, contextWords: Set<String>, naming: Set<String>?) {
            self.text = Array(text.utf8); self.key = key.map { Array($0.utf8) }; self.contextWords = contextWords; self.naming = naming
        }
    }
}

final class CancellationFlag: Sendable {
    private let value = Atomic(false)
    var isSet: Bool { value.load(ordering: .relaxed) }
    func set() { value.store(true, ordering: .relaxed) }
}
