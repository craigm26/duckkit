import XCTest
@testable import DuckKit

/// The choreography, checked on a machine with no duck attached.
///
/// THIS IS THE FILE THAT WOULD OTHERWISE ONLY BE TESTED BY WATCHING. A
/// performance is a pose per instant, and the two ways it can be wrong are
/// both invisible in an AR preview on a desk: a keyframe outside a servo's
/// travel looks fine on a ghost and stalls a real joint against its stop, and
/// a twist left commanded at the end of a held sound looks like nothing at all
/// until a real duck walks off the table while its noise fades out. Both are
/// arithmetic, so both are testable here, at 50 Hz, in milliseconds, with no
/// phone in the room — which is the whole argument for the timelines living in
/// a zero-dependency package instead of in an app's view layer.
final class DuckPerformanceTests: XCTestCase {

    /// The four head joints, in the order `DuckCommand.head` carries them.
    private let headJoints = ["neck_pitch", "head_pitch", "head_yaw", "head_roll"]

    private func headValues(_ frame: DuckPerformance.Keyframe) -> [Double] {
        [frame.neckPitch, frame.headPitch, frame.headYaw, frame.headRoll]
    }

    /// Every timeline in the kit: each sound whole, plus the three parts of
    /// the ride separately.
    private func everyTimeline() -> [DuckPerformance.Timeline] {
        DuckSound.allCases.flatMap { sound in
            DuckSound.Part.allCases
                .filter { sound.supports($0) }
                .map { DuckPerformance.timeline(for: sound, part: $0) }
        }
    }

    private func assertPose(
        _ actual: DuckPerformance.Pose, _ expected: DuckPerformance.Pose,
        accuracy: Double, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.command.twist.0, expected.command.twist.0, accuracy: accuracy,
                       message + " (forward)", file: file, line: line)
        XCTAssertEqual(actual.command.twist.1, expected.command.twist.1, accuracy: accuracy,
                       message + " (left)", file: file, line: line)
        XCTAssertEqual(actual.command.twist.2, expected.command.twist.2, accuracy: accuracy,
                       message + " (yaw)", file: file, line: line)
        XCTAssertEqual(actual.command.head.0, expected.command.head.0, accuracy: accuracy,
                       message + " (neck_pitch)", file: file, line: line)
        XCTAssertEqual(actual.command.head.1, expected.command.head.1, accuracy: accuracy,
                       message + " (head_pitch)", file: file, line: line)
        XCTAssertEqual(actual.command.head.2, expected.command.head.2, accuracy: accuracy,
                       message + " (head_yaw)", file: file, line: line)
        XCTAssertEqual(actual.command.head.3, expected.command.head.3, accuracy: accuracy,
                       message + " (head_roll)", file: file, line: line)
        XCTAssertEqual(actual.command.bodyZ, expected.command.bodyZ, accuracy: accuracy,
                       message + " (bodyZ)", file: file, line: line)
        XCTAssertEqual(actual.command.bodyRoll, expected.command.bodyRoll, accuracy: accuracy,
                       message + " (bodyRoll)", file: file, line: line)
        XCTAssertEqual(actual.command.bodyPitch, expected.command.bodyPitch, accuracy: accuracy,
                       message + " (bodyPitch)", file: file, line: line)
        XCTAssertEqual(actual.mouth, expected.mouth, accuracy: accuracy,
                       message + " (mouth)", file: file, line: line)
    }

    // ── the envelope the hardware imposes ────────────────────────────────

    /// No keyframe may ask for a head angle the joint cannot reach — checked
    /// twice, as an absolute target and as an offset from the home pose,
    /// because nothing available to this package settles which one robotd
    /// composes the head command as. Legal under both readings is the only
    /// claim that can be made honestly from here, and it is the claim these
    /// tables are written to satisfy.
    func testEveryKeyframeStaysInsideJointTravelUnderEitherReading() {
        for timeline in everyTimeline() {
            for frame in timeline.keyframes {
                let values = headValues(frame)
                for (slot, name) in headJoints.enumerated() {
                    let joint = DuckModel.jointIndex(of: name)!
                    let travel = DuckModel.jointRanges[joint]
                    let commanded = values[slot]
                    let label = "\(timeline.sound.tag).\(timeline.part.rawValue) at \(frame.time)s, \(name)"
                    XCTAssertGreaterThanOrEqual(commanded, travel.lower, "\(label) below travel")
                    XCTAssertLessThanOrEqual(commanded, travel.upper, "\(label) above travel")

                    let absolute = DuckModel.homePose[joint] + commanded
                    XCTAssertGreaterThanOrEqual(absolute, travel.lower,
                                                "\(label) below travel read as an offset from home")
                    XCTAssertLessThanOrEqual(absolute, travel.upper,
                                             "\(label) above travel read as an offset from home")
                }
            }
        }
    }

    /// The mouth is a fraction, not an angle, and every fraction has to land
    /// inside the beak's −5°…+30° once `DuckModel` converts it. A keyframe
    /// carrying 1.2 would be silently clamped and the gesture would arrive
    /// looking almost right, which is the worst way for it to be wrong.
    func testEveryMouthFractionIsAFractionAndLandsInsideTheBeaksTravel() {
        for timeline in everyTimeline() {
            for frame in timeline.keyframes {
                let label = "\(timeline.sound.tag).\(timeline.part.rawValue) at \(frame.time)s"
                XCTAssertGreaterThanOrEqual(frame.mouth, 0, "\(label): negative beak")
                XCTAssertLessThanOrEqual(frame.mouth, 1, "\(label): beak past wide open")
                let angle = DuckModel.mouthTarget(open: frame.mouth)
                XCTAssertGreaterThanOrEqual(angle, DuckModel.mouthClosed, "\(label)")
                XCTAssertLessThanOrEqual(angle, DuckModel.mouthOpen, "\(label)")
            }
        }
        XCTAssertEqual(DuckPerformance.timeline(for: .alarm).keyframes.map(\.mouth).max() ?? 0, 0.95,
                       accuracy: 1e-12, "the alarm opens widest — a honk is not a mumble")
    }

    /// Body offsets stay small. There is no published bound on the command's
    /// body block, so these tables stay inside one that can be defended from
    /// geometry instead: the trunk sits 12 cm up in the vendored MuJoCo
    /// model, and nothing here moves it by more than 3 cm, a quarter of that.
    func testTheBodyOffsetsStaySmallAgainstTheTrunkHeight() {
        let trunkHeight = DuckKinematics.bodies.first { $0.parent == nil }!.position.z
        XCTAssertEqual(trunkHeight, 0.12, accuracy: 1e-9, "the model's trunk height, in metres")
        let bound = trunkHeight / 4

        for timeline in everyTimeline() {
            for frame in timeline.keyframes {
                let label = "\(timeline.sound.tag).\(timeline.part.rawValue) at \(frame.time)s"
                XCTAssertLessThanOrEqual(abs(frame.bodyZ), bound, "\(label): bodyZ past a quarter of the trunk height")
                XCTAssertLessThanOrEqual(abs(frame.bodyRoll), 0.15, "\(label): bodyRoll")
                XCTAssertLessThanOrEqual(abs(frame.bodyPitch), 0.15, "\(label): bodyPitch")
            }
        }
    }

    // ── the twist threshold ──────────────────────────────────────────────

    /// A NOISE IS A GESTURE, NOT A DRIVE COMMAND — except the ride, which
    /// says so. `DuckGait.locomotion` picks the walking network the moment a
    /// twist passes 0.05, so a performance that put a stray velocity in its
    /// command block would switch policies mid-gesture and the duck would set
    /// off across the table while quacking. Six of the seven never come near
    /// it; `wheee` crosses it deliberately, and crosses back.
    func testOnlyTheRideEverCrossesTheStandingThreshold() {
        let step = 1.0 / DuckModel.tickHz
        for sound in DuckSound.allCases {
            let timeline = DuckPerformance.timeline(for: sound)
            var walked = false
            var peak = 0.0
            var time = 0.0
            while time <= timeline.duration {
                let command = timeline.pose(at: time).command
                peak = max(peak, command.twistMagnitude)
                if DuckGait.locomotion(for: command) == .walk { walked = true }
                time += step
            }
            if sound == .wheee {
                XCTAssertTrue(walked, "the ride is the one performance that means to move the duck")
                XCTAssertEqual(peak, 0.60, accuracy: 1e-9, "a slow spin: 2π/0.6 ≈ 10.5 s for a full turn")
                XCTAssertGreaterThan(peak, DuckModel.standingThreshold * 10,
                                     "and unambiguously above the threshold, not hovering on it")
            } else {
                XCTAssertFalse(walked, "\(sound.tag) must never select the walking policy")
                XCTAssertEqual(peak, 0, accuracy: 1e-12,
                               "\(sound.tag) commands no velocity at all, not merely a small one")
            }
        }
    }

    /// Every performance opens and closes on the neutral pose. This is what
    /// makes a sound safe to schedule: however it ends — played out,
    /// interrupted, decayed — the duck is standing still with its beak shut.
    func testEveryPerformanceStartsAndEndsNeutral() {
        for sound in DuckSound.allCases {
            let timeline = DuckPerformance.timeline(for: sound)
            XCTAssertEqual(timeline.pose(at: 0), .neutral, "\(sound.tag) does not start from rest")
            XCTAssertEqual(timeline.pose(at: timeline.duration), .neutral, "\(sound.tag) does not return to rest")
            XCTAssertEqual(timeline.duration, sound.nominalDuration, accuracy: 1e-12,
                           "\(sound.tag)'s gesture must last exactly as long as its noise")
            XCTAssertEqual(timeline.keyframes.last!.time, sound.duration(of: .whole), accuracy: 1e-9,
                           "\(sound.tag)'s last keyframe is the end of the sound")
        }
    }

    // ── the ride's seams ─────────────────────────────────────────────────

    /// The ride's four joins carry the same pose: the end of the start part,
    /// both ends of the loop, and the beginning of the end part. If they
    /// differed the body would jump every half second for as long as somebody
    /// held the button — the identical rule the voice's loop obeys, and the
    /// reason both are written from one `rideSeam`.
    func testTheRideSeamIsTheSamePoseAtAllFourJoins() {
        let start = DuckPerformance.timeline(for: .wheee, part: .start)
        let loop = DuckPerformance.timeline(for: .wheee, part: .loop)
        let end = DuckPerformance.timeline(for: .wheee, part: .end)

        let seam = start.pose(at: start.duration)
        XCTAssertEqual(loop.pose(at: 0), seam, "the loop must pick up exactly where the start left off")
        XCTAssertEqual(loop.pose(at: loop.duration), seam, "and arrive back at it, so it can repeat")
        XCTAssertEqual(end.pose(at: 0), seam, "and the end must begin from it")
        XCTAssertNotEqual(seam, .neutral, "the seam is mid-ride; if it were neutral this would prove nothing")
        XCTAssertEqual(end.pose(at: end.duration), .neutral, "and only the end returns to rest")
    }

    /// `.whole` of the ride is its three parts laid end to end. Sampled
    /// against a straight-through `pose(_:elapsed:)`, which drives the same
    /// three parts through the hold state machine instead — two routes to the
    /// same pose, which is what stops a preview and a real ride from drifting.
    func testTheWholeRideIsItsThreePartsPlayedThroughOnce() {
        let timeline = DuckPerformance.timeline(for: .wheee)
        XCTAssertEqual(timeline.duration, 1.10, accuracy: 1e-12, "start 0.24 + loop 0.50 + end 0.36")

        var time = 0.0
        while time <= 1.10 {
            assertPose(DuckPerformance.pose(.wheee, elapsed: time), timeline.pose(at: time),
                       accuracy: 1e-9, "the ride diverged from its own timeline at \(time)s")
            time += 0.01
        }
    }

    // ── interpolation ────────────────────────────────────────────────────

    /// Linear between keyframes, clamped outside them, and unbothered by a
    /// clock that came back from a stall carrying a NaN.
    func testPosesInterpolateLinearlyAndClampAtBothEnds() {
        let chirp = DuckPerformance.timeline(for: .chirp)
        // Keyframes at 0.05 (mouth 0.70) and 0.16 (mouth 0.25).
        XCTAssertEqual(chirp.pose(at: 0.05).mouth, 0.70, accuracy: 1e-12)
        XCTAssertEqual(chirp.pose(at: 0.16).mouth, 0.25, accuracy: 1e-12)
        XCTAssertEqual(chirp.pose(at: 0.105).mouth, 0.475, accuracy: 1e-9,
                       "halfway between two keyframes is the average of them")

        XCTAssertEqual(chirp.pose(at: -5), .neutral, "before the start, hold the first pose")
        XCTAssertEqual(chirp.pose(at: 99), .neutral, "after the end, hold the last one — never extrapolate")
        XCTAssertEqual(chirp.pose(at: .nan), chirp.pose(at: 0),
                       "a NaN clock reads as the opening pose rather than as an unchecked index")
    }

    // ── hold and decay ───────────────────────────────────────────────────

    /// A one-shot ignores holds, because robotd ignores them too: a UI that
    /// keeps a finger on a `chirp` button should behave like the robot rather
    /// than invent a sound the robot cannot make.
    func testAOneShotFinishesOnTimeNoMatterHowHardItIsHeld() {
        var playback = DuckPerformance.Playback(.chirp, at: 0)
        for beat in 0..<50 { playback.hold(at: Double(beat) * DuckSound.holdInterval) }
        XCTAssertEqual(playback.lastHoldAt, 0, "a one-shot has nothing to hold")
        XCTAssertEqual(playback.stage(at: 0.1).part, DuckSound.Part.whole)
        XCTAssertFalse(playback.isFinished(at: 0.29), "chirp lasts 0.30 s")
        XCTAssertTrue(playback.isFinished(at: 0.31), "and not a tick longer for being held")
        XCTAssertEqual(playback.pose(at: 0.31), .neutral, "finished means neutral")
    }

    /// The clock's origin is the caller's business. A playback started at
    /// zero and one started at some arbitrary monotonic timestamp have to
    /// behave identically, because on a phone the second one is what actually
    /// happens.
    func testAPlaybackHasNoOpinionAboutWhatTimeItIs() {
        let origin = 12_345.678
        var fromZero = DuckPerformance.Playback(.wheee, at: 0)
        var fromOrigin = DuckPerformance.Playback(.wheee, at: origin)
        for step in 0..<20 {
            let elapsed = Double(step) * 0.05
            fromZero.hold(at: elapsed)
            fromOrigin.hold(at: origin + elapsed)
            assertPose(fromOrigin.pose(at: origin + elapsed), fromZero.pose(at: elapsed),
                       accuracy: 1e-9, "the same ride at a different clock origin at \(elapsed)s")
        }
    }

    /// Holds keep the loop going indefinitely, which is the point of a held
    /// tag: five seconds of ride is ten loops, not ten sounds.
    func testTheRideLoopsForAsLongAsHoldsKeepArriving() {
        var playback = DuckPerformance.Playback(.wheee, at: 0)
        // Holds counted rather than accumulated: fifty times 0.1 is exactly
        // five seconds, where fifty additions of 0.1 is not.
        for beat in 1...50 {
            let time = Double(beat) * DuckSound.holdInterval
            playback.hold(at: time)
            if time > DuckSound.wheee.duration(of: .start) {
                XCTAssertEqual(playback.stage(at: time).part, DuckSound.Part.loop,
                               "still riding at \(time)s")
            }
        }
        XCTAssertFalse(playback.isFinished(at: 5.0), "five seconds in, still going")
        XCTAssertGreaterThan(5.0, DuckSound.wheee.nominalDuration * 4,
                             "and that is several times longer than one straight-through ride")

        // The loop position wraps rather than running away: at 5 s the ride
        // has been looping for 5 − 0.24 s, which is 9 whole loops and change.
        guard case .playing(let part, let elapsed) = playback.stage(at: 5.0) else {
            return XCTFail("the ride should still be playing")
        }
        XCTAssertEqual(part, DuckSound.Part.loop)
        XCTAssertGreaterThanOrEqual(elapsed, 0)
        XCTAssertLessThan(elapsed, DuckSound.wheee.duration(of: .loop),
                          "the loop clock wraps; it does not accumulate")
    }

    /// THE DEADMAN. Stop sending holds — because the app was backgrounded,
    /// the phone left the network, or the rider was dropped in a pond — and
    /// the ride ends on its own half a second later, exactly as robotd would
    /// end it. Nothing has to notice; nothing has to be cancelled.
    func testTheRideDecaysHalfASecondAfterTheLastHold() {
        var playback = DuckPerformance.Playback(.wheee, at: 0)
        for beat in 1...20 { playback.hold(at: Double(beat) * DuckSound.holdInterval) }
        XCTAssertEqual(playback.lastHoldAt, 2.0, accuracy: 1e-9)
        XCTAssertNil(playback.releasedAt, "nobody let go — the holds simply stopped")
        XCTAssertEqual(playback.endBegins, 2.5, accuracy: 1e-9, "the deadman is half a second")

        XCTAssertEqual(playback.stage(at: 2.4).part, DuckSound.Part.loop, "still looping inside the window")
        XCTAssertEqual(playback.stage(at: 2.7).part, DuckSound.Part.end, "and decaying after it")
        XCTAssertFalse(playback.isFinished(at: 2.8), "the end part is 0.36 s long")
        XCTAssertTrue(playback.isFinished(at: 2.9), "so by 2.86 s the ride is over")
    }

    /// A ride that decays leaves the duck standing still. This is the failure
    /// the whole hold-and-decay design exists to prevent: a twist still
    /// commanded after the sound has gone is a duck walking away from a
    /// phone that is no longer talking to it.
    func testADecayedRideLeavesTheDuckStandingStill() {
        var playback = DuckPerformance.Playback(.wheee, at: 0)
        for beat in 1...20 { playback.hold(at: Double(beat) * DuckSound.holdInterval) }

        var time = 2.0
        while time <= 6.0 {
            let pose = playback.pose(at: time)
            XCTAssertLessThanOrEqual(pose.command.twistMagnitude, 0.6 + 1e-9,
                                     "the ride must never command more than it started with, at \(time)s")
            if time >= 2.9 {
                XCTAssertEqual(pose, .neutral, "after the decay the duck is neutral, at \(time)s")
                XCTAssertEqual(DuckGait.locomotion(for: pose.command), .stand,
                               "and standing, at \(time)s")
            }
            time += 1.0 / DuckModel.tickHz
        }
        XCTAssertTrue(playback.isFinished(at: 6.0))
    }

    /// Letting go early ends the ride early, but it cannot cut the take-off
    /// short: the duck has already drawn breath. The loop simply gets no time.
    func testReleasingDuringTheTakeOffStillPlaysTheWholeStart() {
        var playback = DuckPerformance.Playback(.wheee, at: 0)
        playback.release(at: 0.05)
        XCTAssertEqual(playback.releasedAt ?? -1, DuckSound.wheee.duration(of: .start), accuracy: 1e-12,
                       "the earliest an end can begin is where the start finishes")
        XCTAssertEqual(playback.stage(at: 0.10).part, DuckSound.Part.start, "the take-off plays out")
        XCTAssertEqual(playback.stage(at: 0.30).part, DuckSound.Part.end, "then straight to the landing")
        XCTAssertTrue(playback.isFinished(at: 0.61), "0.24 + 0.36 = 0.60 s of ride")

        // And a hold arriving after the release changes nothing: the rider
        // let go, and a late packet does not un-let-go.
        playback.hold(at: 0.5)
        XCTAssertEqual(playback.releasedAt ?? -1, DuckSound.wheee.duration(of: .start), accuracy: 1e-12)
        XCTAssertTrue(playback.isFinished(at: 0.61))
    }

    /// Holds that arrive out of order never move the deadline backwards. Over
    /// a network they will arrive out of order, and a stale hold that shortened
    /// the ride would read as a random stutter nobody could reproduce.
    func testAStaleHoldCannotShortenTheRide() {
        var playback = DuckPerformance.Playback(.wheee, at: 0)
        playback.hold(at: 1.0)
        playback.hold(at: 0.4)  // late delivery of an older hold
        XCTAssertEqual(playback.lastHoldAt, 1.0, accuracy: 1e-12,
                       "the newest hold stands; an older one arriving late is not news")
        XCTAssertEqual(playback.endBegins, 1.5, accuracy: 1e-9)
    }
}
