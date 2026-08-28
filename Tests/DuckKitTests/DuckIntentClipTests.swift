import XCTest
@testable import DuckKit

/// A one-shot is not a gait, and every one of these is about that difference.
final class DuckIntentClipTests: XCTestCase {

    private func clips() throws -> [String: DuckIntentClip] { try DuckIntentClip.bundled() }

    func testTheCorpusLoads() throws {
        let all = try clips()
        XCTAssertEqual(all.count, 14)
        for name in ["hold", "kick_left", "sit", "stand", "roulade", "headspin"] {
            XCTAssertNotNil(all[name], "missing \(name)")
        }
    }

    /// The whole reason this type exists. Ask a gait for four loops and it
    /// gives you four strides; ask a kick and it must give you one kick and
    /// then a duck standing where the kick left it.
    func testAOneShotClampsRatherThanWrapping() throws {
        let kick = try XCTUnwrap(try clips()["kick_left"])
        XCTAssertFalse(kick.loops)
        let end = kick.pose(at: kick.duration)
        let wayPast = kick.pose(at: kick.duration * 40)
        XCTAssertTrue(end.hasFinished)
        XCTAssertTrue(wayPast.hasFinished)
        XCTAssertEqual(wayPast.jointAngles, end.jointAngles,
                       "forty durations in, it is still where it finished")
    }

    /// `hold` is the one clip that loops, and it must NOT report finished.
    func testTheIdleLoopsForever() throws {
        let hold = try XCTUnwrap(try clips()["hold"])
        XCTAssertTrue(hold.loops)
        XCTAssertFalse(hold.pose(at: hold.duration * 12).hasFinished)
    }

    /// A one-shot's last frame IS its end, so it spans one fewer interval than
    /// it has frames. A loop hands back to its first and spans them all.
    func testDurationCountsIntervalsNotFrames() throws {
        let all = try clips()
        let kick = try XCTUnwrap(all["kick_left"])
        XCTAssertEqual(kick.duration, Double(kick.frames.count - 1) / kick.hz, accuracy: 1e-12)
        let hold = try XCTUnwrap(all["hold"])
        XCTAssertEqual(hold.duration, Double(hold.frames.count) / hold.hz, accuracy: 1e-12)
    }

    /// Poses must be 15 joints for DuckKinematics, with the mouth filled in —
    /// a recording carries nothing for it, since it is outside every policy's
    /// action space.
    func testPosesCoverEveryJointIncludingTheMouth() throws {
        let pose = try XCTUnwrap(clips()["hold"]).pose(at: 0.2)
        XCTAssertEqual(pose.jointAngles.count, DuckModel.jointCount)
        XCTAssertEqual(pose.jointAngles[DuckModel.mouthIndex],
                       DuckModel.homePose[DuckModel.mouthIndex],
                       "the mouth defaults to home rather than to zero")
    }

    /// Every clip is de-origined at record time, so a fired intent does not
    /// teleport the duck across the room.
    func testEveryClipStartsAtTheOrigin() throws {
        for (name, clip) in try clips() {
            let start = clip.pose(at: 0).root
            XCTAssertEqual(start.x, 0, accuracy: 1e-4, name)
            XCTAssertEqual(start.y, 0, accuracy: 1e-4, name)
        }
    }

    /// Postures are measured from the recording, so they can disagree with the
    /// clip's name — and that disagreement is the useful part.
    func testPosturesAreMeasuredNotAssumed() throws {
        let all = try clips()
        XCTAssertEqual(try XCTUnwrap(all["sit"]).endsIn, .seated)
        XCTAssertEqual(try XCTUnwrap(all["stand"]).startsFrom, .seated)
        XCTAssertEqual(try XCTUnwrap(all["step_up"]).endsIn, .toppled,
                       "step_up falls over against a real stair, and the label says so")
    }

    /// netYaw is unwrapped, and `headspin` is the clip that proves why it has
    /// to be: its total is +4.070 rad, while atan2 of its final quaternion
    /// gives −2.213. They differ by exactly 2π — so the wrapped answer does not
    /// merely lose a turn, it points the duck the OTHER WAY.
    func testNetYawIsUnwrappedAndCanDisagreeWithTheFinalQuaternion() throws {
        let clip = try XCTUnwrap(clips()["headspin"])
        XCTAssertGreaterThan(abs(clip.netYaw), Double.pi,
                             "an unwrapped total can exceed half a turn")

        let q = clip.pose(at: clip.duration).root.quaternion
        let wrapped = atan2(2 * (q.0 * q.3 + q.1 * q.2),
                            1 - 2 * (q.2 * q.2 + q.3 * q.3))
        XCTAssertEqual(abs(clip.netYaw - wrapped), 2 * Double.pi, accuracy: 1e-3,
                       "exactly one full turn apart")
        XCTAssertNotEqual(clip.netYaw.sign, wrapped.sign,
                          "and opposite in sign — the wrapped answer turns the wrong way")
    }

    func testInterpolationIsSmoothBetweenFrames() throws {
        let clip = try XCTUnwrap(try clips()["sit"])
        let dt = 1 / clip.hz
        let a = clip.pose(at: dt * 10).jointAngles
        let mid = clip.pose(at: dt * 10.5).jointAngles
        let b = clip.pose(at: dt * 11).jointAngles
        for joint in 0..<DuckModel.jointCount {
            let low = min(a[joint], b[joint]), high = max(a[joint], b[joint])
            XCTAssertGreaterThanOrEqual(mid[joint], low - 1e-9)
            XCTAssertLessThanOrEqual(mid[joint], high + 1e-9)
        }
    }

    func testGarbageIsRefused() {
        XCTAssertThrowsError(try DuckIntentClip.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try DuckIntentClip.decode(Data("not json".utf8)))
    }
}
