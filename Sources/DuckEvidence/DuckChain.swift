import Crypto
import Foundation

/// Hash-chaining, and only hash-chaining.
///
/// THE ARITHMETIC IS LIFTED, THE CONTAINER IS NOT. OpenCastor's `Journal`
/// chains over a `Receipt` — a record of a decision some robot's gateway
/// actually signed — and that type means nothing to a duck's diary or a
/// soccer match. Dragging it across would let a phone-minted record wear the
/// shape of a gateway decision, which is the one failure the whole evidence
/// rail exists to prevent: fabricated provenance in the artifact whose
/// integrity is the product.
///
/// So what moves is the fold, not the ledger. Each consumer keeps its own
/// namespace and its own record kinds, and shares only this:
///
///     head₀ = "GENESIS"
///     headᵢ = sha256_hex( utf8(headᵢ₋₁) ‖ canonical(recordᵢ) )
///
/// Insert, drop or reorder a record and the head changes. Sign the head and
/// the whole sequence is pinned by one signature — which is what makes "your
/// duck walked 1.2 km" a claim someone else can check rather than a number
/// you typed.
public enum DuckChain {

    /// Where every chain starts. A literal, so an empty chain has a defined
    /// head rather than an empty string that could be confused with a missing
    /// one.
    public static let genesis = "GENESIS"

    /// Fold one record into the chain.
    ///
    /// The previous head is hashed as its own UTF-8 bytes rather than decoded
    /// from hex — the string is the value, and re-deriving it invites two
    /// implementations to disagree about case.
    public static func head(after previous: String, record: CanonicalValue) -> String {
        var bytes = Data(previous.utf8)
        bytes.append(CanonicalJSON.serialize(record))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Fold a whole sequence from genesis.
    public static func head(of records: [CanonicalValue]) -> String {
        records.reduce(genesis) { head(after: $0, record: $1) }
    }
}
