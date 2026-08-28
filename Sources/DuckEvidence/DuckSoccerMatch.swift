import Crypto
import Foundation

/// A Microduck soccer match as an append-only, hash-chained, Ed25519-signed
/// record — a league table nobody can quietly edit.
///
/// WHAT THIS IS NOT: a record of anything a robot decided. OpenCastor's
/// gateway journal holds decisions a robot's own gateway signed, and a
/// phone-minted goal dressed up as one would be fabricated evidence in the one
/// artifact whose integrity is the product. So a match keeps its OWN chain —
/// the same canonical bytes (`CanonicalJSON`), the same fold (`DuckChain`), the
/// same signature shape (`DuckSigning`), a different namespace, and no contact
/// with anybody else's ledger.
///
/// The referee is the phone: its signing identity signs the match record, so a
/// result is `(participant RRNs, event chain, referee key)` — checkable by
/// anyone holding the public key, with no server, no account, and nothing
/// collected. Practice matches (any simulated participant) are marked and
/// refuse to sign for export, which is the same rule that keeps demo fixtures
/// from ever becoming real evidence.
public struct DuckSoccerMatch: Equatable, Sendable {

    public enum Event: Equatable, Sendable {
        case kickoff(atMs: Int64)
        /// A goal, credited to a participant RRN, judged by the named
        /// authority — "phone-vision" for the AR referee, "human" for a tap.
        case goal(scorerRRN: String, atMs: Int64, judgedBy: String)
        case finalWhistle(atMs: Int64)
    }

    /// Participant robot RRNs, in team order.
    public let participantRRNs: [String]
    /// True when any participant is simulated — an AR ghost, a demo fixture.
    /// A practice match is still signed and chained locally, but exporting it
    /// as evidence is refused.
    public let isPractice: Bool
    public private(set) var events: [Event] = []

    public init(participantRRNs: [String], isPractice: Bool) {
        self.participantRRNs = participantRRNs
        self.isPractice = isPractice
    }

    public mutating func append(_ event: Event) {
        events.append(event)
    }

    /// Goals per participant RRN.
    public var score: [String: Int] {
        var tally: [String: Int] = [:]
        for event in events {
            if case .goal(let rrn, _, _) = event {
                tally[rrn, default: 0] += 1
            }
        }
        return tally
    }

    // ── the signed record ────────────────────────────────────────────────

    static func canonical(event: Event) -> CanonicalValue {
        switch event {
        case .kickoff(let ms):
            return .object(["event": .string("kickoff"), "at_ms": .int(ms)])
        case .goal(let rrn, let ms, let judge):
            return .object([
                "event": .string("goal"), "scorer_rrn": .string(rrn),
                "at_ms": .int(ms), "judged_by": .string(judge),
            ])
        case .finalWhistle(let ms):
            return .object(["event": .string("final_whistle"), "at_ms": .int(ms)])
        }
    }

    /// The chain hash over the events so far — every event folded through
    /// `DuckChain` from its genesis, so inserting, dropping or
    /// reordering a goal changes the head and breaks the signature.
    public var chainHead: String {
        var head = DuckChain.genesis
        for event in events {
            head = DuckChain.head(after: head, record: Self.canonical(event: event))
        }
        return head
    }

    /// The unsigned match record.
    public var record: CanonicalValue {
        .object([
            "kind": .string("duck.soccer.match.v1"),
            "participants": .array(participantRRNs.map(CanonicalValue.string)),
            "practice": .bool(isPractice),
            "events": .array(events.map(Self.canonical(event:))),
            "chain_head": .string(chainHead),
            "score": .object(score.mapValues { .int(Int64($0)) }),
        ])
    }

    /// The match record signed by the referee's device identity. Refuses to
    /// sign a practice match *for export*: a practice result signed like a
    /// real one is the soccer version of a fabricated receipt.
    public enum ExportRefusal: Error, Equatable {
        case practiceMatchesStayOnDevice
    }

    public func signedRecord(
        with key: Curve25519.Signing.PrivateKey,
        kid: String,
        allowPractice: Bool = false
    ) throws -> CanonicalValue {
        guard !isPractice || allowPractice else {
            throw ExportRefusal.practiceMatchesStayOnDevice
        }
        return try DuckSigning.sign(record, with: key, kid: kid)
    }

    /// Verify a signed match record against the referee's public key.
    public static func verify(signedRecord: CanonicalValue, with publicKey: Curve25519.Signing.PublicKey) -> Bool {
        DuckSigning.verify(signedObject: signedRecord, with: publicKey)
    }
}
