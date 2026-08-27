import XCTest
@testable import DuckKit

/// The 61-float layout, pinned with the same tests the robot's own runtime
/// pins it with (`duck-control/src/obs.rs`) — distinguishable values at every
/// block boundary, so a block that moves shows up as a specific index rather
/// than as a duck that walks badly.
final class DuckObservationTests: XCTestCase {

    private func command() -> DuckCommand {
        DuckCommand(twist: (0.1, 0.2, 0.3), head: (0.4, 0.5, 0.6, 0.7),
                    bodyZ: 0.8, bodyRoll: 0.9, bodyPitch: 1.0)
    }

    private func build(positions: [Double], lastAction: [Float]) -> DuckObservation {
        DuckObservation.build(
            gyro: [1, 2, 3], gravity: [4, 5, 6],
            jointPositions: positions,
            jointVelocities: [Double](repeating: 0, count: 15),
            lastAction: lastAction, command: command())
    }

    func testTheLayoutWidthsSumToTheDeclaredInput() {
        XCTAssertEqual(3 + 3 + 14 * 3 + DuckObservation.commandLength, DuckObservation.length)
    }

    func testEveryBlockLandsAtItsDocumentedOffset() {
        var positions = DuckModel.homePose
        positions[0] += 0.25
        var lastAction = [Float](repeating: 0, count: 14)
        lastAction[0] = -0.5
        lastAction[13] = 0.75

        let d = build(positions: positions, lastAction: lastAction).values
        XCTAssertEqual(Array(d[0..<3]), [1, 2, 3], "gyro")
        XCTAssertEqual(Array(d[3..<6]), [4, 5, 6], "gravity")
        XCTAssertEqual(d[6], 0.25, accuracy: 1e-6, "joint position relative to home")
        XCTAssertEqual(d[20], 0, "joint velocity")
        XCTAssertEqual(d[34], -0.5, "last action, first slot")
        XCTAssertEqual(d[47], 0.75, "last action, last slot")
        XCTAssertEqual(Array(d[48..<51]), [0.1, 0.2, 0.3], "twist")
        XCTAssertEqual(Array(d[51..<55]), [0.4, 0.5, 0.6, 0.7], "head")
    }

    /// Body x, y and yaw are unbound in training — zero is the *nominal*
    /// encoding, regardless of what a caller might wish into them.
    func testUnboundBodyAxesAreAlwaysZero() {
        let d = build(positions: DuckModel.homePose, lastAction: [Float](repeating: 0, count: 14)).values
        XCTAssertEqual(d[55], 0, "body x")
        XCTAssertEqual(d[56], 0, "body y")
        XCTAssertEqual(d[60], 0, "body yaw")
    }

    /// z, roll, pitch — NOT z, pitch, roll. Swapping the last two tilts the
    /// robot sideways when asked to lean forward.
    func testTheBodyBlockIsZRollPitch() {
        let d = build(positions: DuckModel.homePose, lastAction: [Float](repeating: 0, count: 14)).values
        XCTAssertEqual(d[57], 0.8, "body z")
        XCTAssertEqual(d[58], 0.9, "body roll")
        XCTAssertEqual(d[59], 1.0, "body pitch")
    }

    func testJointPositionsAreRelativeToTheHomePose() {
        let d = build(positions: DuckModel.homePose, lastAction: [Float](repeating: 0, count: 14)).values
        for (i, value) in d[6..<20].enumerated() {
            XCTAssertEqual(value, 0, accuracy: 1e-9, "joint \(i) should read zero at home")
        }
    }

    /// If the observation included the mouth, every joint after index 9 would
    /// shift by one — silently.
    func testTheMouthIsExcludedFromTheObservation() {
        var positions = DuckModel.homePose
        positions[DuckModel.mouthIndex] += 1.0
        let d = build(positions: positions, lastAction: [Float](repeating: 0, count: 14)).values
        for (i, value) in d[6..<20].enumerated() {
            XCTAssertEqual(value, 0, accuracy: 1e-9, "moving the mouth changed joint slot \(i)")
        }
    }

    func testScatteringAnActionSkipsTheMouth() {
        let action = (1...14).map(Float.init)
        let scattered = DuckObservation.scatterAction(action)
        XCTAssertEqual(scattered[DuckModel.mouthIndex], 0, "mouth must be left alone")
        XCTAssertEqual(scattered[0], 1)
        XCTAssertEqual(scattered[8], 9)
        XCTAssertEqual(scattered[10], 10)
        XCTAssertEqual(scattered[14], 14)
    }

    func testTwistMagnitudeIgnoresHeadAndBody() {
        var c = DuckCommand()
        XCTAssertEqual(c.twistMagnitude, 0)
        c.head = (1, 1, 1, 1)
        c.bodyZ = 1; c.bodyRoll = 1; c.bodyPitch = 1
        XCTAssertEqual(c.twistMagnitude, 0, "only the twist counts")
        c.twist = (3, 4, 0)
        XCTAssertEqual(c.twistMagnitude, 5, accuracy: 1e-12)
    }
}
