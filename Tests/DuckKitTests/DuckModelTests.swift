import XCTest
@testable import DuckKit

/// The duck's data tables, held against the same invariants the robot's own
/// runtime pins — plus one this repo adds: the tables must re-derive from the
/// vendored MuJoCo model, so a hardcoded number cannot drift from upstream.
final class DuckModelTests: XCTestCase {

    func testTheTablesAgreeOnLength() {
        XCTAssertEqual(DuckModel.jointNames.count, DuckModel.jointCount)
        XCTAssertEqual(DuckModel.homePose.count, DuckModel.jointCount)
        XCTAssertEqual(DuckModel.jointRanges.count, DuckModel.jointCount)
        XCTAssertEqual(DuckModel.policyJointCount, DuckModel.jointCount - 1)
    }

    func testTheMouthIndexNamesTheMouth() {
        XCTAssertEqual(DuckModel.jointNames[DuckModel.mouthIndex], "mouth")
        XCTAssertEqual(DuckModel.jointIndex(of: "mouth"), DuckModel.mouthIndex)
    }

    /// A sign typo in the home pose is invisible by inspection and makes the
    /// robot stand crooked — the legs must be equal and opposite.
    func testTheHomePoseLegsAreMirrored() {
        for (left, right) in [
            ("left_hip_roll", "right_hip_roll"),
            ("left_hip_pitch", "right_hip_pitch"),
            ("left_knee", "right_knee"),
            ("left_ankle", "right_ankle"),
        ] {
            let l = DuckModel.homePose[DuckModel.jointIndex(of: left)!]
            let r = DuckModel.homePose[DuckModel.jointIndex(of: right)!]
            XCTAssertEqual(l + r, 0, accuracy: 1e-9, "\(left) and \(right) should mirror")
        }
    }

    /// The fourteen policy-joint ranges must be the MuJoCo model's ranges,
    /// exactly — the fixture is the upstream file's numbers.
    func testTheJointRangesMatchTheVendoredModel() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "duck_chain", withExtension: "json", subdirectory: "Fixtures/duck"))
        let bodies = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        var seen = 0
        for body in bodies {
            guard let joint = body["joint"] as? [String: Any],
                  let name = joint["name"] as? String,
                  let range = joint["range"] as? [Double] else { continue }
            let index = try XCTUnwrap(DuckModel.jointIndex(of: name), "unknown joint \(name)")
            XCTAssertEqual(DuckModel.jointRanges[index].lower, range[0], accuracy: 1e-12, name)
            XCTAssertEqual(DuckModel.jointRanges[index].upper, range[1], accuracy: 1e-12, name)
            seen += 1
        }
        XCTAssertEqual(seen, 14, "the model articulates exactly the fourteen policy joints")
    }

    func testMouthTargetSpansTheTravelAndRefusesNonsense() {
        XCTAssertEqual(DuckModel.mouthTarget(open: 0), DuckModel.mouthClosed, accuracy: 1e-12)
        XCTAssertEqual(DuckModel.mouthTarget(open: 1), DuckModel.mouthOpen, accuracy: 1e-12)
        XCTAssertEqual(DuckModel.mouthTarget(open: -3), DuckModel.mouthTarget(open: 0))
        XCTAssertEqual(DuckModel.mouthTarget(open: 7), DuckModel.mouthTarget(open: 1))
        XCTAssertEqual(DuckModel.mouthTarget(open: .nan), DuckModel.mouthTarget(open: 0))
    }

    func testBatteryPercentSpansTheUsableRangeAndClamps() {
        XCTAssertEqual(DuckModel.batteryPercent(volts: 8.2), 100)
        XCTAssertEqual(DuckModel.batteryPercent(volts: 6.6), 0)
        XCTAssertEqual(DuckModel.batteryPercent(volts: 7.4), 50, accuracy: 0.001)
        XCTAssertEqual(DuckModel.batteryPercent(volts: 9.5), 100)
        XCTAssertEqual(DuckModel.batteryPercent(volts: 0), 0)
        XCTAssertEqual(DuckModel.batteryPercent(volts: .nan), 0)
    }
}
