import XCTest
@testable import DuckKit

/// Recorded walking, and the arithmetic that replays it.
final class DuckTrajectoryTests: XCTestCase {

    // ── the shipped clips ────────────────────────────────────────────────

    func testEveryDeclaredClipShipsAndIsWellFormed() throws {
        let all = try DuckTrajectory.all()
        for clip in DuckTrajectory.Clip.allCases {
            let t = try XCTUnwrap(all[clip.rawValue], "\(clip.rawValue) is declared but not shipped")
            XCTAssertEqual(t, try DuckTrajectory.bundled(clip))
            XCTAssertGreaterThan(t.frames.count, 50, "\(clip.rawValue) is too short to be a gait")
            XCTAssertEqual(t.hz, DuckModel.tickHz, "clips are recorded at the robot's own rate")
            XCTAssertEqual(t.frames.count % t.period, 0,
                           "\(clip.rawValue) is not a whole number of strides, so it cannot loop cleanly")
            for frame in t.frames {
                XCTAssertEqual(frame.count, DuckModel.jointCount)
                for (j, angle) in frame.enumerated() {
                    XCTAssertTrue(angle.isFinite)
                    let r = DuckModel.jointRanges[j]
                    XCTAssertTrue(angle >= r.lower - 1e-6 && angle <= r.upper + 1e-6,
                                  "\(clip.rawValue) \(DuckModel.jointNames[j]) is outside its travel")
                }
            }
        }
    }

    /// The duck was upright for every recorded frame — a clip of a fallen duck
    /// would replay as a ghost lying on its side.
    func testEveryClipWasRecordedStandingUp() throws {
        for clip in DuckTrajectory.Clip.allCases {
            let t = try DuckTrajectory.bundled(clip)
            XCTAssertTrue((0.10...0.20).contains(t.height),
                          "\(clip.rawValue) recorded at \(t.height) m — that is not a duck on its feet")
        }
    }

    /// The mouth is in no policy, so nothing should have moved it.
    func testTheMouthNeverMovesInARecording() throws {
        for clip in DuckTrajectory.Clip.allCases {
            for frame in try DuckTrajectory.bundled(clip).frames {
                XCTAssertEqual(frame[DuckModel.mouthIndex], 0, accuracy: 1e-9)
            }
        }
    }

    // ── sampling ─────────────────────────────────────────────────────────

    /// A clip must not jump at its own seam: the pose approaching the end has
    /// to match the pose at the start, or a looping ghost twitches once a
    /// stride.
    func testTheLoopSeamDoesNotJump() throws {
        for clip in DuckTrajectory.Clip.allCases {
            let t = try DuckTrajectory.bundled(clip)
            let first = t.pose(at: 0).jointAngles
            let last = t.pose(at: t.duration - 1.0 / t.hz).jointAngles
            for j in 0..<DuckModel.jointCount {
                XCTAssertEqual(first[j], last[j], accuracy: 0.25,
                               "\(clip.rawValue) jumps at the seam on \(DuckModel.jointNames[j])")
            }
        }
    }

    /// Between ticks the pose is interpolated, so a 120 Hz display gets motion
    /// rather than the same frame three times.
    func testPosesInterpolateBetweenTicks() throws {
        let t = try DuckTrajectory.bundled(.walk)
        let step = 1.0 / t.hz
        let a = t.pose(at: 0).jointAngles
        let mid = t.pose(at: step * 0.5).jointAngles
        let b = t.pose(at: step).jointAngles
        var moved = false
        for j in 0..<DuckModel.jointCount where abs(b[j] - a[j]) > 1e-6 {
            moved = true
            XCTAssertEqual(mid[j], (a[j] + b[j]) / 2, accuracy: 1e-9)
        }
        XCTAssertTrue(moved, "nothing moved between two ticks of a walk")
    }

    /// A looping walk keeps covering ground.
    ///
    /// Asserted as PATH LENGTH, not as distance from the start, and the
    /// difference matters: the recorded walk carries −1.15 rad of yaw per loop,
    /// so the duck walks a circle and comes back past its own starting point.
    /// The obvious version of this test — "ten loops must be further out than
    /// one" — fails for exactly that reason, and the walk is fine. The drift is
    /// a property of the actuator model the clips were recorded against, and is
    /// written down in `DuckTrajectory`'s own comment.
    func testWalkingKeepsCoveringGround() throws {
        let t = try DuckTrajectory.bundled(.walk)
        func pathLength(loops: Double) -> Double {
            var total = 0.0
            var previous = t.pose(at: 0)
            let steps = Int(loops * Double(t.frames.count))
            for i in 1...steps {
                let now = t.pose(at: Double(i) / t.hz)
                total += hypot(now.x - previous.x, now.y - previous.y)
                previous = now
            }
            return total
        }
        let one = pathLength(loops: 1), ten = pathLength(loops: 10)
        XCTAssertGreaterThan(one, 0.05, "one loop of walking went nowhere")
        XCTAssertEqual(ten / one, 10, accuracy: 0.5, "ten loops should cover ten times the ground")
    }

    /// The recorded walk curves, and a caller placing a ghost needs to know it
    /// will come round rather than head for the horizon.
    func testTheRecordedWalkCurves() throws {
        let t = try DuckTrajectory.bundled(.walk)
        XCTAssertGreaterThan(abs(t.deltaYaw), 0.5,
                             "if this walk has become straight, the clips were re-recorded — say so in the docs")
    }

    /// Standing still stays still.
    func testStandingDoesNotDriftAcrossLoops() throws {
        let t = try DuckTrajectory.bundled(.stand)
        let far = t.pose(at: t.duration * 20)
        XCTAssertLessThan(hypot(far.x, far.y), 0.05, "the idle wandered off")
        XCTAssertLessThan(abs(far.yaw), 0.1, "the idle span round")
    }

    /// Time inside a loop advances the body smoothly rather than in a jump at
    /// the seam.
    func testRootMotionIsContinuousAtTheSeam() throws {
        let t = try DuckTrajectory.bundled(.walk)
        let just = t.pose(at: t.duration - 1e-6)
        let after = t.pose(at: t.duration + 1e-6)
        XCTAssertEqual(just.x, after.x, accuracy: 1e-3)
        XCTAssertEqual(just.y, after.y, accuracy: 1e-3)
        XCTAssertEqual(just.yaw, after.yaw, accuracy: 1e-3)
    }

    /// A caller that backgrounds an app and comes back with a huge time must
    /// get an answer rather than a spin.
    func testAnAbsurdTimeStillReturns() throws {
        let t = try DuckTrajectory.bundled(.walk)
        let p = t.pose(at: 60 * 60 * 24 * 365)
        XCTAssertTrue(p.x.isFinite && p.y.isFinite && p.yaw.isFinite)
        XCTAssertEqual(p.jointAngles.count, DuckModel.jointCount)
    }

    // ── mirroring ────────────────────────────────────────────────────────

    /// The robot's home pose is exactly antisymmetric, so mirroring it must
    /// give it back. This is the cheapest possible check that the swap-and-
    /// negate convention is the right one.
    func testTheHomePoseIsAFixedPointOfTheMirror() {
        let mirrored = DuckTrajectory.mirror(pose: DuckModel.homePose)
        for j in 0..<DuckModel.jointCount {
            XCTAssertEqual(mirrored[j], DuckModel.homePose[j], accuracy: 1e-12,
                           "\(DuckModel.jointNames[j]) is not symmetric about the mirror")
        }
    }

    func testMirroringTwiceIsTheIdentity() throws {
        let t = try DuckTrajectory.bundled(.walk)
        let back = t.mirrored().mirrored()
        XCTAssertEqual(back.frames, t.frames)
        XCTAssertEqual(back.deltaYaw, t.deltaYaw, accuracy: 1e-12)
        XCTAssertEqual(back.deltaY, t.deltaY, accuracy: 1e-12)
    }

    /// The reason mirroring exists: a right turn, from the only turn we could
    /// record honestly.
    func testAMirroredLeftTurnTurnsRight() throws {
        let left = try DuckTrajectory.bundled(.turnLeft)
        let right = left.mirrored()
        XCTAssertGreaterThan(left.deltaYaw, 0.2, "the recorded turn should go left")
        XCTAssertEqual(right.deltaYaw, -left.deltaYaw, accuracy: 1e-12)
        XCTAssertLessThan(right.pose(at: right.duration).yaw, 0, "the mirror must come round the other way")
    }

    /// Mirroring swaps the legs, so the left knee's motion becomes the right
    /// knee's — negated.
    func testMirroringSwapsTheLegs() throws {
        let t = try DuckTrajectory.bundled(.walk)
        let m = t.mirrored()
        let leftKnee = DuckModel.jointNames.firstIndex(of: "left_knee")!
        let rightKnee = DuckModel.jointNames.firstIndex(of: "right_knee")!
        for (a, b) in zip(t.frames, m.frames) {
            XCTAssertEqual(b[leftKnee], -a[rightKnee], accuracy: 1e-12)
            XCTAssertEqual(b[rightKnee], -a[leftKnee], accuracy: 1e-12)
        }
    }

    // ── loading ──────────────────────────────────────────────────────────

    func testMalformedDataIsRefusedRatherThanGuessed() {
        let notAnObject = Data("[]".utf8)
        XCTAssertThrowsError(try DuckTrajectory.decode(notAnObject))
        let shortFrame = Data(#"{"hz":50,"clips":{"x":{"frames":[[0,0]],"period":1,"deltaX":0,"deltaY":0,"deltaYaw":0,"height":0.13}}}"#.utf8)
        XCTAssertThrowsError(try DuckTrajectory.decode(shortFrame)) { error in
            guard case DuckTrajectory.LoadError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }
}
