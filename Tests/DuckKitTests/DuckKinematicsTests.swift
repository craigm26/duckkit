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
        XCTAssertEqual(fixture.count, DuckKinematics.bodies.count, "body count")

        for (expected, body) in zip(fixture, DuckKinematics.bodies) {
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
            XCTAssertEqual(sites.map { $0["name"] as? String }, body.sites.map { $0.name }, body.name)
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
}
