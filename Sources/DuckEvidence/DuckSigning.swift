import Crypto
import Foundation

/// Ed25519 over canonical bytes — one recipe, used by everything that signs.
///
/// The recipe is `rcan-canonical-json-v1` and it is deliberately boring: sort
/// keys by Unicode code point at every level, no whitespace, integers stay
/// integers, and the `envelope_signature` key is excluded to form the
/// pre-image. A signature is then attached back under that key as
/// `{"kid": …, "sig": …}`.
///
/// WHY IT IS SPELLED OUT RATHER THAN LEFT TO JSONEncoder: `JSONSerialization`
/// collapses 50 and 50.0 to the same bytes and does not promise key order.
/// Either one silently produces a signature the verifier cannot reproduce, and
/// the symptom is "verification fails on some records", which is the worst
/// possible bug to debug.
///
/// Crypto comes from swift-crypto, not CryptoKit — the same `Curve25519.Signing`
/// API, but one that also compiles on Linux, so the signer under `swift test`
/// on a Pi is the signer on the phone.
public enum DuckSigning {

    public enum SigningError: Error, Equatable {
        /// Only an object can carry an `envelope_signature` key.
        case notAnObject
    }

    /// Sign an object, returning it with `envelope_signature` attached.
    public static func sign(
        _ object: CanonicalValue,
        with key: Curve25519.Signing.PrivateKey,
        kid: String
    ) throws -> CanonicalValue {
        guard case .object(var fields) = object else { throw SigningError.notAnObject }
        let bytes = CanonicalJSON.serialize(object, excludingKey: CanonicalJSON.envelopeSignatureKey)
        let signature = try key.signature(for: bytes)
        fields[CanonicalJSON.envelopeSignatureKey] = .object([
            "kid": .string(kid),
            "sig": .string(signature.base64EncodedString()),
        ])
        return .object(fields)
    }

    /// Verify an object that carries its own `envelope_signature`.
    ///
    /// Returns false rather than throwing for every failure — a malformed
    /// signature block, a missing one, unreadable base64 and a genuinely bad
    /// signature are all the same answer to the only question being asked.
    public static func verify(
        signedObject: CanonicalValue,
        with publicKey: Curve25519.Signing.PublicKey
    ) -> Bool {
        guard case .object(let fields) = signedObject,
              case .object(let block)? = fields[CanonicalJSON.envelopeSignatureKey],
              case .string(let base64)? = block["sig"],
              let signature = Data(base64Encoded: base64)
        else { return false }
        let bytes = CanonicalJSON.serialize(signedObject, excludingKey: CanonicalJSON.envelopeSignatureKey)
        return publicKey.isValidSignature(signature, for: bytes)
    }

    /// The key id for a public key: `duck-` and the first six bytes of its
    /// SHA-256, in hex. Short enough to show a person, long enough that two
    /// devices colliding is not a practical concern.
    public static func kid(for publicKey: Curve25519.Signing.PublicKey) -> String {
        let digest = SHA256.hash(data: publicKey.rawRepresentation)
        return "duck-" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
