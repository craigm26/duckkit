import XCTest
@testable import DuckKit

/// An authored move is arithmetic, so all of it is testable here — which is the
/// point of it living in the package rather than in the simulator that found it.
final class DuckMoveTests: XCTestCase {

    private func simple() -> DuckMove {
        var a = DuckModel.homePose; a[5] = 1.0
        var b = DuckModel.homePose; b[5] = 0.2
        return DuckMove(name: "t", keyframes: [
            .init(time: 0.5, pose: a),
            .init(time: 1.0, pose: b),
        ])
    }

    // ── sampling ─────────────────────────────────────────────────────────

    /// A move begins wherever the duck already is, not at its first keyframe.
    func testAMoveStartsFromTheBasePose() {
        let m = simple()
        XCTAssertEqual(m.pose(at: 0), DuckModel.homePose)
        XCTAssertEqual(m.pose(at: -1), DuckModel.homePose)
    }

    /// A move whose first keyframe sits AT zero opens on that keyframe, not on
    /// the base. Every motion the editor writes starts at 0.00 s, so for as
    /// long as `pose(at:)` answered `base` for all non-positive times, the
    /// opening pose of an authored motion was the one instant it could not be
    /// sampled at: posing it moved nothing on screen, and a reader that
    /// recovered keyframes by sampling silently replaced it with the home
    /// stance.
    func testAMoveThatOpensOnAKeyframeOpensOnThatKeyframe() {
        var opening = DuckModel.homePose; opening[5] = 1.5
        var later = DuckModel.homePose; later[5] = 0.2
        let m = DuckMove(name: "opens at zero", keyframes: [
            .init(time: 0.0, pose: opening),
            .init(time: 1.0, pose: later),
        ])
        XCTAssertEqual(m.pose(at: 0), opening)
        XCTAssertEqual(m.pose(at: -1), opening)
        // And it does not jump: one microsecond later is still essentially the
        // opening pose, where before the fix it leapt the whole way from home.
        XCTAssertEqual(m.pose(at: 1e-6)[5], opening[5], accuracy: 1e-4)
    }

    /// Read as offsets, the opening keyframe is still resolved against the base
    /// rather than handed back raw.
    func testAnOpeningKeyframeIsResolvedThroughTheReadingMode() {
        var delta = [Double](repeating: 0, count: DuckModel.jointCount); delta[5] = 0.25
        let m = DuckMove(name: "offset at zero",
                         keyframes: [.init(time: 0.0, pose: delta),
                                     .init(time: 1.0, pose: delta)],
                         base: DuckModel.homePose, posesAre: .offset)
        XCTAssertEqual(m.pose(at: 0)[5], DuckModel.homePose[5] + 0.25, accuracy: 1e-12)
    }

    /// The keyframes somebody wrote are readable as such, without sampling.
    func testAbsolutePoseIsReachableFromOutsideThePackage() {
        var opening = DuckModel.homePose; opening[5] = 1.5
        let m = DuckMove(name: "readable", keyframes: [.init(time: 0.0, pose: opening),
                                                       .init(time: 1.0, pose: DuckModel.homePose)])
        XCTAssertEqual(m.absolutePose(m.keyframes[0]), opening)
    }

    func testItHoldsTheLastKeyframeAfterTheEnd() {
        let m = simple()
        XCTAssertEqual(m.pose(at: m.duration), m.keyframes.last!.pose)
        XCTAssertEqual(m.pose(at: m.duration + 10), m.keyframes.last!.pose)
        XCTAssertTrue(m.hasFinished(at: m.duration))
        XCTAssertFalse(m.hasFinished(at: m.duration - 0.01))
    }

    /// Smoothstep, not linear — and the difference is the reason. A linear
    /// blend reaches each keyframe with a velocity step, and a servo asked to
    /// change speed instantly answers with a jolt the balance controller then
    /// has to absorb.
    func testInterpolationIsSmoothstepAndNotLinear() {
        let m = simple()
        let mid = m.pose(at: 0.25)[5]                 // halfway to the first frame
        XCTAssertEqual(mid, 0.5 * (DuckModel.homePose[5] + 1.0), accuracy: 1e-12,
                       "smoothstep and linear agree at exactly halfway")
        // ...but not at a quarter, which is what distinguishes them.
        let quarter = m.pose(at: 0.125)[5]
        let linear = DuckModel.homePose[5] + (1.0 - DuckModel.homePose[5]) * 0.25
        XCTAssertNotEqual(quarter, linear, accuracy: 1e-6)
        XCTAssertLessThan(quarter, linear, "smoothstep starts slower than linear")
    }

    /// The derivative is zero at both ends of every segment. That is the whole
    /// reason for smoothstep, so it is worth asserting rather than assuming.
    func testTheMoveStartsAndEndsWithoutAVelocityStep() {
        let m = simple()
        let dt = 1e-4
        let startRate = (m.pose(at: dt)[5] - m.pose(at: 0)[5]) / dt
        let endRate = (m.pose(at: 0.5)[5] - m.pose(at: 0.5 - dt)[5]) / dt
        XCTAssertEqual(startRate, 0, accuracy: 1e-2)
        XCTAssertEqual(endRate, 0, accuracy: 1e-2)
    }

    func testOffsetIsThePoseMinusTheBase() {
        let m = simple()
        for t in [0.0, 0.2, 0.5, 0.9, 1.4] {
            let pose = m.pose(at: t), offset = m.offset(at: t)
            for j in 0..<DuckModel.jointCount {
                XCTAssertEqual(offset[j], pose[j] - DuckModel.homePose[j], accuracy: 1e-12)
            }
        }
    }

    // ── applying it to a policy ──────────────────────────────────────────

    /// The move ADDS to what the policy asked for; it does not replace it.
    /// Replacing it does not work on this robot — with kp 0.55 the servos
    /// cannot hold a pose, and an open-loop version fell over on a flat floor.
    func testApplyingAddsToThePolicyRatherThanOverridingIt() {
        let m = simple()
        let policy = DuckModel.homePose.map { $0 + 0.05 }
        let out = m.applied(to: policy, at: 0.5, blend: 1)
        for j in 0..<DuckModel.jointCount where j != 5 {
            XCTAssertEqual(out[j], policy[j], accuracy: 1e-12,
                           "\(DuckModel.jointNames[j]) should carry the policy's value untouched")
        }
        // ...and the neck lands on its travel stop rather than where the sum
        // would put it, which is the clamp doing its job: neck_pitch tops out
        // at pi/3, and policy + offset asks for more than that.
        let neckRange = DuckModel.jointRanges[5]
        XCTAssertEqual(out[5], neckRange.upper, accuracy: 1e-9)
        XCTAssertGreaterThan(policy[5] + (1.0 - DuckModel.homePose[5]), neckRange.upper,
                             "the unclamped sum really does exceed the stop")
    }

    func testBlendScalesTheOffset() {
        let m = simple()
        let policy = DuckModel.homePose
        let half = m.applied(to: policy, at: 0.5, blend: 0.5)[5]
        let full = m.applied(to: policy, at: 0.5, blend: 1.0)[5]
        XCTAssertEqual(half - policy[5], (full - policy[5]) / 2, accuracy: 1e-9)
        XCTAssertEqual(m.applied(to: policy, at: 0.5, blend: 0), policy)
    }

    /// No combination of a policy and a move may ask for an angle the joint
    /// does not have.
    func testTheResultIsAlwaysInsideTheRobotsTravel() {
        let m = DuckMove.stepUp
        // A deliberately absurd policy output, to prove the clamp is the thing
        // holding the line rather than the arithmetic happening to be small.
        let wild = (0..<DuckModel.jointCount).map { _ in 6.0 }
        for t in stride(from: 0.0, through: m.duration + 0.5, by: 0.05) {
            for (j, v) in m.applied(to: wild, at: t, blend: 4).enumerated() {
                let r = DuckModel.jointRanges[j]
                XCTAssertTrue(v >= r.lower - 1e-9 && v <= r.upper + 1e-9,
                              "\(DuckModel.jointNames[j]) left its travel at t=\(t)")
            }
        }
    }

    // ── the shipped move ─────────────────────────────────────────────────

    func testStepUpIsWellFormed() {
        let m = DuckMove.stepUp
        XCTAssertEqual(m.keyframes.count, 5, "plant, push, swing, transfer, recover")
        XCTAssertGreaterThan(m.duration, 2.0)
        XCTAssertLessThan(m.duration, 4.0)
        for f in m.keyframes { XCTAssertEqual(f.pose.count, DuckModel.jointCount) }
        // It has to end back at a stance, or a second one could not follow it.
        XCTAssertEqual(m.keyframes.last!.pose, DuckModel.homePose)
    }

    /// The search's two surprising choices, pinned so a re-tune has to
    /// acknowledge them rather than quietly undo them.
    func testTheSearchChoseToStandIntoTheStepAndToPullUpAtTheEnd() {
        XCTAssertLessThan(DuckMove.stepUpApproach, 0.3,
                          "below the speed the walking policy engages at — it stands into the step")
        XCTAssertGreaterThan(DuckMove.stepUpBlend, 1.0,
                             "the search over-drives the authored offset")
        let neckAtPlant = DuckMove.stepUp.keyframes[0].pose[5]
        let neckAtTransfer = DuckMove.stepUp.keyframes[3].pose[5]
        XCTAssertGreaterThan(neckAtPlant, 0, "the head goes down to plant")
        XCTAssertLessThan(neckAtTransfer, 0, "and pulls up to haul the body over")
    }

    /// The mouth is in no policy and no phase of this move should touch it.
    func testStepUpNeverMovesTheMouth() {
        for f in DuckMove.stepUp.keyframes {
            XCTAssertEqual(f.pose[DuckModel.mouthIndex], DuckModel.homePose[DuckModel.mouthIndex],
                           accuracy: 1e-12)
        }
    }

    // ── mirroring ────────────────────────────────────────────────────────

    func testMirroringSwapsTheLeadLegAndIsItsOwnInverse() {
        let m = DuckMove.stepUp, n = m.mirrored()
        XCTAssertEqual(n.keyframes.count, m.keyframes.count)
        for (a, b) in zip(m.keyframes, n.keyframes) {
            XCTAssertEqual(a.time, b.time, accuracy: 1e-12)
            XCTAssertEqual(b.pose[3], -a.pose[13], accuracy: 1e-12, "left knee becomes the right, negated")
        }
        XCTAssertEqual(n.mirrored().keyframes.map(\.pose), m.keyframes.map(\.pose))
    }

    // ── refusing malformed moves ─────────────────────────────────────────

    func testKeyframesMustBeInTimeOrder() {
        // Construction preconditions are not catchable in-process, so the
        // guarantee is asserted on the shipped move instead.
        let times = DuckMove.stepUp.keyframes.map(\.time)
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(Set(times).count, times.count, "no two keyframes share a time")
        XCTAssertTrue(times.allSatisfy { $0 > 0 })
    }
}

/// Importing a move somebody else wrote. The existing initializer traps, which
/// is right for a literal in this package and exactly wrong for a file, a
/// shared clip, or a pose sequence a language model drafted.
final class DuckMoveValidatingTests: XCTestCase {

    private func pose(_ value: Double = 0) -> [Double] {
        DuckModel.homePose.map { _ in value }
    }

    func testAGoodMoveIsAccepted() throws {
        let move = try DuckMove(validating: "ok", keyframes: [
            .init(time: 0.0, pose: DuckModel.homePose),
            .init(time: 0.5, pose: DuckModel.homePose),
        ])
        XCTAssertEqual(move.keyframes.count, 2)
        XCTAssertEqual(move.duration, 0.5, accuracy: 1e-12)
    }

    func testTheFailuresThrowRatherThanCrash() {
        XCTAssertThrowsError(try DuckMove(validating: "e", keyframes: [])) {
            XCTAssertEqual($0 as? DuckMove.Invalid, .empty)
        }
        XCTAssertThrowsError(try DuckMove(validating: "t", keyframes: [
            .init(time: 0.5, pose: DuckModel.homePose),
            .init(time: 0.5, pose: DuckModel.homePose),
        ])) { XCTAssertEqual($0 as? DuckMove.Invalid, .timesNotIncreasing(keyframe: 1)) }
    }

    /// The exported intent files are all 14-wide, so this is the error a real
    /// import actually hits — and the message has to point at the way out.
    func testAFourteenWidePoseSaysWhichDoorToUse() {
        let policyWide = [Double](repeating: 0, count: DuckModel.policyJointCount)
        // Through the RAW door. Wrapping this in a `Keyframe` first would trap
        // inside `Keyframe.init` — which is exactly why the raw door exists.
        XCTAssertThrowsError(try DuckMove(validating: "w", times: [0],
                                          poses: [policyWide])) { error in
            guard case DuckMove.Invalid.wrongWidth(_, let got, let expected) = error else {
                return XCTFail("wrong error")
            }
            XCTAssertEqual(got, 14)
            XCTAssertEqual(expected, 15)
            XCTAssertTrue((error as! DuckMove.Invalid).message.contains("validatingPolicyPoses"),
                          "the message must name the initializer that takes this shape")
        }
    }

    /// And that door works on the shape the files carry.
    func testPolicyWidePosesLoadAndPlaceTheMouthAtHome() throws {
        let move = try DuckMove(validatingPolicyPoses: "exported",
                                times: [0, 0.4],
                                poses: [Array(policyJoints(DuckModel.homePose)),
                                        Array(policyJoints(DuckModel.homePose))])
        XCTAssertEqual(move.keyframes[0].pose.count, DuckModel.jointCount)
        XCTAssertEqual(move.keyframes[0].pose[DuckModel.mouthIndex],
                       DuckModel.homePose[DuckModel.mouthIndex],
                       "a 14-wide file says nothing about the mouth, so it goes home")
    }

    /// A drafted pose that puts a joint through its own travel is refused by
    /// name, so the author is told which joint rather than that something is
    /// wrong somewhere.
    func testAPoseOutsideTravelIsRefusedByJointName() {
        var bad = DuckModel.homePose
        bad[3] = DuckModel.jointRanges[3].upper + 1.0
        XCTAssertThrowsError(try DuckMove(validating: "b", times: [0],
                                          poses: [bad])) { error in
            guard case DuckMove.Invalid.outsideTravel(_, let joint) = error else {
                return XCTFail("wrong error")
            }
            XCTAssertEqual(joint, DuckModel.jointNames[3])
        }
    }

    private func policyJoints(_ all: [Double]) -> [Double] {
        (0..<DuckModel.policyJointCount).map { all[DuckModel.jointOfPolicySlot($0)] }
    }
}
