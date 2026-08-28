import Crypto
import XCTest
@testable import DuckEvidence

/// Signed match records: unfakeable by construction, and never a gateway
/// receipt in disguise.
final class DuckSoccerMatchTests: XCTestCase {

    private let key = Curve25519.Signing.PrivateKey()

    private func playedMatch(practice: Bool = false) -> DuckSoccerMatch {
        var match = DuckSoccerMatch(
            participantRRNs: ["RRN-000000000021", "RRN-000000000022"], isPractice: practice)
        match.append(.kickoff(atMs: 0))
        match.append(.goal(scorerRRN: "RRN-000000000021", atMs: 42_000, judgedBy: "phone-vision"))
        match.append(.goal(scorerRRN: "RRN-000000000022", atMs: 61_000, judgedBy: "human"))
        match.append(.goal(scorerRRN: "RRN-000000000021", atMs: 90_000, judgedBy: "phone-vision"))
        match.append(.finalWhistle(atMs: 120_000))
        return match
    }

    func testTheScoreTalliesGoalsPerRRN() {
        let match = playedMatch()
        XCTAssertEqual(match.score, ["RRN-000000000021": 2, "RRN-000000000022": 1])
    }

    /// Insert, drop or reorder a goal and the chain head changes — the same
    /// property the Journal gives gateway receipts, in a separate namespace.
    func testReorderingEventsChangesTheChainHead() {
        let match = playedMatch()
        var reordered = DuckSoccerMatch(participantRRNs: match.participantRRNs, isPractice: false)
        reordered.append(.kickoff(atMs: 0))
        reordered.append(.goal(scorerRRN: "RRN-000000000022", atMs: 61_000, judgedBy: "human"))
        reordered.append(.goal(scorerRRN: "RRN-000000000021", atMs: 42_000, judgedBy: "phone-vision"))
        reordered.append(.goal(scorerRRN: "RRN-000000000021", atMs: 90_000, judgedBy: "phone-vision"))
        reordered.append(.finalWhistle(atMs: 120_000))
        XCTAssertNotEqual(match.chainHead, reordered.chainHead)

        var truncated = playedMatch()
        _ = truncated // same events; now drop one by rebuilding
        var dropped = DuckSoccerMatch(participantRRNs: match.participantRRNs, isPractice: false)
        dropped.append(.kickoff(atMs: 0))
        dropped.append(.goal(scorerRRN: "RRN-000000000021", atMs: 42_000, judgedBy: "phone-vision"))
        dropped.append(.finalWhistle(atMs: 120_000))
        XCTAssertNotEqual(match.chainHead, dropped.chainHead)
    }

    func testASignedRecordVerifiesAndATamperedOneDoesNot() throws {
        let match = playedMatch()
        let signed = try match.signedRecord(with: key, kid: "opencastor-test")
        XCTAssertTrue(DuckSoccerMatch.verify(signedRecord: signed, with: key.publicKey))

        // Flip the score inside the signed object: verification must fail.
        guard case .object(var fields) = signed else { return XCTFail("record is an object") }
        fields["score"] = .object(["RRN-000000000022": .int(99)])
        XCTAssertFalse(DuckSoccerMatch.verify(signedRecord: .object(fields), with: key.publicKey))

        // A different key must not verify it either.
        let stranger = Curve25519.Signing.PrivateKey()
        XCTAssertFalse(DuckSoccerMatch.verify(signedRecord: signed, with: stranger.publicKey))
    }

    /// A practice result signed like a real one is the soccer version of a
    /// fabricated receipt — export is refused unless explicitly overridden.
    func testAPracticeMatchRefusesToSignForExport() {
        let match = playedMatch(practice: true)
        XCTAssertThrowsError(try match.signedRecord(with: key, kid: "opencastor-test")) { error in
            XCTAssertEqual(error as? DuckSoccerMatch.ExportRefusal, .practiceMatchesStayOnDevice)
        }
        XCTAssertNoThrow(try match.signedRecord(with: key, kid: "opencastor-test", allowPractice: true))
    }

    func testTheRecordCarriesItsChainHeadAndPracticeFlag() throws {
        let match = playedMatch(practice: true)
        guard case .object(let fields) = match.record else { return XCTFail() }
        XCTAssertEqual(fields["kind"], .string("duck.soccer.match.v1"))
        XCTAssertEqual(fields["practice"], .bool(true))
        XCTAssertEqual(fields["chain_head"], .string(match.chainHead))
    }
}
