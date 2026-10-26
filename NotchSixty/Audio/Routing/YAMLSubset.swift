import Foundation

// E8 S9: an in-house reader for the YAML subset CamillaDSP files use (owner decision 2 of 25 Oct 2026: no dependency).
// Supported: block mappings and sequences by indentation, inline `- key: value` items, flow sequences and mappings
// (`[0, 1]`, `{}`), plain and quoted scalars, comments, a leading `---`. Not supported, and reported with a line number:
// tabs for indentation, anchors and aliases, tags, block scalars (`|`, `>`), multiple documents. Pure; no I/O.

struct YAMLSubsetError: Error, Equatable, LocalizedError {
    var line: Int
    var message: String
    var errorDescription: String? { "Line \(line): \(message)" }
}

indirect enum YAMLNode: Equatable {
    case scalar(String, quoted: Bool, line: Int)
    case map([(key: String, value: YAMLNode, line: Int)], line: Int)
    case seq([YAMLNode], line: Int)

    static func == (lhs: YAMLNode, rhs: YAMLNode) -> Bool {
        switch (lhs, rhs) {
        case let (.scalar(a, qa, _), .scalar(b, qb, _)): return a == b && qa == qb
        case let (.seq(a, _), .seq(b, _)): return a == b
        case let (.map(a, _), .map(b, _)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    var line: Int {
        switch self {
        case .scalar(_, _, let l), .map(_, let l), .seq(_, let l): return l
        }
    }

    var string: String? { if case .scalar(let s, _, _) = self { return s } else { return nil } }
    var double: Double? { string.flatMap { Double($0) }.flatMap { $0.isFinite ? $0 : nil } }
    var int: Int? { string.flatMap { Int($0) } }
    var bool: Bool? {
        guard case .scalar(let s, false, _) = self else { return nil }
        switch s.lowercased() {
        case "true", "yes", "on": return true
        case "false", "no", "off": return false
        default: return nil
        }
    }
    var items: [YAMLNode]? { if case .seq(let items, _) = self { return items } else { return nil } }
    var entries: [(key: String, value: YAMLNode, line: Int)]? { if case .map(let e, _) = self { return e } else { return nil } }

    subscript(key: String) -> YAMLNode? {
        entries?.first { $0.key == key }?.value
    }
}

enum YAMLSubset {
    static func parse(_ text: String) throws -> YAMLNode {
        var parser = Parser(text)
        return try parser.parseDocument()
    }

    private struct Line {
        var number: Int
        var indent: Int
        var text: String
    }

    private struct Parser {
        var lines: [Line] = []
        var index = 0

        init(_ text: String) {
            var number = 0
            for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
                number += 1
                var indent = 0
                var chars = Substring(raw)
                while let c = chars.first, c == " " { indent += 1; chars = chars.dropFirst() }
                let body = Parser.stripComment(String(chars)).trimmingCharacters(in: .whitespaces)
                if body.isEmpty { continue }
                lines.append(Line(number: number, indent: indent, text: body))
                if chars.first == "\t" { lines[lines.count - 1].indent = -1 }   // reported when reached
            }
        }

        static func stripComment(_ s: String) -> String {
            var quote: Character?
            var previous: Character = " "
            for (offset, c) in s.enumerated() {
                if let q = quote {
                    if c == q { quote = nil }
                } else if c == "\"" || c == "'" {
                    if previous == " " || previous == "[" || previous == "{" || previous == "," || previous == ":" || offset == 0 { quote = c }
                } else if c == "#", previous == " " || offset == 0 {
                    return String(s.prefix(offset))
                }
                previous = c
            }
            return s
        }

        mutating func parseDocument() throws -> YAMLNode {
            if lines.first?.text == "---" { lines.removeFirst() }
            guard let first = lines.first else { throw YAMLSubsetError(line: 1, message: "The file is empty.") }
            if lines.contains(where: { $0.text == "---" }) {
                let l = lines.first { $0.text == "---" }!
                throw YAMLSubsetError(line: l.number, message: "Multiple documents are not supported.")
            }
            let node = try parseBlock(indent: first.indent)
            if index < lines.count {
                throw YAMLSubsetError(line: lines[index].number, message: "Unexpected indentation.")
            }
            return node
        }

        mutating func parseBlock(indent: Int) throws -> YAMLNode {
            let line = lines[index]
            if line.indent < 0 { throw YAMLSubsetError(line: line.number, message: "Tabs are not allowed for indentation.") }
            if line.text == "-" || line.text.hasPrefix("- ") { return try parseSequence(indent: indent) }
            if Parser.splitKey(line.text) != nil { return try parseMapping(indent: indent) }
            // A lone scalar or flow value.
            index += 1
            return try Parser.parseInline(line.text, line: line.number)
        }

        mutating func parseSequence(indent: Int) throws -> YAMLNode {
            let startLine = lines[index].number
            var items: [YAMLNode] = []
            while index < lines.count {
                let line = lines[index]
                if line.indent < 0 { throw YAMLSubsetError(line: line.number, message: "Tabs are not allowed for indentation.") }
                guard line.indent == indent, line.text == "-" || line.text.hasPrefix("- ") else {
                    if line.indent > indent { throw YAMLSubsetError(line: line.number, message: "Unexpected indentation.") }
                    break
                }
                let rest = line.text == "-" ? "" : String(line.text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    index += 1
                    if index < lines.count, lines[index].indent > indent {
                        items.append(try parseBlock(indent: lines[index].indent))
                    } else {
                        items.append(.scalar("", quoted: false, line: line.number))
                    }
                } else if Parser.isStructural(rest) {
                    // `- key: value` or `- - x`: re-seat the line as a nested block at the content column.
                    let contentIndent = indent + (line.text.count - rest.count)
                    lines[index] = Line(number: line.number, indent: contentIndent, text: rest)
                    items.append(try parseBlock(indent: contentIndent))
                } else {
                    index += 1
                    items.append(try Parser.parseInline(rest, line: line.number))
                }
            }
            return .seq(items, line: startLine)
        }

        mutating func parseMapping(indent: Int) throws -> YAMLNode {
            let startLine = lines[index].number
            var entries: [(key: String, value: YAMLNode, line: Int)] = []
            while index < lines.count {
                let line = lines[index]
                if line.indent < 0 { throw YAMLSubsetError(line: line.number, message: "Tabs are not allowed for indentation.") }
                if line.indent < indent { break }
                if line.indent > indent { throw YAMLSubsetError(line: line.number, message: "Unexpected indentation.") }
                guard let (key, rest) = Parser.splitKey(line.text) else {
                    throw YAMLSubsetError(line: line.number, message: "Expected a `key: value` line.")
                }
                if entries.contains(where: { $0.key == key }) {
                    throw YAMLSubsetError(line: line.number, message: "Duplicate key `\(key)`.")
                }
                index += 1
                let value: YAMLNode
                if rest.isEmpty {
                    if index < lines.count, lines[index].indent > indent {
                        value = try parseBlock(indent: lines[index].indent)
                    } else if index < lines.count, lines[index].indent == indent,
                              lines[index].text == "-" || lines[index].text.hasPrefix("- ") {
                        value = try parseSequence(indent: indent)
                    } else {
                        value = .scalar("", quoted: false, line: line.number)
                    }
                } else {
                    value = try Parser.parseInline(rest, line: line.number)
                }
                entries.append((key, value, line.number))
            }
            return .map(entries, line: startLine)
        }

        /// True when `text` starts a nested block rather than being one scalar or flow value.
        static func isStructural(_ text: String) -> Bool {
            if text.hasPrefix("[") || text.hasPrefix("{") { return false }
            if text == "-" || text.hasPrefix("- ") { return true }
            return splitKey(text) != nil
        }

        /// Splits `key: rest` at the first `:` that ends a key (followed by a space or the end), outside quotes.
        static func splitKey(_ text: String) -> (String, String)? {
            if text.hasPrefix("[") || text.hasPrefix("{") { return nil }
            let chars = Array(text)
            var quote: Character?
            for i in chars.indices {
                let c = chars[i]
                if let q = quote { if c == q { quote = nil }; continue }
                if (c == "\"" || c == "'") && i == 0 { quote = c; continue }
                if c == ":" && (i + 1 == chars.count || chars[i + 1] == " ") {
                    var key = String(chars[..<i]).trimmingCharacters(in: .whitespaces)
                    if key.count >= 2, let f = key.first, f == "\"" || f == "'", key.last == f { key = String(key.dropFirst().dropLast()) }
                    guard !key.isEmpty else { return nil }
                    return (key, String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces))
                }
            }
            return nil
        }

        static func parseInline(_ text: String, line: Int) throws -> YAMLNode {
            if let first = text.first, "|>&*!".contains(first) {
                throw YAMLSubsetError(line: line, message: "Block scalars, anchors, aliases and tags are not supported.")
            }
            if text.hasPrefix("[") || text.hasPrefix("{") {
                var flow = Flow(chars: Array(text), line: line)
                let node = try flow.parseValue()
                flow.skipSpaces()
                if flow.position != flow.chars.count { throw YAMLSubsetError(line: line, message: "Unexpected text after the closing bracket.") }
                return node
            }
            return try scalar(text, line: line)
        }

        static func scalar(_ text: String, line: Int) throws -> YAMLNode {
            let t = text.trimmingCharacters(in: .whitespaces)
            if let f = t.first, f == "\"" || f == "'" {
                guard t.count >= 2, t.last == f else { throw YAMLSubsetError(line: line, message: "Unterminated quoted string.") }
                var body = String(t.dropFirst().dropLast())
                if f == "\"" {
                    body = body.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                } else {
                    body = body.replacingOccurrences(of: "''", with: "'")
                }
                return .scalar(body, quoted: true, line: line)
            }
            return .scalar(t, quoted: false, line: line)
        }
    }

    private struct Flow {
        var chars: [Character]
        var line: Int
        var position = 0

        init(chars: [Character], line: Int) { self.chars = chars; self.line = line }

        mutating func skipSpaces() { while position < chars.count, chars[position] == " " { position += 1 } }

        mutating func parseValue() throws -> YAMLNode {
            skipSpaces()
            guard position < chars.count else { throw YAMLSubsetError(line: line, message: "Unexpected end of a flow value.") }
            switch chars[position] {
            case "[":
                position += 1
                var items: [YAMLNode] = []
                while true {
                    skipSpaces()
                    guard position < chars.count else { throw YAMLSubsetError(line: line, message: "Missing `]`.") }
                    if chars[position] == "]" { position += 1; break }
                    items.append(try parseValue())
                    skipSpaces()
                    guard position < chars.count else { throw YAMLSubsetError(line: line, message: "Missing `]`.") }
                    if chars[position] == "," { position += 1 } else if chars[position] != "]" {
                        throw YAMLSubsetError(line: line, message: "Expected `,` or `]`.")
                    }
                }
                return .seq(items, line: line)
            case "{":
                position += 1
                var entries: [(key: String, value: YAMLNode, line: Int)] = []
                while true {
                    skipSpaces()
                    guard position < chars.count else { throw YAMLSubsetError(line: line, message: "Missing `}`.") }
                    if chars[position] == "}" { position += 1; break }
                    let key = try token(stopping: ":,}]")
                    guard position < chars.count, chars[position] == ":" else {
                        throw YAMLSubsetError(line: line, message: "Expected `key: value` inside `{}`.")
                    }
                    position += 1
                    let value = try parseValue()
                    entries.append((key.string ?? "", value, line))
                    skipSpaces()
                    guard position < chars.count else { throw YAMLSubsetError(line: line, message: "Missing `}`.") }
                    if chars[position] == "," { position += 1 } else if chars[position] != "}" {
                        throw YAMLSubsetError(line: line, message: "Expected `,` or `}`.")
                    }
                }
                return .map(entries, line: line)
            default:
                return try token(stopping: ",]}")
            }
        }

        mutating func token(stopping: String) throws -> YAMLNode {
            skipSpaces()
            guard position < chars.count else { throw YAMLSubsetError(line: line, message: "Unexpected end of a flow value.") }
            if chars[position] == "\"" || chars[position] == "'" {
                let q = chars[position]
                var end = position + 1
                while end < chars.count, chars[end] != q { end += 1 }
                guard end < chars.count else { throw YAMLSubsetError(line: line, message: "Unterminated quoted string.") }
                let text = String(chars[position...end])
                position = end + 1
                return try Parser.scalar(text, line: line)
            }
            var end = position
            while end < chars.count, !stopping.contains(chars[end]) { end += 1 }
            let text = String(chars[position..<end]).trimmingCharacters(in: .whitespaces)
            position = end
            return .scalar(text, quoted: false, line: line)
        }
    }
}
