import Foundation

struct DocumentLeaf {
    let text: String
    let key: String?
    let records: [Int]
    let contextWords: Set<String>
    let numericEntity: String?

    init(_ text: String, key: String? = nil, records: [Int] = [], contextWords: Set<String> = [], numericEntity: String? = nil) {
        self.text = text
        self.key = key
        self.records = records
        self.contextWords = contextWords
        self.numericEntity = numericEntity
    }
}

struct DocumentValue {
    let text: String
    let marks: [Mark]
    let unresolved: [Mark]
}

enum DocumentPipeline {
    private static let identityHints: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME", "EMAIL_ADDRESS", "USERNAME"]

    static func run(_ leaves: [DocumentLeaf], job: Job) throws -> [DocumentValue] {
        var recordFields: [Int: [String: String]] = [:]
        for leaf in leaves {
            guard let record = leaf.records.last, let hint = KeyHints.hint(leaf.key), identityHints.contains(hint), !leaf.text.isEmpty else { continue }
            recordFields[record, default: [:]][hint] = leaf.text
        }
        var owners: [Int: Persona] = [:]
        for record in recordFields.keys.sorted() {
            guard let fields = recordFields[record] else { continue }
            owners[record] = job.associateRecord(first: fields["FIRST_NAME"], last: fields["LAST_NAME"], full: fields["PERSON"], email: fields["EMAIL_ADDRESS"])
        }
        func detected(_ leaf: DocumentLeaf, gazetteer: GazetteerMatcher? = nil) -> [Span] {
            if let entity = leaf.numericEntity {
                return [Span(range: 0..<(leaf.text as NSString).length, entity: entity, score: 1)]
            }
            if let gazetteer { return job.detector.find(leaf.text, key: leaf.key, matcher: gazetteer, contextWords: leaf.contextWords) }
            return job.detector.find(leaf.text, key: leaf.key, contextWords: leaf.contextWords)
        }
        var spans = leaves.map { detected($0) }
        job.observeSpans(zip(leaves, spans).map { ($0.text, $1) })
        let gazetteer = GazetteerMatcher(job.gazetteer)
        spans = leaves.map { detected($0, gazetteer: gazetteer) }
        job.recordOriginals(zip(leaves, spans).map { ($0.text, $1) })
        var values: [DocumentValue] = []
        for (leaf, found) in zip(leaves, spans) {
            try Scrubber.checkCancellation()
            let owner = identityHints.contains(KeyHints.hint(leaf.key) ?? "") ? leaf.records.reversed().compactMap { owners[$0] }.first : nil
            let (text, marks): (String, [Mark])
            if let entity = leaf.numericEntity {
                text = job.numericLexeme(leaf.text, entity: entity)
                marks = [Mark(range: 0..<(text as NSString).length, entity: entity)]
            } else {
                (text, marks) = try job.apply(leaf.text, spans: found, owner: owner)
            }
            values.append(DocumentValue(text: text, marks: marks, unresolved: []))
        }
        for _ in 0..<3 {
            let originals = OriginalMatcher(job)
            var changed = false
            for index in values.indices {
                try Scrubber.checkCancellation()
                let previous = values[index]
                let (text, marks, unresolved) = try Correction.run(previous.text, marks: previous.marks, job: job, matcher: originals, gazetteer: gazetteer, passes: 1)
                if text != previous.text { changed = true }
                values[index] = DocumentValue(text: text, marks: marks, unresolved: unresolved)
            }
            if !changed { break }
        }
        return values
    }
}
