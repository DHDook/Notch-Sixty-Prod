import Foundation

/// A small JSON Schema (2020-12) checker for the subset the `schemas/` documents use:
/// type, const, enum, required, properties, additionalProperties (boolean), items, minimum,
/// exclusiveMinimum, pattern, and local or sibling-file `$ref`. No third-party dependency.
/// Unknown keywords are an error, so a schema cannot silently use something unchecked.
struct JSONSchemaChecker {
    let schemasDirectory: URL
    private static let supported: Set<String> = [
        "$schema", "$id", "$defs", "$ref", "title", "description", "type", "const", "enum", "required",
        "properties", "additionalProperties", "items", "minimum", "exclusiveMinimum", "pattern"
    ]

    enum CheckerError: Error { case notObject, badRef(String), unsupportedKeyword(String) }

    func load(_ file: String) throws -> [String: Any] {
        let data = try Data(contentsOf: schemasDirectory.appendingPathComponent(file))
        return try Self.object(JSONSerialization.jsonObject(with: data))
    }

    /// Returns human-readable violations; empty means the instance conforms.
    func violations(of instance: Any, schemaFile: String) throws -> [String] {
        let root = try load(schemaFile)
        var out: [String] = []
        try check(instance, root, root: root, rootFile: schemaFile, path: "$", out: &out)
        return out
    }

    private static func object(_ value: Any) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw CheckerError.notObject }
        return object
    }

    private func resolve(_ ref: String, root: [String: Any], rootFile: String) throws -> ([String: Any], [String: Any], String) {
        let parts = ref.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let file = String(parts[0])
        let pointer = parts.count > 1 ? String(parts[1]) : ""
        var newRoot = root
        var newFile = rootFile
        if !file.isEmpty { newRoot = try load(file); newFile = file }
        var node: Any = newRoot
        for component in pointer.split(separator: "/") {
            guard let dict = node as? [String: Any], let next = dict[String(component)] else {
                throw CheckerError.badRef(ref)
            }
            node = next
        }
        return (try Self.object(node), newRoot, newFile)
    }

    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func typeMatches(_ type: String, _ value: Any) -> Bool {
        switch type {
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "string": return value is String
        case "boolean": return isBool(value)
        case "null": return value is NSNull
        case "number": return value is NSNumber && !isBool(value)
        case "integer":
            guard let n = value as? NSNumber, !isBool(value) else { return false }
            return n.doubleValue == n.doubleValue.rounded() && n.doubleValue.isFinite
        default: return false
        }
    }

    private func check(_ value: Any, _ schema: [String: Any], root: [String: Any], rootFile: String,
                       path: String, out: inout [String]) throws {
        for key in schema.keys where !Self.supported.contains(key) {
            throw CheckerError.unsupportedKeyword(key)
        }
        if let ref = schema["$ref"] as? String {
            let (target, newRoot, newFile) = try resolve(ref, root: root, rootFile: rootFile)
            try check(value, target, root: newRoot, rootFile: newFile, path: path, out: &out)
            return
        }
        if let type = schema["type"] as? String, !Self.typeMatches(type, value) {
            out.append("\(path): expected \(type)")
            return
        }
        if let constant = schema["const"] as? NSNumber {
            if let n = value as? NSNumber, !Self.isBool(value), n == constant {} else { out.append("\(path): const mismatch") }
        }
        if let allowed = schema["enum"] as? [Any] {
            let ok = allowed.contains { a in
                if let s = a as? String, let v = value as? String { return s == v }
                if let n = a as? NSNumber, let v = value as? NSNumber { return n == v }
                return false
            }
            if !ok { out.append("\(path): not in enum") }
        }
        if let n = value as? NSNumber, !Self.isBool(value) {
            if let m = schema["minimum"] as? NSNumber, n.doubleValue < m.doubleValue { out.append("\(path): below minimum") }
            if let m = schema["exclusiveMinimum"] as? NSNumber, n.doubleValue <= m.doubleValue { out.append("\(path): not above exclusiveMinimum") }
        }
        if let s = value as? String, let pattern = schema["pattern"] as? String,
           s.range(of: pattern, options: .regularExpression) == nil {
            out.append("\(path): pattern mismatch")
        }
        if let object = value as? [String: Any] {
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for key in (schema["required"] as? [String] ?? []) where object[key] == nil {
                out.append("\(path): missing \(key)")
            }
            for (key, child) in object.sorted(by: { $0.key < $1.key }) {
                if let sub = properties[key] as? [String: Any] {
                    try check(child, sub, root: root, rootFile: rootFile, path: "\(path).\(key)", out: &out)
                } else if schema["additionalProperties"] as? Bool == false {
                    out.append("\(path): unexpected key \(key)")
                }
            }
        }
        if let array = value as? [Any], let items = schema["items"] as? [String: Any] {
            for (index, child) in array.enumerated() {
                try check(child, items, root: root, rootFile: rootFile, path: "\(path)[\(index)]", out: &out)
            }
        }
    }
}
