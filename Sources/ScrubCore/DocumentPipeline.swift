import Foundation
import Synchronization

struct DocumentLeaf: Sendable {
    let text: String
    let key: String?
    private let records: RecordPath
    var lastRecord: Int? { records.last }
    func owner<Value>(in owners: [Value?]) -> Value? { records.owner(in: owners) }
    /// The records this value sits in, innermost first.
    var enclosing: [Int] { records.all.reversed() }
    let contextWords: Set<String>
    let numericEntity: String?
    /// A column header or similar label: read for patterns only, since the name
    /// model takes words like "Dob" for places.
    let fieldName: Bool
    /// The key of a value no hint covers ("country", "gender", "timezone"),
    /// kept because it tells what the personal values beside it should fit.
    let rawKey: String?

    init(_ text: String, key: String? = nil, records: [Int] = [], contextWords: Set<String> = [], numericEntity: String? = nil, fieldName: Bool = false) {
        self.text = text
        self.key = numericEntity != nil || KeyHints.fits(key, text) ? key : nil
        self.rawKey = KeyHints.hint(key) == nil ? key : nil
        self.records = RecordPath(records)
        self.contextWords = contextWords
        self.numericEntity = numericEntity
        self.fieldName = fieldName
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
    func owner<Value>(in owners: [Value?]) -> Value? {
        switch self {
        case .none: return nil
        case .one(let record): return owners.indices.contains(record) ? owners[record] : nil
        case .many(let records):
            for record in records.reversed() where owners.indices.contains(record) {
                if let owner = owners[record] { return owner }
            }
            return nil
        }
    }
}

struct DocumentValue {
    let text: String
    private let storedMarks: [Mark]
    private let fullEntity: String?
    let unresolved: [Mark]

    init(text: String, marks: [Mark], unresolved: [Mark]) {
        self.text = text
        self.unresolved = unresolved
        if marks.count == 1, marks[0].range == 0..<(text as NSString).length {
            storedMarks = []
            fullEntity = marks[0].entity
        } else {
            storedMarks = marks
            fullEntity = nil
        }
    }
    var marks: [Mark] {
        if let fullEntity { return [Mark(range: 0..<(text as NSString).length, entity: fullEntity)] }
        return storedMarks
    }
    var fullyMarked: Bool { fullEntity != nil }
}

enum DocumentPipeline {
    private struct IdentityFields {
        var first: String?
        var last: String?
        var full: String?
        var email: String?
        var gender: String?
        mutating func set(_ value: String, for hint: String) {
            switch hint {
            case "FIRST_NAME": first = value
            case "LAST_NAME": last = value
            case "PERSON": full = value
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

    static func run(_ leaves: [DocumentLeaf], job: Job, forceFullDetection: Bool = false, progress: (Stage, Int, Int) -> Void = { _, _, _ in }) throws -> [DocumentValue] {
        var (gazetteer, values, emptyBases) = try detectAndPrepare(leaves, job: job, progress: progress)
        var active = Array(repeating: true, count: values.count)
        var originals = OriginalMatcher(job)
        for _ in 0..<3 {
            let beforeReplacements = job.replacements.count
            var changedIndices: [Int] = []
            var changed = false
            for index in values.indices where active[index] {
                try Scrubber.checkCancellation()
                let previous = values[index]
                if previous.fullyMarked { continue }
                let reusable = !forceFullDetection && emptyBases[index] && previous.text == leaves[index].text
                let (text, marks, unresolved) = try Correction.run(previous.text, marks: previous.marks, job: job, matcher: originals, gazetteer: gazetteer, passes: 1, base: reusable ? [] : nil)
                if text != previous.text { changed = true; changedIndices.append(index) }
                values[index] = DocumentValue(text: text, marks: marks, unresolved: unresolved)
            }
            if !changed { break }
            let newReplacements = job.replacements[beforeReplacements...]
            originals.add(newReplacements)
            if forceFullDetection { continue }
            active = Array(repeating: false, count: values.count)
            for index in changedIndices { active[index] = true }
            let newOriginals = newReplacements.map(\.original).filter { !$0.isEmpty }
            if !newOriginals.isEmpty {
                let newMatcher = Matcher(newOriginals, isCancelled: { Task.isCancelled })
                for index in values.indices where !active[index] {
                    if index.isMultiple(of: 1024) { try Scrubber.checkCancellation() }
                    let value = values[index]
                    guard !value.marks.contains(where: { $0.range == 0..<(value.text as NSString).length }) else { continue }
                    if !newMatcher.matches(in: value.text).isEmpty { active[index] = true }
                }
            }
        }
        return values
    }
    private static func detectAndPrepare(_ leaves: [DocumentLeaf], job: Job, progress: (Stage, Int, Int) -> Void) throws -> (GazetteerMatcher, [DocumentValue], [Bool]) {
        let bases = try detectBases(leaves, progress: progress)
        let prepared = try prepare(leaves, bases: bases, job: job)
        return (prepared.0, prepared.1, bases.map { $0?.isEmpty == true })
    }

    private static func prepare(_ leaves: [DocumentLeaf], bases: [[Span]?], job: Job) throws -> (GazetteerMatcher, [DocumentValue]) {
        job.reserveNames(zip(leaves, bases).flatMap { leaf, stored in
            base(leaf, stored: stored).filter { nameEntities.contains($0.entity) }.map { TextRanges.substring(leaf.text, $0.range) }
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
        let gazetteer = GazetteerMatcher(job.gazetteer, nameParts: job.nameParts, isCancelled: { Task.isCancelled })
        try Scrubber.checkCancellation()
        job.setReplacementRecording(false)
        defer { job.setReplacementRecording(true) }
        var values = [DocumentValue?](repeating: nil, count: leaves.count)
        // An age or last four digits is read off the stand-ins it belongs with, so those come first.
        let later = { (index: Int) in StandIns.derived.contains(leaves[index].numericEntity ?? KeyHints.hint(leaves[index].key) ?? "") || KeyHints.hint(leaves[index].key) != nil && StandIns.isMasked(leaves[index].text) }
        var order: [Int] = [], derived: [Int] = []
        for index in leaves.indices {
            if index.isMultiple(of: 1024) { try Scrubber.checkCancellation() }
            if later(index) { derived.append(index) } else { order.append(index) }
        }
        order += derived
        for index in order {
            try Scrubber.checkCancellation()
            let (leaf, stored) = (leaves[index], bases[index])
            let found = detected(leaf, base: base(leaf, stored: stored), gazetteer: gazetteer, detector: job.detector)
            job.recordOriginals([(leaf.text, found)])
            let owner = identityHints.contains(KeyHints.hint(leaf.key) ?? "") ? leaf.owner(in: owners) : nil
            var (text, marks): (String, [Mark])
            if let entity = leaf.numericEntity {
                text = job.numericLexeme(leaf.text, entity: entity, address: addresses[index])
                marks = [Mark(range: 0..<(text as NSString).length, entity: entity)]
            } else if found.isEmpty, let address = addresses[index], isTimeZone(leaf) {
                text = job.replacement(for: "TIME_ZONE", original: leaf.text, persona: nil, address: address)
                marks = [Mark(range: 0..<(text as NSString).length, entity: "TIME_ZONE")]
            } else {
                (text, marks) = try job.apply(leaf.text, spans: found, owner: owner, address: addresses[index])
            }
            // An age with no birth date to follow stays as it was.
            if text == leaf.text, marks.count == 1, StandIns.derived.contains(marks[0].entity) || marks[0].entity == "TIME_ZONE" { marks = [] }
            values[index] = DocumentValue(text: text, marks: marks, unresolved: [])
        }
        return (gazetteer, values.map { $0! })
    }

    static func associateOwners(_ leaves: [DocumentLeaf], job: Job) -> [Persona?] {
        let maxRecord = leaves.compactMap(\.lastRecord).max() ?? -1
        guard maxRecord >= 0 else { return [] }
        var recordFields = Array<IdentityFields?>(repeating: nil, count: maxRecord + 1)
        var genders = Array<String?>(repeating: nil, count: maxRecord + 1)
        for (index, leaf) in leaves.enumerated() {
            if index.isMultiple(of: 1024) && Task.isCancelled { return [] }
            if let record = leaf.lastRecord, let last = KeyHints.words(leaf.rawKey).last, genderWords.contains(last), let gender = People.gender(leaf.text) {
                genders[record] = gender
                continue
            }
            guard let record = leaf.lastRecord, let hint = KeyHints.hint(leaf.key), identityHints.contains(hint), !leaf.text.isEmpty else { continue }
            if recordFields[record] == nil { recordFields[record] = IdentityFields() }
            recordFields[record]?.set(leaf.text, for: hint)
        }
        // A gender beside a name object ("gender" next to "name": {"first": …}) is that person's.
        for (index, leaf) in leaves.enumerated() {
            if index.isMultiple(of: 1024) && Task.isCancelled { return [] }
            guard let record = leaf.lastRecord, recordFields[record] != nil, recordFields[record]?.gender == nil, let gender = leaf.owner(in: genders) else { continue }
            recordFields[record]?.gender = gender
        }
        var identities: [Int?] = recordFields.enumerated().map { index, fields in
            guard let fields, fields.first != nil || fields.last != nil || fields.full != nil else { return nil }
            return index
        }
        // A record whose name sits in one child object ("applicant": {"name": {"first": …},
        // "contact": {"emails": […]}}) is that person's; a list of several people is no one's.
        var parents = [Int?](repeating: nil, count: maxRecord + 1)
        for (index, leaf) in leaves.enumerated() {
            if index.isMultiple(of: 1024) && Task.isCancelled { return [] }
            for (child, parent) in zip(leaf.enclosing, leaf.enclosing.dropFirst()) where parents[child] == nil { parents[child] = parent }
        }
        var named = [Set<Int>](repeating: [], count: maxRecord + 1)
        for record in stride(from: maxRecord, through: 0, by: -1) {
            if let identity = identities[record] { named[record].insert(identity) }
            if identities[record] == nil, named[record].count == 1 { identities[record] = named[record].first }
            if let parent = parents[record], !named[record].isEmpty { named[parent].formUnion(named[record].count == 1 ? named[record] : [-1, -2]) }
        }
        if Task.isCancelled { return [] }
        for leaf in leaves where KeyHints.hint(leaf.key) == "EMAIL_ADDRESS" && !leaf.text.isEmpty {
            if let record = leaf.owner(in: identities), recordFields[record]?.email == nil {
                recordFields[record]?.email = leaf.text
            }
        }
        var owners = Array<Persona?>(repeating: nil, count: maxRecord + 1)
        for record in recordFields.indices {
            if record.isMultiple(of: 1024) && Task.isCancelled { return [] }
            guard let fields = recordFields[record] else { continue }
            owners[record] = job.associateRecord(first: fields.first, last: fields.last, full: fields.full, email: fields.email, gender: fields.gender)
        }
        return identities.map { $0.flatMap { owners[$0] } }
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
            guard let record = leaf.lastRecord, let key = leaf.key ?? leaf.rawKey, !leaf.text.isEmpty else { continue }
            let words = KeyHints.words(key)
            let hint = KeyHints.hint(leaf.key) ?? leaf.numericEntity
            let country = leaf.key == nil && (words.last == "country" || words.suffix(2) == ["country", "code"])
            guard StandIns.placed.contains(hint ?? "") || StandIns.local.contains(hint ?? "") || country || isTimeZone(leaf) else { continue }
            let group = "\(record)\u{0}\(split.contains(record) ? qualifier(key) : "")"
            member[index] = group
            var parts = groups[group] ?? AddressParts()
            switch hint {
            case "LOCATION": if parts.city == nil { parts.city = leaf.text }
            case "REGION": if parts.region == nil { parts.region = leaf.text }
            case "POSTAL_CODE": if parts.postal == nil { parts.postal = leaf.text }
            case "LATITUDE", "COORDINATES": if parts.coordinates == nil || hint == "LATITUDE" { parts.coordinates = leaf.text }
            case "LONGITUDE": if parts.coordinates == nil { parts.coordinates = leaf.text }
            case _ where country: if parts.country == nil { parts.country = leaf.text }
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
            job.observeSpans([(leaf.text, found)])
        }
    }

    private static func detected(_ leaf: DocumentLeaf, base: [Span], gazetteer: GazetteerMatcher, detector: Detector) -> [Span] {
        leaf.numericEntity.map { [Span(range: 0..<(leaf.text as NSString).length, entity: $0, score: 1)] }
            ?? detector.combined(base, text: leaf.text, matcher: gazetteer)
    }

    private static func base(_ leaf: DocumentLeaf, stored: [Span]?) -> [Span] {
        if let stored { return stored }
        guard let entity = KeyHints.hint(leaf.key), !leaf.text.isEmpty else { return [] }
        return [Span(range: 0..<(leaf.text as NSString).length, entity: entity, score: 1)]
    }

    private static func detectBases(_ leaves: [DocumentLeaf], progress: (Stage, Int, Int) -> Void) throws -> [[Span]?] {
        let count = leaves.count
        guard count > 0 else { return [] }
        // The context model first: its findings fill only what every other detector leaves.
        let context = try ContextStage.find(leaves.map { leaf in
            leaf.numericEntity != nil || leaf.fieldName || KeyHints.hint(leaf.key) != nil || KeyHints.isStructural(leaf.key) ? nil : leaf.text
        }, progress: progress, cancelled: CancellationFlag())
        let chunkSize = max(128, (count + max(1, ProcessInfo.processInfo.activeProcessorCount) * 4 - 1) / (max(1, ProcessInfo.processInfo.activeProcessorCount) * 4))
        let chunkCount = (count + chunkSize - 1) / chunkSize
        let results = Mutex(Array<[Span]?>(repeating: nil, count: count))
        // Worker threads are outside the task, so Task.isCancelled is always false
        // there; the calling thread watches it and raises a flag they can see.
        let cancelled = CancellationFlag()
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                let detector = Detector(isCancelled: { cancelled.isSet })
                let start = chunk * chunkSize
                let end = min(count, start + chunkSize)
                var local: [[Span]?] = []
                local.reserveCapacity(end - start)
                for index in start..<end {
                    if cancelled.isSet { return }
                    let leaf = leaves[index]
                    if leaf.numericEntity != nil || KeyHints.hint(leaf.key) != nil && !leaf.text.isEmpty { local.append(nil) }
                    else if leaf.fieldName { local.append(Patterns.find(leaf.text, isCancelled: { cancelled.isSet })) }
                    else { local.append(detector.base(leaf.text, key: leaf.key, contextWords: leaf.contextWords, context: context[index] ?? [])) }
                }
                results.withLock { $0.replaceSubrange(start..<end, with: local) }
            }
            done.leave()
        }
        while done.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if Task.isCancelled { cancelled.set() }
        }
        try Scrubber.checkCancellation()
        return results.withLock { $0 }
    }
}

final class CancellationFlag: Sendable {
    private let value = Atomic(false)
    var isSet: Bool { value.load(ordering: .relaxed) }
    func set() { value.store(true, ordering: .relaxed) }
}
