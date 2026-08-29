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

/// A clip played in an empty void cannot be judged, so every one carries the
/// world it was performed against.
final class DuckIntentClipEnvironmentTests: XCTestCase {

    private func clips() throws -> [String: DuckIntentClip] { try DuckIntentClip.bundled() }

    func testEveryClipHasGround() throws {
        for (name, clip) in try clips() {
            XCTAssertTrue(clip.environment.ground,
                          "\(name) needs a floor — it is what says whether the feet are on it")
        }
    }

    /// The four stair moves were recorded against a staircase, and without it
    /// on screen step_up looks like a duck falling over for no reason.
    func testTheStairMovesCarryTheirStaircase() throws {
        let all = try clips()
        for name in ["step_up", "lever_up", "riser_up", "climb"] {
            let env = try XCTUnwrap(all[name]).environment
            XCTAssertEqual(env.steps.count, 4, "\(name) was recorded against four steps")
            XCTAssertTrue(env.hasProps)
            // Each tread is higher than the last, which is what makes it a
            // flight rather than four blocks in a row.
            for (a, b) in zip(env.steps, env.steps.dropFirst()) {
                XCTAssertGreaterThan(b.top, a.top, "\(name) steps must ascend")
            }
        }
    }

    func testWallFlipCarriesItsWall() throws {
        let env = try XCTUnwrap(clips()["wall_flip"]).environment
        XCTAssertEqual(env.walls.count, 1)
        XCTAssertTrue(env.steps.isEmpty, "it flips off a wall, not a stair")
    }

    /// Clips with no prop say so, rather than carrying an empty staircase that
    /// a renderer would have to special-case.
    func testFlatFloorClipsHaveNoProps() throws {
        for name in ["hold", "sit", "kick_left", "roulade"] {
            let env = try XCTUnwrap(clips()[name]).environment
            XCTAssertFalse(env.hasProps, "\(name) happens on flat ground")
        }
    }

    /// The props live in the SAME de-origined frame as the roots. If they did
    /// not, the staircase would end up behind the robot.
    func testPropsAreNearTheDuckNotWhereMuJoCoPutThem() throws {
        let clip = try XCTUnwrap(clips()["climb"])
        for step in clip.environment.steps {
            XCTAssertLessThan(abs(step.x), 2.0, "a step 1.3 m away in y would be the raw MuJoCo frame")
            XCTAssertLessThan(abs(step.y), 2.0)
        }
    }
}

// MARK: - format 3: what the policy emitted, not just what the robot did

extension DuckIntentClipTests {

    /// The three telemetry arrays are PARALLEL TO THE FRAMES or they are
    /// useless: a reward term pairs the action at tick i with the pose at tick
    /// i, and a short array shifts every pairing after the gap.
    func testTelemetryIsParallelToTheFrames() throws {
        let clips = try DuckIntentClip.bundled()
        for (name, clip) in clips {
            XCTAssertFalse(clip.telemetry.isEmpty, "\(name) was recorded before format 3")
            XCTAssertEqual(clip.telemetry.actions.count, clip.frames.count, name)
            XCTAssertEqual(clip.telemetry.commands.count, clip.frames.count, name)
            XCTAssertEqual(clip.telemetry.twists.count, clip.frames.count, name)
            for action in clip.telemetry.actions {
                XCTAssertEqual(action.count, DuckModel.policyJointCount, name)
            }
            for twist in clip.telemetry.twists { XCTAssertEqual(twist.count, 6, name) }
            for command in clip.telemetry.commands { XCTAssertEqual(command.count, 3, name) }
        }
    }

    /// A format-2 file has to decode to ABSENT rather than to zeros. A reward
    /// panel reading zeros would report a perfectly smooth policy for a
    /// recording that never measured smoothness.
    func testAnOlderRecordingHasNoTelemetryRatherThanZeroes() throws {
        let json = """
        {"hz":50,"clips":{"old":{"frames":[[0,0,0,0,0,0,0,0,0,0,0,0,0,0]],
        "roots":[[0,0,0.1,1,0,0,0]],"policy":"x.onnx"}}}
        """
        let clips = try DuckIntentClip.decode(Data(json.utf8))
        let clip = try XCTUnwrap(clips["old"])
        XCTAssertTrue(clip.telemetry.isEmpty)
        XCTAssertTrue(clip.telemetry.actions.isEmpty)
    }
}

// MARK: - a rate is not something a recording can carry

final class DuckIntentSuccessTests: XCTestCase {

    func testEveryRolledOutIntentIsAlsoInTheCorpus() throws {
        let success = try DuckIntentSuccess.bundled()
        let clips = try DuckIntentClip.bundled()
        XCTAssertGreaterThan(success.intents.count, 0)
        for name in success.intents.keys {
            XCTAssertNotNil(clips[name], "\(name) has a rate and no recording")
        }
    }

    /// The rates must be counts of the rollouts actually performed — a rate
    /// over zero runs is not a rate, and one over more successes than runs is
    /// a decoding bug that would read as a very good policy.
    func testTheCountsAreWithinTheRollouts() throws {
        for (name, outcome) in try DuckIntentSuccess.bundled().intents {
            XCTAssertGreaterThan(outcome.rollouts, 0, name)
            XCTAssertLessThanOrEqual(outcome.achieves, outcome.rollouts, name)
            XCTAssertLessThanOrEqual(outcome.repeats, outcome.rollouts, name)
            XCTAssertFalse(outcome.criterion.isEmpty,
                           "\(name) has a rate with no stated criterion")
        }
    }

    /// The randomisation is quoted from Pollen's config, and the app shows it
    /// beside the rate — a robustness number with no distribution attached is
    /// not a measurement of anything.
    func testTheDistributionIsNamedAndAttributed() throws {
        let success = try DuckIntentSuccess.bundled()
        XCTAssertTrue(success.randomisation.source.contains("microduck_rl"))
        XCTAssertEqual(success.randomisation.lines.count, 4)
        XCTAssertTrue(success.randomisation.lines.contains { $0.contains("Footpad friction") })
    }

    /// The whole reason for two rates: a stair move ends upright reliably and
    /// gets up the flight never, and one number cannot say both.
    func testAStairMoveRepeatsWithoutAchieving() throws {
        let success = try DuckIntentSuccess.bundled()
        let climb = try XCTUnwrap(success["climb"])
        XCTAssertEqual(climb.achieves, 0,
                       "the measured 10 mm ceiling means it does not get up a flight")
        XCTAssertGreaterThan(climb.repeats, climb.rollouts / 2,
                             "it reliably ends where the recording ended, which is on the floor")
        XCTAssertTrue(climb.criterion.contains("on the flight"))
    }
}

// MARK: - a rate that is not a rate

extension DuckIntentClipTests {

    /// A shared file carrying `"hz": -50` crashed the player about twenty
    /// milliseconds after the clip opened — the playhead timer's first tick —
    /// because a negative rate makes a negative index and the bounds check was
    /// one-sided.
    func testANegativeRateCannotProduceANegativeIndex() {
        let clip = DuckIntentClip(
            name: "hostile", hz: -50,
            frames: [[Double](repeating: 0, count: DuckModel.policyJointCount),
                     [Double](repeating: 0, count: DuckModel.policyJointCount)],
            roots: [.init(x: 0, y: 0, z: 0.1, quaternion: (1, 0, 0, 0)),
                    .init(x: 0, y: 0, z: 0.1, quaternion: (1, 0, 0, 0))],
            netYaw: 0, loops: false, startsFrom: .standing, endsIn: .standing,
            policy: "x.onnx", authored: false, environment: .bareFloor)
        // Would have trapped. Every one of these must simply answer.
        for time in [0.0, 0.02, 0.5, 4.0, -1.0] {
            _ = clip.pose(at: time)
        }
        XCTAssertEqual(clip.pose(at: 0.02).jointAngles.count, DuckModel.jointCount)
    }

    func testAZeroRateDoesNotDivideOrTrap() {
        let clip = DuckIntentClip(
            name: "zero", hz: 0,
            frames: [[Double](repeating: 0, count: DuckModel.policyJointCount)],
            roots: [.init(x: 0, y: 0, z: 0.1, quaternion: (1, 0, 0, 0))],
            netYaw: 0, loops: true, startsFrom: .standing, endsIn: .standing,
            policy: "x.onnx", authored: false, environment: .bareFloor)
        _ = clip.pose(at: 1.0)
        XCTAssertTrue(clip.duration.isFinite)
    }

    /// And the decoder refuses it by name, because that is where a message can
    /// actually reach somebody.
    func testTheDecoderRefusesARateThatIsNotOne() {
        for bad in ["-50", "0"] {
            let json = """
            {"hz":\(bad),"clips":{"c":{"frames":[[0,0,0,0,0,0,0,0,0,0,0,0,0,0]],
            "roots":[[0,0,0.1,1,0,0,0]],"policy":"x.onnx"}}}
            """
            XCTAssertThrowsError(try DuckIntentClip.decode(Data(json.utf8)),
                                 "hz \(bad) must be refused") { error in
                guard case DuckIntentClip.LoadError.malformed(let why) = error else {
                    return XCTFail("wrong error for hz \(bad)")
                }
                XCTAssertTrue(why.contains("not a rate"), why)
            }
        }
    }
}
