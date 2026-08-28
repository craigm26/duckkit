import Foundation

/// A JSON value model that preserves the int/float distinction the RCAN
/// canonical form depends on.
///
/// `Foundation.JSONSerialization` collapses `50` and `50.0` into an ambiguous
/// `NSNumber`, and its behaviour differs between Apple and swift-corelibs
/// Foundation (Linux). Because the whole-float→int normalization is load-bearing
/// for gateway-receipt parity, CastorKit carries its own value type + parser so
/// the canonicalization is byte-deterministic on every platform.
public indirect enum CanonicalValue: Equatable {
    case object([String: CanonicalValue])
    case array([CanonicalValue])
    case string(String)
    /// A value the source expressed as an integer literal (no `.`, `e`, `E`).
    case int(Int64)
    /// A value the source expressed as a float literal.
    case double(Double)
    case bool(Bool)
    case null
}

/// Canonical JSON serialization matching the `rcan-canonical-json-v1` spec and
/// the robot-md-gateway verifier byte-for-byte:
///   * keys sorted lexicographically by Unicode code point at every level,
///   * no insignificant whitespace,
///   * non-ASCII emitted as raw UTF-8 (never `\uXXXX`),
///   * whole-number floats normalized to integers (`50.0` → `50`), recursively,
///   * booleans never coerced to numbers,
///   * empty object `{}`, empty array `[]`, no trailing newline.
///
/// The recipe intentionally mirrors `scripts/verify_receipt.py::canonical_json`
/// in robot-md-gateway so a CastorKit-signed envelope and a gateway-signed
/// outcome share one canonicalization.
public enum CanonicalJSON {

    /// The signature block key excluded from the signed pre-image, matching the
    /// gateway recipe `canonical_json(outcome, exclude="envelope_signature")`.
    public static let envelopeSignatureKey = "envelope_signature"

    /// Serialize a value to canonical UTF-8 bytes.
    /// - Parameter excludingKey: if set and the value is a top-level object,
    ///   that key is dropped before serialization (the signed pre-image).
    public static func serialize(_ value: CanonicalValue, excludingKey: String? = nil) -> Data {
        var v = value
        if let key = excludingKey, case .object(var dict) = v {
            dict.removeValue(forKey: key)
            v = .object(dict)
        }
        var out = [UInt8]()
        encode(v, into: &out)
        return Data(out)
    }

    // MARK: - Encoding

    private static func encode(_ value: CanonicalValue, into out: inout [UInt8]) {
        switch value {
        case .null:
            out.append(contentsOf: Array("null".utf8))
        case .bool(let b):
            out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case .int(let i):
            out.append(contentsOf: Array(String(i).utf8))
        case .double(let d):
            encodeNumber(d, into: &out)
        case .string(let s):
            encodeString(s, into: &out)
        case .array(let items):
            out.append(0x5B) // [
            var first = true
            for item in items {
                if !first { out.append(0x2C) } // ,
                first = false
                encode(item, into: &out)
            }
            out.append(0x5D) // ]
        case .object(let dict):
            out.append(0x7B) // {
            let keys = dict.keys.sorted(by: codePointLess)
            var first = true
            for key in keys {
                if !first { out.append(0x2C) } // ,
                first = false
                encodeString(key, into: &out)
                out.append(0x3A) // :
                encode(dict[key]!, into: &out)
            }
            out.append(0x7D) // }
        }
    }

    /// Encode a float: whole-number floats normalize to the bare integer (within
    /// the JS-safe / Int64 range); otherwise emit Swift's shortest round-tripping
    /// decimal, which matches Python's `repr(float)` for the spec's values.
    private static func encodeNumber(_ d: Double, into out: inout [UInt8]) {
        if d.isFinite, d.rounded(.towardZero) == d, abs(d) < 9.223e18 {
            out.append(contentsOf: Array(String(Int64(d)).utf8))
        } else {
            out.append(contentsOf: Array(String(d).utf8))
        }
    }

    /// JSON string escaping with `ensure_ascii=False` semantics (Python parity):
    /// escape `"`, `\`, and control chars < 0x20 (named short escapes where they
    /// exist, else lowercase `\u00xx`); everything else — including all non-ASCII
    /// — is emitted as raw UTF-8.
    private static func encodeString(_ s: String, into out: inout [UInt8]) {
        out.append(0x22) // "
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"":
                out.append(contentsOf: Array("\\\"".utf8))
            case "\\":
                out.append(contentsOf: Array("\\\\".utf8))
            case "\u{08}":
                out.append(contentsOf: Array("\\b".utf8))
            case "\u{09}":
                out.append(contentsOf: Array("\\t".utf8))
            case "\u{0A}":
                out.append(contentsOf: Array("\\n".utf8))
            case "\u{0C}":
                out.append(contentsOf: Array("\\f".utf8))
            case "\u{0D}":
                out.append(contentsOf: Array("\\r".utf8))
            default:
                if scalar.value < 0x20 {
                    out.append(contentsOf: Array(String(format: "\\u%04x", scalar.value).utf8))
                } else {
                    out.append(contentsOf: Array(String(scalar).utf8))
                }
            }
        }
        out.append(0x22) // "
    }

    /// Lexicographic comparison by Unicode code point (matches Python's
    /// `sort_keys=True`, which compares strings by code point). For BMP text this
    /// equals UTF-8 byte order; it is defined for the whole scalar range.
    static func codePointLess(_ a: String, _ b: String) -> Bool {
        var ai = a.unicodeScalars.makeIterator()
        var bi = b.unicodeScalars.makeIterator()
        while true {
            switch (ai.next(), bi.next()) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case let (x?, y?):
                if x.value != y.value { return x.value < y.value }
            }
        }
    }
}
