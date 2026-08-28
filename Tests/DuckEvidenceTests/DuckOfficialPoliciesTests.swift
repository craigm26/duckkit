import XCTest
import DuckKit
@testable import DuckEvidence

/// The manifest's whole value is that a claim of "official" is checkable, so
/// these check the checking.
final class DuckOfficialPoliciesTests: XCTestCase {

    private func walking() throws -> DuckPolicy {
        let here = URL(fileURLWithPath: #filePath)
        let url = here.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DuckKitTests/Fixtures/duck/alpha_walking.onnx")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        return try DuckPolicy.load(contentsOf: url)
    }

    /// The one release this package vendors must match its own manifest entry.
    /// If this fails the table was hand-edited.
    func testTheVendoredPolicyIsRecognised() throws {
        let policy = try walking()
        guard case .released(let release) = DuckOfficialPolicies.standing(of: policy) else {
            return XCTFail("alpha_walking is one of Pollen's nine and must be recognised")
        }
        XCTAssertEqual(release.filename, "alpha_walking.onnx")
        XCTAssertFalse(release.purpose.isEmpty)
    }

    func testNineReleasesWithDistinctFingerprints() {
        let releases = DuckOfficialPolicies.releases
        XCTAssertEqual(releases.count, 9)
        XCTAssertEqual(Set(releases.map(\.fingerprint)).count, 9, "two entries share a digest")
        XCTAssertEqual(Set(releases.map(\.filename)).count, 9)
        for release in releases {
            XCTAssertEqual(release.fingerprint.count, 64, "\(release.filename)")
            XCTAssertTrue(release.fingerprint.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                          "\(release.filename) must be lowercase hex")
        }
    }

    /// The point of keying on parameters: weights nobody released are
    /// unrecognised however the file is named or wherever it came from.
    func testUnknownWeightsAreUnrecognised() {
        let invented = String(repeating: "ab", count: 32)
        XCTAssertEqual(DuckOfficialPolicies.standing(ofFingerprint: invented), .unrecognised)
    }

    /// A digest recorded earlier must answer the same as the live file, so a
    /// stored provenance record can be re-checked without the policy itself.
    func testAStoredFingerprintAnswersTheSameAsTheFile() throws {
        let policy = try walking()
        XCTAssertEqual(DuckOfficialPolicies.standing(of: policy),
                       DuckOfficialPolicies.standing(ofFingerprint: policy.fingerprint))
        XCTAssertEqual(DuckOfficialPolicies.standing(ofFingerprint: policy.fingerprint.uppercased()),
                       DuckOfficialPolicies.standing(of: policy),
                       "case must not decide provenance")
    }

    /// The copy has to say what is known without implying a judgement — a
    /// person's own training run is unrecognised and belongs in the app.
    func testUnrecognisedCopyDoesNotCallTheFileBad() {
        let text = DuckOfficialPolicies.summary(for: .unrecognised)
        XCTAssertTrue(text.contains("not that they are bad"), text)
        XCTAssertFalse(text.lowercased().contains("untrusted"), text)
        XCTAssertFalse(text.lowercased().contains("unsafe"), text)
    }

    func testReleasedCopyNamesTheFileAndWhatItDoes() throws {
        guard case .released(let release) = DuckOfficialPolicies.standing(of: try walking()) else {
            return XCTFail("expected a release")
        }
        let text = DuckOfficialPolicies.summary(for: .released(release))
        XCTAssertTrue(text.contains("Pollen Robotics"), text)
        XCTAssertTrue(text.contains(release.filename), text)
    }
}
