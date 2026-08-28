import Foundation
import Crypto
import DuckKit

/// Which policy actually ran, as sixteen characters somebody can compare.
///
/// WHY THIS LIVES IN `DuckEvidence` AND NOT NEXT TO `DuckPolicy`. Hashing needs
/// swift-crypto, swift-crypto brings BoringSSL, and DuckKit compiling without a
/// single dependency is the reason the real trained network runs under
/// `swift test` on a Raspberry Pi. So the split is: DuckKit knows the canonical
/// byte order of a policy's parameters, because that is robot truth and belongs
/// beside the parser that read them; this file turns those bytes into a digest.
/// An app that just wants a walking duck gets `canonicalParameterBytes` for free
/// and links no TLS library to do it.
///
/// WHY NOT HASH THE FILE. Two ONNX exports of the same learned map differ in
/// producer string, initializer names, opset version and node order — hashing
/// the file calls them different policies, which is wrong and, worse, wrong in
/// the direction that makes a report look suspicious for no reason. And a file
/// can match everywhere except one weight, which is a different robot. The
/// parameters are exactly the thing whose change matters.
extension DuckPolicy {

    /// SHA-256 over `canonicalParameterBytes`, lowercase hex.
    ///
    /// Full 64 characters, because this is what gets signed and compared by
    /// machine. `shortFingerprint` is the one for a screen.
    public var fingerprint: String {
        SHA256.hash(data: canonicalParameterBytes)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The first sixteen hex characters — 64 bits.
    ///
    /// For a human comparing two policies at a glance, or a label under a
    /// chart. Sixty-four bits is far past collision trouble for a set that will
    /// never exceed a few thousand training runs, and short enough to read
    /// aloud. Never accept this in place of the full digest when verifying: a
    /// truncated hash is a weaker claim, and the whole value of an attested
    /// report is that its claims are not weaker than they look.
    public var shortFingerprint: String { String(fingerprint.prefix(16)) }

    /// The fingerprint as a canonical JSON value, ready to fold into a chain or
    /// a signed record.
    ///
    /// Carries the digest algorithm and the parameter count alongside the
    /// digest, because a bare hex string in a record is unverifiable a year
    /// later — the reader has to know what was hashed and how before they can
    /// reproduce it, and "sha-256 over 197,896 little-endian float32
    /// parameters" is the whole recipe.
    public var fingerprintRecord: CanonicalValue {
        .object([
            "algorithm": .string("sha-256"),
            "over": .string("canonical-parameter-bytes-v1"),
            "parameterCount": .int(Int64(parameterCount + normalization.mean.count
                                         + normalization.std.count)),
            "digest": .string(fingerprint),
        ])
    }
}
