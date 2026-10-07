import Foundation
@testable import ScrubCore

/// One payload as each way it reaches the app: a file (JSON, XML, CSV) or
/// pasted text (the JSON itself, a curl command, a log line, a JavaScript or
/// Python literal, YAML).
enum Rendering: String, CaseIterable {
    case json, jsonMinified, xml, csv, pastedJSON, curl, logLine, javascript, python, yaml, prose
    var filename: String {
        switch self {
        case .json, .jsonMinified: return "payload.json"
        case .xml: return "payload.xml"
        case .csv: return "payload.csv"
        default: return "payload.txt"
        }
    }
    /// Pasted text that holds the payload as JSON, which must still parse after scrubbing.
    var embedsJSON: Bool { [.pastedJSON, .curl, .logLine].contains(self) }
}

struct Rendered {
    let rendering: Rendering
    let text: String
    /// For CSV: where each leaf lands, as (row, column), rows counted after the header.
    var cells: [[Int]: (Int, Int)] = [:]
    var header: [String] = []
}

enum Render {
    static func json(_ node: PNode, indent: String?) -> String {
        var out = ""
        func write(_ node: PNode, depth: Int) {
            let pad = indent.map { "\n" + String(repeating: $0, count: depth + 1) } ?? ""
            let close = indent.map { "\n" + String(repeating: $0, count: depth) } ?? ""
            let colon = indent == nil ? ":" : ": "
            switch node {
            case .object(let pairs):
                out += "{"
                for (i, pair) in pairs.enumerated() {
                    out += (i > 0 ? "," : "") + pad + OrderedJSON.quote(pair.0) + colon
                    write(pair.1, depth: depth + 1)
                }
                out += (pairs.isEmpty ? "" : close) + "}"
            case .array(let members, _):
                out += "["
                for (i, member) in members.enumerated() {
                    out += (i > 0 ? "," : "") + pad
                    write(member, depth: depth + 1)
                }
                out += (members.isEmpty ? "" : close) + "]"
            case .leaf(let leaf): out += leaf.number ? leaf.text : OrderedJSON.quote(leaf.text)
            case .bool(let value): out += value ? "true" : "false"
            case .null: out += "null"
            }
        }
        write(node, depth: 0)
        return out
    }

    static func xml(_ node: PNode) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        func element(_ name: String, _ node: PNode, depth: Int) -> String {
            let pad = "\n" + String(repeating: "  ", count: depth)
            switch node {
            case .object(let pairs): return pad + "<\(name)>" + pairs.map { element($0.0, $0.1, depth: depth + 1) }.joined() + pad + "</\(name)>"
            case .array(let members, let item): return pad + "<\(name)>" + members.map { element(item, $0, depth: depth + 1) }.joined() + pad + "</\(name)>"
            case .leaf(let leaf): return pad + "<\(name)>\(escape(leaf.text))</\(name)>"
            case .bool(let value): return pad + "<\(name)>\(value)</\(name)>"
            case .null: return pad + "<\(name)/>"
            }
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + element("response", node, depth: 0) + "\n"
    }

    /// The records of a list page as rows, or a single record flattened into one
    /// row, with headers written the ways exports write them.
    static func csv(_ node: PNode, gen: inout Gen) -> Rendered? {
        var records: [PNode] = []
        if case .object(let pairs) = node {
            if let list = pairs.first(where: { if case .array(let m, _) = $0.1, m.count > 1, case .object = m[0] { return true }; return false }), case .array(let members, _) = list.1 {
                records = members
            } else if pairs.contains(where: { if case .leaf = $0.1 { return true }; return false }) {
                records = [node]
            }
        }
        guard !records.isEmpty else { return nil }
        let style = gen.int(0...2)
        func header(_ keys: [String]) -> String {
            switch style {
            case 0: return keys.joined(separator: ".")
            case 1: return keys.joined(separator: "_")
            default: return keys.flatMap { KeyHints.words($0) }.map(\.capitalized).joined(separator: " ")
            }
        }
        var columns: [String] = []
        var index: [String: Int] = [:]
        var rows: [[String]] = []
        var cells: [[Int]: (Int, Int)] = [:]
        let base: [Int] = {
            guard records.count > 1, case .object(let pairs) = node else { return [] }
            return [pairs.firstIndex { if case .array(let m, _) = $0.1, m.count > 1 { return true }; return false }!]
        }()
        for (r, record) in records.enumerated() {
            var row: [String] = []
            func visit(_ node: PNode, path: [Int], keys: [String]) {
                switch node {
                case .object(let pairs): for (i, pair) in pairs.enumerated() { visit(pair.1, path: path + [i], keys: keys + [pair.0]) }
                case .array(let members, _): for (i, member) in members.enumerated() { visit(member, path: path + [i], keys: keys + [String(i)]) }
                default:
                    let name = header(keys)
                    let column = index[name] ?? { index[name] = columns.count; columns.append(name); return columns.count - 1 }()
                    while row.count <= column { row.append("") }
                    switch node {
                    case .leaf(let leaf):
                        row[column] = leaf.text
                        cells[(records.count > 1 ? base + [r] : []) + path] = (r, column)
                    case .bool(let value): row[column] = String(value)
                    default: row[column] = ""
                    }
                }
            }
            visit(record, path: [], keys: [])
            rows.append(row)
        }
        func quote(_ cell: String) -> String {
            cell.contains(",") || cell.contains("\"") || cell.contains("\n") ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
        }
        let lines = [columns] + rows.map { $0 + Array(repeating: "", count: columns.count - $0.count) }
        return Rendered(rendering: .csv, text: lines.map { $0.map(quote).joined(separator: ",") }.joined(separator: "\n") + "\n", cells: cells, header: columns)
    }

    static func literal(_ node: PNode, python: Bool, singleQuotes: Bool) -> String {
        func string(_ s: String) -> String {
            let q = singleQuotes ? "'" : "\""
            return q + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: q, with: "\\" + q) + q
        }
        func key(_ k: String) -> String {
            !python && k.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) && k.first?.isLetter == true ? k : string(k)
        }
        func write(_ node: PNode, depth: Int) -> String {
            let pad = String(repeating: "    ", count: depth + 1), close = String(repeating: "    ", count: depth)
            switch node {
            case .object(let pairs): return "{\n" + pairs.map { pad + key($0.0) + ": " + write($0.1, depth: depth + 1) }.joined(separator: ",\n") + ",\n" + close + "}"
            case .array(let members, _): return "[" + members.map { write($0, depth: depth + 1) }.joined(separator: ", ") + "]"
            case .leaf(let leaf): return leaf.number ? leaf.text : string(leaf.text)
            case .bool(let value): return python ? (value ? "True" : "False") : String(value)
            case .null: return python ? "None" : "null"
            }
        }
        return write(node, depth: 0)
    }

    static func yaml(_ node: PNode) -> String {
        func scalar(_ leaf: PLeaf) -> String {
            let plain = leaf.number || leaf.text.allSatisfy { $0.isLetter || $0.isNumber || " ._-@/+".contains($0) } && !leaf.text.hasPrefix(" ")
            return plain ? leaf.text : OrderedJSON.quote(leaf.text)
        }
        var lines: [String] = []
        func write(_ node: PNode, depth: Int, prefix: String) {
            let pad = String(repeating: "  ", count: depth)
            switch node {
            case .object(let pairs):
                for (i, pair) in pairs.enumerated() {
                    let lead = i == 0 && !prefix.isEmpty ? prefix : pad
                    switch pair.1 {
                    case .leaf(let leaf): lines.append(lead + pair.0 + ": " + scalar(leaf))
                    case .bool(let value): lines.append(lead + pair.0 + ": " + String(value))
                    case .null: lines.append(lead + pair.0 + ": null")
                    default:
                        lines.append(lead + pair.0 + ":")
                        write(pair.1, depth: depth + 1, prefix: "")
                    }
                }
            case .array(let members, _):
                for member in members {
                    switch member {
                    case .leaf(let leaf): lines.append(pad + "- " + scalar(leaf))
                    default: write(member, depth: depth + 1, prefix: pad + "- ")
                    }
                }
            default: break
            }
        }
        write(node, depth: 0, prefix: "")
        return lines.joined(separator: "\n") + "\n"
    }

    static func render(_ node: PNode, as rendering: Rendering, gen: inout Gen) -> Rendered? {
        switch rendering {
        case .json: return Rendered(rendering: rendering, text: json(node, indent: gen.choose(["  ", "    ", "\t"])) + "\n")
        case .jsonMinified: return Rendered(rendering: rendering, text: json(node, indent: nil))
        case .xml: return Rendered(rendering: rendering, text: xml(node))
        case .csv: return csv(node, gen: &gen)
        case .pastedJSON: return Rendered(rendering: rendering, text: json(node, indent: "  "))
        case .curl:
            // An apostrophe in the body ("O'Sullivan") is written as a shell writes it in single quotes.
            let body = json(node, indent: gen.int(0...1) == 0 ? nil : "  ").replacingOccurrences(of: "'", with: "'\\''")
            return Rendered(rendering: rendering, text: "curl -X POST https://api.example.com/v1/records \\\n  -H 'Content-Type: application/json' \\\n  -H 'Authorization: Bearer $API_TOKEN' \\\n  -d '\(body)'\n")
        case .logLine:
            return Rendered(rendering: rendering, text: "2025-11-04T16:21:09.412Z INFO  [http-nio-8080-exec-7] c.e.api.RequestLogger - POST /v1/records status=200 duration_ms=184 body=\(json(node, indent: nil))\n")
        case .javascript: return Rendered(rendering: rendering, text: "const payload = " + literal(node, python: false, singleQuotes: gen.int(0...1) == 0) + ";\n")
        case .python: return Rendered(rendering: rendering, text: "payload = " + literal(node, python: true, singleQuotes: gen.int(0...1) == 0) + "\n")
        case .yaml: return Rendered(rendering: rendering, text: yaml(node))
        case .prose: return prose(node, gen: &gen)
        }
    }

    /// The payload's first person and address as people write them: a support
    /// note, a mailing label, or labelled lines.
    static func prose(_ node: PNode, gen: inout Gen) -> Rendered? {
        let leaves = node.leaves()
        func value(_ kind: Kind, link: String? = nil) -> String? {
            leaves.first { $0.leaf.truth == .pii(kind) && (link == nil || $0.leaf.links.contains(link!)) }?.leaf.text
        }
        guard let nameLink = leaves.first(where: { $0.leaf.truth == .pii(.firstName) })?.leaf.links.first(where: { $0.hasSuffix(".name") }),
              let first = value(.firstName, link: nameLink), let last = value(.lastName, link: nameLink) else { return nil }
        let email = value(.email, link: nameLink)
        let phone = value(.phone)
        var address: String?
        if let city = leaves.first(where: { $0.leaf.truth == .pii(.city) }), let link = city.leaf.links.first(where: { $0.hasPrefix("a") }),
           let street = value(.street, link: link), let region = value(.region, link: link), region.count <= 3, let zip = value(.zip, link: link) {
            address = "\(street), \(city.leaf.text), \(region) \(zip)"
        }
        let full = first + " " + last
        var lines: [String]
        switch gen.int(0...2) {
        case 0:
            lines = ["Hi team,", "", "\(full)" + (email.map { " (\($0))" } ?? "") + " called about a missing delivery." + (phone.map { " Best number is \($0)." } ?? "")]
            if let address { lines.append("Please ship the replacement to \(full), \(address).") }
            lines += ["", "Thanks,", "Support"]
        case 1:
            guard let address else { return nil }
            let parts = address.components(separatedBy: ", ")
            lines = [full.uppercased(), parts[0], parts.dropFirst().joined(separator: ", ")]
        default:
            lines = ["Customer: \(full)"] + (email.map { ["Email: \($0)"] } ?? []) + (phone.map { ["Phone: \($0)"] } ?? []) + (address.map { ["Address: \($0)"] } ?? [])
        }
        return Rendered(rendering: .prose, text: lines.joined(separator: "\n") + "\n")
    }
}

extension Judge {
    static func sameShape(_ payload: PNode, _ parsed: JSONValue, path: String) -> String? {
        switch payload {
        case .object(let a):
            guard case .object(let b) = parsed else { return path + ": type changed" }
            guard a.count == b.count else { return path + ": \(a.count) keys → \(b.count)" }
            for index in a.indices {
                let (left, right) = (a[index], b[index])
                if left.0 != right.0 { return path + ": key " + left.0 + " → " + right.0 }
                if let problem = sameShape(left.1, right.1, path: path + "." + left.0) { return problem }
            }
            return nil
        case .array(let a, _):
            guard case .array(let b) = parsed else { return path + ": type changed" }
            guard a.count == b.count else { return path + ": \(a.count) items → \(b.count)" }
            for index in a.indices { if let problem = sameShape(a[index], b[index], path: path + "[\(index)]") { return problem } }
            return nil
        case .leaf(_):
            switch parsed { case .string(_), .number(_): return nil; default: return path + ": type changed" }
        case .bool(_):
            if case .bool(_) = parsed { return nil }
            return path + ": type changed"
        case .null:
            if case .null = parsed { return nil }
            return path + ": type changed"
        }
    }
}
