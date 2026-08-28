import XCTest
@testable import DuckKit

/// The pipeline with its lid off. `stages` exists so that "where did this
/// target come from?" is answerable — the policy's raw idea, the filter's
/// lag, or a joint stop — and these tests hold it to the two claims that
/// makes worth having: it is the *same* arithmetic `frame` runs, not a
/// second copy of it, and each stage is exactly the one step it says it is.
final class DuckGaitStagesTests: XCTestCase {

    /// Fourteen mid-sized actions, well inside every joint's travel — a
    /// plausible tick rather than a pathological one.
    private let plausible: [Float] = (0..<14).map { Float($0 % 5) * 0.11 - 0.22 }

    /// Fourteen actions far past every stop, so the clamp has work to do.
    private let extreme: [Float] = (0..<14).map { $0.isMultiple(of: 2) ? 9 : -9 }

    /// A previous tick that is not the home pose, so the filter has a real
    /// lag to apply rather than blending home with home.
    private var displaced: [Double] {
        var targets = DuckModel.homePose
        targets[3] += 0.4   // left_knee
        targets[7] -= 0.3   // head_yaw
        return targets
    }

    /// ONE PIPELINE, NOT TWO. `frame` is `stages` with the intermediates
    /// dropped, so its targets must be the clamped stage to the bit — across
    /// both action scales, with and without a previous tick, with the filter
    /// swept, and with the clamp biting.
    func testTheClampedStageIsExactlyWhatFrameReturns() {
        let cases: [(action: [Float], previous: [Double]?, kind: DuckPolicyKind,
                     mouth: Double, alphas: DuckGait.Alphas)] = [
            (plausible, nil, .walk, 0, .trained),
            (plausible, displaced, .walk, 0.2, .trained),
            (plausible, displaced, .stand, 0.2, .trained),
            (extreme, displaced, .walk, 0, .trained),
            (extreme, nil, .stand, 0, .trained),
            (plausible, displaced, .walk, 0, DuckGait.Alphas(head: 0.25, legs: 0.9)),
            (plausible, displaced, .walk, 0, DuckGait.Alphas(head: 1, legs: 1)),
        ]
        for (index, test) in cases.enumerated() {
            let stages = DuckGait.stages(
                action: test.action, previousTargets: test.previous, kind: test.kind,
                mouth: test.mouth, alphas: test.alphas)
            let frame = DuckGait.frame(
                action: test.action, previousTargets: test.previous, kind: test.kind,
                mouth: test.mouth, alphas: test.alphas)
            XCTAssertEqual(stages.clamped, frame.targets,
                           "case \(index): frame's targets must be the clamped stage, bit for bit")
            XCTAssertEqual(stages.limitedBy, frame.limitedBy,
                           "case \(index): both must name the same held joints, in the same order")
        }
    }

    /// The filter starts from reality: with no previous tick there is nothing
    /// to lag behind, so the first tick passes through untouched.
    func testTheFirstTickHasNoPreviousToLagBehindSoScaledAndFilteredAgree() {
        let stages = DuckGait.stages(action: plausible, previousTargets: nil, mouth: 0.1)
        XCTAssertEqual(stages.scaled, stages.filtered,
                       "the first tick is its own filter input, so nothing may move")
        XCTAssertEqual(stages.clamped, stages.filtered,
                       "these actions are inside every travel, so the clamp must be a no-op")
        XCTAssertTrue(stages.limitedBy.isEmpty, "nothing was held: \(stages.limitedBy)")
        XCTAssertEqual(stages.scaled[DuckModel.mouthIndex], 0.1, accuracy: 1e-12,
                       "the mouth is the caller's, and rides through the scaled stage as given")
    }

    /// α·new + (1−α)·previous, with each group's own α. Held to the arithmetic
    /// rather than to a fixture: a zero action makes the scaled stage exactly
    /// the home pose, so displacing the previous tick by one radian means the
    /// filtered stage must retain exactly (1−α) of that radian — 0.3 of it on
    /// a leg, 0.5 on a head joint.
    func testScaledAndFilteredPartOnTheSecondTickByEachGroupsOwnAlpha() {
        let zero = [Float](repeating: 0, count: 14)
        var previous = DuckGait.frame(action: zero, previousTargets: nil).targets
        previous[2] += 1.0   // left_hip_pitch, a leg
        previous[6] += 1.0   // head_pitch

        let stages = DuckGait.stages(action: zero, previousTargets: previous)
        XCTAssertEqual(stages.scaled[2], DuckModel.homePose[2], accuracy: 1e-12,
                       "the scaled stage is the policy's idea alone and never sees the previous tick")
        XCTAssertEqual(stages.scaled[6], DuckModel.homePose[6], accuracy: 1e-12,
                       "the same holds for the head")
        XCTAssertNotEqual(stages.scaled, stages.filtered,
                          "with a displaced previous tick the filter must have something to do")
        XCTAssertEqual(stages.filtered[2] - DuckModel.homePose[2], 0.3, accuracy: 1e-9,
                       "a leg keeps 1 − 0.7 of last tick's displacement")
        XCTAssertEqual(stages.filtered[6] - DuckModel.homePose[6], 0.5, accuracy: 1e-9,
                       "a head joint keeps 1 − 0.5, so it lags further behind than the legs do")
        XCTAssertEqual(stages.filtered[3], stages.scaled[3], accuracy: 1e-12,
                       "an undisplaced joint has nothing to lag towards")
    }

    /// The sweep knob at its degenerate end: α = 1 ignores the previous tick
    /// entirely, which is the loop the policies were *not* trained in and is
    /// exactly why the parameter defaults to the trained pair.
    func testAnAlphaOfOneTurnsTheFilterOffCompletely() {
        XCTAssertEqual(DuckGait.Alphas.trained.head, 0.5, accuracy: 1e-12, "the trained head coefficient")
        XCTAssertEqual(DuckGait.Alphas.trained.legs, 0.7, accuracy: 1e-12, "the trained leg coefficient")

        let zero = [Float](repeating: 0, count: 14)
        var previous = DuckModel.homePose
        for joint in 0..<DuckModel.jointCount where joint != DuckModel.mouthIndex {
            previous[joint] += 0.2
        }
        let unfiltered = DuckGait.stages(
            action: zero, previousTargets: previous, alphas: DuckGait.Alphas(head: 1, legs: 1))
        XCTAssertEqual(unfiltered.scaled, unfiltered.filtered,
                       "at α = 1 the previous tick contributes nothing, so the filter is off")

        let trained = DuckGait.stages(action: zero, previousTargets: previous)
        XCTAssertNotEqual(trained.filtered, unfiltered.filtered,
                          "the trained filter must actually lag, or the comparison proves nothing")
        XCTAssertEqual(trained.filtered,
                       DuckGait.stages(action: zero, previousTargets: previous, alphas: .trained).filtered,
                       "the default alphas are the trained pair, not a fresh guess")
    }

    /// `clamped − filtered` is non-zero at exactly the joints in `limitedBy`
    /// and nowhere else — the property that lets a caller tell a policy that
    /// *wants* to be at a stop from one being *held* there.
    func testClampingChangesTheTargetOnlyAtTheJointsItNames() {
        var action = [Float](repeating: 0, count: 14)
        action[0] = 10   // left_hip_yaw, way past its ~0.52 rad ceiling
        action[3] = -10  // left_knee, way below its floor
        let stages = DuckGait.stages(action: action, previousTargets: nil)

        XCTAssertEqual(stages.limitedBy, ["left_hip_yaw", "left_knee"],
                       "both stops must be named, in joint order")
        XCTAssertGreaterThan(stages.filtered[0], DuckModel.jointRanges[0].upper,
                             "the unheld stage must show what the policy actually asked for")
        XCTAssertEqual(stages.clamped[0], DuckModel.jointRanges[0].upper, accuracy: 1e-12,
                       "and the held stage must sit on the stop")
        XCTAssertEqual(stages.clamped[3], DuckModel.jointRanges[3].lower, accuracy: 1e-12,
                       "a floor is held the same way a ceiling is")

        let named = Set(stages.limitedBy)
        for joint in 0..<DuckModel.jointCount where !named.contains(DuckModel.jointNames[joint]) {
            XCTAssertEqual(stages.clamped[joint], stages.filtered[joint], accuracy: 1e-12,
                           "\(DuckModel.jointNames[joint]) was moved by the clamp without being named")
        }
    }
}
