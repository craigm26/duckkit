import Foundation

/// A minimal, self-contained JSON parser that preserves the int/float
/// distinction from the source text (`50` → `.int`, `50.0` → `.double`).
///
/// This exists so the vendored `canonical-json-v1.json` fixture — whose whole
/// point is that `50.0` must canonicalize as `50` — can be re-serialized and
/// byte-matched without depending on `JSONSerialization`'s platform-dependent
/// number handling. It parses over Unicode scalars for O(1) indexing and
/// correct `\uXXXX` / surrogate-pair handling.
public struct CanonicalJSONParser {

    public enum ParseError: Error, Equatable {
        case unexpectedEnd
        case tooDeeplyNested
        case unexpectedCharacter(String, at: Int)
        case invalidNumber(String)
        case invalidEscape(String)
        case invalidUTF16Surrogate
    }

    private let scalars: [Unicode.Scalar]
    private var pos = 0

    public init(_ text: String) {
        self.scalars = Array(text.unicodeScalars)
    }

    /// Parse a full JSON document into a `CanonicalValue`.
    public static func parse(_ text: String) throws -> CanonicalValue {
        var parser = CanonicalJSONParser(text)
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        if parser.pos != parser.scalars.count {
            throw ParseError.unexpectedCharacter(parser.currentDescription(), at: parser.pos)
        }
        return value
    }

    // MARK: - Grammar

    /// Nesting is capped: this parser runs on bodies the network hands us,
    /// and unbounded recursion let a deeply-nested payload (`[[[[…`) overflow
    /// the stack — a remote crash with one response. 64 levels is far beyond
    /// any real receipt.
    static let maxDepth = 64

    private mutating func parseValue(depth: Int) throws -> CanonicalValue {
        guard depth < Self.maxDepth else { throw ParseError.tooDeeplyNested }
        skipWhitespace()
        guard pos < scalars.count else { throw ParseError.unexpectedEnd }
        switch scalars[pos] {
        case "{": return try parseObject(depth: depth + 1)
        case "[": return try parseArray(depth: depth + 1)
        case "\"": return .string(try parseString())
        case "t", "f": return .bool(try parseBool())
        case "n": try parseLiteral("null"); return .null
        default: return try parseNumber()
        }
    }

    private mutating func parseObject(depth: Int) throws -> CanonicalValue {
        pos += 1 // {
        var dict = [String: CanonicalValue]()
        skipWhitespace()
        if matches("}") { pos += 1; return .object(dict) }
        while true {
            skipWhitespace()
            guard matches("\"") else {
                throw ParseError.unexpectedCharacter(currentDescription(), at: pos)
            }
            let key = try parseString()
            skipWhitespace()
            guard matches(":") else {
                throw ParseError.unexpectedCharacter(currentDescription(), at: pos)
            }
            pos += 1 // :
            let value = try parseValue(depth: depth)
            dict[key] = value
            skipWhitespace()
            if matches(",") {
                pos += 1
            } else if matches("}") {
                pos += 1
                return .object(dict)
            } else {
                throw ParseError.unexpectedCharacter(currentDescription(), at: pos)
            }
        }
    }

    private mutating func parseArray(depth: Int) throws -> CanonicalValue {
        pos += 1 // [
        var items = [CanonicalValue]()
        skipWhitespace()
        if matches("]") { pos += 1; return .array(items) }
        while true {
            let value = try parseValue(depth: depth)
            items.append(value)
            skipWhitespace()
            if matches(",") {
                pos += 1
            } else if matches("]") {
                pos += 1
                return .array(items)
            } else {
                throw ParseError.unexpectedCharacter(currentDescription(), at: pos)
            }
        }
    }

    private mutating func parseString() throws -> String {
        pos += 1 // opening quote
        var result = String.UnicodeScalarView()
        while pos < scalars.count {
            let c = scalars[pos]
            pos += 1
            switch c {
            case "\"":
                return String(result)
            case "\\":
                guard pos < scalars.count else { throw ParseError.unexpectedEnd }
                let esc = scalars[pos]
                pos += 1
                switch esc {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "n": result.append("\u{0A}")
                case "r": result.append("\u{0D}")
                case "t": result.append("\u{09}")
                case "u": result.append(try parseUnicodeEscape())
                default: throw ParseError.invalidEscape(String(esc))
                }
            default:
                result.append(c)
            }
        }
        throw ParseError.unexpectedEnd
    }

    /// Parse the 4 hex digits after `\u`, resolving UTF-16 surrogate pairs.
    private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        let high = try readHex4()
        if high >= 0xD800 && high <= 0xDBFF {
            // High surrogate: expect a following \uXXXX low surrogate.
            guard pos + 1 < scalars.count, scalars[pos] == "\\", scalars[pos + 1] == "u" else {
                throw ParseError.invalidUTF16Surrogate
            }
            pos += 2 // consume "\u"
            let low = try readHex4()
            guard low >= 0xDC00 && low <= 0xDFFF else { throw ParseError.invalidUTF16Surrogate }
            let combined = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
            guard let scalar = Unicode.Scalar(combined) else { throw ParseError.invalidUTF16Surrogate }
            return scalar
        }
        guard let scalar = Unicode.Scalar(high) else { throw ParseError.invalidUTF16Surrogate }
        return scalar
    }

    private mutating func readHex4() throws -> Int {
        guard pos + 4 <= scalars.count else { throw ParseError.unexpectedEnd }
        var value = 0
        for _ in 0..<4 {
            let c = scalars[pos]
            pos += 1
            guard let digit = hexDigit(c) else { throw ParseError.invalidEscape("\\u") }
            value = value * 16 + digit
        }
        return value
    }

    private func hexDigit(_ c: Unicode.Scalar) -> Int? {
        switch c {
        case "0"..."9": return Int(c.value - 0x30)
        case "a"..."f": return Int(c.value - 0x61 + 10)
        case "A"..."F": return Int(c.value - 0x41 + 10)
        default: return nil
        }
    }

    private mutating func parseNumber() throws -> CanonicalValue {
        let start = pos
        var isFloat = false
        loop: while pos < scalars.count {
            switch scalars[pos] {
            case "0"..."9", "-", "+":
                pos += 1
            case ".", "e", "E":
                isFloat = true
                pos += 1
            default:
                break loop
            }
        }
        let token = String(String.UnicodeScalarView(scalars[start..<pos]))
        guard !token.isEmpty else { throw ParseError.unexpectedCharacter(currentDescription(), at: pos) }
        if isFloat {
            guard let d = Double(token) else { throw ParseError.invalidNumber(token) }
            return .double(d)
        }
        if let i = Int64(token) { return .int(i) }
        // Integer literal beyond Int64 range: fall back to Double so the parser
        // never crashes (out of scope for the spec, but defensive).
        guard let d = Double(token) else { throw ParseError.invalidNumber(token) }
        return .double(d)
    }

    private mutating func parseBool() throws -> Bool {
        if matches("t") { try parseLiteral("true"); return true }
        try parseLiteral("false"); return false
    }

    private mutating func parseLiteral(_ literal: String) throws {
        for expected in literal.unicodeScalars {
            guard pos < scalars.count, scalars[pos] == expected else {
                throw ParseError.unexpectedCharacter(currentDescription(), at: pos)
            }
            pos += 1
        }
    }

    // MARK: - Helpers

    private func matches(_ c: Unicode.Scalar) -> Bool {
        pos < scalars.count && scalars[pos] == c
    }

    private func currentDescription() -> String {
        pos < scalars.count ? String(scalars[pos]) : "<end>"
    }

    private mutating func skipWhitespace() {
        while pos < scalars.count {
            switch scalars[pos] {
            case " ", "\t", "\n", "\r": pos += 1
            default: return
            }
        }
    }
}
