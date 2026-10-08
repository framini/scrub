import Foundation

/// The values a JSON document gives the pipeline, and the document written
/// again from what the pipeline made of them. A .json file is one; so is each
/// body written inside other text (a curl command's, a log line's), and a
/// string that holds a document of its own ("body": "{\"password\": …}") is
/// read as one inside the document around it, to a limit (see `deepest`). Only
/// the tokens whose value changed are written again (see `JSONSource`).
final class JSONDocument {
    let source: JSONSource
    /// The leaf each string or number value went to, and each key, by path.
    private var valueIDs: [String: Int] = [:]
    private var keyIDs: [String: Int] = [:]
    /// Keys that name a field ("password"): a value written into one is
    /// replaced, but the name is never replaced whole for being the same word.
    private var fieldKeys: Set<String> = []
    /// Strings that hold a document of their own, by path, and those that hold one in base64.
    private var nested: [String: JSONDocument] = [:]
    private var encoded: Set<String> = []
    /// How many documents deep one is read inside another, how many objects and lists deep
    /// one may start (each adds up to 64, read through the same frames), and how much text,
    /// in UTF-16 units, the documents strings hold may decode to in one scrub. A string
    /// holding one past any of them is replaced whole, as a secret is (see `Embedding`).
    private static let deepest = 16
    private static let deepestLevel = 192
    private static let decodable = 64 << 20
    /// How many objects and lists deep its root sits in the documents around it.
    private var level = 0
    /// Numbers no key names, by path, outside fields that say they hold no one's data ("count"):
    /// one that writes a number replaced elsewhere takes its stand-in (see `render`).
    private var looseNumbers: Set<String> = []

    private init(_ source: JSONSource) { self.source = source }

    /// What a string holds, read as a document: none; a document, sent as a string or in
    /// base64; or one Scrub reads no further, past the limits or in base64 that reads as no
    /// document. That one is replaced whole, as a secret's opaque value: nothing it holds is
    /// written back unread, and the review lists it.
    enum Embedding {
        case none, opaque
        case document(JSONDocument, encoded: Bool)
    }
    /// A string holding a document read no further: its stand-in is a secret's.
    static func opaque(_ string: String, records: [Int]) -> DocumentLeaf { DocumentLeaf(string, key: "secret", records: records) }

    /// What a string holding `child` writes now, unquoted: the document as rendered, in base64
    /// again where it came so, under one mark over the whole as what it holds can't be shown.
    /// Nil where nothing changed. A JSON string writes it quoted; a table's cell as it is.
    static func written(_ child: JSONDocument, encoded: Bool, _ values: [DocumentValue], numbers: [String: (text: String, mark: Mark)]? = nil) -> (String, [Mark])? {
        let (inner, marks) = numbers.map { child.render(values, numbers: $0) } ?? child.render(values)
        if encoded {
            guard inner != child.source.text else { return nil }
            let text = Data(inner.utf8).base64EncodedString()
            return (text, marks.first.map { [$0.moved(to: 0..<(text as NSString).length)] } ?? [])
        }
        return !inner.unicodeScalars.elementsEqual(child.source.text.unicodeScalars) || !marks.isEmpty ? (inner, marks) : nil
    }

    /// What every document of one scrub shares: the leaves they add, the
    /// records they number, and the keys they write.
    final class Collector {
        private var items: [DocumentLeaf] = []
        /// Every value collected, each field's identifier decided across all its values (see `identifyColumns`).
        var leaves: [DocumentLeaf] {
            identifyColumns()
            return items
        }
        var names: [String] = []
        var nextRecord = 0

        /// `key`: what the text around a body calls it (`credentials = {…}`).
        func add(_ source: JSONSource, records: [Int] = [], key: String? = nil) -> JSONDocument {
            let document = JSONDocument(source)
            collect(document, source.root, key: key, path: "", records: records, keys: key.map { [$0] } ?? [], depth: 0)
            return document
        }
        /// A number no key names, kept until its whole field is read.
        private struct BareNumber {
            let document: JSONDocument
            let path: String
            let number: String
            let key: String?
            let records: [Int]
            let field: String
        }
        private var bareNumbers: [BareNumber] = []
        /// Values under a bare "name", by path, written as a person's though nothing says they are (see `KeyHints.writtenAsName`).
        private var unsureNames: Set<String> = []
        private var doubtedNames: Set<String> = []
        /// Every value each field writes, strings and numbers alike, and the strings' leaves.
        private var population: [String: [String]] = [:]
        private var fieldStrings: [String: [Int]] = [:]
        /// Each field's identifier, decided once across every value it writes, strings and numbers
        /// alike (see `Fields.column`): its strings take the decision, and its numbers no key named
        /// that pass the identifier's check become values to replace, written as numbers.
        private func identifyColumns() {
            guard !population.isEmpty else { return }
            defer { population = [:]; fieldStrings = [:]; bareNumbers = [] }
            let numbers = Dictionary(grouping: bareNumbers, by: \.field)
            for (field, values) in population {
                let recognizer = Fields.column(values)
                for index in fieldStrings[field] ?? [] { items[index].column = recognizer?.name ?? "" }
                guard let recognizer else { continue }
                for item in numbers[field] ?? [] where Recognizers.candidates(item.number).contains(where: { $0.name == recognizer.name }) {
                    item.document.valueIDs[item.path] = items.count
                    var leaf = DocumentLeaf(item.number, key: item.key, records: item.records, numericEntity: recognizer.entity)
                    leaf.field = item.field
                    leaf.column = recognizer.name
                    items.append(leaf)
                }
            }
        }

        /// Keys whose value says what kind of thing a record's other values are ("type": "CPR").
        private static let kindKeys: Set<String> = ["type", "kind", "object", "idtype", "idkind", "documenttype", "doctype", "documentkind", "identifiertype", "identificationtype", "identitytype", "scheme", "idscheme", "typecode", "category", "system"]
        /// `typed`: the words a record's own kind field writes, which name its other values as a key would.
        private func collect(_ document: JSONDocument, _ value: JSONValue, key: String?, path: String, records: [Int], keys: [String], depth: Int, listed: Bool = false, typed: Set<String> = []) {
            // Each kind of value read in its own frame: a document nested sixty levels deep recurses
            // through these, and only an object's reading needs a large one.
            switch value {
            case .object(let pairs): collectObject(document, pairs, key: key, path: path, records: records, keys: keys, depth: depth, listed: listed, typed: typed)
            case .array(let values): collectArray(document, values, key: key, path: path, records: records, keys: keys, depth: depth, typed: typed)
            case .string(let string): collectString(document, string, key: key, path: path, records: records, keys: keys, depth: depth, typed: typed)
            case .number(let number): collectNumber(document, number, key: key, path: path, records: records, keys: keys, typed: typed)
            default: break
            }
        }
        @inline(never)
        private func collectObject(_ document: JSONDocument, _ pairs: [(String, JSONValue)], key: String?, path: String, records: [Int], keys: [String], depth: Int, listed: Bool, typed: Set<String>) {
            names += pairs.map(\.0)
            // A record that says what its number is ({"type": "CPR", "number": "…"}) names it there.
            let kind = Set(pairs.flatMap { pair -> [String] in
                guard Self.kindKeys.contains(KeyHints.words(pair.0).joined()), let text = pair.1.stringValue, text.utf16.count <= 64 else { return [] }
                return KeyHints.words(text)
            })
            // So does a coded type ({"type": {"text": "Passport Number"}, "value": …}), as a field's name would.
            let typeNames = Self.typeNames(pairs)
            let referred = Self.referredRole(pairs, parent: keys.last)
            // A person's own identifiers: those of their record, or of a reference to them.
            let documentID = ObjectIdentifier(document)
            if Self.identifiesPerson(pairs, parent: keys.last), let index = pairs.firstIndex(where: { $0.0 == "identifier" }) {
                personIdentifiers.insert(Place(document: documentID, path: path + "/" + String(index)))
            }
            let ownIdentifier = personIdentifiers.contains(Place(document: documentID, path: path))
                || path.lastIndex(of: "/").map { personIdentifiers.contains(Place(document: documentID, path: String(path[..<$0]))) } == true
            nextRecord += 1
            let ancestry = KeyHints.isWrapper(pairs.map(\.0)) && !records.isEmpty ? records : records + [nextRecord]
            let named = pairs.compactMap { pair in pair.1.stringValue.map { (pair.0, $0) } }
            // A name's parts side by side under keys of their own ({"fn": "TOMASZ", "ln": "WISNIEWSKI"}).
            let nameParts = KeyHints.nameParts(named, parent: key)
            // A name's given names beside its family name ({"family": "Lind", "given": ["Ama", "Rose"]})
            // are one person's, not several people's: the first is the record's first name.
            let surnamed = pairs.contains { if case .array = $0.1 { true } else { false } } && named.contains { pair in
                KeyHints.hint(KeyHints.resolve(pair.0, parent: key, listed: listed, value: pair.1)) == "LAST_NAME"
            }
            for (index, pair) in pairs.enumerated() {
                let childPath = path + "/" + String(index)
                // A field's plain name ("password") is read for what a pattern or a value
                // found elsewhere writes in it ("quillharbor_token"); any other key as a value.
                let fieldName = KeyHints.isFieldName(pair.0) && !KeyHints.holdsData(pair.0)
                document.keyIDs[childPath] = items.count
                if fieldName { document.fieldKeys.insert(childPath) }
                items.append(DocumentLeaf(pair.0, fieldName: fieldName))
                var inherited: String?
                // A UUID a record's type calls its number is the system's own key, kept as every
                // UUID is: a record number of any other shape is replaced.
                let kindField = KeyHints.typedField(pair.0, names: typeNames).flatMap { field in
                    KeyHints.hint(field) == nil && pair.1.stringValue.map(RecordIDs.isUUID) == true ? nil : field
                }
                switch pair.1 {
                case .object, .array: inherited = KeyHints.namedField(pair.0, siblings: named) ?? kindField ?? KeyHints.resolveContainer(pair.0, parent: key, listed: listed)
                default: inherited = KeyHints.namedField(pair.0, siblings: named) ?? kindField ?? KeyHints.resolve(pair.0, parent: key, listed: listed, value: pair.1.stringValue)
                }
                // Whatever its system calls it, a person's identifier is theirs; a UUID is the system's own key, kept as every UUID is.
                if ownIdentifier, pair.0 == "value", KeyHints.hint(inherited) == nil, !RecordIDs.isPersonKey(inherited),
                   case .string(let text) = pair.1, !RecordIDs.isUUID(text) { inherited = "person_id" }
                if KeyHints.hint(inherited) == nil, case .string(let text) = pair.1 {
                    // A reference's display names what it points to: a person in a role, or a business or a place.
                    if let referred, pair.0 == "display" { inherited = referred }
                    // "Patient/5b0e7c2a": a record's type and its ID in the document's store, no one's handle.
                    if pair.0 == "reference", !TextRanges.matches(Self.storeReference, in: text).isEmpty { inherited = "reference_id" }
                }
                // The record's ancestors say whose it is too: "documents": [{"analysis": {"extracted_data": {"expiration_date": …}}}].
                if let expiry = KeyHints.expiry(pair.0, siblings: pairs.map(\.0), parent: ([key ?? ""] + keys).joined(separator: "_"), kind: kind.union(typed)) { inherited = expiry }
                // A document's own number in a record whose kind names the document ({"object": "driver_license", "number": …}).
                if KeyHints.hint(inherited) == nil, KeyHints.isDocumentNumber(pair.0), !kind.isDisjoint(with: KeyHints.documentKinds) { inherited = "document_number" }
                if KeyHints.hint(inherited) == nil, let part = nameParts[pair.0] { inherited = part }
                if KeyHints.hint(inherited) == nil, let born = KeyHints.birthField(pair.0, value: pair.1.stringValue ?? pair.1.numberText, siblings: named, kind: kind) { inherited = born }
                if KeyHints.isBareName(pair.0), case .string(let name) = pair.1,
                   !KeyHints.bareNameIsPerson(name, siblings: pairs.map(\.0), parent: key, values: named.map(\.1)) {
                    inherited = nil
                    if KeyHints.writtenAsName(name, parent: key) { unsureNames.insert(childPath) }
                    else if KeyHints.writtenAsName(name, parent: nil), KeyHints.onlyNames(name) { doubtedNames.insert(childPath) }
                }
                // The kind a record says reaches its own values, and through a slot ("number": {"value": …}, "number": […]) the values it wraps.
                let reaches: Bool
                switch pair.1 {
                case .object, .array: reaches = Self.isSlot(pair.0)
                default: reaches = true
                }
                let reached = Self.kindKeys.contains(KeyHints.words(pair.0).joined()) || !reaches ? [] : kind.union(typed)
                if surnamed, case .array(let values) = pair.1, KeyHints.hint(inherited) == "FIRST_NAME" {
                    collectArray(document, values, key: inherited, path: childPath, records: ancestry, keys: keys + [pair.0], depth: depth, typed: reached, given: true)
                } else {
                    collect(document, pair.1, key: inherited, path: childPath, records: ancestry, keys: keys + [pair.0], depth: depth, typed: reached)
                }
            }
        }
        private static let cities = Set(Places.all.map { $0.city.lowercased() } + Places.abroad.map { $0.city.lowercased() })
        /// A country, a region or a city a list of places names ("New Zealand", "San Mateo"): no one.
        private static func isPlace(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return cities.contains(trimmed.lowercased()) || Places.region(trimmed) != nil || Places.code(trimmed) != nil
        }
        /// `given`: the list is one person's given names, the first the record's (see `collectObject`).
        @inline(never)
        private func collectArray(_ document: JSONDocument, _ values: [JSONValue], key: String?, path: String, records: [Int], keys: [String], depth: Int, typed: Set<String>, given: Bool = false) {
            let pair = JSONFile.coordinateKeys(key, values)
            // A list of names under a key that says nothing of them ("household_members": ["Halina Lis", …]):
            // each is a person's, as a bare "name" written as one is (see `KeyHints.writtenAsName`).
            if KeyHints.hint(key) == nil, !KeyHints.isStructural(key), !values.isEmpty,
               values.allSatisfy({ if case .string(let text) = $0 { KeyHints.writtenAsName(text, parent: key) && !Self.isPlace(text) } else { false } }) {
                for index in values.indices { unsureNames.insert(path + "/" + String(index)) }
            }
            for (index, child) in values.enumerated() {
                // Several names or emails in one list may be several people's; one is the record's own.
                let several = values.count > 1 && KeyHints.hint(key).map({ ["PERSON", "FIRST_NAME", "LAST_NAME", "EMAIL_ADDRESS", "USERNAME"].contains($0) }) == true
                collect(document, child, key: pair?[index] ?? key, path: path + "/" + String(index), records: several && !(given && index == 0) ? [] : records, keys: keys, depth: depth, listed: true, typed: typed)
            }
        }
        @inline(never)
        private func collectString(_ document: JSONDocument, _ string: String, key: String?, path: String, records: [Int], keys: [String], depth: Int, typed: Set<String>) {
            guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            switch embed(string, level: document.level + path.utf8.lazy.filter { $0 == 47 }.count, key: key, records: records, keys: keys, depth: depth, typed: typed) {
            case .document(let child, let base64):
                document.nested[path] = child
                if base64 { document.encoded.insert(path) }
                return
            case .opaque:
                document.valueIDs[path] = items.count
                items.append(JSONDocument.opaque(string, records: records))
                return
            case .none: break
            }
            document.valueIDs[path] = items.count
            var leaf = DocumentLeaf(string, key: key, records: records, contextWords: Set(keys.flatMap { KeyHints.words($0) }))
            leaf.namingWords = Self.naming(keys, typed)
            leaf.field = keys.joined(separator: ".")
            leaf.unsureName = unsureNames.contains(path)
            leaf.doubtedName = doubtedNames.contains(path)
            population[leaf.field ?? "", default: []].append(leaf.seen)
            fieldStrings[leaf.field ?? "", default: []].append(items.count)
            items.append(leaf)
        }
        @inline(never)
        private func collectNumber(_ document: JSONDocument, _ number: String, key: String?, path: String, records: [Int], keys: [String], typed: Set<String>) {
            // Counts and measurements can pass an identifier's checksum by chance.
            // Exclude them from both individual detection and column inference.
            if DocumentLeaf.holdsNoOnesData(key)
                || KeyHints.hint(key) == nil && KeyHints.words(key).last.map(Self.measures.contains) == true { return }
            population[keys.joined(separator: "."), default: []].append(number)
            guard let entity = JSONFile.numericEntity(key: key, number: number, context: Self.naming(keys, typed)) else {
                if (7...20).contains(number.count), number.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    bareNumbers.append(BareNumber(document: document, path: path, number: number, key: key, records: records, field: keys.joined(separator: ".")))
                }
                if !DocumentLeaf.holdsNoOnesData(keys.last), KeyHints.words(keys.last).last.map(Self.measures.contains) != true { document.looseNumbers.insert(path) }
                return
            }
            document.valueIDs[path] = items.count
            var leaf = DocumentLeaf(number, key: key, records: records, numericEntity: entity)
            // Its stand-in is of the kind its record names, as a string's is ({"type":"ABA","number":111900659}).
            leaf.namingWords = Self.naming(keys, typed)
            leaf.field = keys.joined(separator: ".")
            items.append(leaf)
        }
        /// Keys whose number measures something ("ratio": 2128675309.0): never a value written again.
        private static let measures: Set<String> = ["ratio", "rate", "percent", "percentage", "average", "avg", "mean", "sum", "min", "max", "size", "length", "width", "height",
                                                    "weight", "duration", "latency", "ms", "seconds", "bytes"]
        /// Keys that only hold a value, naming nothing of their own ("number", "id_value").
        private static let slots: Set<String> = ["number", "num", "no", "nr", "value", "val", "id", "identifier", "ident", "code", "digits", "text", "data", "document", "doc"]
        /// The words that may name an identifier under `keys`: the innermost key's, and where it
        /// is only a slot, those of the keys around it and of its record's kind field. A batch
        /// number under "medicare" is a batch's; "medicare": {"number": …} is the card's.
        /// Outward from the innermost key, through slots, up to and with the nearest key that names something:
        /// "medicare": {"batch": {"number": …}} is the batch's number.
        /// The record's kind field names a value whose own key is a slot.
        static func naming(_ keys: [String], _ typed: Set<String>) -> Set<String> {
            var words: Set<String> = keys.last.map(isSlot) ?? true ? typed : []
            for key in keys.reversed() {
                words.formUnion(KeyHints.words(key))
                if !isSlot(key) { break }
            }
            return words
        }
        static func isSlot(_ key: String) -> Bool {
            let words = KeyHints.words(key)
            return !words.isEmpty && words.allSatisfy(slots.contains)
        }
        private var decoded = 0
        /// A value outside any document (a table's cell) that holds one, read as a JSON string holding it is.
        func embed(_ string: String, key: String?, records: [Int], keys: [String]) -> Embedding {
            embed(string, level: 0, key: key, records: records, keys: keys, depth: 0, typed: [])
        }
        /// A body sent as a string, or as base64: its own document, read under the key that holds it,
        /// `level` objects and lists deep. Past the limits it is read no further (see `Embedding`).
        private func embed(_ string: String, level: Int, key: String?, records: [Int], keys: [String], depth: Int, typed: Set<String>) -> Embedding {
            guard let (text, base64) = Self.document(in: string) else { return .none }
            // Text that only opens like a document is read as text, unless base64 hid it.
            guard let inner = try? JSONSource.read(text) else { return base64 ? .opaque : .none }
            guard Self.holds(inner.root) else { return .none }
            let units = text.utf16.count
            guard depth < JSONDocument.deepest, level <= JSONDocument.deepestLevel, decoded + units <= JSONDocument.decodable else { return .opaque }
            decoded += units
            let child = JSONDocument(inner)
            child.level = level
            collect(child, inner.root, key: key, path: "", records: records, keys: keys, depth: depth + 1,
                    typed: keys.last.map(Self.isSlot) ?? false ? typed : [])
            return .document(child, encoded: base64)
        }
        /// What a record's own kind says it is, each read as a field's name would be (see `KeyHints.typedField`):
        /// a coded type's text, each of its codings' display and the key its code stands for, and the last
        /// part of its system's or its extension's URI. {"system": "…/sid/us-ssn", "type": {"coding":
        /// [{"code": "DL", "display": "Driver's license number"}], "text": …}}. The texts stay as written.
        static func typeNames(_ pairs: [(String, JSONValue)]) -> [String] {
            var names: [String] = []
            for (key, value) in pairs {
                switch key {
                case "type":
                    guard case .object(let concept) = value else { continue }
                    for (part, member) in concept {
                        if part == "text", let text = member.stringValue { names.append(text) }
                        guard part == "coding", case .array(let codings) = member else { continue }
                        for case .object(let coding) in codings {
                            let field = { (name: String) in coding.first { $0.0 == name }?.1.stringValue }
                            if let display = field("display") { names.append(display) }
                            // A code means what its table says: one of the identifier types' table, or written with none.
                            if let code = field("code"), let key = KeyHints.identifierTypeCodes[code], field("system").map({ $0.hasSuffix("0203") }) ?? true { names.append(key) }
                        }
                    }
                case "system", "url":
                    if let name = value.stringValue.flatMap(KeyHints.uriName) { names.append(name) }
                default: continue
                }
            }
            return names
        }
        /// The key a reference's display is read under: a role, where the record points to a person
        /// by its reference ("Patient/…", "Practitioner/…") or under a key that names one ("subject",
        /// "beneficiary"), so the detector reads a written name there; a business's, where it points
        /// to anything else ("Organization/…", "Location/…") or under "insurer" or "location", so
        /// the name of a practice or a ward ("Clinic East Wing") stays as written.
        static func referredRole(_ pairs: [(String, JSONValue)], parent: String?) -> String? {
            guard pairs.contains(where: { $0.0 == "display" }) else { return nil }
            if let reference = pairs.first(where: { $0.0 == "reference" })?.1.stringValue,
               let match = TextRanges.matches(referenceType, in: reference).first {
                let type = TextRanges.substring(reference, match.range(at: 1).location..<NSMaxRange(match.range(at: 1)))
                if let role = typeRole(type) { return role }
            }
            // A reference no type is read from (a contained "#p1", a "urn:uuid:…", an identifier
            // alone) says it in its own "type": "Practitioner", or the type's full address.
            if let type = pairs.first(where: { $0.0 == "type" })?.1.stringValue,
               let name = type.split(separator: "/").last.map(String.init), let role = typeRole(name) {
                return role
            }
            guard let parent else { return nil }
            let word = KeyHints.words(parent).joined()
            if referringPeople.contains(word) { return KeyHints.isRole(parent) ? parent : "patient" }
            return referringNoOne.contains(word) ? "institution" : nil
        }
        /// A person's role for a record type that names one, a business's for one known to name none
        /// ("Organization", "Location", "Encounter"), and nil for a type no record standard lists ("Human"),
        /// whose display the key it is under still names.
        private static func typeRole(_ type: String) -> String? {
            personTypes.contains(type) ? "patient" : otherTypes.contains(type) ? "institution" : nil
        }
        /// The record types a reference names something other than a person by: every resource the
        /// health record standard's fourth and fifth releases list, but its people's and those that may
        /// stand for one (a study's subject, a relative's history), whose display the key they are under names.
        private static let otherTypes: Set<String> = [
            "Account", "ActivityDefinition", "ActorDefinition", "AdministrableProductDefinition", "AdverseEvent", "AllergyIntolerance",
            "Appointment", "AppointmentResponse", "ArtifactAssessment", "AuditEvent", "Basic", "Binary", "BiologicallyDerivedProduct",
            "BiologicallyDerivedProductDispense", "BodyStructure", "Bundle", "CanonicalResource", "CapabilityStatement", "CarePlan", "CareTeam",
            "CatalogEntry", "ChargeItem", "ChargeItemDefinition", "Citation", "Claim", "ClaimResponse", "ClinicalImpression",
            "ClinicalUseDefinition", "CodeSystem", "Communication", "CommunicationRequest", "CompartmentDefinition", "Composition", "ConceptMap",
            "Condition", "ConditionDefinition", "Consent", "Contract", "Coverage", "CoverageEligibilityRequest", "CoverageEligibilityResponse",
            "DetectedIssue", "Device", "DeviceAssociation", "DeviceDefinition", "DeviceDispense", "DeviceMetric", "DeviceRequest", "DeviceUsage",
            "DeviceUseStatement", "DiagnosticReport", "DocumentManifest", "DocumentReference", "DomainResource", "EffectEvidenceSynthesis",
            "Encounter", "EncounterHistory", "Endpoint", "EnrollmentRequest", "EnrollmentResponse", "EpisodeOfCare", "EventDefinition", "Evidence",
            "EvidenceReport", "EvidenceVariable", "ExampleScenario", "ExplanationOfBenefit", "Flag", "FormularyItem",
            "GenomicStudy", "Goal", "GraphDefinition", "Group", "GuidanceResponse", "HealthcareService", "ImagingSelection", "ImagingStudy",
            "Immunization", "ImmunizationEvaluation", "ImmunizationRecommendation", "ImplementationGuide", "Ingredient", "InsurancePlan",
            "InventoryItem", "InventoryReport", "Invoice", "Library", "Linkage", "List", "Location", "ManufacturedItemDefinition", "Measure",
            "MeasureReport", "Media", "Medication", "MedicationAdministration", "MedicationDispense", "MedicationKnowledge", "MedicationRequest",
            "MedicationStatement", "MedicinalProduct", "MedicinalProductAuthorization", "MedicinalProductContraindication",
            "MedicinalProductDefinition", "MedicinalProductIndication", "MedicinalProductIngredient", "MedicinalProductInteraction",
            "MedicinalProductManufactured", "MedicinalProductPackaged", "MedicinalProductPharmaceutical", "MedicinalProductUndesirableEffect",
            "MessageDefinition", "MessageHeader", "MetadataResource", "MolecularDefinition", "MolecularSequence", "NamingSystem", "NutritionIntake",
            "NutritionOrder", "NutritionProduct", "Observation", "ObservationDefinition", "OperationDefinition", "OperationOutcome", "Organization",
            "OrganizationAffiliation", "PackagedProductDefinition", "Parameters", "PaymentNotice", "PaymentReconciliation", "Permission",
            "PlanDefinition", "Procedure", "Provenance", "Questionnaire", "QuestionnaireResponse", "RegulatedAuthorization", "RequestGroup",
            "RequestOrchestration", "Requirements", "ResearchDefinition", "ResearchElementDefinition", "ResearchStudy",
            "Resource", "RiskAssessment", "RiskEvidenceSynthesis", "Schedule", "SearchParameter", "ServiceRequest", "Slot", "Specimen",
            "SpecimenDefinition", "StructureDefinition", "StructureMap", "Subscription", "SubscriptionStatus", "SubscriptionTopic", "Substance",
            "SubstanceDefinition", "SubstanceNucleicAcid", "SubstancePolymer", "SubstanceProtein", "SubstanceReferenceInformation",
            "SubstanceSourceMaterial", "SubstanceSpecification", "SupplyDelivery", "SupplyRequest", "Task", "TerminologyCapabilities", "TestPlan",
            "TestReport", "TestScript", "Transport", "ValueSet", "VerificationResult", "VisionPrescription"]
        /// Where a person's "identifier" sits: in each document, the path of the object or list it is.
        private struct Place: Hashable { let document: ObjectIdentifier; let path: String }
        private var personIdentifiers: Set<Place> = []
        /// Whether a record's "identifier" names a person: the record is one ("resourceType": "Patient"),
        /// or a reference to one, by its type ("Patient/…") or, with none, by the key it is under ("subject").
        static func identifiesPerson(_ pairs: [(String, JSONValue)], parent: String?) -> Bool {
            if let type = pairs.first(where: { $0.0 == "resourceType" })?.1.stringValue { return people.contains(type) }
            guard let parent, referringPeople.contains(KeyHints.words(parent).joined()) else { return false }
            guard let reference = pairs.first(where: { $0.0 == "reference" })?.1.stringValue,
                  let match = TextRanges.matches(referenceType, in: reference).first else {
                return pairs.first(where: { $0.0 == "type" })?.1.stringValue.flatMap { $0.split(separator: "/").last }.map { people.contains(String($0)) } ?? true
            }
            return people.contains(TextRanges.substring(reference, match.range(at: 1).location..<NSMaxRange(match.range(at: 1))))
        }
        /// The record types that are a person, whose identifiers are theirs (a role's are the role's).
        private static let people: Set<String> = ["Patient", "Practitioner", "RelatedPerson", "Person"]
        /// The record types a reference names a person by.
        private static let personTypes: Set<String> = ["Patient", "Practitioner", "PractitionerRole", "RelatedPerson", "Person"]
        /// Keys whose reference is to a person. A "provider" may be a practice as often as a
        /// practitioner, so only its reference's type says it is one ("Practitioner/…").
        private static let referringPeople: Set<String> = ["patient", "subject", "beneficiary", "subscriber", "policyholder", "practitioner", "requester", "performer", "recorder",
                                                           "asserter", "author", "individual", "enterer", "informant", "attester"]
        /// Keys whose reference is to an organisation or a place.
        private static let referringNoOne: Set<String> = ["organization", "organisation", "managingorganization", "serviceprovider", "insurer", "payor", "coverage", "location",
                                                          "facility", "custodian", "assigner", "partof"]
        /// A reference by type to a record, alone ("Patient/5b0e7c2a"), at a server ("https://…/Patient/5b0e7c2a"), or by a search ("Practitioner?identifier=…").
        private static let referenceType = TextPattern(#"(?:^|/)([A-Z][A-Za-z]+)(?:/[A-Za-z0-9.-]{1,64}(?:/_history/[A-Za-z0-9.-]{1,64})?$|\?)"#)
        /// A reference by type to a record in the document's own store, alone: "Patient/5b0e7c2a", "Encounter/42/_history/2".
        private static let storeReference = TextPattern(#"^[A-Z][A-Za-z]+/[A-Za-z0-9.-]{1,64}(?:/_history/[A-Za-z0-9.-]{1,64})?$"#)
        /// The document a string writes: itself when it opens as one, or what its base64 decodes to.
        private static func document(in string: String) -> (String, Bool)? {
            guard let first = string.first(where: { !$0.isWhitespace }) else { return nil }
            if first == "{" || first == "[" { return (string, false) }
            guard string.utf16.count >= 16, string.utf16.count % 4 == 0,
                  string.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }),
                  let data = Data(base64Encoded: string), let text = String(data: data, encoding: .utf8) else { return nil }
            let opening = text.first(where: { !$0.isWhitespace })
            return opening == "{" || opening == "[" ? (text, true) : nil
        }
        private static func holds(_ value: JSONValue) -> Bool {
            switch value {
            case .object(let pairs): return !pairs.isEmpty
            case .array(let members): return !members.isEmpty
            default: return false
            }
        }
    }

    /// Each key's own long digits written as drawn (see `JSONFile.drawDigits`), in this document and those it holds.
    func writeKeyDigits(_ values: inout [DocumentValue], drawn: [String: String]) {
        guard !drawn.isEmpty else { return }
        for id in keyIDs.values { values[id] = JSONFile.rewritingOwnText(values[id]) { JSONFile.replaceDigits($0, drawn: drawn) } }
        for child in nested.values { child.writeKeyDigits(&values, drawn: drawn) }
    }

    /// `number` with each digit drawn again from `seed`, the first never a zero:
    /// its sign, point and exponent stay, so it is still a JSON number.
    static func numberShaped(like number: String, from seed: String) -> String {
        var state = seed.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
        var output = "", first = true
        for character in number {
            guard character.isASCII, character.isNumber else { output.append(character); continue }
            state = state &* 6364136223846793005 &+ 1442695040888963407
            var digit = Int(state >> 33) % 10
            if first, digit == 0, character != "0" { digit = 1 + Int(state >> 40) % 9 }
            if first, character == "0" { digit = 0 }
            output += String(digit)
            first = false
        }
        return output == number ? String(number.dropLast()) + String(((Int(String(number.last!)) ?? 0) + 1) % 10) : output
    }
    /// Kinds read off words, which a key's own word may only look like: a middle name "The" in "lengthOfTheCurrentLease".
    private static let wordKinds: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME", "INITIALS", "LOCATION", "REGION", "ADDRESS", "EMPLOYER"]
    /// A key as scrubbed, each name matched inside one of its words (a letter or a digit runs on
    /// at either end) written back as it was: a key's word is no name. A secret, an email or an
    /// ID written into a key ("quillharborMetric") is still replaced. Nil where a name can't be written back.
    private static func keyWritten(_ value: DocumentValue) -> DocumentValue? {
        let ns = value.text as NSString
        func joins(_ at: Int) -> Bool {
            guard at >= 0, at < ns.length, let scalar = Unicode.Scalar(ns.character(at: at)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        let inside = value.marks.filter { wordKinds.contains($0.entity) && !$0.range.isEmpty && (joins($0.range.lowerBound - 1) || joins($0.range.upperBound)) }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        guard !inside.isEmpty else { return value }
        guard inside.allSatisfy({ $0.original != nil }) else { return nil }
        let edits = inside.map { (range: $0.range, value: $0.original ?? "") }
        return DocumentValue(text: TextRanges.apply(edits, to: value.text).0, marks: TextRanges.shift(value.marks, by: edits), unresolved: [])
    }
    /// A JSON number's parts as written: its sign, its digits before and after the point, and its exponent's text and value.
    private static func numberParts(_ number: String) -> (negative: Bool, whole: Substring, fraction: Substring, exponent: Substring, power: Int)? {
        guard !TextRanges.matches(OrderedJSON.numberGrammar, in: number).isEmpty else { return nil }
        let negative = number.hasPrefix("-")
        let unsigned = number.dropFirst(negative ? 1 : 0)
        let mark = unsigned.firstIndex { $0 == "e" || $0 == "E" }
        let mantissa = unsigned[..<(mark ?? unsigned.endIndex)], exponent = unsigned[(mark ?? unsigned.endIndex)...]
        guard let power = exponent.isEmpty ? 0 : Int(exponent.dropFirst()) else { return nil }
        let point = mantissa.firstIndex(of: ".")
        return (negative, mantissa[..<(point ?? mantissa.endIndex)], point.map { mantissa[mantissa.index(after: $0)...] } ?? "", exponent, power)
    }
    /// A JSON number's value, exactly, whatever its spelling: "2128675309", "2128675309.0" and
    /// "2.128675309e9" are all "2128675309e0". No rounding: its significant digits and their power of ten.
    static func numberValue(_ number: String) -> String? {
        guard let parts = numberParts(number) else { return nil }
        // The exponent counted wider than any written: a spelling at either end of the range still matches.
        var digits = (String(parts.whole) + parts.fraction).drop { $0 == "0" }
        guard !digits.isEmpty else { return "0" }
        let zeros = digits.reversed().prefix { $0 == "0" }.count
        digits = digits.dropLast(zeros)
        let power = Int128(parts.power) + Int128(zeros - parts.fraction.count)
        return (parts.negative ? "-" : "") + digits + "e" + String(power)
    }
    /// The number `value` written in `like`'s shape: its exponent as written, and at least as many
    /// places after the point. "3475550182" like "2.128675309e9" is "3.475550182e9". Nil where it can't be.
    static func numberWritten(_ value: String, like: String) -> String? {
        guard let exact = numberValue(value), let shape = numberParts(like) else { return nil }
        let negative = exact.hasPrefix("-")
        let parts = exact.dropFirst(negative ? 1 : 0).split(separator: "e")
        let digits = String(parts[0])
        guard let power = parts.count == 2 ? Int128(String(parts[1])) : 0 else { return nil }
        let wide = power - Int128(shape.power)
        guard wide.magnitude <= 400 else { return nil }
        let shift = Int(wide)
        var whole: String, fraction: String
        if shift >= 0 {
            (whole, fraction) = (digits + String(repeating: "0", count: shift), "")
        } else if digits.count > -shift {
            (whole, fraction) = (String(digits.dropLast(-shift)), String(digits.suffix(-shift)))
        } else {
            (whole, fraction) = ("0", String(repeating: "0", count: -shift - digits.count) + digits)
        }
        if digits == "0" { fraction = "" }
        if fraction.count < shape.fraction.count { fraction += String(repeating: "0", count: shape.fraction.count - fraction.count) }
        return (negative ? "-" : "") + whole + (fraction.isEmpty ? "" : "." + fraction) + shape.exponent
    }
    /// Each number replaced somewhere, by its value (see `numberValue`), with what a number writing it again is written as:
    /// its stand-in where that is a number, else the stand-in's digits in its shape.
    private static func numberStandIns(_ values: [DocumentValue]) -> [String: (text: String, mark: Mark)] {
        var found: [String: (text: String, mark: Mark)] = [:]
        for value in values {
            for mark in value.marks {
                guard let original = mark.original, original.utf8.allSatisfy({ (48...57).contains($0) || [43, 45, 46, 69, 101].contains($0) }),
                      let exact = numberValue(original), found[exact] == nil, OriginalMatcher.spreads(original, entity: mark.entity) else { continue }
                let fake = TextRanges.substring(value.text, mark.range)
                guard fake != original else { continue }
                let digits = fake.filter { $0.isASCII && $0.isNumber }
                let text = !TextRanges.matches(OrderedJSON.numberGrammar, in: fake).isEmpty ? fake
                    : original.allSatisfy({ $0.isASCII && $0.isNumber }) && digits.count == original.count && (digits.first != "0" || original.count == 1) ? digits
                    : numberShaped(like: original, from: fake)
                found[exact] = (text, mark.moved(to: 0..<(text as NSString).length))
            }
        }
        return found
    }
    /// The UTF-16 offset in `units` where each unit of the string token at `range` decoded starts, and
    /// past the last its closing quote: an escape is one unit (`\/`, an escaped letter, half a surrogate pair), as is a shell's `'\''`.
    private func decodedOffsets(_ range: Range<Int>, in units: [UInt16]) -> [Int] {
        var offsets: [Int] = [], at = range.lowerBound + 1
        let end = range.upperBound - 1
        while at < end {
            offsets.append(at)
            if source.shell, units[at] == 39, units[at...].starts(with: [39, 92, 39, 39]) { at += 4 } else if units[at] == 92 { at += units[at + 1] == 117 ? 6 : 2 } else { at += 1 }
        }
        return offsets + [end]
    }
    /// The document written with each changed token's new value, and the marks over them.
    func render(_ values: [DocumentValue]) -> (String, [Mark]) {
        render(values, numbers: looseNumbers.isEmpty && nested.isEmpty ? [:] : Self.numberStandIns(values))
    }
    private func render(_ values: [DocumentValue], numbers: [String: (text: String, mark: Mark)]) -> (String, [Mark]) {
        applied(edits(values, numbers: numbers))
    }
    /// One token, or part of one, written again: where in the source, what it writes, and the marks over that.
    private typealias Edit = (range: Range<Int>, value: String, marks: [Mark])
    /// The source with `edits` (sorted, apart) written in, and their marks where they land.
    private func applied(_ edits: [Edit]) -> (String, [Mark]) {
        guard !edits.isEmpty else { return (source.text, []) }
        let (output, placed) = TextRanges.apply(edits.map { ($0.range, $0.value) }, to: source.text)
        let marks = zip(edits, placed).flatMap { edit, range in
            edit.marks.map { $0.moved(to: ($0.range.lowerBound + range.lowerBound)..<($0.range.upperBound + range.lowerBound)) }
        }
        return (output, marks)
    }
    /// What changes in the source: each changed token, or the part of one a mark replaced, in order.
    private func edits(_ values: [DocumentValue], numbers: [String: (text: String, mark: Mark)]) -> [Edit] {
        var edits: [Edit] = []
        var units: [UInt16]?
        // A string changed in part is written again only where a mark replaced its original, so
        // every escape around that is kept as written; where the marks don't account for every
        // change, the whole token is written again.
        func write(_ text: String, _ marks: [Mark], original: String, at range: Range<Int>) {
            guard !text.unicodeScalars.elementsEqual(original.unicodeScalars) || !marks.isEmpty else { return }
            if let patches = patches(text, marks, original: original, at: range) { edits += patches; return }
            let (token, placed) = OrderedJSON.quoted(text, marks: marks)
            edits.append((range, token, placed))
        }
        func patches(_ text: String, _ marks: [Mark], original: String, at range: Range<Int>) -> [Edit]? {
            let written = Array(text.utf16)
            var rebuilt: [UInt16] = [], spans: [(range: Range<Int>, mark: Mark)] = []
            var cursor = 0
            for mark in marks.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                guard let was = mark.original, mark.range.lowerBound >= cursor, mark.range.upperBound <= written.count else { return nil }
                rebuilt += written[cursor..<mark.range.lowerBound]
                let start = rebuilt.count
                rebuilt += was.utf16
                spans.append((start..<rebuilt.count, mark))
                cursor = mark.range.upperBound
            }
            rebuilt += written[cursor...]
            guard !spans.isEmpty, rebuilt.elementsEqual(original.utf16) else { return nil }
            if units == nil { units = Array(source.text.utf16) }
            let offsets = decodedOffsets(range, in: units ?? [])
            guard offsets.count == rebuilt.count + 1 else { return nil }
            return spans.map { span in
                let value = String(OrderedJSON.quote(TextRanges.substring(text, span.mark.range)).dropFirst().dropLast())
                return (offsets[span.range.lowerBound]..<offsets[span.range.upperBound], value, [span.mark.moved(to: 0..<(value as NSString).length)])
            }
        }
        // A document written inside the string token at `range` changes where its own edits do: each
        // escaped for the string and moved to where the part it replaces is written in this source.
        func escaped(_ inner: [Edit], of child: JSONDocument, original: String, at range: Range<Int>) -> [Edit]? {
            guard child.source.text.utf16.elementsEqual(original.utf16) else { return nil }
            if units == nil { units = Array(source.text.utf16) }
            let offsets = decodedOffsets(range, in: units ?? [])
            guard offsets.count == original.utf16.count + 1 else { return nil }
            return inner.map { edit in
                let (token, placed) = OrderedJSON.quoted(edit.value, marks: edit.marks)
                return (offsets[edit.range.lowerBound]..<offsets[edit.range.upperBound], String(token.dropFirst().dropLast()),
                        placed.map { $0.moved(to: ($0.range.lowerBound - 1)..<($0.range.upperBound - 1)) })
            }
        }
        func walk(_ value: JSONValue, path: String) {
            switch value {
            case .object(let pairs):
                // A key written again as another's is set apart; two keys the input writes alike stay alike.
                // Alike in every scalar: "é" and "e" with its accent are two keys, each kept as spelled.
                func spelling(_ key: String) -> [UInt32] { key.unicodeScalars.map(\.value) }
                let given = Set(pairs.map { spelling($0.0) })
                var outputs: Set<[UInt32]> = [], chosen: [[UInt32]: (key: String, marks: [Mark])] = [:]
                for (index, pair) in pairs.enumerated() {
                    let childPath = path + "/" + String(index)
                    var key = pair.0, marks: [Mark] = []
                    if let known = chosen[spelling(pair.0)] {
                        (key, marks) = known
                    } else {
                        if let id = keyIDs[childPath] {
                            let scrubbed = values[id]
                            let whole = scrubbed.marks.count == 1 && scrubbed.marks[0].range == 0..<(scrubbed.text as NSString).length
                            if !(fieldKeys.contains(childPath) && whole), let kept = Self.keyWritten(scrubbed) { key = kept.text; marks = kept.marks }
                        }
                        if spelling(key) != spelling(pair.0) { while outputs.contains(spelling(key)) || given.contains(spelling(key)) { key += "_"; marks = [] } }
                        outputs.insert(spelling(key))
                        chosen[spelling(pair.0)] = (key, marks)
                    }
                    if let range = source.keys[childPath] { write(key, marks, original: pair.0, at: range) }
                    walk(pair.1, path: childPath)
                }
            case .array(let members):
                for (index, member) in members.enumerated() { walk(member, path: path + "/" + String(index)) }
            case .string(let string):
                guard let range = source.values[path] else { return }
                if let child = nested[path] {
                    if encoded.contains(path) {
                        // Written in base64 again: one mark over the whole, as what it holds can't be shown.
                        if let (inner, marks) = Self.written(child, encoded: true, values, numbers: numbers) {
                            let (text, placed) = OrderedJSON.quoted(inner, marks: marks); edits.append((range, text, placed))
                        }
                    } else {
                        // Written as text: only what changed in it is written again, each escape around that as written.
                        let inner = child.edits(values, numbers: numbers)
                        guard !inner.isEmpty else { return }
                        if let patches = escaped(inner, of: child, original: string, at: range) { edits += patches; return }
                        let (text, marks) = child.applied(inner)
                        write(text, marks, original: string, at: range)
                    }
                } else if let id = valueIDs[path] {
                    write(values[id].text, values[id].marks, original: string, at: range)
                }
            case .number(let number):
                guard let range = source.values[path] else { return }
                // Written again in any spelling of its value ("2128675309.0"), it takes the stand-in in its own,
                // or as the stand-in is written where its shape can't hold it: never the original.
                if valueIDs[path] == nil, looseNumbers.contains(path), let exact = Self.numberValue(number), let copy = numbers[exact],
                   let text = Self.numberWritten(copy.text, like: number)
                    ?? (TextRanges.matches(OrderedJSON.numberGrammar, in: copy.text).isEmpty ? nil : copy.text) {
                    edits.append((range, text, [copy.mark.moved(to: 0..<(text as NSString).length)]))
                    return
                }
                guard let id = valueIDs[path], values[id].text != number || !values[id].marks.isEmpty else { return }
                let text = values[id].text
                if TextRanges.matches(OrderedJSON.numberGrammar, in: text).isEmpty {
                    // A stand-in that is no number (a secret's) is written in the number's own shape instead.
                    let shaped = Self.numberShaped(like: number, from: text)
                    edits.append((range, shaped, values[id].marks.isEmpty ? [] : [values[id].marks[0].moved(to: 0..<(shaped as NSString).length)]))
                } else {
                    edits.append((range, text, values[id].marks))
                }
            default: break
            }
        }
        walk(source.root, path: "")
        guard !edits.isEmpty else { return [] }
        // Inside a shell's quotes an apostrophe is written as the shell writes it; each mark's ends move by the apostrophes before them.
        if source.shell {
            edits = edits.map { edit in
                guard edit.value.contains("'") else { return edit }
                let apostrophes = edit.value.utf16.enumerated().filter { $0.element == 39 }.map(\.offset)
                func moved(_ at: Int) -> Int { at + 3 * apostrophes.filter { $0 < at }.count }
                let marks = edit.marks.map { $0.moved(to: moved($0.range.lowerBound)..<moved($0.range.upperBound)) }
                return (edit.range, edit.value.replacingOccurrences(of: "'", with: "'\\''"), marks)
            }
        }
        return edits.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}

extension JSONValue {
    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    var numberText: String? { if case .number(let value) = self { return value }; return nil }
}
