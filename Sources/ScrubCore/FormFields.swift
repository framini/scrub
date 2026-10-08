import Foundation

/// Values a form, a list or a table gives after their label, in any of the
/// languages a form is filled in: "- **License Plate:** BH 789 XT 92",
/// "| **Postcode** | 692950 |", a table whose header row names its columns,
/// "Geboortedatum: 01-01-1980", and a sentence that names a value before
/// giving it ("the CVV for this card is 364", "for user tw_ryan332"). The
/// value must look like what its label promises, so "Postcode: see above"
/// and "the PIN must be 4 digits" stay as written.
enum FormFields {
    // MARK: Emphasis

    /// Markdown's emphasis around a label or a value ("**CVV:**", "__Postcode__"): only
    /// between a mark and its pair, set off from the words around them, so "a**b" stays.
    private static let emphasis = TextPattern(#"(?<![\p{L}\p{N}*_\\])(\*{1,3}|_{2,3})(?=[^\s*_])([^*\n]{0,80}?[^\s*\\])\1(?![\p{L}\p{N}*_])"#)
    /// A mark left against a label's colon once the text as seen drops the one against its letters ("CVV:** 771", see `Visible`).
    private static let colonMark = TextPattern(#"(?<=[:：])(?:\*{1,3}|_{2,3})(?![\p{L}\p{N}*_])|(?<![\p{L}\p{N}*_\\])(?:\*{1,3}|_{2,3})(?=[:：])"#)
    /// The text with its emphasis marks written as spaces, every offset kept: a label in
    /// bold reads as the plain label it is ("**CVV:** 771" as "  CVV:   771").
    static func masked(_ text: String) -> String {
        guard text.contains("*") || text.contains("__") else { return text }
        let paired = TextRanges.matches(emphasis, in: text)
        let lone = text.contains(":") || text.contains("：") ? TextRanges.matches(colonMark, in: text) : []
        guard !paired.isEmpty || !lone.isEmpty else { return text }
        var units = Array(text.utf16)
        for match in paired {
            let marker = match.range(at: 1).length
            for index in match.range.location..<(match.range.location + marker) { units[index] = 32 }
            for index in (NSMaxRange(match.range) - marker)..<NSMaxRange(match.range) { units[index] = 32 }
        }
        for match in lone {
            for index in match.range.location..<NSMaxRange(match.range) { units[index] = 32 }
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    static func scan(_ text: String, isCancelled: () -> Bool = { false }) -> ProseLabels.Found {
        var found = ProseLabels.Found()
        let ns = text as NSString
        guard ns.length >= 4 else { return found }
        let units = Array(text.utf16)
        if text.contains(":") || text.contains("：") { fields(ns, units, into: &found, isCancelled: isCancelled) }
        if text.contains("|") { tables(ns, units, into: &found, isCancelled: isCancelled) }
        cues(text, ns, into: &found, isCancelled: isCancelled)
        return found
    }

    // MARK: Labels

    private static func space(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 || unit == 0xA0 }
    private static func lineBreak(_ unit: UInt16) -> Bool { unit == 10 || unit == 13 }
    private static func digit(_ unit: UInt16) -> Bool { (48...57).contains(unit) }
    private static func alphanumeric(_ unit: UInt16) -> Bool { digit(unit) || (65...90).contains(unit) || (97...122).contains(unit) }
    /// What ends a label read backwards from its colon: a line, a cell, a clause, a sentence's end.
    private static let labelBreaks: Set<UInt16> = Set(",;|:：[]{}<>\"=!?`\u{2022}".utf16)
    private static let bullet = TextPattern(#"^[ \t\u00A0]*(?:(?:[-*+•·>]+|\d{1,3}[.)]|[a-z][.)]|#{1,6})[ \t\u00A0]+)*"#)

    /// The label a colon closes, written as a form writes one: one to six words from the
    /// start of a line, a cell or a clause, a list's bullet apart. Nil in a sentence's middle.
    private static func label(before colon: Int, _ ns: NSString, _ units: [UInt16]) -> Range<Int>? {
        var end = colon
        while end > 0, space(units[end - 1]) { end -= 1 }
        guard end > 0 else { return nil }
        var start = end, depth = 0
        while start > 0 {
            let unit = units[start - 1]
            if lineBreak(unit) || labelBreaks.contains(unit) { break }
            if unit == 41 { depth += 1 }
            if unit == 40 { if depth == 0 { break }; depth -= 1 }
            // A sentence's end: "… on file. Postcode: 83473".
            if unit == 46, start < end, space(units[start]) { break }
            start -= 1
            if end - start > 64 { return nil }
        }
        let lead = TextRanges.matches(bullet, in: ns.substring(with: NSRange(location: start, length: end - start))).first.map(\.range.length) ?? 0
        start += lead
        while start < end, space(units[start]) { start += 1 }
        guard start < end, end - start <= 56 else { return nil }
        let text = ns.substring(with: NSRange(location: start, length: end - start))
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{A0}" })
        guard (1...6).contains(words.count), text.first?.isLetter == true, !text.contains("@"), !text.contains("/") || words.count <= 3 else { return nil }
        return start..<end
    }

    /// Words naming whose a number is, in the languages forms are written in, and the
    /// words for the number itself: "Kundennummer", "numéro client", "ID del dispositivo".
    private static let owners: [String: String] = [
        "customer": "customer", "client": "customer", "cliente": "customer", "kunde": "customer", "kunden": "customer", "kund": "customer", "klant": "customer", "klanten": "customer",
        "patient": "patient", "patients": "patient", "paciente": "patient", "paziente": "patient", "patienten": "patient", "patiente": "patient",
        "employee": "employee", "staff": "employee", "empleado": "employee", "empleada": "employee", "employe": "employee", "dipendente": "employee", "medewerker": "employee",
        "werknemer": "employee", "mitarbeiter": "employee", "personal": "employee", "personeel": "employee", "personeels": "employee", "anstalld": "employee", "anstallnings": "employee",
        "funcionario": "employee", "salarie": "employee", "matricule": "employee",
        "device": "device", "dispositivo": "device", "appareil": "device", "apparaat": "device", "gerat": "device", "gerate": "device", "enhet": "device", "enhets": "device",
        "user": "user", "usuario": "user", "utilisateur": "user", "utente": "user", "benutzer": "user", "gebruiker": "user", "anvandare": "user", "member": "member"]
    private static let numberWords: Set<String> = ["id", "nummer", "numero", "num", "nr", "no", "n", "number", "identificador", "identifiant", "identificativo", "identifier", "kennung", "code", "codigo", "codice", "matricule"]
    private static let joiningWords: Set<String> = ["de", "del", "du", "da", "do", "di", "della", "dello", "des", "van", "von", "der", "the", "of", "d", "l", "la", "le", "el"]
    /// Words after which a label only qualifies its field ("Password for Secure Portal", "Password per l'accesso").
    private static let qualifying: Set<String> = ["for", "per", "para", "pour", "fur", "voor", "till", "to", "used"]

    /// The key a label stands for, as a record's key would name the field: "License
    /// Plate" is "licenseplate", "Date de naissance" a birth date, "Kundennummer" a customer's ID.
    static func key(_ label: String) -> String? {
        let folded = label.folding(options: .diacriticInsensitive, locale: nil)
        let all = KeyHints.words(folded)
        guard !all.isEmpty, all.count <= 8 else { return nil }
        // The label ends in the field's name ("Customer Name", "Date of Birth"): the longest run of its last words that names one.
        // A label that only opens with one says something else about it ("Passwords must meet the following criteria").
        for length in stride(from: min(4, all.count), through: 1, by: -1) {
            let run = all.suffix(length).joined(separator: "_")
            guard KeyHints.hint(run) != nil else { continue }
            // A bare "name" after other words is a company's or a plan's as often ("Company Name").
            if KeyHints.isBareName(run), all.count > 1 { break }
            return run
        }
        // Or opens with it before a word that only qualifies it: "Código de seguridad de la tarjeta", "Password for Secure Portal".
        for length in stride(from: min(4, all.count - 1), through: 1, by: -1) where joiningWords.contains(all[length]) || qualifying.contains(all[length]) {
            // A name's field so opened names something else's ("Nom de la banque" is the bank's).
            let run = all.prefix(length).joined(separator: "_")
            if let kind = KeyHints.hint(run), !["PERSON", "FIRST_NAME", "LAST_NAME"].contains(kind) { return run }
        }
        // A vehicle's plate, however the label names it ("Plate", "Vehicle Plate").
        if all.last == "plate" || all.last == "plates" { return "license_plate" }
        if RecordIDs.isPersonKey(all.joined(separator: "_")) { return all.joined(separator: "_") }
        let words = all.filter { !joiningWords.contains($0) }
        guard !words.isEmpty, words.count <= 6 else { return nil }
        // Whose number it is and the word for a number, in either order or as one compound.
        if words.count <= 3, let owner = words.lazy.compactMap({ owners[$0] }).first, words.contains(where: numberWords.contains) || words == ["matricule"] { return owner + "_id" }
        // A column headed by a device alone holds its identifier ("| Device |"); a person's word alone holds names.
        if words.count == 1, owners[words[0]] == "device" { return "device_id" }
        if words.count == 1, let word = words.first {
            for suffix in ["nummer", "nr", "id", "kennung", "numero"] where word.hasSuffix(suffix) && word.count > suffix.count + 2 {
                let head = String(word.dropLast(suffix.count))
                if let owner = owners[head] ?? owners[String(head.dropLast())] { return owner + "_id" }
            }
        }
        return nil
    }
    /// A secret a person keeps, as a form asks for it: a password, a PIN, a card's code. A form's
    /// "Authorization", "Cookie" or "API Key Management" holds a scheme's word or a heading's.
    private static let keptSecrets = ["pass", "pwd", "pin", "cvv", "cvc", "cvn", "csc", "securitycode", "wachtwoord", "senha", "contrasena", "kennwort", "losenord", "motdepasse",
                                      "veiligheidscode", "sicherheitscode", "prufnummer", "codedesecurite", "cryptogramme", "codigodeseguridad", "codicedisicurezza", "sakerhetskod", "codigodeseguranca"]

    private static let passwordWords = ["pass", "pwd", "wachtwoord", "senha", "contrasena", "kennwort", "losenord", "motdepasse"]
    /// Whether a secret's key names a password, which is no number as a PIN or a card's code is.
    private static func passwordKey(_ key: String) -> Bool { passwordWords.contains(where: KeyHints.words(key).joined().contains) }

    /// Kinds a label's value is read as here; the rest are read by what they are.
    private static let readKinds: Set<String> = ["SECRET", "ID_NUMBER", "US_SSN", "POSTAL_CODE", "USERNAME", "DATE_OF_BIRTH", "PERSON", "FIRST_NAME", "LAST_NAME",
                                                 "LATITUDE", "LONGITUDE", "COORDINATES", "ADDRESS", "LOCATION"]
    private static let latitudeWords: Set<String> = ["latitude", "lat"], longitudeWords: Set<String> = ["longitude", "long", "lng", "lon"]

    /// The values a label names in `range`, by its key.
    private static func values(_ range: Range<Int>, key: String, label: String, _ ns: NSString) -> [Span] {
        var words = Set(KeyHints.words(label.folding(options: .diacriticInsensitive, locale: nil)))
        words.formUnion(KeyHints.words(key))
        // "Latitude/Longitude", "Local Latitude-Longitude": the point, in that order.
        var entity = !words.isDisjoint(with: latitudeWords) && !words.isDisjoint(with: longitudeWords) ? "COORDINATES" : KeyHints.hint(key)
        // A kind of the registry's ("numberplate" is a British plate's key) is read as a number, and named by its check if it passes one.
        if let kind = entity, Recognizers.entities.contains(kind), !readKinds.contains(kind) { entity = "ID_NUMBER" }
        let text = ns.substring(with: NSRange(location: range.lowerBound, length: range.count))
        guard let entity else {
            // A person's ID only fills a gap: where a label's own reading names the number ("employee ID: EMP-894875"), that stands.
            guard let token = firstToken(range, ns), RecordIDs.identifying(key: key, value: substring(ns, token)), substring(ns, token).contains(where: \.isNumber) else { return [] }
            return [Span(range: token, entity: "RECORD_ID", score: 0.85)]
        }
        guard readKinds.contains(entity), !KeyHints.isCommonValue(text.trimmingCharacters(in: .whitespaces)) else { return [] }
        // A bare "Name" names products and plans as often as people: only a name written as one, with a first name the lists hold.
        if KeyHints.isBareName(key) {
            guard let name = Detector.writtenName(text), text.prefix(name.lowerBound).allSatisfy(\.isWhitespace),
                  let first = substring(ns, (range.lowerBound + name.lowerBound)..<(range.lowerBound + name.upperBound)).split(separator: " ").first,
                  NameLists.isFirst(String(first)), !NameLists.isOrdinary(String(first)) else { return [] }
            return [Span(range: (range.lowerBound + name.lowerBound)..<(range.lowerBound + name.upperBound), entity: "PERSON", score: 0.9)]
        }
        switch entity {
        case "SECRET", "USERNAME":
            if entity == "SECRET", !keptSecrets.contains(where: KeyHints.words(key).joined().contains) { return [] }
            guard let token = firstToken(range, ns) else { return [] }
            let value = substring(ns, token)
            guard value.contains(where: { $0.isLetter || $0.isNumber }), !"[(<{".contains(value.first!), KeyHints.fits(key, value) else { return [] }
            // A password is shaped as one, as a sentence's is (see `ProseLabels`): "password: sql`SELECT 1`" is code.
            if entity == "SECRET", passwordKey(key),
               !ProseLabels.secretLike(value, label: "password", joined: true) || token.upperBound < ns.length && "`(\"'".utf16.contains(ns.character(at: token.upperBound)) { return [] }
            // A name written for a user ("Prepared By: Jennifer Lane") is a person's, not a handle; a handle is one token.
            if entity == "USERNAME", NameLists.isWord(value), value.allSatisfy(\.isLetter) { return [] }
            return [Span(range: token, entity: entity, score: 0.95)]
        case "ID_NUMBER", "US_SSN", "POSTAL_CODE":
            guard let run = idRun(range, ns, pieces: entity == "POSTAL_CODE" ? 2 : 4) else { return [] }
            let value = substring(ns, run)
            guard value.contains(where: \.isNumber), KeyHints.fits(key, value) else { return [] }
            let named = entity == "ID_NUMBER" ? Recognizers.named(value, by: words) ?? entity : entity
            return [Span(range: run, entity: named, score: 0.95)]
        case "DATE_OF_BIRTH":
            guard let match = TextRanges.matches(date, in: text).first else { return [] }
            return [Span(range: (range.lowerBound + match.range.location)..<(range.lowerBound + NSMaxRange(match.range)), entity: entity, score: 0.95)]
        case "PERSON", "FIRST_NAME", "LAST_NAME":
            if let name = Detector.writtenName(text), text.prefix(name.lowerBound).allSatisfy(\.isWhitespace) {
                return [Span(range: (range.lowerBound + name.lowerBound)..<(range.lowerBound + name.upperBound), entity: entity, score: 0.95)]
            }
            // One word under a label for a name ("First Name: Ava"), written as a name and no ordinary word unless the lists name someone so.
            guard let token = firstToken(range, ns), token.upperBound == range.upperBound else { return [] }
            let word = substring(ns, token)
            guard word.count >= 2, word.first?.isUppercase == true, word.dropFirst().allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" || $0 == "’" }),
                  word.contains(where: \.isLowercase),
                  NameLists.isFirst(word) || NameLists.isSurname(word) || !NameLists.isOrdinary(word) else { return [] }
            return [Span(range: token, entity: entity, score: 0.95)]
        case "LATITUDE", "LONGITUDE", "COORDINATES":
            return coordinates(at: range.lowerBound, ns, pair: entity == "COORDINATES", single: entity)
        case "ADDRESS", "LOCATION":
            // Only a label that is the field's name whole ("Street Address", "City"): "ipv4_address" holds no street.
            guard KeyHints.words(key).count == KeyHints.words(label.folding(options: .diacriticInsensitive, locale: nil)).count else { return [] }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard trimmed.utf16.count <= 100, trimmed.first.map({ $0.isUppercase || $0.isNumber }) == true, KeyHints.fits(key, trimmed),
                  entity == "ADDRESS" || trimmed.split(separator: " ").count <= 5 else { return [] }
            let start = range.lowerBound + (text.utf16.count - text.drop(while: { $0 == " " || $0 == "\t" }).utf16.count)
            return [Span(range: start..<(start + trimmed.utf16.count), entity: entity, score: 0.9)]
        default:
            return []
        }
    }

    private static func substring(_ ns: NSString, _ range: Range<Int>) -> String { ns.substring(with: NSRange(location: range.lowerBound, length: range.count)) }
    private static let tokenEnd = CharacterSet(charactersIn: ".,;:)]}\"'`*")

    /// The value's first token, without the punctuation that ends a clause.
    private static func firstToken(_ range: Range<Int>, _ ns: NSString) -> Range<Int>? {
        var start = range.lowerBound
        while start < range.upperBound, space(ns.character(at: start)) { start += 1 }
        var end = start
        while end < range.upperBound, !space(ns.character(at: end)), !lineBreak(ns.character(at: end)) { end += 1 }
        while end > start, let scalar = Unicode.Scalar(ns.character(at: end - 1)), tokenEnd.contains(scalar) { end -= 1 }
        return end > start ? start..<end : nil
    }

    /// An identifier written in pieces ("BH 789 XT 92", "SW1A 1AA", "33-002739-17"): its
    /// first token, and after it pieces of capitals and digits set apart by single spaces.
    private static func idRun(_ range: Range<Int>, _ ns: NSString, pieces limit: Int) -> Range<Int>? {
        guard var run = firstToken(range, ns) else { return nil }
        var count = 1
        while count < limit, run.upperBound + 1 < range.upperBound, ns.character(at: run.upperBound) == 32 {
            var end = run.upperBound + 1
            while end < range.upperBound, alphanumeric(ns.character(at: end)) || ns.character(at: end) == 45 { end += 1 }
            let piece = substring(ns, (run.upperBound + 1)..<end)
            guard !piece.isEmpty, piece.count <= 8, piece.allSatisfy({ $0.isNumber || $0.isUppercase || $0 == "-" }),
                  end == range.upperBound || space(ns.character(at: end)) || lineBreak(ns.character(at: end)) || ",;.)".utf16.contains(ns.character(at: end)) else { break }
            run = run.lowerBound..<end
            count += 1
        }
        return run
    }

    /// A date as a form writes one: "1980-02-03", "01-01-1980", "12 maart 1985", "March 5, 1971".
    private static let date = TextPattern(#"^[ \t]*(?:\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.]\d{1,2}[-/.](?:\d{4}|\d{2})|\d{1,2}\.?[ \t]+\p{L}{3,10}\.?,?[ \t]+\d{4}|\p{L}{3,10}\.?[ \t]+\d{1,2}(?:st|nd|rd|th)?,?[ \t]+\d{4}|\d{8})(?![\w/.-]*\d)"#)

    /// A point written as numbers: "30.5135, 47.7458", "(-19.6247995, 76.664640)", "89.8218855 N, -59.782812 E".
    private static let pair = TextPattern(#"^[ \t]*\(?[ \t]*([-+]?\d{1,3}\.\d{2,})[ \t]*°?[ \t]*([NSns])?[ \t]*(?:[,;/][ \t]*|[ \t]+)([-+]?\d{1,3}\.\d{2,})[ \t]*°?[ \t]*([EWew])?(?!\d|\.\d|\p{L})"#)
    private static let single = TextPattern(#"^[ \t]*([-+]?\d{1,3}\.\d{2,})(?!\d|\.\d)"#)
    /// The latitude and the longitude written from `start`, each its own value; or one, under a label for one.
    static func coordinates(at start: Int, _ ns: NSString, pair wanted: Bool, single entity: String = "LATITUDE") -> [Span] {
        let rest = ns.substring(with: NSRange(location: start, length: min(64, ns.length - start)))
        if let match = TextRanges.matches(pair, in: rest).first {
            let latitude = match.range(at: 1), longitude = match.range(at: 3)
            guard let a = Double((rest as NSString).substring(with: latitude)), let b = Double((rest as NSString).substring(with: longitude)), abs(a) <= 90, abs(b) <= 180 else { return [] }
            // Under a label for one ("Latitude: 30.5135, 47.7458" is no form's way), only when a pair is wanted.
            if wanted || entity == "COORDINATES" {
                return [Span(range: (start + latitude.location)..<(start + NSMaxRange(latitude)), entity: "LATITUDE", score: 0.95),
                        Span(range: (start + longitude.location)..<(start + NSMaxRange(longitude)), entity: "LONGITUDE", score: 0.95)]
            }
        }
        guard !wanted, let match = TextRanges.matches(single, in: rest).first else { return [] }
        let number = match.range(at: 1)
        guard let value = Double((rest as NSString).substring(with: number)), abs(value) <= (entity == "LATITUDE" ? 90 : 180) else { return [] }
        return [Span(range: (start + number.location)..<(start + NSMaxRange(number)), entity: entity == "LONGITUDE" ? "LONGITUDE" : "LATITUDE", score: 0.95)]
    }

    // MARK: Fields

    /// Kinds an address holds. Their labels ("City", "Code postal") stay open to the address
    /// model, which reads an address whole with the lines around it (see `Detector.placed`).
    private static let placeKinds: Set<String> = ["ADDRESS", "LOCATION", "POSTAL_CODE", "REGION", "LATITUDE", "LONGITUDE"]
    /// Whether a label's words are kept from every other reading: no name is read in "First Name", no address in "PIN".
    private static func quiets(_ spans: [Span]) -> Bool { spans.contains { !placeKinds.contains($0.entity) } }

    /// The next label on the same line, after a comma or a semicolon: "Date of Birth: 1996-10-21, License Plate: …".
    private static let nextLabel = TextPattern(#"^[,;][ \t]+(?:\p{L}[\p{L}\p{M}'’.()-]*[ \t]+){0,5}\p{L}[\p{L}\p{M}'’.()-]*[ \t]*[:：](?!//)"#)

    private static func fields(_ ns: NSString, _ units: [UInt16], into found: inout ProseLabels.Found, isCancelled: () -> Bool) {
        for colon in units.indices where units[colon] == 58 || units[colon] == 0xFF1A {
            if colon.isMultiple(of: 4096) && isCancelled() { return }
            // A link's "://", Ruby's "::", a time's "12:30".
            if colon + 1 < units.count, units[colon + 1] == 47 || units[colon + 1] == 58 { continue }
            if colon > 0, colon + 1 < units.count, digit(units[colon - 1]), digit(units[colon + 1]) { continue }
            guard let labelRange = label(before: colon, ns, units) else { continue }
            let labelText = substring(ns, labelRange)
            guard let key = Self.key(labelText) else { continue }
            guard let value = valueRange(after: colon, ns, units, formLine: lineStart(labelRange.lowerBound, units)) else { continue }
            let spans = values(value, key: key, label: labelText, ns)
            guard !spans.isEmpty else { continue }
            if quiets(spans) { found.labels.append(labelRange) }
            found.spans.append(contentsOf: spans)
        }
    }

    private static func lineStart(_ index: Int, _ units: [UInt16]) -> Bool {
        var at = index
        while at > 0, space(units[at - 1]) || "-*+•#>".utf16.contains(units[at - 1]) || digit(units[at - 1]) || units[at - 1] == 46 { at -= 1 }
        return at == 0 || lineBreak(units[at - 1])
    }

    /// The value after a label's colon: to the end of its line or cell, or to the next label
    /// on the line, without a sentence's last stop. A label alone on its line ("**CVV:**")
    /// gives the next line that holds something, if that line is no label itself.
    private static func valueRange(after colon: Int, _ ns: NSString, _ units: [UInt16], formLine: Bool) -> Range<Int>? {
        var start = colon + 1
        while start < units.count, space(units[start]) { start += 1 }
        if start < units.count, lineBreak(units[start]) {
            guard formLine else { return nil }
            var breaks = 0
            while start < units.count, space(units[start]) || lineBreak(units[start]) {
                if units[start] == 10 { breaks += 1 }
                start += 1
            }
            guard breaks <= 2, start < units.count else { return nil }
            let line = ns.lineRange(for: NSRange(location: start, length: 0))
            let text = ns.substring(with: NSRange(location: start, length: NSMaxRange(line) - start))
            guard !text.hasPrefix("|"), !text.hasPrefix("#"), !text.contains(":") else { return nil }
        }
        guard start < units.count else { return nil }
        var end = start
        while end < units.count, !lineBreak(units[end]), units[end] != 124, units[end] != 96 { end += 1 }
        // A later label on the line ends this value.
        var at = start
        while at < end {
            if units[at] == 44 || units[at] == 59 {
                let rest = ns.substring(with: NSRange(location: at, length: min(64, end - at)))
                if !TextRanges.matches(nextLabel, in: rest).isEmpty { end = at; break }
            }
            at += 1
        }
        while end > start, space(units[end - 1]) || units[end - 1] == 46 || units[end - 1] == 44 || units[end - 1] == 59 { end -= 1 }
        return end > start ? start..<end : nil
    }

    // MARK: Tables

    private static func cells(_ line: NSRange, _ units: [UInt16]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        for index in line.location..<NSMaxRange(line) where !lineBreak(units[index]) {
            if units[index] == 124 && (index == 0 || units[index - 1] != 92) {
                if let open = start {
                    var lower = open, upper = index
                    while lower < upper, space(units[lower]) { lower += 1 }
                    while upper > lower, space(units[upper - 1]) { upper -= 1 }
                    result.append(lower..<upper)
                }
                start = index + 1
            }
        }
        // A row may leave its last cell open: "| PIN | 620438".
        if let open = start {
            var lower = open, upper = NSMaxRange(line)
            while upper > lower, space(units[upper - 1]) || lineBreak(units[upper - 1]) { upper -= 1 }
            while lower < upper, space(units[lower]) { lower += 1 }
            if lower < upper { result.append(lower..<upper) }
        }
        return result
    }
    private static let separatorCell = TextPattern(#"^:?-{2,}:?$"#)

    /// A markdown table's values: a row that names its field in its first cell
    /// ("| PIN | 620438 |"), and every row under a header that names its columns.
    private static func tables(_ ns: NSString, _ units: [UInt16], into found: inout ProseLabels.Found, isCancelled: () -> Bool) {
        var rows: [(NSRange, [Range<Int>])] = []
        var at = 0
        func flush() {
            defer { rows = [] }
            guard rows.count >= 1 else { return }
            let separators = rows.map { row in !row.1.isEmpty && row.1.allSatisfy { !TextRanges.matches(separatorCell, in: substring(ns, $0)).isEmpty } }
            var columns: [(key: String, label: String)?] = []
            for (index, row) in rows.enumerated() {
                if separators[index] { continue }
                let header = index + 1 < rows.count && separators[index + 1]
                if header {
                    columns = row.1.map { cell in
                        let text = substring(ns, cell)
                        guard (1...6).contains(text.split(separator: " ").count), text.first?.isLetter == true, text.utf16.count <= 56, let key = Self.key(text) else { return nil }
                        if !placeKinds.contains(KeyHints.hint(key) ?? "") { found.labels.append(cell) }
                        return (key, text)
                    }
                    continue
                }
                for (column, cell) in row.1.enumerated() where column < columns.count && !cell.isEmpty {
                    guard let named = columns[column] else { continue }
                    found.spans.append(contentsOf: values(cell, key: named.key, label: named.label, ns))
                }
                // A row that is a field and its value.
                guard row.1.count >= 2, !row.1[0].isEmpty, !row.1[1].isEmpty else { continue }
                let first = substring(ns, row.1[0]), second = substring(ns, row.1[1])
                guard (1...6).contains(first.split(separator: " ").count), first.first?.isLetter == true, first.utf16.count <= 56,
                      let key = Self.key(first.trimmingCharacters(in: CharacterSet(charactersIn: ": "))), Self.key(second) == nil else { continue }
                let spans = values(row.1[1], key: key, label: first, ns)
                if quiets(spans) { found.labels.append(row.1[0]) }
                found.spans.append(contentsOf: spans)
            }
        }
        while at < units.count {
            if at.isMultiple(of: 4096) && isCancelled() { return }
            let line = ns.lineRange(for: NSRange(location: at, length: 0))
            var first = line.location
            while first < NSMaxRange(line), space(units[first]) { first += 1 }
            if first < NSMaxRange(line), units[first] == 124 { rows.append((line, cells(line, units))) } else { flush() }
            at = max(NSMaxRange(line), at + 1)
        }
        flush()
    }

    // MARK: Sentences

    /// Words naming a kind in a sentence, before its value, and what the value after them
    /// must look like to be one; `bridged`: words stood between them.
    private struct Cue: Sendable {
        let pattern: TextPattern
        let value: @Sendable (NSString, Int, _ bridged: Bool) -> [Span]
    }
    private static func cue(_ words: String) -> TextPattern { TextPattern(#"(?<![\p{L}\p{N}_@./-])(?:"# + words + #")(?![\p{L}\p{N}_-])"#, options: [.caseInsensitive]) }
    /// Words that may stand between a cue and its value without changing what it names.
    private static let fillers: Set<String> = [
        "is", "was", "are", "were", "be", "been", "must", "should", "will", "shall", "would", "can", "it", "its", "of", "as", "such", "like", "which", "that", "this",
        "these", "the", "a", "an", "number", "no", "nr", "code", "provided", "used", "entered", "given", "set", "to", "for", "your", "my", "his", "her", "their", "our",
        "card", "credit", "debit", "transaction", "payment", "new", "current", "with", "here", "below", "now", "on", "file", "listed", "assigned", "associated", "following",
        "identifier", "id", "value", "reads", "named", "called", "name", "e.g", "eg", "ist", "lautet", "est", "es", "är", "é", "è", "zijn", "uw", "votre", "su", "ihre", "seu", "sua", "din"]
    private static let handleFillers: Set<String> = ["name", "named", "is", "was", "the", "called", "account", "id", "of"]

    /// Where the value after a cue starts: past a phrase closed by a colon ("Password for
    /// Secure Portal: …"), or past punctuation and filler words ("CVV, which is …").
    /// `bridged`: words stood between, so the value must be surer of its shape.
    private static let phrase = TextPattern(#"^(?:[ \t\u00A0]+[\p{L}\p{N}_.'’-]+){0,6}[ \t\u00A0]*[:：=#?][ \t\u00A0]*"#)
    private static let colonOnly = TextPattern(#"^[ \t\u00A0]*[:：=#][ \t\u00A0]*"#)
    private static func valueStart(_ ns: NSString, from start: Int, fillers allowed: Set<String>, phrases: Bool = true) -> (Int, Bool)? {
        let rest = ns.substring(with: NSRange(location: start, length: min(80, ns.length - start)))
        let restNS = rest as NSString
        if let match = TextRanges.matches(phrases ? phrase : colonOnly, in: rest).first, !restNS.substring(with: match.range).contains("://") {
            var at = start + match.range.length
            // A label alone on its line gives the next line.
            if at < ns.length, lineBreak(ns.character(at: at)) {
                var breaks = 0
                while at < ns.length, space(ns.character(at: at)) || lineBreak(ns.character(at: at)) { if ns.character(at: at) == 10 { breaks += 1 }; at += 1 }
                guard breaks <= 2 else { return nil }
            }
            return (at, match.range.length > 3 && restNS.substring(with: match.range).contains(where: \.isLetter))
        }
        var at = start, words = 0, marks = 0
        while at < ns.length {
            let unit = ns.character(at: at)
            if space(unit) { at += 1; continue }
            if "(,–—\"'`“‘".utf16.contains(unit) || unit == 45 && at + 1 < ns.length && space(ns.character(at: at + 1)) {
                marks += 1
                guard marks <= 3 else { return nil }
                at += 1
                continue
            }
            var end = at
            while end < ns.length, let scalar = Unicode.Scalar(ns.character(at: end)), CharacterSet.letters.contains(scalar) || scalar == "." && end > at { end += 1 }
            guard end > at else { break }
            let word = ns.substring(with: NSRange(location: at, length: end - at)).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard allowed.contains(word), words < 6 else { break }
            words += 1
            at = end
        }
        return at < ns.length ? (at, words > 0) : nil
    }

    private static func match(_ pattern: TextPattern, _ ns: NSString, at start: Int) -> NSTextCheckingResult? {
        guard let regex = pattern.regex else { return nil }
        return regex.firstMatch(in: ns as String, options: [.anchored, .withTransparentBounds], range: NSRange(location: start, length: ns.length - start))
    }
    private static func year(_ value: String) -> Bool { value.count == 4 && (value.hasPrefix("19") || value.hasPrefix("20")) }

    private static let digits3to4 = TextPattern(#"\d{3,4}(?!\d|[.,]\d|[\p{L}%$€£])"#)
    private static let digits4to8 = TextPattern(#"\d{4,8}(?!\d|[.,]\d|[\p{L}%$€£])"#)
    private static let deviceValue = TextPattern(#"[A-Za-z0-9][A-Za-z0-9:-]{6,62}[A-Za-z0-9](?![\w-])"#)
    private static let postcodeValue = TextPattern(#"(?:\d{4,6}(?:-\d{4})?|[A-Z]\d[A-Z] ?\d[A-Z]\d|[A-Z]{1,2}\d[A-Z\d]? ?\d[A-Z]{2}|\d{4} ?[A-Z]{2})(?![\w-]|[.,]\d)"#)
    private static let phoneValue = TextPattern(#"(?:\+\d{1,3}[ .-]?)?(?:\(\d{1,4}\)[ .-]?)?\d{1,10}(?:[ .-]\d{1,8}){0,5}(?![\w@-]|[.,]\d)"#)
    private static let handleValue = TextPattern(#"[A-Za-z0-9][A-Za-z0-9._-]{0,38}[A-Za-z0-9](?![\w@-]|\.\w)"#)
    private static let idValue = TextPattern(#"[A-Za-z0-9][A-Za-z0-9_-]{1,30}[A-Za-z0-9](?![\w-]|\.\w)"#)

    private static func digitsValue(_ pattern: TextPattern) -> @Sendable (NSString, Int, Bool) -> [Span] {
        { ns, start, bridged in
            guard let found = match(pattern, ns, at: start) else { return [] }
            let value = ns.substring(with: found.range)
            // "the PIN expires in 2026": a year after words is a date, not a code.
            if bridged, year(value) { return [] }
            return [Span(range: found.range.location..<NSMaxRange(found.range), entity: "SECRET", score: 0.9)]
        }
    }

    private static let cues: [Cue] = [
        // A card's security code: three or four digits.
        Cue(pattern: cue(#"cvv2?|cvc2?|cvn|csc|card security code|card verification (?:value|code|number)|security code|\p{L}*veiligheidscode|\p{L}*sicherheitscode|\p{L}*pr[uü]fnummer|code de s[ée]curit[ée]|cryptogramme(?: visuel)?|c[oó]digo de seguridad|codice di sicurezza|\p{L}*s[aä]kerhetskod|c[oó]digo de seguran[cç]a|c[oó]digo cvv|codice cvv|code cvv"#),
            value: digitsValue(digits3to4)),
        // A PIN, a one-time code: four to eight digits.
        Cue(pattern: cue(#"pin(?:[ -]?(?:code|number|nummer|nr|kod|kode))?|pincode|code pin|c[oó]digo pin|codice pin|personal identification number|(?:two-factor|2fa|one-time|verification|authentication|login|access) code|one-time password|otp|passcode|\p{L}*verifizierungscode|code de v[ée]rification|c[oó]digo de verificaci[oó]n|verificatiecode|verifieringskod"#),
            value: digitsValue(digits4to8)),
        // A vehicle's plate: pieces of capitals and digits.
        Cue(pattern: cue(#"licen[cs]e[ -]?plates?(?:[ -]?(?:number|no\.?|#))?|number[ -]?plates?|registration[ -]?plates?|plate[ -]?(?:number|no\.?)|vehicle registration(?: number| no\.?)?|kenteken(?:nummer)?|kfz-kennzeichen|kennzeichen|nummernschild|plaque d['’]immatriculation|immatriculation|n[uú]mero de matr[ií]cula|matr[ií]cula|placa(?: do ve[ií]culo| del veh[ií]culo)?|targa|registreringsnummer|regnr"#),
            value: { ns, start, _ in plate(ns, at: start) }),
        // A device's own identifier, a UUID among them: named, it is someone's.
        Cue(pattern: cue(#"device[ -]?(?:id|identifiers?|serial(?: number| no\.?)?|udid|fingerprint|number)|device with the identifier|udid|imei(?: number)?|meid|ger[aä]te-?(?:id|kennung|nummer)|identifiant (?:de l['’]appareil|d['’]appareil|du terminal)|id(?:entificador)? del dispositivo|id(?:entificativo)? (?:del )?dispositivo|identificador do dispositivo|id do dispositivo|apparaat-?id|enhets-?id"#),
            value: { ns, start, _ in
                guard let found = match(deviceValue, ns, at: start), ns.substring(with: found.range).contains(where: \.isNumber) else { return [] }
                return [Span(range: found.range.location..<NSMaxRange(found.range), entity: "RECORD_ID", score: 0.9)]
            }),
        // A phone number named as one, in any country's grouping: "phone +39 393 068 0434", "mobile 323 1798382".
        Cue(pattern: cue(#"(?:tele)?phone(?: number| no\.?)?|mobile(?: number| no\.?)?|cell(?: ?phone)?|tel\.?|whatsapp|handy(?:nummer)?|telefono|tel[ée]fono|t[ée]l[ée]phone|portable|cellulare|celular|telefoon(?:nummer)?|mobiel(?:nummer)?|telefon(?:nummer)?"#),
            value: { ns, start, _ in
                guard let found = match(phoneValue, ns, at: start) else { return [] }
                let value = ns.substring(with: found.range), digits = value.filter(\.isNumber).count
                // Not a date ("2026-01-02") nor a time.
                guard (7...15).contains(digits), value.range(of: #"^\d{4}[-./]\d{1,2}[-./]\d{1,2}$|^\d{1,2}[-./]\d{1,2}[-./]\d{2,4}$"#, options: .regularExpression) == nil else { return [] }
                return [Span(range: found.range.location..<NSMaxRange(found.range), entity: "PHONE_NUMBER", score: 0.9)]
            }),
        // A point named as one: "the coordinates 40.7128, -74.0060", "Location: 41.4989, -81.6944".
        Cue(pattern: cue(#"co-?ordinates?|gps(?: co-?ordinates?| location| position)?|lat(?:itude)?[ \t]*(?:[/,&-]|and)?[ \t]*long?(?:itude)?|latlng|location|position|located at|koordinaten|koordinater|coordonn[ée]es(?: gps)?|coordenadas|coordinate gps|co[oö]rdinaten"#),
            value: { ns, start, _ in coordinates(at: start, ns, pair: true) }),
        // A postcode named in a sentence: "a postcode of 94005", "PLZ 10115".
        Cue(pattern: cue(#"post ?code|postal code|zip(?: ?code)?|postleitzahl|plz|code postal|c[oó]digo postal|codice postale|postnummer"#),
            value: { ns, start, _ in
                guard let found = match(postcodeValue, ns, at: start) else { return [] }
                return [Span(range: found.range.location..<NSMaxRange(found.range), entity: "POSTAL_CODE", score: 0.9)]
            }),
    ]
    /// A first or last name after the words for one: "the last name Wellborn", "**Last Name** Testa".
    private static let nameCue = cue(#"(first|given|middle|last|family)[ -]?name|(surname|forename)"#)
    private static let nameValue = TextPattern(#"\p{Lu}[\p{L}'’-]*\p{Ll}[\p{L}'’-]*(?![\p{L}\p{N}_@-])"#)
    /// A user's handle after the word for one: "for user tw_ryan332", "the user name cedric.prince".
    private static let handleCue = cue(#"user(?:[ -]?name)?|login(?: name| id)?|screen ?name|account name|benutzer(?:name)?|nom d['’]utilisateur|nombre de usuario|usuario|nome utente|nome de usu[aá]rio|utente|gebruikersnaam|gebruiker|anv[aä]ndarnamn|anv[aä]ndare|usu[aá]rio"#)
    /// A password named in a sentence, in any of a form's languages: "use the password password123", "Passwort ist N#Ihh+uk@88".
    private static let passwordCue = cue(#"passwords?|passwort|wachtwoord|mot de passe|contrase[ñn]a|senha|l[öo]senord|kennwort|passphrase"#)
    /// A person's own number after whose it is: "an employee ID such as SM456", "Kundennummer: K-48213".
    private static let personIDCue = cue(#"(?:customer|client|employee|staff|patient|member)[ -]?(?:id|number|no\.?|#)|kunden-?(?:nummer|nr\.?|id)|personalnummer|mitarbeiter-?(?:nummer|id)|patienten-?(?:nummer|id)|klantnummer|personeelsnummer|pati[eë]ntnummer|kundnummer|anst[aä]llningsnummer|num[ée]ro (?:de )?client|num[ée]ro d['’]employ[ée]|num[ée]ro (?:de )?patient|n[uú]mero de (?:cliente|empleado|paciente)|id (?:del )?(?:cliente|dipendente|paziente)|codice (?:cliente|dipendente)|matricule"#)

    /// A plate: up to four pieces of capitals and digits set apart by a space or a dash, a digit in them.
    private static func plate(_ ns: NSString, at start: Int) -> [Span] {
        func capitalOrDigit(_ unit: UInt16) -> Bool { digit(unit) || (65...90).contains(unit) }
        var pieces: [Range<Int>] = []
        var at = start
        while pieces.count < 4 {
            var end = at
            while end < ns.length, capitalOrDigit(ns.character(at: end)) { end += 1 }
            guard end > at, end - at <= 8 else { break }
            // A piece run into small letters is a word ("Box", "IDs"): it ends the plate, or is none.
            if end < ns.length, (97...122).contains(ns.character(at: end)) || ns.character(at: end) >= 0xC0 { if pieces.isEmpty { return [] }; break }
            pieces.append(at..<end)
            guard end + 1 < ns.length, ns.character(at: end) == 32 || ns.character(at: end) == 45, capitalOrDigit(ns.character(at: end + 1)) else { break }
            at = end + 1
        }
        guard let first = pieces.first, let last = pieces.last else { return [] }
        let value = substring(ns, first.lowerBound..<last.upperBound)
        let characters = pieces.map(\.count).reduce(0, +)
        guard value.contains(where: \.isNumber), (4...12).contains(characters), !year(value) else { return [] }
        return [Span(range: first.lowerBound..<last.upperBound, entity: "ID_NUMBER", score: 0.9)]
    }

    /// A point written with its hemispheres needs no word to name it: "57.7692525 S, 48.945249 W".
    private static let hemispheres = TextPattern(#"(?<![\w.-])([-+]?\d{1,2}\.\d{3,})[ \t]*°?[ \t]*[NS](?![\p{L}\p{N}])[ \t]*,?[ \t]*([-+]?\d{1,3}\.\d{3,})[ \t]*°?[ \t]*[EW](?![\p{L}\p{N}])"#)

    private static func cues(_ text: String, _ ns: NSString, into found: inout ProseLabels.Found, isCancelled: () -> Bool) {
        for hit in TextRanges.matches(hemispheres, in: text, isCancelled: isCancelled) {
            let latitude = hit.range(at: 1), longitude = hit.range(at: 2)
            guard let a = Double(ns.substring(with: latitude)), let b = Double(ns.substring(with: longitude)), abs(a) <= 90, abs(b) <= 180 else { continue }
            found.spans.append(Span(range: latitude.location..<NSMaxRange(latitude), entity: "LATITUDE", score: 0.9))
            found.spans.append(Span(range: longitude.location..<NSMaxRange(longitude), entity: "LONGITUDE", score: 0.9))
        }
        for cue in cues {
            for hit in TextRanges.matches(cue.pattern, in: text, isCancelled: isCancelled) {
                guard let (start, bridged) = valueStart(ns, from: NSMaxRange(hit.range), fillers: fillers) else { continue }
                let spans = cue.value(ns, start, bridged)
                guard !spans.isEmpty else { continue }
                if quiets(spans) { found.labels.append(hit.range.location..<NSMaxRange(hit.range)) }
                found.spans.append(contentsOf: spans)
            }
        }
        for hit in TextRanges.matches(handleCue, in: text, isCancelled: isCancelled) {
            guard let (start, bridged) = valueStart(ns, from: NSMaxRange(hit.range), fillers: handleFillers, phrases: false), let value = match(handleValue, ns, at: start) else { continue }
            let handle = ns.substring(with: value.range)
            // Small letters alone are a handle only where the text says it names one ("user name lzimmermann", "User: martinparry").
            let between = ns.substring(with: NSRange(location: NSMaxRange(hit.range), length: start - NSMaxRange(hit.range))).lowercased()
            let naming = !bridged && between.contains(":") || between.contains("name") || between.contains("called") || ns.substring(with: hit.range).lowercased().hasSuffix("name")
            guard handled(handle, naming: naming) else { continue }
            found.labels.append(hit.range.location..<NSMaxRange(hit.range))
            found.spans.append(Span(range: value.range.location..<NSMaxRange(value.range), entity: "USERNAME", score: 0.9))
        }
        for hit in TextRanges.matches(nameCue, in: text, isCancelled: isCancelled) {
            guard let (start, _) = valueStart(ns, from: NSMaxRange(hit.range), fillers: ["is", "was", "of", "the", "reads"], phrases: false), let value = match(nameValue, ns, at: start) else { continue }
            let word = ns.substring(with: value.range)
            // A name the lists hold, or no ordinary word: "the last name field" names none.
            guard NameLists.isFirst(word) || NameLists.isSurname(word) || !NameLists.isOrdinary(word), !NameLists.isWord(word) || NameLists.isName(word) || NameLists.isFirst(word) else { continue }
            let first = ["first", "given", "middle", "forename"].contains { ns.substring(with: hit.range).lowercased().hasPrefix($0) }
            found.labels.append(hit.range.location..<NSMaxRange(hit.range))
            found.spans.append(Span(range: value.range.location..<NSMaxRange(value.range), entity: first ? "FIRST_NAME" : "LAST_NAME", score: 0.9))
        }
        for hit in TextRanges.matches(passwordCue, in: text, isCancelled: isCancelled) {
            guard let (start, bridged) = valueStart(ns, from: NSMaxRange(hit.range), fillers: fillers.union(["like", "example"])), let token = firstToken(start..<min(ns.length, start + 128), ns) else { continue }
            let value = substring(ns, token)
            guard passwordLike(value, bridged: bridged) else { continue }
            found.labels.append(hit.range.location..<NSMaxRange(hit.range))
            found.spans.append(Span(range: token, entity: "SECRET", score: 0.9))
        }
        for hit in TextRanges.matches(personIDCue, in: text, isCancelled: isCancelled) {
            let named = ns.substring(with: hit.range)
            guard let key = Self.key(named), let (start, _) = valueStart(ns, from: NSMaxRange(hit.range), fillers: fillers), let value = match(idValue, ns, at: start) else { continue }
            let id = ns.substring(with: value.range)
            guard id.contains(where: \.isNumber), RecordIDs.identifying(key: key, value: id) || KeyHints.hint(key) != nil else { continue }
            found.labels.append(hit.range.location..<NSMaxRange(hit.range))
            found.spans.append(Span(range: value.range.location..<NSMaxRange(value.range), entity: "RECORD_ID", score: 0.85))
        }
    }

    /// A handle, not a word: digits, an underscore or a dot in it, capitals inside it
    /// ("JenniferLane89", "NjokiPhantomX"), or a run of small letters no dictionary holds.
    private static func handled(_ value: String, naming: Bool) -> Bool {
        guard value.count >= 3, value.count <= 40, !KeyHints.isCommonValue(value) else { return false }
        if value.contains(where: { $0.isNumber || $0 == "_" }) { return value.contains(where: \.isLetter) }
        if value.contains(".") { return value.split(separator: ".").allSatisfy { $0.count >= 2 && $0.allSatisfy(\.isLetter) } }
        let inner = value.dropFirst().contains(where: \.isUppercase) && value.contains(where: \.isLowercase)
        if inner { return true }
        return naming && value.allSatisfy({ $0.isLowercase }) && value.count >= 6 && !NameLists.isWord(value) && !NameLists.isOrdinary(value)
    }

    /// A password, not a word: letters with digits or symbols. After words ("the password
    /// hello123"), it must be both; after a colon, as `ProseLabels` reads one.
    private static func passwordLike(_ value: String, bridged: Bool) -> Bool {
        guard value.count >= 6, value.count <= 64, let first = value.first, !"-[(<{?$~/.'\"`".contains(first), !value.contains("://"), !value.contains(where: { "`{}".contains($0) }), !value.contains("@") || value.count >= 8 && !value.contains(".") else { return false }
        // A hyphen or an apostrophe writes a word ("two-factor"), not a password.
        let letters = value.contains(where: \.isLetter), digits = value.contains(where: \.isNumber), symbols = value.contains { !$0.isLetter && !$0.isNumber && !"-'’".contains($0) }
        let inner = value.dropFirst().contains(where: \.isUppercase) && value.contains(where: \.isLowercase)
        return letters && (digits || symbols || !bridged && inner)
    }
}
