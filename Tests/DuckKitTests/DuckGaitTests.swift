import XCTest
@testable import DuckKit

/// The action→target pipeline, held to the robot runtime's own arithmetic:
/// scale, filter with the trained-in coefficients, hold at travel stops and
/// say so.
final class DuckGaitTests: XCTestCase {

    func testTargetsAreHomePlusScaledActionOnTheFirstTick() {
        var action = [Float](repeating: 0, count: 14)
        action[2] = 0.1 // left_hip_pitch
        let frame = DuckGait.frame(action: action, previousTargets: nil, kind: .walk)
        XCTAssertEqual(frame.targets[2], DuckModel.homePose[2] + 0.9 * Double(action[2]), accuracy: 1e-12)
        XCTAssertEqual(frame.targets[0], DuckModel.homePose[0], accuracy: 1e-9)
    }

    func testTheStandingPolicyIsAppliedWhole() {
        var action = [Float](repeating: 0, count: 14)
        action[2] = 0.1
        let frame = DuckGait.frame(action: action, previousTargets: nil, kind: .stand)
        XCTAssertEqual(frame.targets[2], DuckModel.homePose[2] + 1.0 * Double(action[2]), accuracy: 1e-12)
    }

    func testTheMouthBelongsToTheCallerNotThePolicy() {
        let frame = DuckGait.frame(
            action: [Float](repeating: 1, count: 14), previousTargets: nil, mouth: 0.123)
        XCTAssertEqual(frame.targets[DuckModel.mouthIndex], 0.123)
        XCTAssertFalse(frame.limitedBy.contains("mouth"))
    }

    /// α·new + (1−α)·previous, with the trained-in α per joint group.
    func testTheLowpassUsesTheTrainedCoefficients() {
        let zero = [Float](repeating: 0, count: 14)
        let first = DuckGait.frame(action: zero, previousTargets: nil)
        var previous = first.targets
        previous[2] = DuckModel.homePose[2] + 1.0   // a leg, displaced
        previous[6] = DuckModel.homePose[6] + 1.0   // head_pitch, displaced
        let frame = DuckGait.frame(action: zero, previousTargets: previous)
        XCTAssertEqual(frame.targets[2], 0.7 * DuckModel.homePose[2] + 0.3 * previous[2], accuracy: 1e-9,
                       "legs filter at 0.7")
        XCTAssertEqual(frame.targets[6], 0.5 * DuckModel.homePose[6] + 0.5 * previous[6], accuracy: 1e-9,
                       "head filters at 0.5")
    }

    /// A target past a joint stop is held at the stop, and the hold is named
    /// — robotd reports `limited_by`, and so does the ghost.
    func testATargetPastTheTravelStopIsHeldAndNamed() {
        var action = [Float](repeating: 0, count: 14)
        action[0] = 10 // way past left_hip_yaw's ~0.52 rad ceiling
        let frame = DuckGait.frame(action: action, previousTargets: nil)
        XCTAssertEqual(frame.targets[0], DuckModel.jointRanges[0].upper, accuracy: 1e-12)
        XCTAssertEqual(frame.limitedBy, ["left_hip_yaw"])
    }

    func testLocomotionSelectsStandBelowTheThresholdAndWalkAbove() {
        XCTAssertEqual(DuckGait.locomotion(for: DuckCommand()), .stand)
        XCTAssertEqual(DuckGait.locomotion(for: DuckCommand(twist: (0.04, 0, 0))), .stand)
        XCTAssertEqual(DuckGait.locomotion(for: DuckCommand(twist: (0.06, 0, 0))), .walk)
        // Head and body motion must not make the duck think it is walking.
        XCTAssertEqual(DuckGait.locomotion(for: DuckCommand(head: (1, 1, 1, 1), bodyZ: 1)), .stand)
    }
}
