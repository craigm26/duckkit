import XCTest
@testable import DuckKit

/// The room writer: deterministic bytes, true-to-scale numbers, and the duck
/// included by reference rather than copied.
final class DuckSceneMJCFTests: XCTestCase {

    private func capture() -> DuckSceneMJCF.Capture {
        DuckSceneMJCF.Capture(floorHalfX: 2.5, floorHalfY: 3.0, obstacles: [
            .init(name: "couch", center: (1.0, -0.5, 0.35), size: (1.8, 0.9, 0.7)),
            .init(name: "step", center: (-1.2, 0.8, 0.06), size: (0.9, 0.3, 0.12), yaw: 0.5),
        ])
    }

    func testTheSceneIsDeterministicAndSortsObstaclesByName() {
        let forward = DuckSceneMJCF.scene(from: capture())
        let reversed = DuckSceneMJCF.scene(from: DuckSceneMJCF.Capture(
            floorHalfX: 2.5, floorHalfY: 3.0, obstacles: capture().obstacles.reversed()))
        XCTAssertEqual(forward, reversed, "obstacle order in must not change bytes out")
        let couch = forward.range(of: "\"couch\"")!.lowerBound
        let step = forward.range(of: "\"step\"")!.lowerBound
        XCTAssertLessThan(couch, step)
    }

    func testTheSceneIncludesTheUpstreamDuckAndAFloor() {
        let scene = DuckSceneMJCF.scene(from: capture())
        XCTAssertTrue(scene.contains("<include file=\"robot_walk.xml\" />"))
        XCTAssertTrue(scene.contains("type=\"plane\" size=\"2.5 3.0 0.05\""))
        XCTAssertTrue(scene.contains("<compiler angle=\"radian\""))
    }

    /// MJCF box sizes are half-extents; a full-extent slip would double every
    /// piece of furniture.
    func testBoxSizesAreHalfExtents() {
        let scene = DuckSceneMJCF.scene(from: capture())
        XCTAssertTrue(scene.contains("name=\"couch\" type=\"box\" size=\"0.9 0.45 0.35\""),
                      "couch 1.8×0.9×0.7 must emit halves 0.9 0.45 0.35")
    }

    func testNamesAreEscapedForXML() {
        let scene = DuckSceneMJCF.scene(from: DuckSceneMJCF.Capture(
            floorHalfX: 1, floorHalfY: 1,
            obstacles: [.init(name: "a<b>&\"c", center: (0, 0, 0), size: (1, 1, 1))]))
        XCTAssertTrue(scene.contains("a&lt;b&gt;&amp;&quot;c"))
        XCTAssertFalse(scene.contains("a<b>"))
    }

    func testNumbersAreStableAndLocaleProof() {
        XCTAssertEqual(DuckSceneMJCF.number(0.5), "0.5")
        XCTAssertEqual(DuckSceneMJCF.number(0), "0.0")
        XCTAssertEqual(DuckSceneMJCF.number(1.0 / 3.0), "0.333333")
        XCTAssertEqual(DuckSceneMJCF.number(-2.45), "-2.45")
    }
}
