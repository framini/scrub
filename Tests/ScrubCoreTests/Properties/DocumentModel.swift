import Foundation
@testable import ScrubCore

struct ModelLeaf {
    let path: String
    let key: String?
    let value: String
    let isName: Bool
}

struct DocumentModel {
    var shape: [String] = []
    var leaves: [ModelLeaf] = []
    init(data: Data, format: String, delimiter: Character = ",", quote: Character = "\"") throws {
        let text = String(decoding: data, as: UTF8.self)
        switch format {
        case "json": json(try OrderedJSON.parse(text), path: "$", key: nil)
        case "csv":
            let rows = try CSVFile.parse(text, delimiter: delimiter, quoteCharacter: quote)
            shape = rows.map { "row:\($0.count)" }
            for (r, row) in rows.enumerated() {
                for (c, cell) in row.enumerated() {
                    leaves.append(ModelLeaf(path: "row[\(r)]/column[\(c)]", key: r > 0 ? rows.first?[c] : nil, value: cell, isName: r == 0))
                }
            }
        case "xml":
            let document = try XMLDocument(data: data, options: [.nodePreserveCDATA, .nodePreserveWhitespace, .nodePreserveAttributeOrder, .nodePreserveNamespaceOrder, .nodeLoadExternalEntitiesNever])
            xml(document, path: "$", key: nil)
        default: leaves = [ModelLeaf(path: "$", key: nil, value: text, isName: false)]
        }
    }
    private mutating func json(_ node: JSONValue, path: String, key: String?) {
        switch node {
        case .object(let pairs):
            shape.append("\(path):object:\(pairs.count)")
            for (i, pair) in pairs.enumerated() {
                let child = path + "/key[\(i)]"
                leaves.append(ModelLeaf(path: child + "/name", key: nil, value: pair.0, isName: true))
                json(pair.1, path: child, key: pair.0)
            }
        case .array(let children):
            shape.append("\(path):array:\(children.count)")
            for (i, child) in children.enumerated() { json(child, path: path + "/[\(i)]", key: key) }
        case .string(let value): scalar("string", value, path, key)
        case .number(let value): scalar("number", value, path, key)
        case .bool(let value): scalar("bool", String(value), path, key)
        case .null: scalar("null", "null", path, key)
        }
    }
    private mutating func scalar(_ type: String, _ value: String, _ path: String, _ key: String?) {
        shape.append("\(path):\(type)")
        leaves.append(ModelLeaf(path: path, key: key, value: value, isName: false))
    }
    private mutating func xml(_ node: XMLNode, path: String, key: String?) {
        shape.append("\(path):kind=\(node.kind.rawValue):children=\(node.childCount)")
        if let name = node.name { leaves.append(ModelLeaf(path: path + "/name", key: nil, value: name, isName: true)) }
        if let element = node as? XMLElement {
            let attributes = element.attributes ?? []
            let namespaces = element.namespaces ?? []
            shape.append("\(path):attributes=\(attributes.count):namespaces=\(namespaces.count)")
            for (i, attribute) in attributes.enumerated() { xml(attribute, path: path + "/attribute[\(i)]", key: attribute.localName) }
            for (i, namespace) in namespaces.enumerated() { xml(namespace, path: path + "/namespace[\(i)]", key: nil) }
        } else if node.kind != .document, let value = node.stringValue {
            leaves.append(ModelLeaf(path: path + "/value", key: key, value: value, isName: false))
        }
        for (i, child) in (node.children ?? []).enumerated() {
            xml(child, path: path + "/node[\(i)]", key: child.kind == .text ? node.localName : nil)
        }
    }
}
