import Foundation
import Synchronization

struct DocumentLeaf: Sendable {
    let text: String
    let key: String?
    private let records: RecordPath
    var lastRecord: Int? { records.last }
    func owner<Value>(in owners: [Value?]) -> Value? { records.owner(in: owners) }
    let contextWords: Set<String>
    let numericEntity: String?

    init(_ text: String, key: String? = nil, records: [Int] = [], contextWords: Set<String> = [], numericEntity: String? = nil) {
        self.text = text
        self.key = key
        self.records = RecordPath(records)
        self.contextWords = contextWords
        self.numericEntity = numericEntity
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
    private static let identityHints: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME", "EMAIL_ADDRESS", "USERNAME"]

    static func run(_ leaves: [DocumentLeaf], job: Job, forceFullDetection: Bool = false) throws -> [DocumentValue] {
        var (gazetteer, values, emptyBases) = try detectAndPrepare(leaves, job: job)
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
                let newMatcher = Matcher(newOriginals)
                for index in values.indices where !active[index] {
                    let value = values[index]
                    guard !value.marks.contains(where: { $0.range == 0..<(value.text as NSString).length }) else { continue }
                    if !newMatcher.matches(in: value.text).isEmpty { active[index] = true }
                }
            }
        }
        return values
    }
    private static func detectAndPrepare(_ leaves: [DocumentLeaf], job: Job) throws -> (GazetteerMatcher, [DocumentValue], [Bool]) {
        let bases = try detectBases(leaves)
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
        let owners = associateOwners(leaves, job: job)
        observeInitial(leaves, bases: bases, job: job)
        let gazetteer = GazetteerMatcher(job.gazetteer, nameParts: job.nameParts)
        job.setReplacementRecording(false)
        defer { job.setReplacementRecording(true) }
        var values: [DocumentValue] = []
        for (leaf, stored) in zip(leaves, bases) {
            try Scrubber.checkCancellation()
            let found = detected(leaf, base: base(leaf, stored: stored), gazetteer: gazetteer, detector: job.detector)
            job.recordOriginals([(leaf.text, found)])
            let owner = identityHints.contains(KeyHints.hint(leaf.key) ?? "") ? leaf.owner(in: owners) : nil
            let (text, marks): (String, [Mark])
            if let entity = leaf.numericEntity {
                text = job.numericLexeme(leaf.text, entity: entity)
                marks = [Mark(range: 0..<(text as NSString).length, entity: entity)]
            } else {
                (text, marks) = try job.apply(leaf.text, spans: found, owner: owner)
            }
            values.append(DocumentValue(text: text, marks: marks, unresolved: []))
        }
        return (gazetteer, values)
    }

    private static func associateOwners(_ leaves: [DocumentLeaf], job: Job) -> [Persona?] {
        let maxRecord = leaves.compactMap(\.lastRecord).max() ?? -1
        guard maxRecord >= 0 else { return [] }
        var recordFields = Array<IdentityFields?>(repeating: nil, count: maxRecord + 1)
        for leaf in leaves {
            guard let record = leaf.lastRecord, let hint = KeyHints.hint(leaf.key), identityHints.contains(hint), !leaf.text.isEmpty else { continue }
            if recordFields[record] == nil { recordFields[record] = IdentityFields() }
            recordFields[record]?.set(leaf.text, for: hint)
        }
        let identities: [Int?] = recordFields.enumerated().map { index, fields in
            guard let fields, fields.first != nil || fields.last != nil || fields.full != nil else { return nil }
            return index
        }
        for leaf in leaves where KeyHints.hint(leaf.key) == "EMAIL_ADDRESS" && !leaf.text.isEmpty {
            if let record = leaf.owner(in: identities), recordFields[record]?.email == nil {
                recordFields[record]?.email = leaf.text
            }
        }
        var owners = Array<Persona?>(repeating: nil, count: maxRecord + 1)
        for record in recordFields.indices {
            guard let fields = recordFields[record] else { continue }
            owners[record] = job.associateRecord(first: fields.first, last: fields.last, full: fields.full, email: fields.email)
        }
        return owners
    }

    private static func observeInitial(_ leaves: [DocumentLeaf], bases: [[Span]?], job: Job) {
        for (leaf, stored) in zip(leaves, bases) {
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

    private static func detectBases(_ leaves: [DocumentLeaf]) throws -> [[Span]?] {
        let count = leaves.count
        guard count > 0 else { return [] }
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
                    else { local.append(detector.base(leaf.text, key: leaf.key, contextWords: leaf.contextWords)) }
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

private final class CancellationFlag: Sendable {
    private let value = Atomic(false)
    var isSet: Bool { value.load(ordering: .relaxed) }
    func set() { value.store(true, ordering: .relaxed) }
}
