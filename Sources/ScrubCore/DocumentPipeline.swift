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
    private static let nonPersonalWords: Set<String> = ["status", "state", "type", "kind", "result", "outcome", "decision", "amount", "currency", "total", "balance", "fee",
                                                        "price", "count", "quantity", "at", "time", "timestamp", "date", "created", "updated", "version", "method", "code", "level", "score", "reason", "category", "channel", "mode"]

    init(_ text: String, key: String? = nil, records: [Int] = [], contextWords: Set<String> = [], numericEntity: String? = nil, fieldName: Bool = false, objectPath: String = "") {
        self.objectPath = objectPath
        self.text = text
        self.key = numericEntity != nil || KeyHints.fits(key, text) ? key : nil
        addressKey = self.key == nil && numericEntity == nil && (KeyHints.numberlessLine(key, text) || KeyHints.regionCode(key, text)) ? key : nil
        self.rawKey = KeyHints.hint(key) == nil ? key : nil
        datePart = rawKey == nil ? KeyHints.datePart(self.key) : nil
        self.records = RecordPath(records)
        self.contextWords = contextWords
        self.numericEntity = numericEntity
        self.fieldName = fieldName
        view = numericEntity == nil ? Visible(text) : nil
        nonPersonal = KeyHints.hint(key) == nil && KeyHints.words(key).last.map(Self.nonPersonalWords.contains) == true
            || KeyHints.hint(key) == "SECRET" && numericEntity == nil && !KeyHints.fits(key, text)
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
        mutating func set(_ value: String, for hint: String) {
            switch hint {
            case "FIRST_NAME": first = value
            case "LAST_NAME": last = value
            case "PERSON":
                func words(_ name: String) -> Set<String> { Set(name.lowercased().split { !$0.isLetter }.map(String.init)) }
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
                if previous.fullyMarked { continue }
                let reusable = !forceFullDetection && emptyBases[index] && previous.text == leaves[index].text
                job.enter(value: index, records: leaves[index].enclosing, part: leaves[index].datePart, object: leaves[index].objectPath)
                var held = previous.held
                let (text, marks, unresolved) = try Correction.run(previous.text, marks: previous.marks, job: job, matcher: originals, gazetteer: gazetteer, gate: gate, passes: 1, base: reusable ? [] : nil, held: &held,
                                                                   sparing: leaves[index].nonPersonal ? ["SECRET"] : [])
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
        // What is left as written gets the stand-in it would take, drawn in
        // document order once the rounds are done, so review can offer it.
        for index in values.indices where !values[index].unresolved.isEmpty || !values[index].held.isEmpty {
            try Scrubber.checkCancellation()
            let value = values[index]
            job.enter(value: index, records: leaves[index].enclosing, part: leaves[index].datePart, object: leaves[index].objectPath)
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
        let (bases, doubts) = try detectBases(leaves, progress: progress)
        let prepared = try prepare(leaves, bases: bases, doubts: doubts, job: job)
        return (prepared.0, prepared.1, bases.map { $0?.isEmpty == true })
    }

    private static func prepare(_ leaves: [DocumentLeaf], bases: [[Span]?], doubts: [[Span]], job: Job) throws -> (GazetteerMatcher, [DocumentValue]) {
        job.reserveNames(zip(leaves, bases).flatMap { leaf, stored in
            base(leaf, stored: stored).compactMap { span -> String? in
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
        let addresses = associateAddresses(leaves)
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
        for index in order {
            try Scrubber.checkCancellation()
            let (leaf, stored) = (leaves[index], bases[index])
            var found = detected(leaf, base: base(leaf, stored: stored), gazetteer: gazetteer, detector: job.detector)
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
            founds[index] = found
        }
        Fields.decide(leaves, &founds)
        for index in order {
            try Scrubber.checkCancellation()
            let leaf = leaves[index]
            job.enter(value: index, records: leaf.enclosing, part: leaf.datePart, object: leaf.objectPath)
            var found = founds[index]
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
            } else if found.isEmpty, let address = addresses[index], isTimeZone(leaf) {
                text = job.replacement(for: "TIME_ZONE", original: leaf.text, persona: nil, address: address)
                marks = [Mark(range: 0..<(text as NSString).length, entity: "TIME_ZONE", original: leaf.text, confidence: 1)]
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
            guard let record = innermost(leaf), let hint = KeyHints.hint(leaf.key), identityHints.contains(hint), !leaf.text.isEmpty else { continue }
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

    private static func observeInitial(_ leaves: [DocumentLeaf], bases: [[Span]?], job: Job) {
        for (index, (leaf, stored)) in zip(leaves, bases).enumerated() {
            if index.isMultiple(of: 1024) && Task.isCancelled { return }
            let found = leaf.numericEntity.map { [Span(range: 0..<(leaf.text as NSString).length, entity: $0, score: 1)] }
                ?? Detector.resolve(base(leaf, stored: stored))
            job.observeSpans([(leaf.seen, found)])
        }
    }

    private static func detected(_ leaf: DocumentLeaf, base: [Span], gazetteer: GazetteerMatcher, detector: Detector) -> [Span] {
        leaf.numericEntity.map { [Span(range: 0..<(leaf.text as NSString).length, entity: $0, score: 1)] }
            ?? detector.combined(base, text: leaf.seen, matcher: gazetteer)
    }

    /// Spans in the text as seen (`DocumentLeaf.seen`).
    private static func base(_ leaf: DocumentLeaf, stored: [Span]?) -> [Span] {
        if let stored { return stored }
        guard !leaf.text.isEmpty else { return [] }
        return Detector.keyed(leaf.seen, key: leaf.key) ?? []
    }

    private static func detectBases(_ leaves: [DocumentLeaf], progress: (Stage, Int, Int) -> Void) throws -> ([[Span]?], [[Span]]) {
        let count = leaves.count
        guard count > 0 else { return ([], []) }
        // The context model first: its findings fill only what every other detector leaves.
        let context = try ContextStage.find(leaves.map { leaf in
            leaf.numericEntity != nil || leaf.fieldName || KeyHints.hint(leaf.key) != nil || KeyHints.isStructural(leaf.key) ? nil : leaf.seen
        }, progress: progress, cancelled: CancellationFlag())
        let chunkSize = max(128, (count + max(1, ProcessInfo.processInfo.activeProcessorCount) * 4 - 1) / (max(1, ProcessInfo.processInfo.activeProcessorCount) * 4))
        let chunkCount = (count + chunkSize - 1) / chunkSize
        let results = Mutex(Array<[Span]?>(repeating: nil, count: count))
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
                for index in start..<end {
                    if cancelled.isSet { return }
                    let leaf = leaves[index]
                    if leaf.numericEntity != nil || KeyHints.hint(leaf.key) != nil && !leaf.text.isEmpty { local.append(nil) }
                    else if leaf.fieldName { local.append(Patterns.find(leaf.seen, isCancelled: { cancelled.isSet })) }
                    else {
                        let read = detector.read(leaf.seen, key: leaf.key, contextWords: leaf.contextWords, naming: leaf.namingWords, context: context[index])
                        local.append(read.spans)
                        if !read.doubts.isEmpty { doubts.append((index, read.doubts)) }
                    }
                }
                results.withLock { $0.replaceSubrange(start..<end, with: local) }
                if !doubts.isEmpty { doubted.withLock { all in for (index, found) in doubts { all[index] = found } } }
            }
            done.leave()
        }
        while done.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if Task.isCancelled { cancelled.set() }
        }
        try Scrubber.checkCancellation()
        return (results.withLock { $0 }, doubted.withLock { $0 })
    }
}

final class CancellationFlag: Sendable {
    private let value = Atomic(false)
    var isSet: Bool { value.load(ordering: .relaxed) }
    func set() { value.store(true, ordering: .relaxed) }
}
