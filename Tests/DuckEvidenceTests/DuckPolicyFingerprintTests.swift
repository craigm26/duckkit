import XCTest
import DuckKit
@testable import DuckEvidence

/// The fingerprint is what a signed report claims ran. These tests pin the
/// properties that make that claim worth anything.
final class DuckPolicyFingerprintTests: XCTestCase {

    /// The fixture lives in DuckKitTests. Reached by walking up from this
    /// file rather than copied here: a second 800 KB copy of the same network
    /// is a thing that can drift, and then two test targets would disagree
    /// about what the policy is.
    private func policy() throws -> DuckPolicy {
        let here = URL(fileURLWithPath: #filePath)
        let url = here
            .deletingLastPathComponent()          // DuckEvidenceTests
            .deletingLastPathComponent()          // Tests
            .appendingPathComponent("DuckKitTests/Fixtures/duck/alpha_walking.onnx")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "policy fixture not found at \(url.path)")
        return try DuckPolicy.load(contentsOf: url)
    }

    func testItIsASha256HexDigest() throws {
        let f = try policy().fingerprint
        XCTAssertEqual(f.count, 64, "sha-256 is 32 bytes, 64 hex characters")
        XCTAssertTrue(f.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                      "lowercase hex only, so two spellings of one digest cannot exist")
    }

    /// Two loads of the same file fingerprint the same. If this ever fails the
    /// cause is upstream — a nondeterministic parse — and every stored report
    /// is void, so it is worth a test of its own.
    func testTheSamePolicyFingerprintsTheSame() throws {
        XCTAssertEqual(try policy().fingerprint, try policy().fingerprint)
    }

    /// The short form is a prefix and nothing cleverer, so a person comparing
    /// sixteen characters is comparing the real digest's first sixteen.
    func testTheShortFormIsAPrefixOfTheFull() throws {
        let p = try policy()
        XCTAssertEqual(p.shortFingerprint.count, 16)
        XCTAssertTrue(p.fingerprint.hasPrefix(p.shortFingerprint))
    }

    /// It hashes the PARAMETERS, not the file. Proven by hashing the file's
    /// bytes and showing the two disagree — otherwise nothing distinguishes
    /// this from `sha256(fileContents)`, which would call two identical
    /// networks different because their producer strings differ.
    func testItIsNotJustTheFileHash() throws {
        let here = URL(fileURLWithPath: #filePath)
        let url = here.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DuckKitTests/Fixtures/duck/alpha_walking.onnx")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        let fileBytes = try Data(contentsOf: url)
        let p = try policy()
        XCTAssertNotEqual(p.canonicalParameterBytes, fileBytes,
                          "the parameters are a strict subset of the file")
        XCTAssertLessThan(p.canonicalParameterBytes.count, fileBytes.count,
                          "the file also carries a graph, names and an opset")
    }

    /// A record a reader can reproduce a year later: what was hashed, how, and
    /// over how many numbers. A bare hex string would not be checkable.
    func testTheRecordCarriesTheWholeRecipe() throws {
        let p = try policy()
        guard case .object(let fields) = p.fingerprintRecord else {
            return XCTFail("the record must be an object")
        }
        XCTAssertEqual(fields["algorithm"], .string("sha-256"))
        XCTAssertEqual(fields["over"], .string("canonical-parameter-bytes-v1"))
        XCTAssertEqual(fields["digest"], .string(p.fingerprint))
        XCTAssertEqual(fields["parameterCount"], .int(197_896))
        // It has to survive canonicalization, because that is how it reaches a
        // chain or a signature.
        XCTAssertFalse(CanonicalJSON.serialize(p.fingerprintRecord).isEmpty)
    }
}
