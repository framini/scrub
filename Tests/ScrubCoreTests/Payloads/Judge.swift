import Foundation
import ScrubTestSupport
@testable import ScrubCore

struct Finding: Hashable {
    /// leak, typeChanged, keptChanged, softChanged, keyChanged, shapeChanged, invalid, error
    let problem: String
    let rendering: String
    let truth: String
    let key: String
    let parent: String
    let detail: String
    var group: String { "\(problem) \(truth) key=\(key) parent=\(parent)" }
}

enum Judge {
    static func truthLabel(_ truth: Truth) -> String {
        switch truth {
        case .pii(let kind): return kind.rawValue
        case .keep: return "keep"
        case .keepSoft: return "keepSoft"
        case .ignore: return "ignore"
        }
    }

    static func judge(_ payload: PNode, _ rendered: Rendered, output: Data) -> [Finding] {
        let text = String(decoding: output, as: UTF8.self)
        let leaves = payload.leaves()
        var findings: [Finding] = []
        func add(_ problem: String, _ leaf: PathLeaf?, _ detail: String) {
            findings.append(Finding(problem: problem, rendering: rendered.rendering.rawValue, truth: leaf.map { truthLabel($0.leaf.truth) } ?? "-",
                                    key: leaf?.key ?? "-", parent: leaf.map { $0.keys.dropLast().last ?? "-" } ?? "-", detail: detail))
        }
        // A stand-in is always a value; "[TIME_ZONE]" means none could be drawn.
        if let placeholder = text.range(of: #"\[[A-Z_]{3,}\]"#, options: .regularExpression), !rendered.text.contains(String(text[placeholder])) {
            add("placeholder", nil, String(text[placeholder]))
        }
        var seen: [[Int]: String] = [:]
        // Wherever it sits, a personal value must be gone from the whole output.
        for leaf in leaves {
            guard case .pii(let kind) = leaf.leaf.truth, ![.routing, .sortCode].contains(kind), let found = leaked(leaf.leaf.text, kind: kind, in: text) else { continue }
            add("leak", leaf, "\(leaf.keys.joined(separator: ".")) = \(leaf.leaf.text) → still has \(found)")
        }
        switch rendered.rendering {
        case .json, .jsonMinified, .pastedJSON, .curl, .logLine:
            var body = text
            if rendered.rendering == .curl || rendered.rendering == .logLine {
                guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}") else { add("invalid", nil, "no JSON body left"); return findings }
                body = String(text[open...close])
                // A quote in a stand-in ("O'Brien") is written the shell's way inside a single-quoted body.
                if rendered.rendering == .curl { body = body.replacingOccurrences(of: "'\\''", with: "'") }
            }
            guard let parsed = try? OrderedJSON.parse(body) else { add("invalid", nil, "JSON no longer parses: \(body.prefix(300))"); return findings }
            if let problem = sameShape(payload, parsed, path: "$") { add("shapeChanged", nil, problem); return findings }
            for leaf in leaves {
                guard let value = jsonValue(parsed, at: leaf.path) else { add("shapeChanged", leaf, "missing"); continue }
                switch value {
                case .string(let s): seen[leaf.path] = s; compare(leaf, s, number: false, add: add)
                case .number(let n): seen[leaf.path] = n; compare(leaf, n, number: true, add: add)
                default: add("shapeChanged", leaf, "became \(value)")
                }
            }
        case .xml:
            guard let document = try? XMLDocument(data: output, options: [.nodePreserveWhitespace]), let root = document.rootElement() else { add("invalid", nil, "XML no longer parses"); return findings }
            for leaf in leaves {
                var element: XMLElement? = root
                for index in leaf.path {
                    let children = element?.children?.compactMap { $0 as? XMLElement } ?? []
                    element = index < children.count ? children[index] : nil
                }
                guard let element else { add("shapeChanged", leaf, "missing"); continue }
                seen[leaf.path] = element.stringValue ?? ""
                compare(leaf, element.stringValue ?? "", number: nil, add: add)
            }
        case .csv:
            guard let rows = try? CSVFile.parse(text, delimiter: ","), let head = rows.first else { add("invalid", nil, "CSV no longer parses"); return findings }
            if head != rendered.header { add("keyChanged", nil, "header \(rendered.header) → \(head)") }
            for leaf in leaves {
                guard let (row, column) = rendered.cells[leaf.path] else { continue }
                guard row + 1 < rows.count, column < rows[row + 1].count else { add("shapeChanged", leaf, "missing cell"); continue }
                seen[leaf.path] = rows[row + 1][column]
                compare(leaf, rows[row + 1][column], number: nil, add: add)
            }
        case .prose:
            // A written "City, ST 12345" must still be a real place.
            let ns = text as NSString
            for match in (try? NSRegularExpression(pattern: #"(\p{Lu}[\p{L}. ]+?), ([A-Z]{2,3}) (\d{5}(?:-\d{4})?|[A-Z]\d[A-Z] ?\d[A-Z]\d|\d{4})\b"#))?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
                let city = ns.substring(with: match.range(at: 1)).components(separatedBy: ", ").last ?? "", region = ns.substring(with: match.range(at: 2)), postal = ns.substring(with: match.range(at: 3))
                let real = Places.all.contains { $0.city.caseInsensitiveCompare(city) == .orderedSame && regionMatches(region, $0) && postalMatches(postal, $0) }
                if !real { add("placeMismatch", nil, "\(city), \(region) \(postal) is no real place") }
            }
        case .javascript, .python, .yaml:
            // No tree to walk: what must stay must still be there as often as before.
            let source = rendered.text
            let personal = leaves.compactMap { if case .pii = $0.leaf.truth { return $0.leaf.text.filter { !$0.isWhitespace } } else { return nil } }
            for leaf in leaves where leaf.leaf.truth == .keep && leaf.leaf.text.count >= 4 && !personal.contains(where: { $0.contains(leaf.leaf.text) }) {
                let before = source.components(separatedBy: leaf.leaf.text).count, after = text.components(separatedBy: leaf.leaf.text).count
                if after < before { add("keptChanged", leaf, "\(leaf.keys.joined(separator: ".")) = \(leaf.leaf.text)") }
            }
        }
        relations(leaves, seen) { add($0, $1, $2) }
        return findings
    }

    static func compare(_ leaf: PathLeaf, _ output: String, number: Bool?, add: (String, PathLeaf?, String) -> Void) {
        let original = leaf.leaf
        let where_ = leaf.keys.joined(separator: ".")
        switch original.truth {
        case .keep where output != original.text || number.map({ $0 != original.number }) == true:
            add("keptChanged", leaf, "\(where_) = \(original.text) → \(output)")
        case .keepSoft where output != original.text:
            add("softChanged", leaf, "\(where_) = \(original.text) → \(output)")
        // Initials, or a birth date's month or day, may match by chance; the relations check they fit.
        // A routing number or sort code names a bank's branch, not its customer: it may stay.
        case .pii(let kind) where output == original.text && !original.text.isEmpty && ![.initials, .dobMonth, .dobDay, .routing, .sortCode].contains(kind):
            add("unchanged", leaf, "\(where_) = \(original.text)")
        case .pii(let kind):
            if let number, number != original.number { add("typeChanged", leaf, "\(where_) = \(original.text) → \(output) (JSON \(original.number ? "number" : "string") became \(number ? "number" : "string"))") }
            else if output != original.text, let problem = misfit(kind, original, output) { add("typeChanged", leaf, "\(where_) = \(original.text) → \(output) (\(problem))") }
        default: break
        }
    }

    /// The SSNs a note writes, dashed.
    static func ssnsIn(_ s: String) -> [String] {
        let ns = s as NSString
        return (try! NSRegularExpression(pattern: #"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)"#)).matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    static func mask(_ s: String) -> String {
        String(s.map { $0.isNumber ? "9" : $0.isLetter ? "A" : $0 })
    }

    /// Why a stand-in can't pass for the value it replaced, or nil when it can.
    static func misfit(_ kind: Kind, _ original: PLeaf, _ output: String) -> String? {
        switch kind {
        case .ssn:
            guard mask(original.text) == mask(output) else { return "shape \(mask(original.text)) → \(mask(output))" }
            // Whole, or each one a note writes: a number the SSA could issue.
            let written = output.contains(where: \.isLetter) ? ssnsIn(output) : [output]
            return written.allSatisfy(KYCChecks.ssn) ? nil : "no valid SSN: \(output)"
        case .itin: return mask(original.text) == mask(output) && KYCChecks.itin(output) ? nil : "not a valid ITIN like \(original.text)"
        case .nationalID:
            guard mask(original.text) == mask(output) else { return "shape \(mask(original.text)) → \(mask(output))" }
            return original.scheme.map { KYCChecks.valid($0, output) } == false ? "fails the \(original.scheme!) check" : nil
        case .iban:
            return mask(original.text) == mask(output) && output.prefix(2) == original.text.prefix(2) && KYCChecks.ibanValid(output) ? nil : "not a valid IBAN like \(original.text)"
        case .routing: return mask(original.text) == mask(output) && KYCChecks.aba(output) ? nil : "not a valid routing number"
        case .sortCode, .zip4: return mask(original.text) == mask(output) ? nil : "shape \(mask(original.text)) → \(mask(output))"
        case .deviceID:
            // Hex in the same layout and case: a UUID stays a UUID, a hash a hash.
            let shape = { (s: String) in String(s.map { $0.isHexDigit ? "x" : $0 }) }
            let upper = { (s: String) in s.contains { $0.isLetter && $0.isUppercase } }
            return shape(original.text) == shape(output) && upper(original.text) == upper(output) ? nil : "not an ID shaped like \(original.text)"
        case .fullAddress:
            guard output.filter({ $0 == "," }).count == original.text.filter({ $0 == "," }).count, output.contains(where: \.isLetter) else { return "not an address like \(original.text)" }
            // The country it names stays.
            if let country = original.text.split(separator: ",").last.map({ $0.trimmingCharacters(in: .whitespaces) }), PayloadGen.kycPlaces.contains(where: { $0.countryName == country }), !output.hasSuffix(country) {
                return "country \(country) not kept"
            }
            return nil
        case .ssnLast4, .taxID, .account, .zip, .passport, .license, .card, .dobYear:
            return mask(original.text) == mask(output) ? nil : "shape \(mask(original.text)) → \(mask(output))"
        case .phone:
            let digits = output.filter(\.isNumber).count
            return digits >= 10 && !output.contains(where: \.isLetter) ? nil : "not a phone number"
        case .email:
            return output.range(of: #"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil ? nil : "not an email"
        case .dob:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = original.dateFormat ?? "yyyy-MM-dd"
            return formatter.date(from: output) == nil ? "not a date as \(formatter.dateFormat!)" : nil
        case .fullName, .firstName, .lastName, .middleName:
            return output.contains(where: \.isNumber) || output.contains("@") || !output.contains(where: \.isLetter) ? "not a name" : nil
        case .city: return output.allSatisfy { $0.isLetter || $0 == " " || $0 == "." || $0 == "-" } ? nil : "not a place"
        case .street: return output.contains(where: \.isLetter) && output.contains(where: \.isNumber) ? nil : "not a street"
        case .ip:
            if original.text.contains(":") { return output.contains(":") ? nil : "not an IPv6 address" }
            return output.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil ? nil : "not an IPv4 address"
        case .username: return output.isEmpty || output.contains(" ") ? "not a username" : nil
        case .recordID:
            // Its type prefix and its shape stay, so joins still work.
            // A type prefix is letters before "_" or "-": "cus_", "E-"; a UUID has none.
            let prefix = { (s: String) -> String in
                let letters = String(s.prefix { $0.isLetter })
                guard let next = s.dropFirst(letters.count).first, "_-".contains(next), !letters.isEmpty else { return "" }
                return letters + String(next)
            }
            return prefix(original.text) == prefix(output) && mask(original.text) == mask(output) ? nil : "not an ID shaped like \(original.text)"
        case .lastDigits, .initials: return mask(original.text) == mask(output) ? nil : "shape \(mask(original.text)) → \(mask(output))"
        case .houseNumber: return mask(original.text) == mask(output) ? nil : "not a house number like \(original.text)"
        case .streetName: return output.contains(where: \.isLetter) && !output.contains(where: \.isNumber) ? nil : "not a street's name"
        // A code stays a code ("TO" → "MI"); a state's name another name ("Jalisco" → "Nuevo León").
        case .province where original.text.count > 3: return output.count > 3 && output.allSatisfy({ $0.isLetter || $0 == " " }) ? nil : "not a state's name"
        case .province: return mask(original.text) == mask(output) && output == output.uppercased() ? nil : "not a province code"
        case .dobMonth: return Int(output).map { (1...12).contains($0) } == true ? nil : "not a month"
        case .dobDay: return Int(output).map { (1...31).contains($0) } == true ? nil : "not a day"
        case .mrz: return MRZ.misfit(original.text, output)
        case .age: return Int(output).map { (0...120).contains($0) } == true ? nil : "not an age"
        case .expiry:
            // A month or a year alone may change width ("6" → "11"); anything longer keeps its layout.
            if original.text.count <= 2 { return Int(output).map { (1...99).contains($0) } == true ? nil : "not a month or a year" }
            return mask(original.text) == mask(output) ? nil : "shape \(mask(original.text)) → \(mask(output))"
        case .region:
            let countries = { (s: String) in Set(Places.regions.filter { $0.code == s || $0.name.caseInsensitiveCompare(s) == .orderedSame }.map(\.country)) }
            guard Places.region(output) != nil else { return "not a region" }
            if countries(original.text).isDisjoint(with: countries(output)) { return "a region of another country" }
            return (original.text.count <= 3) == (output.count <= 3) ? nil : "code and name swapped"
        case .unit:
            let word = { (s: String) in s.split(whereSeparator: { $0 == " " || $0.isNumber }).first.map(String.init) ?? "" }
            // "Bât. A" is a unit named by a letter: its stand-in may be too.
            return word(original.text) == word(output) && (output.contains(where: \.isNumber) || !original.text.contains(where: \.isNumber)) ? nil : "not a unit like \(original.text)"
        case .addressLine:
            return output.filter { $0 == "," }.count == original.text.filter { $0 == "," }.count && AddressParts.line(output) != nil ? nil : "not an address line"
        case .latitude, .longitude:
            let decimals = { (s: String) in s.split(separator: ".").last?.count ?? 0 }
            guard let value = Double(output), abs(value) <= (kind == .latitude ? 90 : 180) else { return "not a coordinate" }
            return decimals(output) == decimals(original.text) ? nil : "precision changed"
        }
    }

    // MARK: Relations

    static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased().filter(\.isLetter) }
    static func regionMatches(_ written: String, _ place: Place) -> Bool {
        guard let region = Places.region(written, in: place.country) else { return false }
        return region.country == place.country && (region.code == place.region || region.name == place.region)
    }
    static func postalMatches(_ written: String, _ place: Place) -> Bool {
        let upper = written.uppercased().trimmingCharacters(in: .whitespaces)
        switch place.country {
        case "US": return place.postal.contains(String(upper.filter(\.isNumber).prefix(5)))
        case "AU": return place.postal.contains(upper)
        case "CA": return place.postal.contains(String(upper.prefix(3)))
        default: return place.postal.contains(upper.contains(" ") ? String(upper.prefix { $0 != " " }) : String(upper.dropLast(3)))
        }
    }

    /// Values that belong together must still agree: an address's parts are
    /// one real place, with the time zone and phone area code beside it; a
    /// person's email, username, initials and first name fit the stand-in
    /// name and gender; a birth year and age fit the birth date; last digits
    /// end the number they come from.
    static func relations(_ leaves: [PathLeaf], _ seen: [[Int]: String], add: (String, PathLeaf?, String) -> Void) {
        guard !seen.isEmpty else { return }
        var groups: [String: [PathLeaf]] = [:]
        for leaf in leaves { for link in leaf.leaf.links { groups[link, default: []].append(leaf) } }
        func kind(_ leaf: PathLeaf) -> Kind? { if case .pii(let kind) = leaf.leaf.truth { return kind }; return nil }
        func outputs(_ members: [PathLeaf], _ wanted: Kind) -> [(PathLeaf, String)] { members.filter { kind($0) == wanted }.compactMap { m in seen[m.path].map { (m, $0) } } }
        for (link, members) in groups.sorted(by: { $0.key < $1.key }) {
            let first = members.first
            if link.hasPrefix("a") {
                streetParts(link, members, seen, add: add)
                // A city abroad stays a city of its country, with that city's province.
                let towns = PayloadGen.towns.map { ($0.country, $0.city) } + PayloadGen.kycPlaces.filter { !["US", "CA", "GB", "AU"].contains($0.country) }.map { ($0.country, $0.city) }
                if let town = towns.first(where: { t in members.contains { kind($0) == .city && $0.leaf.text.caseInsensitiveCompare(t.1) == .orderedSame } }).map({ (country: $0.0, city: $0.1) }) {
                    guard let (cityLeaf, written) = outputs(members, .city).first else { continue }
                    guard let stand = Places.abroad.first(where: { $0.city.caseInsensitiveCompare(written) == .orderedSame }) else {
                        add("placeMismatch", cityLeaf, "\(link): \(written) is no city Scrub knows abroad"); continue
                    }
                    if stand.country != town.country { add("placeMismatch", cityLeaf, "\(link): moved from \(town.country) to \(stand.country)") }
                    for (leaf, value) in outputs(members, .province) where value != stand.region { add("placeMismatch", leaf, "\(link): province \(value) is not \(stand.city)'s \(stand.region ?? "-")") }
                    for (leaf, value) in outputs(members, .zip) where mask(value) != mask(leaf.leaf.text) { add("placeMismatch", leaf, "\(link): postcode \(value) is not written as \(leaf.leaf.text)") }
                    // The postcode is one of the city's: its area, the first two digits, is the city's own.
                    for (leaf, value) in outputs(members, .zip) where value.filter(\.isNumber).prefix(2) != stand.postal.filter(\.isNumber).prefix(2) {
                        add("placeMismatch", leaf, "\(link): postcode \(value) is not in \(stand.city) (\(stand.postal))")
                    }
                    for (leaf, value) in outputs(members, .fullAddress) {
                        let zip = outputs(members, .zip).first?.1
                        if value.range(of: written, options: .caseInsensitive) == nil || zip.map({ value.contains($0) }) == false {
                            add("placeMismatch", leaf, "\(link): line \(value) is not \(zip ?? "") \(written)")
                        }
                    }
                    continue
                }
                let city = outputs(members, .city).first, region = outputs(members, .region).first, postal = outputs(members, .zip).first
                let originalCountry = (PayloadGen.usCities + PayloadGen.otherCities).first { c in members.contains { $0.leaf.text == c.name } }?.country
                    ?? PayloadGen.kycPlaces.first { c in members.contains { kind($0) == .city && $0.leaf.text.caseInsensitiveCompare(c.city) == .orderedSame } }?.country
                var place: Place?
                if let city {
                    // Birmingham, AL or Birmingham, England: the postcode and country say which.
                    let named = Places.all.filter { $0.city.compare(city.1, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame && (region == nil || regionMatches(region!.1, $0)) }
                    place = named.first { p in postal.map { postalMatches($0.1, p) } ?? (p.country == originalCountry) } ?? named.first
                    if place == nil { add("placeMismatch", city.0, "\(link): \(city.1), \(region?.1 ?? "-") \(postal?.1 ?? "") is no real place") }
                } else if let postal {
                    place = Places.all.first { postalMatches(postal.1, $0) && (region == nil || regionMatches(region!.1, $0)) }
                    if place == nil { add("placeMismatch", postal.0, "\(link): \(region?.1 ?? "-") \(postal.1) is no real place") }
                }
                guard let place else { continue }
                if let originalCountry, originalCountry != place.country { add("placeMismatch", first, "\(link): moved from \(originalCountry) to \(place.country)") }
                if let region, !regionMatches(region.1, place) { add("placeMismatch", region.0, "\(link): \(region.1) is not \(place.city)'s region") }
                if let postal, !postalMatches(postal.1, place) { add("placeMismatch", postal.0, "\(link): \(postal.1) is not in \(place.city), \(place.region)") }
                for (leaf, value) in outputs(members, .latitude) + outputs(members, .longitude) {
                    let centre = kind(leaf) == .latitude ? place.latitude : place.longitude
                    if let number = Double(value), abs(number - centre) > 0.1 { add("placeMismatch", leaf, "\(link): \(value) is not near \(place.city)") }
                }
                for (leaf, value) in outputs(members, .addressLine) {
                    guard let parsed = AddressParts.line(value)?.parts else { continue }
                    if parsed.city != place.city || parsed.region.map({ regionMatches($0, place) }) == false || parsed.postal.map({ postalMatches($0, place) }) == false {
                        add("placeMismatch", leaf, "\(link): line \(value) is not \(place.city), \(place.region)")
                    }
                }
                for (leaf, value) in outputs(members, .fullAddress) {
                    let zip = outputs(members, .zip).first?.1
                    if value.range(of: city?.1 ?? place.city, options: .caseInsensitive) == nil || zip.map({ value.contains($0) }) == false || region.map({ value.contains($0.1) }) == false {
                        add("placeMismatch", leaf, "\(link): line \(value) is not \(city?.1 ?? place.city) \(region?.1 ?? "") \(zip ?? "")")
                    }
                }
                for leaf in members where leaf.leaf.truth == .ignore && KeyHints.words(leaf.key).contains(where: { ["timezone", "tz", "zone"].contains($0) }) {
                    guard let value = seen[leaf.path], value != leaf.leaf.text else { continue }
                    if value != place.timeZone { add("placeMismatch", leaf, "\(link): time zone \(value) is not \(place.city)'s \(place.timeZone)") }
                }
                for (leaf, value) in outputs(members, .phone) where ["US", "CA"].contains(place.country) && (!leaf.leaf.text.hasPrefix("+") || leaf.leaf.text.hasPrefix("+1")) {
                    let digits = value.filter(\.isNumber)
                    let area = digits.count == 11 ? String(digits.dropFirst().prefix(3)) : String(digits.prefix(3))
                    if area != place.areaCode { add("placeMismatch", leaf, "\(link): phone \(value) has no \(place.city) area code (\(place.areaCode))") }
                }
            } else if link.hasSuffix(".name") {
                let fulls = outputs(members, .fullName).map { $0.1.split(separator: " ").map(String.init) }
                guard let firstName = outputs(members, .firstName).first?.1 ?? fulls.first?.first, let lastName = outputs(members, .lastName).first?.1 ?? fulls.first?.last else { continue }
                let (f, l) = (fold(firstName), fold(lastName))
                for (leaf, value) in outputs(members, .firstName) where fold(value) != f { add("personMismatch", leaf, "\(link): first name \(value), elsewhere \(firstName)") }
                for (leaf, value) in outputs(members, .lastName) where fold(value) != l { add("personMismatch", leaf, "\(link): last name \(value), elsewhere \(lastName)") }
                for (leaf, value) in outputs(members, .email) + outputs(members, .username) where !fold(String(value.split(separator: "@").first ?? "")).contains(l) {
                    add("personMismatch", leaf, "\(link): \(value) does not follow \(firstName) \(lastName)")
                }
                for (leaf, value) in outputs(members, .mrz) {
                    guard let written = MRZ.writtenName(value) else { add("personMismatch", leaf, "\(link): no name in zone \(value)"); continue }
                    if !fold(lastName).hasPrefix(fold(written.last)) || written.last.isEmpty || !fold(firstName).hasPrefix(fold(written.first)) {
                        add("personMismatch", leaf, "\(link): zone names \(written.last) \(written.first), elsewhere \(firstName) \(lastName)")
                    }
                }
                for (leaf, value) in outputs(members, .initials) where value.filter(\.isLetter) != (firstName.prefix(1) + lastName.prefix(1)).uppercased() {
                    add("personMismatch", leaf, "\(link): initials \(value) for \(firstName) \(lastName)")
                }
                for leaf in members where leaf.leaf.truth == .keep {
                    guard let gender = People.gender(leaf.leaf.text) else { continue }
                    let fits = gender == "female" ? Names.female.contains(firstName.lowercased()) : Names.male.contains(firstName.lowercased())
                    if !fits { add("personMismatch", leaf, "\(link): \(firstName) for \(leaf.key) \(leaf.leaf.text)") }
                }
            } else if link.hasSuffix(".dob") {
                // A zone's birth date is the date its parts write.
                let year = outputs(members, .dobYear).first.flatMap { Int($0.1) }, month = outputs(members, .dobMonth).first.flatMap { Int($0.1) }, day = outputs(members, .dobDay).first.flatMap { Int($0.1) }
                if let year, let month, let day {
                    let date = String(format: "%02d%02d%02d", year % 100, month, day)
                    for (leaf, value) in outputs(members, .mrz) where MRZ.data(value).birth.map({ $0 != date }) == true {
                        add("dateMismatch", leaf, "\(link): zone born \(MRZ.data(value).birth!), parts say \(date)")
                    }
                }
                // A birth date's day and month in fields of their own are the whole date's.
                for (whole, value) in outputs(members, .dob) {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(identifier: "UTC")
                    formatter.dateFormat = whole.leaf.dateFormat ?? "yyyy-MM-dd"
                    guard let date = formatter.date(from: value) else { continue }
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(identifier: "UTC")!
                    let parts = calendar.dateComponents([.year, .month, .day], from: date)
                    for (leaf, part) in outputs(members, .dobMonth) where Int(part) != parts.month { add("dateMismatch", leaf, "\(link): month \(part), birth date \(value)") }
                    for (leaf, part) in outputs(members, .dobDay) where Int(part) != parts.day { add("dateMismatch", leaf, "\(link): day \(part), birth date \(value)") }
                    for (leaf, part) in outputs(members, .dobYear) where Int(part) != parts.year { add("dateMismatch", leaf, "\(link): year \(part), birth date \(value)") }
                }
                let years = outputs(members, .dob).compactMap { value in value.1.range(of: #"(?<!\d)(19|20)\d\d(?!\d)"#, options: .regularExpression).map { Int(value.1[$0])! } }
                guard let year = years.first ?? outputs(members, .dobYear).first.flatMap({ Int($0.1) }) else { continue }
                for (leaf, value) in outputs(members, .dobYear) where Int(value) != year { add("dateMismatch", leaf, "\(link): year \(value), birth date in \(year)") }
                let now = Calendar(identifier: .gregorian).component(.year, from: Date())
                for (leaf, value) in outputs(members, .age) where !(Int(value).map { [now - year - 1, now - year].contains($0) } ?? false) {
                    add("dateMismatch", leaf, "\(link): age \(value), born \(year)")
                }
            } else if link.hasSuffix(".passport") {
                // The zone writes the passport's own number.
                guard let number = outputs(members, .passport).first else { continue }
                for (leaf, value) in outputs(members, .mrz) where MRZ.data(value).number.map({ $0 != number.1.uppercased() }) == true {
                    add("numberMismatch", leaf, "\(link): zone number \(MRZ.data(value).number!), passport \(number.1)")
                }
            } else {
                // A note's number is the one it writes dashed.
                let normal = { (s: String) -> String in let d = (s.contains(where: \.isLetter) ? ssnsIn(s).first ?? s : s).filter(\.isNumber); return d.count == 11 && d.first == "1" ? String(d.dropFirst()) : d }
                let fulls = members.filter { [.ssn, .card, .phone, .account].contains(kind($0)) }.compactMap { m in seen[m.path].map { (m, normal($0)) } }
                if let reference = fulls.first { for (leaf, value) in fulls where value != reference.1 { add("numberMismatch", leaf, "\(link): \(value), elsewhere \(reference.1)") } }
                for (leaf, value) in outputs(members, .lastDigits) {
                    let digits = value.filter(\.isNumber)
                    if let full = fulls.first, !full.1.hasSuffix(digits) { add("numberMismatch", leaf, "\(link): last digits \(value) do not end \(full.1)") }
                }
            }
        }
    }

    /// An address split into its house number and street's name must still
    /// be what the line joining them writes: "Via Garibaldi 12/3" beside
    /// "Garibaldi" and 12 comes out as the same street and number in both.
    static func streetParts(_ link: String, _ members: [PathLeaf], _ seen: [[Int]: String], add: (String, PathLeaf?, String) -> Void) {
        func output(_ kind: Kind) -> [(PathLeaf, String)] {
            members.compactMap { m in m.leaf.truth == .pii(kind) ? seen[m.path].map { (m, $0) } : nil }
        }
        func tokens(_ s: String) -> [String] { s.split(whereSeparator: { !$0.isNumber }).map(String.init) }
        for (line, written) in output(.street) + output(.fullAddress) where line.leaf.text.first?.isNumber != written.first?.isNumber {
            add("streetMismatch", line, "\(link): \(written) does not write its number where \(line.leaf.text) does")
        }
        for (line, written) in output(.street) + output(.addressLine) + output(.fullAddress) {
            for (part, value) in output(.streetName) where line.leaf.text.range(of: part.leaf.text, options: .caseInsensitive) != nil {
                if written.range(of: value, options: .caseInsensitive) == nil { add("streetMismatch", line, "\(link): line \(written) is not on street \(value)") }
            }
            for (part, value) in output(.houseNumber) + output(.unit) where tokens(line.leaf.text).contains(part.leaf.text) {
                if !tokens(written).contains(value) { add("streetMismatch", line, "\(link): line \(written) has no number \(value) (\(part.key))") }
            }
        }
    }

    /// The part of a personal value still in the output, if any: the value
    /// itself, its digits with any separators, or a name word that no stand-in uses.
    static func leaked(_ value: String, kind: Kind, in output: String) -> String? {
        if output.range(of: value, options: [.caseInsensitive]) != nil, value.count >= 4 || kind == .dobYear {
            // Short values that turn up anywhere by chance are judged where they sit.
            if [.lastDigits, .age, .initials, .unit, .expiry].contains(kind) { return nil }
            if kind == .dobYear || kind == .ssnLast4 || kind == .zip {
                // Every IPv6 stand-in starts "2001:db8:", the documentation prefix: no birth year of 2001.
                return output.range(of: #"(?<!\d)"# + NSRegularExpression.escapedPattern(for: value) + #"(?!\d|:db8:)"#, options: .regularExpression) != nil ? value : nil
            }
            if kind.isName || kind == .city || kind == .region {
                // Stand-ins come from the same lists; only a word no stand-in uses proves a leak.
                return value.split(whereSeparator: { !$0.isLetter }).map(String.init).first { word in
                    word.count >= 3 && !Names.firstFolded.contains(word.lowercased()) && !Names.lastFolded.contains(word.lowercased()) && !Names.citiesFolded.contains(word.lowercased())
                        && output.range(of: #"(?<![\p{L}])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![\p{L}])"#, options: [.regularExpression, .caseInsensitive]) != nil
                }
            }
            return value
        }
        let digits = value.filter(\.isNumber)
        if digits.count >= 7, kind != .dob {
            let pattern = #"(?<!\d)"# + digits.map(String.init).joined(separator: #"[\s\-.()/]*"#) + #"(?!\d)"#
            if output.range(of: pattern, options: .regularExpression) != nil { return digits }
        }
        if kind.isName {
            return value.split(whereSeparator: { !$0.isLetter }).map(String.init).first { word in
                word.count >= 3 && !Names.firstFolded.contains(word.lowercased()) && !Names.lastFolded.contains(word.lowercased())
                    && output.range(of: #"(?<![\p{L}])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![\p{L}])"#, options: [.regularExpression, .caseInsensitive]) != nil
            }
        }
        if kind == .streetName || kind == .street {
            // Any word of a street's own name: "Garibaldi" of "Via Garibaldi 12", not "Via" or "Rue".
            let kinds: Set<String> = ["via", "viale", "vicolo", "corso", "piazza", "rue", "avenue", "boulevard", "impasse", "calle", "avenida", "paseo", "de", "del", "la", "las", "los", "des", "du", "dei", "di", "san", "am", "rd", "ave", "ln", "ct", "dr", "blvd", "way", "street", "road", "lane", "grove", "hill", "avenida", "rua", "calle"]
            // Stand-in streets are named from these lists; only a word none of them uses proves a leak.
            let standIns = Set((Names.streets + Places.streetWords.values.flatMap { $0 }).flatMap { $0.lowercased().split(separator: " ").map(String.init) })
            for word in value.split(whereSeparator: { !$0.isLetter }) where word.count >= 4 && !kinds.contains(word.lowercased()) && !standIns.contains(word.lowercased())
                && !Names.firstFolded.contains(word.lowercased()) && !Names.lastFolded.contains(word.lowercased()) {
                if output.range(of: #"(?<![\p{L}])"# + NSRegularExpression.escapedPattern(for: String(word)) + #"(?![\p{L}])"#, options: [.regularExpression, .caseInsensitive]) != nil { return String(word) }
            }
        }
        if kind == .street, value.first?.isNumber == true, let name = value.split(separator: " ", maxSplits: 1).last,
           output.range(of: String(name), options: .caseInsensitive) != nil { return String(name) }
        return nil
    }

    /// Parts of personal values still in the output, judged from the
    /// generator's truth alone (see `ComponentLeaks`): a name's word, an
    /// email's local part, a number's digits or its last four.
    static func componentLeaks(_ payload: PNode, _ rendered: Rendered, output: Data) -> [Finding] {
        let planted = payload.leaves().compactMap { leaf -> ComponentLeaks.Planted? in
            guard case .pii(let kind) = leaf.leaf.truth else { return nil }
            switch kind {
            case .fullName, .firstName, .lastName, .middleName: return .init(leaf.leaf.text, kind: .name)
            case .email: return .init(leaf.leaf.text, kind: .email)
            case .phone, .taxID, .card, .account, .license, .passport, .itin, .nationalID, .iban: return .init(leaf.leaf.text, kind: .number)
            case .ssn: return .init(leaf.leaf.text.contains(where: \.isLetter) ? ssnsIn(leaf.leaf.text).first ?? leaf.leaf.text : leaf.leaf.text, kind: .number)
            case .username, .recordID, .mrz, .deviceID: return .init(leaf.leaf.text, kind: .other)
            default: return nil
            }
        }
        return ComponentLeaks.leaks(planted, input: rendered.text, output: String(decoding: output, as: UTF8.self)).map { part in
            Finding(problem: "componentLeak", rendering: rendered.rendering.rawValue, truth: "-", key: "-", parent: "-", detail: "still has \(part)")
        }
    }

    static func jsonValue(_ value: JSONValue, at path: [Int]) -> JSONValue? {
        var node = value
        for index in path {
            switch node {
            case .object(let pairs) where index < pairs.count: node = pairs[index].1
            case .array(let members) where index < members.count: node = members[index]
            default: return nil
            }
        }
        return node
    }
}
