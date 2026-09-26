import Foundation
@testable import ScrubCore

extension Gen {
    static let hintKeys = [
        ["password", "api_key", "clientSecret", "token"], ["email", "email_address", "mail"],
        ["national_id", "passportNumber", "tax_id"], ["name", "full_name", "displayName"],
        ["firstName", "given_name"], ["lastName", "surname"], ["username", "login", "handle"],
        ["phone", "mobile", "telephone"]
    ]
    mutating func document(format: String, plain: Bool = false, capitalized: Bool = false, large: Bool = false) throws -> GeneratedDocument {
        let delimiter: Character = choose([",", ";", "\t", "|"])
        let quote: Character = choose(["\"", "'"])
        let newline = choose(["\n", "\r\n"])
        let amount = large ? 55 : (int(0...19) == 0 ? int(35...55) : int(1...3))
        var planted: [PlantedValue] = []
        var records: [[(String, String, Bool)]] = []
        let group = int(0...7)
        let key = choose(Self.hintKeys[group])
        var originals: [String] = []
        for i in 0..<amount {
            let original: String
            if i > 0 && int(0...2) == 0 { original = choose(originals) }
            else {
                switch group {
                case 1: original = token().lowercased() + "@private.invalid"
                case 3: original = choose(["Robert Mitchell", "Jennifer Sullivan", "Patricia Reynolds", "Christopher Bennett"])
                case 4: original = choose(["Robert", "Jennifer", "Patricia", "Christopher"])
                case 5: original = choose(["Mitchell", "Sullivan", "Reynolds", "Bennett"])
                case 7: original = "212-867-" + String(int(1000...9999))
                default: original = token() + (group == 0 && !plain && int(0...2) == 0 ? "&<\"'\\\n" + String(delimiter) : "")
                }
            }
            originals.append(original)
            let numeric = !plain && format == "json" && [0, 2, 7].contains(group) && int(0...3) == 0
            let value = numeric ? String(int(20000000...89999999)) : original
            let pattern = patternValue()
            if !plain {
                planted.append(PlantedValue(original: value, key: key))
                planted.append(PlantedValue(original: pattern, key: ""))
            }
            let filler = filler(capitalized: capitalized)
            let punctuation = "\(filler)\(delimiter) useful \(quote)table\(quote)\(newline)summary"
            var fields: [(String, String, Bool)]
            if plain {
                fields = [("description", filler, false), ("quantity", String(int(1...999)), format == "json"), ("details", punctuation, false)]
            } else {
                fields = [(key, value, numeric), ("note", "item \(value) complete; repeat \(value) summary", false), ("details", pattern, false), ("description", punctuation, false)]
            }
            fields = shuffled(fields)
            records.append(fields)
        }
        let text: String
        switch format {
        case "json":
            var children: [JSONValue] = []
            for fields in records {
                var pairs: [(String, JSONValue)] = fields.map { key, value, numeric in
                    (key, numeric ? .number(value) : .string(value))
                }
                if !plain && int(0...2) == 0, let first = fields.first(where: { KeyHints.hint($0.0) != nil }) {
                    pairs.append((choose(Self.hintKeys[group].filter { $0 != first.0 }), .array([.string(first.1), .string(first.1)])))
                }
                if !plain && int(0...3) == 0 {
                    _ = token()
                    if let field = fields.first(where: { KeyHints.hint($0.0) != nil }) { pairs.append((field.1, .bool(true))) }
                }
                pairs.append(("enabled", .bool(true)))
                pairs.append(("optional", .null))
                var node = JSONValue.object(pairs)
                for depth in 0..<int(0...3) {
                    node = int(0...1) == 0 ? .array([node]) : .object([("batch\(depth)", node)])
                }
                children.append(node)
            }
            text = OrderedJSON.render(.array(children)).0
        case "csv":
            let columns = records[0].map(\.0)
            var rows = [columns]
            for fields in records { rows.append(columns.map { column in fields.first { $0.0 == column }!.1 }) }
            text = rows.map { row in row.map { csvCell($0, delimiter: delimiter, quote: quote) }.joined(separator: String(delimiter)) }.joined(separator: newline) + newline
        case "xml":
            let prefix = choose(["p", "data", "v"])
            var body = ""
            for fields in records {
                var attributes = ""
                var elements = ""
                for (key, value, _) in fields {
                    if int(0...2) == 0 {
                        attributes += " \(prefix):\(key)=\"\(xmlEscaped(value))\""
                    } else {
                        let content = int(0...2) == 0 ? "<![CDATA[\(value)]]>" : xmlEscaped(value)
                        elements += "<\(prefix):\(key)>\(content)</\(prefix):\(key)>"
                    }
                }
                var record = "<item\(attributes)>\(elements)</item>"
                for _ in 0..<int(0...3) { record = "<batch>\(record)</batch>" }
                body += record
            }
            let repeated = plain ? "summary" : planted[0].original
            let decorations = "<!--item \(repeated)--><?audit item \(repeated)?>"
            if !plain, let original = planted.first?.original {
                let joined = original.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
                let name = joined.first?.isLetter == true ? joined : "value_" + joined
                body += "<\(name) \(name)=\"\(xmlEscaped(original))\"/>"
                if group == 3 { planted.append(PlantedValue(original: joined, key: "")) }
            }
            let raw = decorations + "<root xmlns:\(prefix)=\"urn:example:records\">" + decorations + body + "</root>" + decorations
            text = raw
        default:
            if plain { text = records.map { $0.map(\.1).joined(separator: " ") }.joined(separator: newline) }
            else {
                planted = (0..<amount).map { _ in PlantedValue(original: patternValue(), key: "") }
                text = planted.map { "item \($0.original) complete" }.joined(separator: newline)
            }
        }
        var document = GeneratedDocument(text: text, format: format, planted: planted, delimiter: delimiter, quote: quote, newline: newline)
        document.structure = try DocumentModel(data: document.data, format: format, delimiter: delimiter, quote: quote)
        for leaf in document.structure?.leaves ?? [] where !leaf.isName && KeyHints.hint(leaf.key) == nil {
            document.plantedRanges[leaf.path] = document.ranges(in: leaf.value)
        }
        return document
    }
    mutating func patternValue() -> String {
        switch int(0...7) {
        case 0: return token().lowercased() + "@private.invalid"
        case 1:
            let account = string("0123456789", count: 10)
            let body = "DE00" + "10020030" + account
            return (0...98).map { "DE" + String(format: "%02d", $0) + body.dropFirst(4) }.first { Patterns.iban($0) }!
        case 2: return "\(int(201...599))-\(int(10...89))-\(int(1000...9999))"
        case 3:
            let stem = "4532" + string("0123456789", count: 11)
            return (0...9).map { stem + String($0) }.first { Patterns.luhn($0.compactMap(\.wholeNumberValue)) }!
        case 4: return "198.51.100.\(int(1...254))"
        case 5: return "sk_live_" + token()
        case 6: return "2001:db8::\(String(int(256...65535), radix: 16))"
        default: return "\(int(100...999)) Example Street"
        }
    }
}

private func csvCell(_ cell: String, delimiter: Character, quote: Character) -> String {
    guard cell.contains(delimiter) || cell.contains(quote) || cell.contains("\n") || cell.contains("\r") else { return cell }
    let q = String(quote)
    return q + cell.replacingOccurrences(of: q, with: q + q) + q
}

private func xmlEscaped(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "\r", with: "&#13;").replacingOccurrences(of: "\n", with: "&#10;").replacingOccurrences(of: "\t", with: "&#9;")
}
