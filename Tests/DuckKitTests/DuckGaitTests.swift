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

    /// α·new + (1−α)·previous, with robotd's α per joint group. (Renamed from
    /// "trained coefficients": the filter is the hardware's, not training's.)
    func testTheLowpassUsesRobotdsCoefficients() {
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

// MARK: - the scales are robotd's, per network

extension DuckGaitTests {

    /// robotd pins roulade, ground-pick and the whole sit/rise cycle at 1.0,
    /// and de-rates only walking and the kicks. The first cut of this mapping
    /// returned 0.9 for all three — a package that claims to mirror the
    /// runtime, quietly de-rating a roulade by 10%.
    func testTheActionScalesMatchRobotdPerNetwork() {
        XCTAssertEqual(DuckPolicyKind.stand.actionScale, 1.0)
        XCTAssertEqual(DuckPolicyKind.sitStand.actionScale, 1.0)
        XCTAssertEqual(DuckPolicyKind.groundPick.actionScale, 1.0)
        XCTAssertEqual(DuckPolicyKind.roulade.actionScale, 1.0)
        XCTAssertEqual(DuckPolicyKind.walk.actionScale, 0.9)
        XCTAssertEqual(DuckPolicyKind.kickLeft.actionScale, 0.9)
        XCTAssertEqual(DuckPolicyKind.kickRight.actionScale, 0.9)
    }

    /// The 10% is not cosmetic: a full-scale roulade action lands 10% further
    /// from home under the fixed mapping than under the old one.
    func testARouladeActionIsNoLongerDeRated() {
        var action = [Float](repeating: 0, count: DuckModel.policyJointCount)
        action[2] = 1.0   // left_hip_pitch, hard over
        let stages = DuckGait.stages(action: action, previousTargets: nil,
                                     kind: .roulade)
        XCTAssertEqual(stages.scaled[2], DuckModel.homePose[2] + 1.0, accuracy: 1e-12,
                       "roulade runs at scale 1.0, robotd's own value")
    }
}

extension DuckGaitTests {

    /// A KNOWN scale beats a guessed one.
    ///
    /// `kind` can only be inferred from a file name, which matches nothing for
    /// a policy somebody trained themselves — so a community policy silently
    /// gets walking's 0.9. A published manifest states the real number.
    func testAnExplicitScaleOverridesTheOneTheKindWouldPick() {
        let action = [Float](repeating: 0.5, count: DuckModel.policyJointCount)
        let guessed = DuckGait.stages(action: action, previousTargets: nil, kind: .walk)
        let declared = DuckGait.stages(action: action, previousTargets: nil,
                                       kind: .walk, scale: 1.0)
        XCTAssertNotEqual(guessed.scaled, declared.scaled,
                          "0.9 and 1.0 must not produce the same targets")
        // The declared one is exactly the walking one divided by 0.9, around
        // HOME — which is the 10% the guess was costing.
        let joint = DuckModel.jointOfPolicySlot(0)
        let guessedOffset = guessed.scaled[joint] - DuckModel.homePose[joint]
        let declaredOffset = declared.scaled[joint] - DuckModel.homePose[joint]
        XCTAssertEqual(declaredOffset, guessedOffset / DuckModel.actionScale, accuracy: 1e-12)
    }

    func testNoExplicitScaleKeepsTheOldBehaviourExactly() {
        let action = [Float](repeating: 0.3, count: DuckModel.policyJointCount)
        XCTAssertEqual(DuckGait.stages(action: action, previousTargets: nil, kind: .roulade).scaled,
                       DuckGait.stages(action: action, previousTargets: nil,
                                       kind: .roulade, scale: nil).scaled)
    }
}
