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

    /// Pollen's set @d5a8b55: the nine the app has always known, plus velstand.
    func testTenReleasesWithDistinctFingerprints() {
        let releases = DuckOfficialPolicies.releases
        XCTAssertEqual(releases.count, 10)
        XCTAssertEqual(Set(releases.map(\.fingerprint)).count, 10, "two entries share a digest")
        XCTAssertEqual(Set(releases.map(\.filename)).count, 10)
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

    /// Sit-stand v6 replaced the earlier one; both are Pollen's, so both are recognised, as the
    /// current release of that file. Velstand is recognised but takes no slot yet.
    func testSitStandV6AndTheEarlierOneAreBothOfficial() {
        let v6 = "da3d3110fd66bfbafbcb20ac093a2b4d827fdd52b6bca1fe5c426517922bd670"
        let earlier = "85fa1fc2331baf003575a96a7dbf2222cf7ca10aef9c17372cf0b92ef42199e2"
        for f in [v6, earlier] {
            guard case .released(let r) = DuckOfficialPolicies.standing(ofFingerprint: f) else {
                return XCTFail("\(f) is Pollen's sit-stand")
            }
            XCTAssertEqual(r.filename, "alpha_sitstand.onnx")
            XCTAssertEqual(r.fingerprint, v6, "the current release is the one reported")
        }
        guard case .released(let v) = DuckOfficialPolicies.standing(
            ofFingerprint: "ef3d55bcfc111d9ccb84443bcedd8e604b9e389f35715ad2d24c829526604039") else {
            return XCTFail("velstand is Pollen's default gait")
        }
        XCTAssertNil(v.slot, "velstand takes the walk slot only by a deliberate change")
        XCTAssertEqual(DuckOfficialPolicies.releases.first { $0.slot == .walk }?.filename,
                       "alpha_walking.onnx", "what the app's walk loads is unchanged")
    }
}
