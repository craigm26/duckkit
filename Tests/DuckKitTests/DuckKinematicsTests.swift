import XCTest
@testable import DuckKit

/// Forward kinematics held against two sources of truth: the vendored MJCF
/// tree (the chain data must match it field for field), and reference site
/// positions computed independently in Python/NumPy over the same file.
final class DuckKinematicsTests: XCTestCase {

    func testTheChainMatchesTheVendoredModelFieldForField() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "duck_chain", withExtension: "json", subdirectory: "Fixtures/duck"))
        let fixture = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        // The jaw is ours, not the vendored model's — see the table's own
        // comment — so the field-for-field check skips it and it gets tests
        // of its own below.
        let vendored = DuckKinematics.bodies.filter { $0.name != "jaw" }
        XCTAssertEqual(fixture.count, vendored.count, "body count")

        for (expected, body) in zip(fixture, vendored) {
            XCTAssertEqual(expected["name"] as? String, body.name)
            XCTAssertEqual(expected["parent"] as? String, body.parent, body.name)
            let pos = try XCTUnwrap(expected["pos"] as? [Double])
            XCTAssertEqual(pos[0], body.position.x, accuracy: 1e-12, body.name)
            XCTAssertEqual(pos[1], body.position.y, accuracy: 1e-12, body.name)
            XCTAssertEqual(pos[2], body.position.z, accuracy: 1e-12, body.name)
            let quat = try XCTUnwrap(expected["quat"] as? [Double])
            XCTAssertEqual(quat[0], body.orientation.w, accuracy: 1e-12, body.name)
            XCTAssertEqual(quat[3], body.orientation.z, accuracy: 1e-12, body.name)
            if let joint = expected["joint"] as? [String: Any], joint["free"] == nil {
                XCTAssertEqual(joint["name"] as? String, body.joint, body.name)
                let axis = try XCTUnwrap(joint["axis"] as? [Double])
                XCTAssertEqual(axis, [0, 0, 1], "\(body.name): every hinge here is body-local Z")
            } else {
                XCTAssertNil(body.joint, body.name)
            }
            let sites = try XCTUnwrap(expected["sites"] as? [[String: Any]])
            // The vendored model pins `mouth_tip` to the fused head; here the
            // tip rides the jaw, which is the whole point of having one.
            let expectedSites = sites.compactMap { $0["name"] as? String }.filter { $0 != "mouth_tip" }
            XCTAssertEqual(expectedSites, body.sites.map { $0.name }, body.name)
        }
    }

    /// Reference positions computed independently (NumPy over the same MJCF).
    /// If the quaternion maths here drifts, these eight numbers catch it.
    func testSitePositionsMatchTheIndependentReferenceAtZeroPose() {
        let sites = DuckKinematics.sitePositions(jointAngles: [Double](repeating: 0, count: 15))
        assertSite(sites["left_foot"], -0.031777, 0.050415, 0.014712)
        assertSite(sites["head_camera"], 0.0816, 0.000001, 0.247386)
    }

    func testSitePositionsMatchTheIndependentReferenceAtHomePose() {
        let sites = DuckKinematics.sitePositions(jointAngles: DuckModel.homePose)
        assertSite(sites["left_foot"], 0.000016, 0.041823, 0.002899)
        assertSite(sites["right_foot"], 0.000016, -0.041823, 0.002899)
        assertSite(sites["head_camera"], 0.064497, 0.000001, 0.24437)
        assertSite(sites["mouth_tip"], 0.068736, 0.000001, 0.224326)
    }

    /// The upstream authors moved the home pose so the centre of mass sits
    /// over the ankle axis. Forward kinematics makes that claim literal: at
    /// home, the feet land directly under the trunk and on the floor.
    func testTheHomePosePutsTheFeetUnderTheTrunkOnTheFloor() throws {
        let sites = DuckKinematics.sitePositions(jointAngles: DuckModel.homePose)
        let left = try XCTUnwrap(sites["left_foot"])
        let right = try XCTUnwrap(sites["right_foot"])
        XCTAssertEqual(left.x, 0, accuracy: 1e-4, "feet under the trunk, not behind it")
        XCTAssertEqual(left.z, 0, accuracy: 5e-3, "feet on the floor")
        XCTAssertEqual(left.y, -right.y, accuracy: 1e-9, "stance is symmetric")
        XCTAssertEqual(left.z, right.z, accuracy: 1e-9)
    }

    /// 25 cm tall is the product spec; the model should stand ~24–25 cm at
    /// the head camera. A unit error (mm vs m, a wrong quaternion) would put
    /// this wildly off.
    func testTheDuckIsAQuarterMetreTall() throws {
        let sites = DuckKinematics.sitePositions(jointAngles: DuckModel.homePose)
        let camera = try XCTUnwrap(sites["head_camera"])
        XCTAssertGreaterThan(camera.z, 0.20)
        XCTAssertLessThan(camera.z, 0.28)
    }

    private func assertSite(
        _ site: DuckVector?, _ x: Double, _ y: Double, _ z: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let site else { return XCTFail("site missing", file: file, line: line) }
        XCTAssertEqual(site.x, x, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(site.y, y, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(site.z, z, accuracy: 1e-5, file: file, line: line)
    }

    // MARK: - the jaw

    /// Opening the mouth lowers the beak tip — by the geometry of the hinge,
    /// about 30 mm at the runtime's fully-open 30° — and moves nothing else.
    func testOpeningTheMouthLowersTheBeakTipAndNothingElse() {
        var open = DuckModel.homePose
        open[DuckModel.mouthIndex] = DuckModel.mouthOpen
        let shut = DuckKinematics.sitePositions(jointAngles: DuckModel.homePose)
        let wide = DuckKinematics.sitePositions(jointAngles: open)
        let drop = shut["mouth_tip"]!.z - wide["mouth_tip"]!.z
        XCTAssertGreaterThan(drop, 0.025, "the tip must go DOWN when the mouth opens")
        XCTAssertLessThan(drop, 0.035)
        XCTAssertEqual(shut["mouth_tip"]!.y, wide["mouth_tip"]!.y, accuracy: 1e-9,
                       "a lateral hinge keeps the tip on the centreline")
        for name in ["head_camera", "tof", "left_foot", "right_foot", "imu"] {
            XCTAssertEqual(shut[name]!.z, wide[name]!.z, accuracy: 1e-12,
                           "\(name) must not move with the mouth")
        }
        let shutBodies = DuckKinematics.bodyPoses(jointAngles: DuckModel.homePose)
        let wideBodies = DuckKinematics.bodyPoses(jointAngles: open)
        XCTAssertEqual(shutBodies["bottom_head_shell"], wideBodies["bottom_head_shell"],
                       "the head shell is the jaw's parent and stays put")
        XCTAssertNotEqual(shutBodies["jaw"], wideBodies["jaw"])
    }

    /// The hinge is where the mouth servo's horn is: 40 mm out from the
    /// head's centreline, level with and just behind the beak root.
    func testTheJawHingesOnTheMouthServoHorn() throws {
        let jaw = try XCTUnwrap(DuckKinematics.bodies.first { $0.name == "jaw" })
        XCTAssertEqual(jaw.parent, "bottom_head_shell")
        XCTAssertEqual(jaw.joint, "mouth")
        XCTAssertEqual(jaw.position.y, 0.040, accuracy: 1e-12)
        let axis = jaw.orientation.rotate(DuckVector(0, 0, 1))
        XCTAssertEqual(axis.x, 0, accuracy: 1e-9)
        XCTAssertEqual(axis.y, 1, accuracy: 1e-9, "its hinge is the head's +Y")
        XCTAssertEqual(axis.z, 0, accuracy: 1e-9)
    }

    // MARK: - rollers

    /// Rollers swap the two ankle bodies for two blades and four wheels, and
    /// touch nothing above the ankles.
    func testRollersSubstituteSixBodiesForTwo() {
        let legs = DuckKinematics.bodies(for: .legs)
        let rollers = DuckKinematics.bodies(for: .rollers)
        XCTAssertEqual(rollers.count, legs.count - 2 + 6)
        XCTAssertFalse(rollers.contains { $0.name == "ankle_left" })
        XCTAssertTrue(rollers.contains { $0.name == "ankle_l_v1" && $0.joint == "left_ankle" })
        XCTAssertEqual(rollers.filter { $0.joint?.hasPrefix("passive_") == true }.count, 4)
        for body in legs where !["ankle_left", "ankle_right"].contains(body.name) {
            XCTAssertTrue(rollers.contains { $0.name == body.name && $0.parent == body.parent },
                          "\(body.name) must be untouched by the swap")
        }
        let sites = DuckKinematics.sitePositions(jointAngles: DuckModel.homePose, variant: .rollers)
        XCTAssertNotNil(sites["left_foot"]); XCTAssertNotNil(sites["right_foot"])
        XCTAssertEqual(sites["left_foot"]!.y, -sites["right_foot"]!.y, accuracy: 0.002,
                       "the blades are mirrored about the centreline")
    }

    /// Every wheel rolls the robot FORWARD for positive spin, whichever way
    /// its axle points — the right blade is a mirrored part.
    func testAllFourWheelsRollForwardTogether() {
        let still = DuckKinematics.bodyPoses(jointAngles: DuckModel.homePose, variant: .rollers)
        let turned = DuckKinematics.bodyPoses(jointAngles: DuckModel.homePose, variant: .rollers,
                                              wheelSpin: 0.3)
        for tire in ["tire", "tire_2", "tire_3", "tire_4"] {
            let s = still[tire]!.orientation, t = turned[tire]!.orientation
            let inverse = DuckQuaternion(w: s.w, x: -s.x, y: -s.y, z: -s.z)
            // The world-frame rotation that took the wheel from still to
            // turned; its axis must be −Y for forward rolling.
            let delta = (t * inverse).normalized
            XCTAssertLessThan(delta.y, 0, "\(tire): spin axis must be −Y for forward rolling")
            // The axle tilts a little with the home pose's hip roll, so it is
            // not exactly −Y; it must be overwhelmingly so.
            XCTAssertGreaterThan(abs(delta.y), 10 * (abs(delta.x) + abs(delta.z)), tire)
        }
    }
}
